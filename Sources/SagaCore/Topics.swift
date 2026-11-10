import Foundation

/// Topics: a short, cached list of what a chat talked about in a period, each topic citing the messages behind it.
/// Runs on a model on this Mac; results are saved by message uid in the local AI cache.
extension LocalAI {
    public static let topicsPromptVersion = "topics-v1"
    public static let maxTopics = 8
    public static let topicsPeriods = [7, 30, 90, 365]

    public struct TopicsProgress: Sendable { public let done: Int, total: Int, fromCache: Int, skipped: Int, merging: Bool }

    /// A saved topic list, with its citations resolved against the current index.
    public struct SavedTopics: Sendable {
        public let points: [SummaryPoint]
        public let created: Date
        /// True when the saved list was made from exactly the current messages and model; false = stale (messages changed since).
        public let isCurrent: Bool
    }

    // MARK: keys

    static func model(id: String) -> AIModel? {
        if id == AIModel.apple.id { return .apple }
        let p = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, let k = AIModel.Kind(rawValue: p[0]) else { return nil }
        return .server(k, base: p[1], model: p[2])
    }

    /// Fingerprint of the ordered eligible uids and the exact prepared inputs (so changed names or text invalidate, not only counts).
    static func topicsFingerprint(_ parts: [(text: String, refs: [Int: MessageRef])]) -> String {
        hash(parts.map { p in hash(p.text, p.refs.keys.sorted().map { p.refs[$0]!.uid }.joined(separator: ",")) }.joined(separator: "|"))
    }
    static func topicsKey(scope: String, jid: String, start: Date, end: Date, modelID: String, fingerprint: String) -> String {
        "\(topicsPromptVersion)|" + hash(scope, jid, "\(VaultStore.topicsMS(start))", "\(VaultStore.topicsMS(end))", modelID, fingerprint)
    }
    /// Per-part cache key. Scoped like the summary so one chat/period/archive can never reuse another one's part result.
    static func topicsChunkKey(scope: String, jid: String, start: Date, end: Date, modelID: String, kind: String, text: String) -> String {
        hash(topicsPromptVersion, "chunk", scope, jid, "\(VaultStore.topicsMS(start))", "\(VaultStore.topicsMS(end))", modelID, kind, text)
    }
    /// Points at the newest saved list for chat+days+model so a stale one can be shown while the user decides to refresh.
    static func topicsLatestKey(scope: String, jid: String, days: Int, modelID: String) -> String {
        "\(topicsPromptVersion)|latest|" + hash(scope, jid, "\(days)", modelID)
    }
    static func topicsKind(chatName: String, isGroup: Bool) -> String { kindText(chatName: chatName, isGroup: isGroup) }

    static func topicsParts(_ rows: [MessageRow], chatID: Int64, model: AIModel) -> [(text: String, refs: [Int: MessageRef])] {
        prepared(rows, chatID: chatID, model: model, detail: .quick)
    }

    // MARK: saved results

    /// Looks up a saved list without any model call: exact match first, else the newest saved list for this chat/period/model
    /// (marked stale). Citations are resolved against `store`; points whose messages are gone are dropped.
    public static func savedTopics(rows: [MessageRow], chatID: Int64, chatJID: String, archiveScope: String, days: Int, periodStart: Date, periodEnd: Date,
                                   modelID: String, cache: AICache?, store: VaultStore) -> SavedTopics? {
        guard let cache else { return nil }
        let model = Self.model(id: modelID) ?? .apple
        let fp = topicsFingerprint(topicsParts(rows, chatID: chatID, model: model))
        let exact = topicsKey(scope: archiveScope, jid: chatJID, start: periodStart, end: periodEnd, modelID: modelID, fingerprint: fp)
        var current = true
        var saved = cache.summary(key: exact)
        if saved == nil { current = false; saved = cache.summary(key: topicsLatestKey(scope: archiveScope, jid: chatJID, days: days, modelID: modelID)) }
        guard let s = saved else { return nil }
        let map = store.resolve(uids: s.points.flatMap(\.uids).filter { !$0.isEmpty })
        let pts = s.points.compactMap { sp -> SummaryPoint? in
            let src = sp.uids.prefix(3).compactMap { u in map[u].map { MessageRef(messageID: $0.id, chatID: $0.chatID, uid: u) } }
            return src.isEmpty ? nil : SummaryPoint(text: sp.text, sources: src)
        }
        return pts.isEmpty ? nil : SavedTopics(points: pts, created: s.created, isCurrent: current)
    }

