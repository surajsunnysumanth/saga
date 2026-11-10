import XCTest
@testable import SagaCore

// MARK: - synthetic fixtures (no private data, no real models)

private typealias Row = (id: Int64, chat: Int64, ts: Int64, uid: String, text: String)

/// Deterministic stand-in for an embedding model: each known input maps to a fixed vector.
private struct ToyEmbedding: EmbeddingEngine {
    let identity: String
    let dimensions: Int
    var map: [String: [Float]]
    init(identity: String = "toy|v1|4|p1", map: [String: [Float]]) {
        self.identity = identity; self.dimensions = 4; self.map = map
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { map[$0] ?? [0, 0, 0, 1] } }
}

/// Returns unusable vectors for three specific inputs and a good one otherwise.
private struct BadVectorEmbedding: EmbeddingEngine {
    let identity = "bad|v1|4|p1"
    let dimensions = 4
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { t in
            if t.contains("nan") { return [Float.nan, 0, 0, 0] }
            if t.contains("zero") { return [0, 0, 0, 0] }
            if t.contains("short") { return [1, 0] }
            return [0, 1, 0, 0]
        }
    }
}

private struct OfflineEmbedding: EmbeddingEngine {
    let identity = "offline|v1|4|p1"
    let dimensions = 4
    func embed(_ texts: [String]) async throws -> [[Float]] { throw SemanticError("synthetic backend offline") }
}

