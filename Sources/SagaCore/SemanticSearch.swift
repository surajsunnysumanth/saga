import Foundation
import NaturalLanguage

/// A local embedding model: turns text into one vector each. Everything here runs on this Mac — Apple's built-in
/// sentence embeddings or an Ollama model already installed on the loopback server. Nothing is downloaded and nothing
/// leaves the machine.
protocol EmbeddingEngine: Sendable {
    /// Provider, model/revision, language and preprocessing version. Vectors from two identities are never compared.
    var identity: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct SemanticError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Which local embedding model to use. Persisted as a tag so the choice survives a restart.
public enum SemanticEmbeddingChoice: Sendable, Equatable, Hashable {
    case apple
    case ollama(model: String)

    public var title: String {
        switch self {
        case .apple: return "Apple on-device"
        case .ollama(let model): return "Ollama · \(model)"
        }
    }
    public var tag: String {
        switch self {
        case .apple: return "apple"
        case .ollama(let model): return "ollama|\(model)"
        }
    }
    public static func from(tag: String) -> SemanticEmbeddingChoice? {
        if tag == "apple" { return .apple }
        let p = tag.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if p.count == 2, p[0] == "ollama", !p[1].isEmpty { return .ollama(model: p[1]) }
        return nil
    }
}

/// A detected embedding model, ready to embed. Detection is explicit (the user turns meaning search on or presses
/// "Look again"); nothing is probed at launch.
public struct SemanticProvider: Sendable {
    public let choice: SemanticEmbeddingChoice
    public let identity: String
    public let dimensions: Int
    let engine: any EmbeddingEngine

    public var title: String { choice.title }

    func embed(_ texts: [String]) async throws -> [[Float]] { try await engine.embed(texts) }
}

/// Counts for a visible build: eligible messages, not batches.
public struct SemanticIndexProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let reused: Int
    public let embedded: Int
    public let skipped: Int
    public let finished: Bool
    public init(completed: Int, total: Int, reused: Int, embedded: Int = 0, skipped: Int = 0, finished: Bool = false) {
        self.completed = completed; self.total = total; self.reused = reused
        self.embedded = embedded; self.skipped = skipped; self.finished = finished
    }
}

public struct SemanticIndexSummary: Sendable, Equatable {
    public let total: Int
    public let embedded: Int
    public let reused: Int
    public let skipped: Int
    public let complete: Bool
}

/// How much of the archive the local vector cache covers for one embedding model.
public enum SemanticCoverage: Sendable, Equatable {
    /// Nothing in the archive can be embedded yet.
    case empty
    /// No index has been built for this archive and model.
    case missing
    /// A build was stopped or interrupted; `indexed` of `total` messages are ready.
    case partial(indexed: Int, total: Int)
    /// A finished index exists, but the archive changed since (messages added, pruned or renamed).
    case stale(indexed: Int, total: Int)
    /// Ready to use for the current archive.
    case current(total: Int)
}

/// A ranked uid and its cosine similarity. Scores are only comparable inside one embedding identity.
public struct SemanticHit: Sendable, Equatable {
    public let uid: String
    public let score: Double
    public init(uid: String, score: Double) { self.uid = uid; self.score = score }
}

/// What a hybrid Ask retrieval produced: the messages to hand the model, in the order the budget should be spent, plus
/// how many seeds each retriever contributed.
public struct SemanticRetrieval: Sendable {
    public let ordered: [VaultStore.ContextMessage]
    public let keywordSeeds: Int
    public let semanticSeeds: Int
}

/// On-device meaning search: an incremental local vector index keyed by message uid, and the hybrid (keyword + meaning)
/// retrieval Ask uses when the user opts in. The index is built only when the user presses Build; a stopped build keeps
/// the work it finished and resumes by input hash.
public struct SemanticSearch: Sendable {
    public let indexPath: String
    public let archiveScope: String
    public let store: SemanticStore
    public let provider: SemanticProvider

    public init(indexPath: String, archiveScope: String, store: SemanticStore, provider: SemanticProvider) {
        self.indexPath = indexPath; self.archiveScope = archiveScope; self.store = store; self.provider = provider
    }

