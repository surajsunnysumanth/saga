import Foundation
import SagaCore

/// Reads link titles and covers once per link, ever.
///
/// The Gallery can show hundreds of links at a time and there is no bulk endpoint, so each
/// card asks for its own metadata as it scrolls into view. Answers land in the same
/// `link_meta.db` the chat's Media tab uses, and a second ask for the same link joins the
/// first request in flight instead of repeating it.
/// A counting semaphore, so a grid of cards cannot open fifty connections at once.
private actor Gate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ slots: Int) { available = slots }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

actor LinkMetaLoader {
    static let shared = LinkMetaLoader()

    private var cache: LinkMetaCache?
    private var inflight: [String: Task<LinkMeta?, Never>] = [:]
    private var failures: Set<String> = []
    private let gate = Gate(4)

    private func db() -> LinkMetaCache? {
        if cache == nil {
            let path = AppModel.supportDir.appendingPathComponent("link_meta.db").path
            cache = try? LinkMetaCache(path: path)
        }
        return cache
    }

    /// Cached first, network second. A link that already failed is not retried for the rest
    /// of the session, so a dead link cannot hammer a service on every scroll.
    func meta(for link: SharedLink) async -> LinkMeta? {
        if let hit = db()?.get(link.key) { return hit }
        if failures.contains(link.key) { return nil }
        if let running = inflight[link.key] { return await running.value }

        let task = Task<LinkMeta?, Never> { [link] in
            await gate.acquire()
            let result = await MediaLinks.fetchMeta(link)
            await gate.release()
            return result
        }
        inflight[link.key] = task
        let result = await task.value
        inflight[link.key] = nil

        if let result, !result.title.isEmpty {
            db()?.put(link.key, result)
            return result
        }
        failures.insert(link.key)
        return nil
    }
}