private actor RecordingEngine: AIEngine {
    private(set) var prompts: [String] = []
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        prompts.append(instruction + (body.isEmpty ? "" : "\n\n" + body))
        return EngineOut(points: [AIParse.Point(text: "Synthetic answer", refs: [1])])
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SemanticIndexSummary, Error>?
    func set(_ t: Task<SemanticIndexSummary, Error>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

final class SemanticSearchTests: XCTestCase {
    private func tmp(_ ext: String = "db") -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID().uuidString).\(ext)").path
    }

    /// Writes a disposable index with the real schema (chats, messages, FTS).
    @discardableResult
    private func makeIndex(_ rows: [Row], chats: [(id: Int64, name: String)] = [(1, "Example"), (2, "Other")]) throws -> String {
        let path = tmp("sqlite")
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        let insChat = try db.prepare("INSERT INTO chats(chat_id, jid, is_group, name, resolved, person) VALUES(?,?,0,?,1,'p')")
        for c in chats { try insChat.run([.int(c.id), .text("\(c.id)@s.whatsapp.net"), .text(c.name)]) }
        let ins = try db.prepare("INSERT INTO messages(id, chat_id, from_me, sender, person, ts, type, text, uid) VALUES(?,?,0,'S','p',?,0,?,?)")
        try db.exec("BEGIN")
        for r in rows { try ins.run([.int(r.id), .int(r.chat), .int(r.ts), .text(r.text), .text(r.uid)]) }
        try db.exec("COMMIT")
        try db.exec(Importer.finish)
        return path
    }

    private func store(_ path: String) throws -> VaultStore { try VaultStore(path: path) }

    private func makeSearch(_ indexPath: String, _ engine: any EmbeddingEngine, scope: String = "archive", vecs: String? = nil) throws -> SemanticSearch {
        let store = try SemanticStore(path: vecs ?? tmp("vec"))
        return SemanticSearch(indexPath: indexPath, archiveScope: scope, store: store, engine: engine)
    }

    // MARK: build

    func testBuildEmbedsOnlyEligibleMessages() async throws {
        let idx = try makeIndex([
            (1, 1, 1000, "a", ""),                       // blank
            (2, 1, 2000, "b", "ok"),                     // too short
            (3, 1, 3000, "c", "  x  "),                  // too short after trimming
            (4, 1, 4000, "d", "planning the trip"),      // eligible
            (5, 1, 5000, "e", "dinner on friday"),       // eligible
            (6, 1, 6000, "", "hello there"),             // no durable uid
        ])
        let s = try makeSearch(idx, ToyEmbedding(map: ["planning the trip": [1, 0, 0, 0], "dinner on friday": [0, 1, 0, 0], "trip": [1, 0, 0, 0]]))
        let summary = try await s.build()
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.embedded, 2)
        XCTAssertEqual(summary.reused, 0)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(try s.coverage(), .current(total: 2))

        let hits = try await s.search("trip")
        XCTAssertEqual(hits.map(\.uid), ["d"])          // only a positive similarity counts as a meaning hit
        XCTAssertGreaterThan(hits[0].score, 0)
    }

    func testRebuildReusesUnchangedVectorsAndReembedsChangedText() async throws {
        let idx = try makeIndex([(1, 1, 1000, "a", "planning the trip"), (2, 1, 2000, "b", "dinner on friday")])
        let s = try makeSearch(idx, ToyEmbedding(map: ["planning the trip": [1, 0, 0, 0], "dinner on friday": [0, 1, 0, 0]]))
        let first = try await s.build()
        XCTAssertEqual(first.embedded, 2)

        let second = try await s.build()                       // resume: nothing to do
        XCTAssertEqual(second.embedded, 0)
        XCTAssertEqual(second.reused, 2)

        let db = try SQLiteDB(path: idx, readOnly: false)       // the user's archive changed (new index text)
        try db.prepare("UPDATE messages SET text='completely different words' WHERE uid='a'").run([])
        let third = try await s.build()                         // input hash changed: only that one is re-embedded
        XCTAssertEqual(third.reused, 1)
        XCTAssertEqual(third.embedded, 1)
    }

    func testPrunedMessagesAreDroppedAndVectorsReconciled() async throws {
        let idx = try makeIndex([(1, 1, 1000, "a", "planning the trip"), (2, 1, 2000, "b", "dinner on friday"), (3, 1, 3000, "c", "borrowed a book")])
        let s = try makeSearch(idx, ToyEmbedding(map: ["planning the trip": [1, 0, 0, 0]]))
        let firstBuild = try await s.build()
        XCTAssertEqual(firstBuild.embedded, 3)

        let db = try SQLiteDB(path: idx, readOnly: false)
        try db.prepare("DELETE FROM messages WHERE uid='c'").run([])   // prune / merge rebuild
        let again = try await s.build()
        XCTAssertEqual(again.total, 2)
        XCTAssertEqual(s.store.count(scope: "archive", identity: "toy|v1|4|p1"), 2)
        XCTAssertEqual(try s.coverage(), .current(total: 2))
        let prunedHits = try await s.search("book")
        XCTAssertFalse(prunedHits.contains { $0.uid == "c" })
    }

    func testUnusableVectorsAreSkippedButDoNotBlockTheRest() async throws {
        let idx = try makeIndex([
            (1, 1, 1000, "a", "nan value here"),
            (2, 1, 2000, "b", "zero value here"),
            (3, 1, 3000, "c", "short value here"),
            (4, 1, 4000, "d", "a perfectly good message"),
        ])
        let s = try makeSearch(idx, BadVectorEmbedding())
        let summary = try await s.build()
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(summary.embedded, 1)
        XCTAssertEqual(try s.coverage(), .current(total: 4))
        let hits = try await s.search("anything")
        XCTAssertEqual(hits.map(\.uid), ["d"])
    }

    func testCancellationKeepsFinishedWorkAndReportsPartial() async throws {
        let rows = (0..<200).map { Row(id: Int64($0 + 1), chat: 1, ts: Int64(1000 + $0), uid: "u\($0)", text: "message number \($0)") }
        let idx = try makeIndex(rows)
        let s = try makeSearch(idx, ToyEmbedding(map: [:]))
        let box = TaskBox()
        let progress = BoxedProgress()
        let t = Task { try await s.build(progress: { p in
            progress.update(p)
            if p.completed >= 64 { box.cancel() }
        }) }
        box.set(t)
        do { _ = try await t.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertGreaterThanOrEqual(progress.last?.completed ?? 0, 64)
        XCTAssertEqual(s.store.count(scope: "archive", identity: "toy|v1|4|p1"), progress.last?.embedded ?? -1)
        let coverage = try s.coverage()
        guard case .partial(let indexed, let total) = coverage else { return XCTFail("expected partial, got \(coverage)") }
        XCTAssertEqual(total, 200)
        XCTAssertGreaterThanOrEqual(indexed, 64)
        XCTAssertLessThan(indexed, 200)
    }

    func testArchiveAndModelAreIsolatedAndStalenessIsReported() async throws {
        let idx = try makeIndex([(1, 1, 1000, "a", "planning the trip"), (2, 1, 2000, "b", "dinner on friday")])
        let vecs = tmp("vec")
        let s = try makeSearch(idx, ToyEmbedding(map: [:]), vecs: vecs)
        _ = try await s.build()
        XCTAssertEqual(try s.coverage(), .current(total: 2))

        // Another archive scope is a different cache: nothing indexed there.
        let other = try makeSearch(idx, ToyEmbedding(map: [:]), scope: "other-vault", vecs: vecs)
        XCTAssertEqual(try other.coverage(), .missing)
        // Another embedding model is a different vector space: nothing comparable.
        let otherModel = try makeSearch(idx, ToyEmbedding(identity: "toy|v2|4|p1", map: [:]), vecs: vecs)
        XCTAssertEqual(try otherModel.coverage(), .missing)

        let db = try SQLiteDB(path: idx, readOnly: false)
        try db.prepare("INSERT INTO messages(id, chat_id, from_me, sender, person, ts, type, text, uid) VALUES(9,1,0,'S','p',9000,0,'a new message','new')").run([])
        XCTAssertEqual(try s.coverage(), .stale(indexed: 2, total: 3))
    }

    func testEmptyArchiveReportsEmptyRatherThanAnIndex() async throws {
        let idx = try makeIndex([])
        let s = try makeSearch(idx, ToyEmbedding(map: [:]))
        XCTAssertEqual(try s.coverage(), .empty)
        let summary = try await s.build()
        XCTAssertEqual(summary.total, 0)
        let emptyHits = try await s.search("anything")
        XCTAssertTrue(emptyHits.isEmpty)
    }

    // MARK: fusion

    func testFusionIsReciprocalRankWithStableTieBreak() {
        let fused = SemanticSearch.fuse(fts: ["a", "b"], semantic: [.init(uid: "b", score: 0.9), .init(uid: "c", score: 0.8)])
        XCTAssertEqual(fused.map(\.uid), ["b", "a", "c"])       // b is found by both
        XCTAssertEqual(fused[0].score, 1.0 / 62 + 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(fused[1].score, 1.0 / 61, accuracy: 1e-12)
        XCTAssertEqual(fused[2].score, 1.0 / 62, accuracy: 1e-12)

        XCTAssertEqual(SemanticSearch.fuse(fts: [], semantic: [.init(uid: "s", score: 1)]).map(\.uid), ["s"])
        XCTAssertEqual(SemanticSearch.fuse(fts: ["k"], semantic: []).map(\.uid), ["k"])
        XCTAssertEqual(SemanticSearch.fuse(fts: ["y"], semantic: [.init(uid: "x", score: 1)]).map(\.uid), ["x", "y"])   // equal score: uid order
        XCTAssertEqual(SemanticSearch.fuse(fts: ["a", "a", "b"], semantic: []).map(\.uid), ["a", "b"])                  // duplicates collapse
        XCTAssertTrue(SemanticSearch.fuse(fts: Array(0..<40).map { "u\($0)" }, semantic: [], limit: 30).count == 30)     // seed cap
    }

    func testCosineRejectsMismatchedZeroAndNonFiniteVectors() {
        XCTAssertEqual(SemanticSearch.cosine([1, 0], [1, 0]) ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(SemanticSearch.cosine([1, 0], [0, 1]) ?? -1, 0, accuracy: 1e-9)   // orthogonal: a real 0, not an error
        XCTAssertNil(SemanticSearch.cosine([0, 0], [1, 0]))
        XCTAssertNil(SemanticSearch.cosine([1], [1, 0]))
        XCTAssertNil(SemanticSearch.cosine([Float.nan, 0], [1, 0]))
        XCTAssertFalse(SemanticSearch.isUsable([Float.infinity, 0], dim: 2))
        XCTAssertFalse(SemanticSearch.isUsable([0, 0], dim: 2))
        XCTAssertFalse(SemanticSearch.isUsable([1, 0], dim: 3))
    }

    // MARK: search and retrieval

    func testChatScopeAppliesToBothRetrievers() async throws {
        let idx = try makeIndex([
            (1, 1, 1000, "a", "booking flights for the goa trip"),
            (2, 2, 2000, "b", "trip photos from last year"),
            (3, 2, 3000, "c", "unrelated note about lunch"),
        ])
        let s = try makeSearch(idx, ToyEmbedding(map: [
            "booking flights for the goa trip": [1, 0.2, 0, 0],
            "trip photos from last year": [0.9, 0, 0, 0],
            "trip": [1, 0, 0, 0],
        ]))
        _ = try await s.build()
        let wide = try await s.search("trip")
        XCTAssertEqual(Set(wide.map(\.uid)), ["a", "b"])
        let chat2 = try await s.search("trip", chat: 2)
        XCTAssertEqual(chat2.map(\.uid), ["b"])

        let v = try store(idx)
        let r = try await s.retrieve(question: "trip", chat: 2, store: v)
        XCTAssertTrue(r.ordered.allSatisfy { $0.chatID == 2 })
        XCTAssertEqual(r.semanticSeeds, 1)
    }

    func testRetrievalResolvesFreshRowIDsAndDropsPrunedUIDs() async throws {
        let first = try makeIndex([(1, 1, 1000, "a", "planning the trip"), (2, 1, 2000, "b", "dinner on friday")])
        let s = try makeSearch(first, ToyEmbedding(map: ["planning the trip": [1, 0, 0, 0], "trip": [1, 0, 0, 0]]))
        _ = try await s.build()

        let rebuilt = try makeIndex([(501, 7, 1000, "a", "planning the trip")], chats: [(7, "Moved")])   // same uid, new row id, new chat id
        let r = try await s.retrieve(question: "trip", chat: nil, store: try store(rebuilt))
        XCTAssertEqual(r.ordered.first?.id, 501)
        XCTAssertEqual(r.ordered.first?.chatID, 7)
        XCTAssertFalse(r.ordered.contains { $0.uid == "b" })                   // no longer in the archive
    }

    // MARK: ask

    func testHybridAskCitesOnlySuppliedMessages() async throws {
        let idx = try makeIndex([
            (1, 1, 1000, "a", "planning the trip to goa"),
            (2, 1, 2000, "b", "booking flights tomorrow"),
            (3, 1, 3000, "c", "dinner on friday"),
            (4, 2, 4000, "d", "lunch plans"),
        ])
        let s = try makeSearch(idx, ToyEmbedding(map: ["planning the trip to goa": [1, 0, 0, 0], "trip": [1, 0, 0, 0]]))
        _ = try await s.build()
        let eng = RecordingEngine()
        let outcome = try await LocalAI.askResult("trip", store: try store(idx), chat: nil, model: .apple, engine: eng, semantic: s)
        guard case .hybrid(let kw, let sem) = outcome.retrieval else { return XCTFail("expected hybrid, got \(outcome.retrieval)") }
        XCTAssertGreaterThan(kw, 0)
        XCTAssertGreaterThan(sem, 0)
        XCTAssertGreaterThan(outcome.searched, 0)
        XCTAssertFalse(outcome.points.isEmpty)
        let prompts = await eng.prompts
        let supplied = prompts.last?.split(separator: "\n").filter { $0.hasPrefix("[") }.count ?? 0
        XCTAssertEqual(outcome.searched, supplied)                    // reported count = messages given to the model
        XCTAssertTrue(outcome.points.allSatisfy { !$0.sources.isEmpty && $0.sources.allSatisfy { !$0.uid.isEmpty } })
    }

    func testSemanticFailureFallsBackToKeywordsVisibly() async throws {
        let idx = try makeIndex([(1, 1, 1000, "a", "planning the trip to goa"), (2, 1, 2000, "b", "booking flights tomorrow")])
        let s = try makeSearch(idx, OfflineEmbedding())
        let outcome = try await LocalAI.askResult("trip", store: try store(idx), chat: nil, model: .apple, engine: RecordingEngine(), semantic: s)
        guard case .keywordFallback(let message) = outcome.retrieval else { return XCTFail("expected a visible fallback, got \(outcome.retrieval)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertGreaterThan(outcome.searched, 0)                    // keywords still found the messages
        XCTAssertFalse(outcome.points.isEmpty)
    }

    func testAskWithoutSemanticKeepsKeywordBehaviour() async throws {
        let idx = try makeIndex([(1, 1, 1000, "a", "planning the trip to goa")])
        let outcome = try await LocalAI.askResult("trip", store: try store(idx), chat: nil, model: .apple, engine: RecordingEngine(), semantic: nil)
        XCTAssertEqual(outcome.retrieval, .keyword)
        XCTAssertGreaterThan(outcome.searched, 0)
    }

    func testAskSurvivesARebuiltIndexWithoutRecycledRowIDs() async throws {
        let first = try makeIndex([(1, 1, 1000, "a", "planning the trip to goa")])
        let s = try makeSearch(first, ToyEmbedding(map: ["planning the trip to goa": [1, 0, 0, 0], "trip": [1, 0, 0, 0]]))
        _ = try await s.build()
        let rebuilt = try makeIndex([(900, 3, 1000, "a", "planning the trip to goa")], chats: [(3, "Moved")])
        let outcome = try await LocalAI.askResult("trip", store: try store(rebuilt), chat: nil, model: .apple, engine: RecordingEngine(), semantic: s)
        guard case .hybrid = outcome.retrieval else { return XCTFail("expected hybrid") }
        XCTAssertEqual(outcome.points.first?.sources.first?.messageID, 900)
        XCTAssertEqual(outcome.points.first?.sources.first?.chatID, 3)
    }

    // MARK: benchmark

    /// Opt-in measurement against the real on-device embedding model (skipped in the normal suite, which stays fast and
    /// deterministic). Run with `SAGA_SEMANTIC_REAL=1 swift test --filter testRealLocalEmbeddingThroughput`.
    func testRealLocalEmbeddingThroughput() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAGA_SEMANTIC_REAL"] == "1",
                          "set SAGA_SEMANTIC_REAL=1 to measure the real local embedding model")
        let available = await SemanticSearch.providers()
        guard let provider = available.first(where: { if case .apple = $0.choice { return true }; return false }) ?? available.first else {
            throw XCTSkip("no local embedding model on this Mac")
        }
        let n = 1_000
        let rows: [Row] = (0..<n).map { i -> Row in
            Row(id: Int64(i + 1), chat: 1, ts: Int64(1_000_000 + i * 1000), uid: "r\(i)", text: "synthetic note number \(i) about planning a holiday with friends")
        }
        let idx = try makeIndex(rows, chats: [(1, "Example")])
        let store = try SemanticStore(path: tmp("vec"))
        let s = SemanticSearch(indexPath: idx, archiveScope: "real", store: store, provider: provider)

        let t0 = Date()
        let built = try await s.build()
        let buildT = Date().timeIntervalSince(t0)
        XCTAssertEqual(built.total, n)
        XCTAssertEqual(built.embedded, n)

        let t1 = Date()
        let hits = try await s.search("booking a vacation", limit: 30)
        let queryT = Date().timeIntervalSince(t1)
        XCTAssertFalse(hits.isEmpty)
        print("SEMANTIC-REAL provider=\(provider.choice.tag) dims=\(provider.dimensions) messages=\(n) "
              + "build_s=\(String(format: "%.2f", buildT)) msg_per_s=\(String(format: "%.0f", Double(n) / max(buildT, 0.001))) "
              + "query_s=\(String(format: "%.3f", queryT)) hits=\(hits.count)")
    }

    /// Opt-in measurement of the scoring scan at a realistic vector size (512 floats, Apple's sentence embeddings).
    /// The normal 100k test uses 4-float toy vectors, which would understate the scan cost.
    func testHundredThousandVectorScanAtRealDimension() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAGA_SEMANTIC_REAL"] == "1",
                          "set SAGA_SEMANTIC_REAL=1 to measure a realistic-dimension scan")
        struct FixedEmbedding: EmbeddingEngine {
            let identity = "fixed|512|512|p1"
            let dimensions = 512
            func embed(_ texts: [String]) async throws -> [[Float]] {
                texts.map { t in (0..<512).map { i in Float((t.count &* (i + 1)) % 11) / 11 + 0.01 } }
            }
        }
        let n = 100_000, dim = 512
        let idx = try makeIndex([], chats: [(1, "Example")])
        let store = try SemanticStore(path: tmp("vec"))
        let records = (0..<n).map { k in
            SemanticStore.Record(uid: "v\(k)", hash: "h", dim: dim,
                                 vector: (0..<dim).map { i in Float((k &* 31 &+ i &* 17) % 97) / 97 + 0.01 })
        }
        for chunk in stride(from: 0, to: n, by: 1000).map({ Array(records[$0..<min($0 + 1000, n)]) }) {
            store.upsert(scope: "s", identity: "fixed|512|512|p1", records: chunk)
        }
        store.saveCoverage(scope: "s", identity: "fixed|512|512|p1", total: n, indexed: n, skipped: 0, complete: true)
        let s = SemanticSearch(indexPath: idx, archiveScope: "s", store: store, engine: FixedEmbedding())
        let t0 = Date()
        let hits = try await s.search("synthetic query about a trip", limit: 30)
        let scanT = Date().timeIntervalSince(t0)
        XCTAssertEqual(hits.count, 30)
        print("SEMANTIC-SCAN vectors=\(n) dim=\(dim) scan_s=\(String(format: "%.2f", scanT)) hits=\(hits.count)")
    }

    func testHundredThousandMessagesThroughput() async throws {
        let n = 100_000
        let rows: [Row] = (0..<n).map { i -> Row in
            Row(id: Int64(i + 1), chat: 1, ts: Int64(1_000_000 + i * 1000), uid: "p\(i)", text: "synthetic words about plan number \(i)")
        }
        let idx = try makeIndex(rows, chats: [(1, "Example")])
        let s = try makeSearch(idx, ToyEmbedding(map: ["synthetic": [1, 0, 0, 0], "plan": [0, 1, 0, 0]]))

        let t0 = Date()
        let built = try await s.build()
        let buildT = Date().timeIntervalSince(t0)
        XCTAssertEqual(built.total, n)
        XCTAssertEqual(built.embedded, n)

        let t1 = Date()
        let hits = try await s.search("synthetic plan", limit: 30)
        let queryT = Date().timeIntervalSince(t1)
        XCTAssertEqual(hits.count, 30)

        let t2 = Date()
        let again = try await s.build()
        let reuseT = Date().timeIntervalSince(t2)
        XCTAssertEqual(again.embedded, 0)
        XCTAssertEqual(again.reused, n)

        print("SEMANTIC-BENCH messages=\(n) eligible=\(built.total) embedded=\(built.embedded) build_s=\(String(format: "%.2f", buildT)) "
              + "msg_per_s=\(String(format: "%.0f", Double(n) / max(buildT, 0.001))) query_s=\(String(format: "%.3f", queryT)) "
              + "reuse_s=\(String(format: "%.2f", reuseT)) (fake engine; not real embedding speed)")
    }
}

/// Thread-safe last progress value for the cancellation test.
private final class BoxedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SemanticIndexProgress?
    func update(_ p: SemanticIndexProgress) { lock.lock(); value = p; lock.unlock() }
    var last: SemanticIndexProgress? { lock.lock(); defer { lock.unlock() }; return value }
}