    // MARK: generation

    public static func topics(_ rows: [MessageRow], chatID: Int64, chatJID: String, chatName: String, isGroup: Bool, archiveScope: String,
                              days: Int = 30, periodStart: Date, periodEnd: Date, model: AIModel, cache: AICache? = nil,
                              onPartial: @Sendable ([SummaryPoint]) -> Void = { _ in },
                              progress: @Sendable (TopicsProgress) -> Void = { _ in }) async throws -> [SummaryPoint] {
        try await topics(rows, chatID: chatID, chatJID: chatJID, chatName: chatName, isGroup: isGroup, archiveScope: archiveScope, days: days,
                         periodStart: periodStart, periodEnd: periodEnd, model: model, cache: cache, engine: try engine(for: model), onPartial: onPartial, progress: progress)
    }

    /// Map-reduce over bounded parts (at most `quickMaxParts`, sampled for huge periods). Unsupported topics (no valid citation) are dropped.
    /// Finished lists are saved only when every part succeeded; a run with failed parts reports `skipped > 0` in its last progress and is not saved.
    static func topics(_ rows: [MessageRow], chatID: Int64, chatJID: String, chatName: String, isGroup: Bool, archiveScope: String,
                       days: Int = 30, periodStart: Date, periodEnd: Date, model: AIModel, cache: AICache?, engine eng: any AIEngine,
                       onPartial: @Sendable ([SummaryPoint]) -> Void = { _ in },
                       progress: @Sendable (TopicsProgress) -> Void = { _ in }) async throws -> [SummaryPoint] {
        let parts = topicsParts(rows, chatID: chatID, model: model)
        guard !parts.isEmpty else { return [] }
        let key = topicsKey(scope: archiveScope, jid: chatJID, start: periodStart, end: periodEnd, modelID: model.id, fingerprint: topicsFingerprint(parts))
        var byUID: [String: MessageRef] = [:]
        for p in parts { for r in p.refs.values where !r.uid.isEmpty { byUID[r.uid] = r } }
        func fromStored(_ s: [AICache.StoredPoint]) -> [SummaryPoint] {
            s.compactMap { sp in
                let src = sp.uids.prefix(3).compactMap { byUID[$0] }
                return src.isEmpty ? nil : SummaryPoint(text: sp.text, sources: src)
            }
        }
        if let hit = cache?.summary(key: key) {
            let pts = fromStored(hit.points)
            if !pts.isEmpty { progress(TopicsProgress(done: parts.count, total: parts.count, fromCache: parts.count, skipped: 0, merging: false)); return pts }
        }
        let kind = topicsKind(chatName: chatName, isGroup: isGroup)
        var done: [Int: [SummaryPoint]] = [:]
        var skipped = 0, hits = 0, finished = 0; var lastError: Error?
        func ordered() -> [SummaryPoint] { done.keys.sorted().flatMap { done[$0]! } }
        for idx in parts.indices.reversed() {
            try Task.checkCancellation()
            let p = parts[idx]
            let h = topicsChunkKey(scope: archiveScope, jid: chatJID, start: periodStart, end: periodEnd, modelID: model.id, kind: kind, text: p.text)
            if let stored = cache?.chunk(hash: h) {
                hits += 1; done[idx] = fromStored(stored)
            } else {
                do {
                    let out = try await withRetry(model) { try await eng.points(
                        system: system,
                        instruction: "This is one part of \(kind). List up to 4 distinct topics people talked about, each a short noun phrase of at most 8 words (not a sentence). For each topic give the numbers of the one to three messages that best show it.",
                        body: p.text,
                        compact: "List up to 4 topics as short noun phrases of at most 8 words. Put the message numbers that show each topic in square brackets at its end.") }
                    let pts = validated(out.points, refs: p.refs)
                    done[idx] = pts
                    cache?.saveChunk(hash: h, points: pts.map { .init(text: $0.text, uids: $0.sources.map(\.uid)) })
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; lastError = error }
            }
            finished += 1
            progress(TopicsProgress(done: finished, total: parts.count, fromCache: hits, skipped: skipped, merging: false))
            onPartial(dedupe(ordered()))
        }
        var points = dedupe(ordered())
        if points.isEmpty, let e = lastError { throw AIError(message: friendly(e)) }
        if points.count > maxTopics {
            progress(TopicsProgress(done: parts.count, total: parts.count, fromCache: hits, skipped: skipped, merging: true))
            try Task.checkCancellation()
            let listing = points.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")
            var merged: [SummaryPoint] = []
            if let m = (try? await eng.points(
                system: system,
                instruction: "These numbered topics come from \(kind). Combine overlapping ones into at most \(maxTopics) short topics (noun phrases). For each give the numbers of the topics it combines.",
                body: listing,
                compact: "Combine these numbered topics into at most \(maxTopics) short noun phrases. Put the topic numbers each one combines in square brackets at its end."))?.points {
                for mp in m {
                    let src = mp.refs.filter { $0 >= 1 && $0 <= points.count }
                    let refs = unique(src.flatMap { points[$0 - 1].sources })
                    if !refs.isEmpty { merged.append(SummaryPoint(text: shorten(mp.text), sources: Array(refs.prefix(3)))) }
                }
            }
            if merged.isEmpty {                                         // merge failed: keep evenly spread topics rather than only the first ones
                let step = Double(points.count) / Double(maxTopics)
                merged = (0..<maxTopics).map { points[Int(Double($0) * step)] }
            }
            points = dedupe(merged)
        }
        points = Array(points.prefix(maxTopics))
        progress(TopicsProgress(done: parts.count, total: parts.count, fromCache: hits, skipped: skipped, merging: false))
        if let cache, skipped == 0, !points.isEmpty {
            let stored = points.map { AICache.StoredPoint(text: $0.text, uids: $0.sources.map(\.uid)) }
            let last = Int64((rows.last?.ts.timeIntervalSince1970 ?? 0) * 1000)
            cache.saveSummary(key: key, lastTS: last, messageCount: rows.count, points: stored)
            cache.saveSummary(key: topicsLatestKey(scope: archiveScope, jid: chatJID, days: days, modelID: model.id), lastTS: last, messageCount: rows.count, points: stored)
        }
        return points
    }

    // MARK: helpers

    static func shorten(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }
    static func unique(_ refs: [MessageRef]) -> [MessageRef] {
        var seen = Set<String>(); return refs.filter { r in r.uid.isEmpty ? true : seen.insert(r.uid).inserted }
    }
    /// Keeps only topics that cite at least one message that was actually in the prompt; invented numbers are ignored.
    static func validated(_ raw: [AIParse.Point], refs: [Int: MessageRef]) -> [SummaryPoint] {
        raw.compactMap { pt in
            let t = shorten(pt.text)
            let src = unique(pt.refs.compactMap { refs[$0] }.filter { !$0.uid.isEmpty })
            return t.isEmpty || src.isEmpty ? nil : SummaryPoint(text: t, sources: Array(src.prefix(3)))
        }
    }
    static func dedupe(_ pts: [SummaryPoint]) -> [SummaryPoint] {
        var seen = Set<String>()
        return pts.filter { seen.insert($0.text.lowercased().filter { $0.isLetter || $0.isNumber }).inserted }
    }
}