    /// Test seam: any `EmbeddingEngine` can stand in for a real model.
    init(indexPath: String, archiveScope: String, store: SemanticStore, engine: any EmbeddingEngine, choice: SemanticEmbeddingChoice = .apple) {
        self.init(indexPath: indexPath, archiveScope: archiveScope, store: store,
                  provider: SemanticProvider(choice: choice, identity: engine.identity, dimensions: engine.dimensions, engine: engine))
    }

    // MARK: input handling

    static let preprocessing = "p1"
    /// Fixed batch so a huge archive advances in visible steps and a stopped build loses at most one batch.
    static let buildBatch = 32
    static let scanPage = 500
    static let inputClip = 600

    /// Identical preprocessing for stored messages and the question: collapse whitespace, trim, clip. It is part of the
    /// embedding identity, so changing it invalidates old vectors instead of mixing spaces.
    static func embeddingInput(_ text: String) -> String {
        let squeezed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return squeezed.count > inputClip ? String(squeezed.prefix(inputClip)) : squeezed
    }
    static func inputHash(_ text: String) -> String { LocalAI.hash("semantic", preprocessing, embeddingInput(text)) }

    static func isUsable(_ v: [Float], dim: Int) -> Bool {
        guard dim > 0, v.count == dim else { return false }
        var nonzero = false
        for x in v {
            guard x.isFinite else { return false }
            if x != 0 { nonzero = true }
        }
        return nonzero
    }

    /// Cosine similarity; nil for mismatched, empty, zero or non-finite vectors.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        return b.withUnsafeBytes { cosine(a, $0) }
    }

    /// Cosine against a stored blob, without copying the stored vector into an array.
    static func cosine(_ a: [Float], _ b: UnsafeRawBufferPointer) -> Double? {
        let n = b.count / MemoryLayout<Float>.size
        guard n == a.count, n > 0, let base = b.baseAddress else { return nil }
        let v = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: n)
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            let x = Double(a[i]), y = Double(v[i])
            guard x.isFinite, y.isFinite else { return nil }
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return nil }
        let score = dot / (na.squareRoot() * nb.squareRoot())
        return score.isFinite ? score : nil
    }

    /// Deterministic order: score, then uid. Two runs over the same vectors return the same ranking.
    static func ranked(_ hits: [SemanticHit], limit: Int) -> [SemanticHit] {
        let sorted = hits.sorted { l, r in
            if l.score != r.score { return l.score > r.score }
            return l.uid < r.uid
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    // MARK: fusion

    /// Reciprocal rank fusion of the two seed lists: `sum(1 / (60 + rank))`, ranks starting at 1. A uid found by both
    /// retrievers naturally outranks one found by only one; equal scores break by uid, so the order is stable.
    public static func fuse(fts: [String], semantic: [SemanticHit], limit: Int = 30) -> [SemanticHit] {
        var scores: [String: Double] = [:]
        for (i, uid) in fts.enumerated() where !uid.isEmpty { scores[uid, default: 0] += 1 / (60 + Double(i + 1)) }
        for (i, hit) in semantic.enumerated() where !hit.uid.isEmpty { scores[hit.uid, default: 0] += 1 / (60 + Double(i + 1)) }
        return ranked(scores.map { SemanticHit(uid: $0.key, score: $0.value) }, limit: limit)
    }

    // MARK: coverage

    /// Index file identity: if the library is rebuilt while a build runs, its row ids and uids may both change, so the
    /// run is discarded rather than written into a different archive.
    public static func indexStamp(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let ino = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(ino)|\(size)|\(mtime)"
    }

    public func coverage() throws -> SemanticCoverage {
        let vault = try VaultStore(path: indexPath)
        let total = try vault.semanticEligibleCount()
        guard total > 0 else { return .empty }
        guard let c = store.coverage(scope: archiveScope, identity: provider.identity) else { return .missing }
        let indexed = store.count(scope: archiveScope, identity: provider.identity)
        if !c.complete { return .partial(indexed: indexed, total: total) }
        // A rebuilt index can keep the same eligible count while its rows (and membership) changed. The generation
        // stamp catches that; older cache rows have no stamp and fall back to the count check.
        if let recorded = c.stamp, recorded != Self.indexStamp(indexPath) { return .stale(indexed: indexed, total: total) }
        if c.total != total || indexed + c.skipped < total { return .stale(indexed: indexed, total: total) }
        return .current(total: total)
    }

    // MARK: build

    /// Embeds every eligible message that has no usable vector yet. Reused vectors are matched by uid + input hash, so a
    /// stopped run resumes where it left off and changed text is re-embedded. Vectors for messages that no longer exist
    /// in the visible index are dropped at the end of a complete scan.
    @discardableResult
    public func build(progress: @Sendable (SemanticIndexProgress) -> Void = { _ in }) async throws -> SemanticIndexSummary {
        let vault = try VaultStore(path: indexPath)
        let total = try vault.semanticEligibleCount()
        let scope = archiveScope, identity = provider.identity, dim = provider.dimensions
        let stamp = Self.indexStamp(indexPath)
        guard total > 0 else {
            store.saveCoverage(scope: scope, identity: identity, total: 0, indexed: 0, skipped: 0, complete: true, stamp: stamp)
            progress(SemanticIndexProgress(completed: 0, total: 0, reused: 0, finished: true))
            return SemanticIndexSummary(total: 0, embedded: 0, reused: 0, skipped: 0, complete: true)
        }
        var completed = 0, reused = 0, embedded = 0, skipped = 0
        var seen = Set<String>(); seen.reserveCapacity(total)
        let existing = store.existingHashes(scope: scope, identity: identity)
        var batch: [(row: VaultStore.SemanticText, hash: String)] = []

        func flush() async throws {
            guard !batch.isEmpty else { return }
            try Task.checkCancellation()
            let texts = batch.map { Self.embeddingInput($0.row.text) }
            let vectors = try await provider.embed(texts)
            var records: [SemanticStore.Record] = []
            records.reserveCapacity(batch.count)
            for (i, item) in batch.enumerated() {
                let v = i < vectors.count ? vectors[i] : []
                if Self.isUsable(v, dim: dim) {
                    records.append(.init(uid: item.row.uid, hash: item.hash, dim: dim, vector: v))
                } else {
                    skipped += 1                       // unembeddable input: counted once, never retried in a loop
                }
            }
            try Task.checkCancellation()
            store.upsert(scope: scope, identity: identity, records: records)
            embedded += records.count
            batch.removeAll(keepingCapacity: true)
            progress(SemanticIndexProgress(completed: completed, total: total, reused: reused, embedded: embedded, skipped: skipped))
        }

        do {
            var afterTs = Int64.min, afterId = Int64.min
            while true {
                try Task.checkCancellation()
                let page = try vault.semanticScanPage(afterTs: afterTs, afterId: afterId, limit: Self.scanPage)
                if page.rows.isEmpty { break }
                for row in page.rows {
                    completed += 1
                    seen.insert(row.uid)
                    let h = Self.inputHash(row.text)
                    if let e = existing[row.uid], e.hash == h, e.dim == dim { reused += 1; continue }
                    batch.append((row, h))
                    if batch.count >= Self.buildBatch { try await flush() }
                }
                afterTs = page.lastTs; afterId = page.lastId
                progress(SemanticIndexProgress(completed: completed, total: total, reused: reused, embedded: embedded, skipped: skipped))
            }
            try await flush()
            try Task.checkCancellation()
            store.reconcile(scope: scope, identity: identity, keeping: seen)
            store.saveCoverage(scope: scope, identity: identity, total: total,
                               indexed: store.count(scope: scope, identity: identity), skipped: skipped, complete: true, stamp: stamp)
            progress(SemanticIndexProgress(completed: total, total: total, reused: reused, embedded: embedded, skipped: skipped, finished: true))
            return SemanticIndexSummary(total: total, embedded: embedded, reused: reused, skipped: skipped, complete: true)
        } catch {
            store.saveCoverage(scope: scope, identity: identity, total: total,
                               indexed: store.count(scope: scope, identity: identity), skipped: skipped, complete: false, stamp: stamp)
            throw error
        }
    }

    // MARK: search

    /// Ranks every stored vector of this archive against the question. Unresolved rows are filtered later by the caller.
    public func search(_ question: String, chat: Int64? = nil, limit: Int = 30) async throws -> [SemanticHit] {
        let vault = try VaultStore(path: indexPath)
        return try await search(question, chat: chat, limit: limit, vault: vault)
    }

    func search(_ question: String, chat: Int64?, limit: Int, vault: VaultStore) async throws -> [SemanticHit] {
        let input = Self.embeddingInput(question)
        guard !input.isEmpty else { return [] }
        let raw = try await provider.embed([input])
        guard let q = raw.first, Self.isUsable(q, dim: provider.dimensions) else {
            throw SemanticError("The embedding model couldn't read that question. Try rephrasing it, or switch meaning search off.")
        }
        let allowed = try chat.map { try vault.semanticChatUIDs(chat: $0) }
        if let allowed, allowed.isEmpty { return [] }
        var hits: [SemanticHit] = []
        var seen = 0
        try store.scan(scope: archiveScope, identity: provider.identity) { uid, _, dim, vector in
            seen += 1
            if seen % 2000 == 0 { try Task.checkCancellation() }
            guard dim == q.count else { return true }
            if let allowed, !allowed.contains(uid) { return true }
            guard let score = Self.cosine(q, vector), score > 0 else { return true }   // unrelated vectors never become hits
            hits.append(SemanticHit(uid: uid, score: score))
            return true
        }
        try Task.checkCancellation()
        return Self.ranked(hits, limit: limit)
    }

    /// Hybrid retrieval for Ask: ranked keyword seeds and ranked meaning seeds fused by uid, then bounded same-chat
    /// neighbours. Seeds come first in `ordered`, so a model budget spent in order always covers the best evidence from
    /// both retrievers before any chat's surrounding messages.
    public func retrieve(question: String, chat: Int64?, limit: Int = 30, store vault: VaultStore, context: Int = 2) async throws -> SemanticRetrieval {
        let semantic = try await search(question, chat: chat, limit: limit, vault: vault)
        let fts = try vault.semanticFTSSearch(question: question, chat: chat, limit: 30)
        let fused = Self.fuse(fts: fts, semantic: semantic, limit: 30)
        let seedUIDs = fused.map(\.uid)
        let rows = try vault.semanticMessages(uids: seedUIDs, chat: chat)
        var byUID: [String: VaultStore.ContextMessage] = [:]
        for r in rows { byUID[r.uid] = r }

        var ordered: [VaultStore.ContextMessage] = [], used = Set<Int64>()
        for uid in seedUIDs {
            guard let m = byUID[uid] else { continue }          // pruned or merged away: never cite a recycled row
            if used.insert(m.id).inserted { ordered.append(m) }
        }
        guard !ordered.isEmpty else {
            return SemanticRetrieval(ordered: [], keywordSeeds: fts.count, semanticSeeds: semantic.count)
        }
        if context > 0 {
            try Task.checkCancellation()
            for seed in ordered.prefix(12) {
                for n in try vault.semanticNeighbours(seedMessageID: seed.id, chatID: seed.chatID, before: context, after: context)
                where used.insert(n.id).inserted {
                    ordered.append(n)
                }
            }
        }
        return SemanticRetrieval(ordered: ordered, keywordSeeds: fts.count, semanticSeeds: semantic.count)
    }

    // MARK: providers

    /// Finds usable on-device embedding models: Apple's sentence embeddings when the OS has them, and Ollama models whose
    /// name says they embed, from the loopback server only. A model that fails a one-word probe is not offered.
    public static func providers() async -> [SemanticProvider] {
        var out: [SemanticProvider] = []
        if let apple = AppleSentenceEmbedding() {
            out.append(SemanticProvider(choice: .apple, identity: apple.identity, dimensions: apple.dimensions, engine: apple))
        }
        for model in await OllamaEmbedding.installedModels() {
            if let p = await OllamaEmbedding.provider(model: model) { out.append(p) }
        }
        return out
    }
}

// MARK: - Apple sentence embeddings

/// Apple's built-in sentence embeddings (`NLEmbedding`). This is a local language asset that ships with the OS: Saga never
/// downloads one, and when it is missing this provider is simply not offered.
final class AppleSentenceEmbedding: EmbeddingEngine, @unchecked Sendable {
    let identity: String
    let dimensions: Int
    private let embedding: NLEmbedding

    init?() {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let d = e.dimension
        guard d > 0 else { return nil }
        embedding = e
        dimensions = d
        identity = "apple.nl.sentence|en|\(d)|\(SemanticSearch.preprocessing)"
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts {
            try Task.checkCancellation()
            out.append(embedding.vector(for: t)?.map(Float.init) ?? [])   // [] = unembeddable, counted as skipped
        }
        return out
    }
}

// MARK: - Ollama (loopback only)

/// Embeddings from an Ollama server on this Mac. The address is fixed to loopback and redirects are refused, so a
/// misconfigured or hostile server can never forward message text off the machine.
final class OllamaEmbedding: EmbeddingEngine, @unchecked Sendable {
    static let base = "http://127.0.0.1:11434"
    static let probe = "hello"

    let model: String
    let dimensions: Int
    let identity: String

    init(model: String, dimensions: Int) {
        self.model = model
        self.dimensions = dimensions
        identity = "ollama|\(model)|\(dimensions)|\(SemanticSearch.preprocessing)"
    }

    /// Only localhost is ever contacted; a URL that is not loopback is refused before any request is made.
    nonisolated(unsafe) static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c, delegate: LoopbackOnlyRedirects(), delegateQueue: nil)
    }()

    static func installedModels() async -> [String] {
        guard let url = URL(string: base + "/api/tags"), let host = url.host, host == "127.0.0.1" else { return [] }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }.filter { $0.lowercased().contains("embed") }.sorted()
    }

    static func provider(model: String) async -> SemanticProvider? {
        let engine = OllamaEmbedding(model: model, dimensions: 0)
        guard let v = try? await engine.probeDimensions(), v > 0 else { return nil }
        let sized = OllamaEmbedding(model: model, dimensions: v)
        return SemanticProvider(choice: .ollama(model: model), identity: sized.identity, dimensions: sized.dimensions, engine: sized)
    }

    private func probeDimensions() async throws -> Int {
        let raw = try await request(texts: [Self.probe])
        guard let first = raw.first, !first.isEmpty, first.allSatisfy({ $0.isFinite }) else { return 0 }
        return first.count
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await request(texts: texts)
    }

    private func request(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let url = URL(string: Self.base + "/api/embed"), url.host == "127.0.0.1" else {
            throw SemanticError("Ollama embeddings are only used from this Mac.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SemanticError("Couldn't reach Ollama on this Mac. Open the Ollama app, then try again.") }
        guard let http = resp as? HTTPURLResponse else { throw SemanticError("Ollama didn't answer.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { return try await legacyRequest(texts: texts) }   // older Ollama
            throw SemanticError("Ollama couldn't embed with \(model) (error \(http.statusCode)). Pick another model in Settings of the Ollama app, then try again.")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["embeddings"] as? [[Double]], arr.count == texts.count else {
            throw SemanticError("Ollama's reply wasn't in the expected format. Try a different embedding model.")
        }
        return arr.map { $0.map(Float.init) }
    }

    /// Ollama before 0.3 exposed one embedding per request at `/api/embeddings`.
    private func legacyRequest(texts: [String]) async throws -> [[Float]] {
        guard let url = URL(string: Self.base + "/api/embeddings"), url.host == "127.0.0.1" else {
            throw SemanticError("Ollama embeddings are only used from this Mac.")
        }
        var out: [[Float]] = []
        for t in texts {
            try Task.checkCancellation()
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": t])
            guard let (data, resp) = try? await Self.session.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let v = obj["embedding"] as? [Double] else {
                throw SemanticError("Ollama couldn't embed with \(model). Pick another embedding model, then try again.")
            }
            out.append(v.map(Float.init))
        }
        return out
    }
}

/// Refuses every redirect: a loopback request must not be able to hand message text to another host.
final class LoopbackOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
