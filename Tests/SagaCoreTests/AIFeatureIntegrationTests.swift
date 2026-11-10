import XCTest
@testable import SagaCore

// MARK: - synthetic fixtures (no private data, no real model calls)

/// Deterministic stand-in for an embedding model: a known input maps to a fixed vector.
private struct IntegrationEmbedding: EmbeddingEngine {
    let identity: String
    let dimensions: Int
    var map: [String: [Float]]
    init(identity: String = "integration|v1|4|p1", map: [String: [Float]]) {
        self.identity = identity; self.dimensions = 4; self.map = map
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { map[$0] ?? [0, 0, 0, 1] } }
}

private struct OfflineEmbedding: EmbeddingEngine {
    let identity = "offline|v1|4|p1"
    let dimensions = 4
    func embed(_ texts: [String]) async throws -> [[Float]] { throw SemanticError("synthetic backend offline") }
}

/// Answers with one point citing the first supplied message. Counts as a fake AIEngine, so no model runs.
private struct IntegrationAnswerEngine: AIEngine {
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        EngineOut(points: [AIParse.Point(text: "Synthetic answer", refs: [1])])
    }
}

private actor IntegrationTopicEngine: AIEngine {
    private(set) var calls = 0
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        calls += 1
        return EngineOut(points: [AIParse.Point(text: "Synthetic planning", refs: [1])])
    }
    func count() -> Int { calls }
}

private struct ChatSpec {
    let id: Int64
    let jid: String
    let name: String
    let isGroup: Int64
    let person: String
}

/// id, chat, ts(ms), uid, text, fromMe, type
private typealias Msg = (id: Int64, chat: Int64, ts: Int64, uid: String, text: String, fromMe: Int64, type: Int64)

final class AIFeatureIntegrationTests: XCTestCase {
    private func tmp(_ ext: String = "sqlite") -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ai-integration-\(UUID().uuidString).\(ext)").path
    }

    /// Writes a disposable visible index with the real schema (chats, messages, FTS, chat_stats).
    @discardableResult
    private func makeIndex(chats: [ChatSpec], messages: [Msg]) throws -> String {
        let path = tmp()
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        let insChat = try db.prepare("INSERT INTO chats(chat_id, jid, is_group, name, resolved, person) VALUES(?,?,?,?,1,?)")
        for c in chats { try insChat.run([.int(c.id), .text(c.jid), .int(c.isGroup), .text(c.name), .text(c.person)]) }
        let ins = try db.prepare("INSERT INTO messages(id, chat_id, from_me, sender, person, ts, type, text, uid) VALUES(?,?,?,?,?,?,?,?,?)")
        try db.exec("BEGIN")
        for m in messages {
            try ins.run([.int(m.id), .int(m.chat), .int(m.fromMe), .text(m.fromMe == 1 ? "" : "Example"), .text("example"),
                         .int(m.ts), .int(m.type), .text(m.text), .text(m.uid)])
        }
        try db.exec("COMMIT")
        try db.exec(Importer.finish)
        return path
    }

    /// A vault folder whose vault.json carries a stable archive id, as `archiveScope` reads it.
    private func makeVault(id: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-vault-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": id]).write(to: vault.appendingPathComponent("vault.json"))
        return vault
    }

    private let scope = "vault:integration"
    private let start = Date(timeIntervalSince1970: 0.5)
    private let end = Date(timeIntervalSince1970: 3)

    // MARK: - shared data lifecycle

    /// The three features cache by uid, so a rebuilt index (new row and chat ids) must still resolve
    /// every saved citation and every vector to the current rows.
    func testCachedTopicsAndVectorsFollowUIDsAcrossARebuiltIndex() async throws {
        let chatA = ChatSpec(id: 1, jid: "111@s.whatsapp.net", name: "Example", isGroup: 0, person: "111")
        let chatB = ChatSpec(id: 91, jid: "111@s.whatsapp.net", name: "Example", isGroup: 0, person: "111")
        let a = try makeIndex(chats: [chatA], messages: [
            (1, 1, 1_000, "u1", "planning the demo trip", 0, 0),
            (2, 1, 2_000, "u2", "did you book the cab for saturday?", 0, 0),
        ])
        // Same archive, same uids, different chat and message ids: what a rebuild can produce.
        let b = try makeIndex(chats: [chatB], messages: [
            (201, 91, 1_000, "u1", "planning the demo trip", 0, 0),
            (202, 91, 2_000, "u2", "did you book the cab for saturday?", 0, 0),
        ])
        let vectors = try SemanticStore(path: tmp("vec"))
        let engine = IntegrationEmbedding(map: [
            "planning the demo trip": [1, 0, 0, 0],
            "did you book the cab for saturday?": [0, 1, 0, 0],
            "trip": [1, 0, 0, 0],
        ])
        let semanticA = SemanticSearch(indexPath: a, archiveScope: scope, store: vectors, engine: engine)
        let built = try await semanticA.build()
        XCTAssertEqual(built.embedded, 2)
        let coverageAfterBuild = try semanticA.coverage()
        XCTAssertEqual(coverageAfterBuild, .current(total: 2))

        let cache = try AICache(path: tmp("cache"))
        let rowsA = try VaultStore(path: a).topicsRead(chat: 1, start: start, end: end).rows
        XCTAssertEqual(rowsA.count, 2)
        let topicEngine = IntegrationTopicEngine()
        let points = try await LocalAI.topics(rowsA, chatID: 1, chatJID: chatA.jid, chatName: chatA.name, isGroup: false,
                                              archiveScope: scope, days: 30, periodStart: start, periodEnd: end,
                                              model: .apple, cache: cache, engine: topicEngine)
        XCTAssertEqual(points.first?.sources.first?.uid, "u1")
        XCTAssertEqual(points.first?.sources.first?.messageID, 1)

        // Reopen against the rebuilt index. The generation stamp marks the saved coverage stale, even
        // though the eligible count is unchanged; a rebuild reuses every vector by uid and input hash.
        let storeB = try VaultStore(path: b)
        let semanticB = SemanticSearch(indexPath: b, archiveScope: scope, store: vectors, engine: engine)
        let coverageAfterRebuild = try semanticB.coverage()
        XCTAssertEqual(coverageAfterRebuild, .stale(indexed: 2, total: 2))
        let rebuilt = try await semanticB.build()
        XCTAssertEqual(rebuilt.reused, 2)
        XCTAssertEqual(rebuilt.embedded, 0)
        let coverageAfterResume = try semanticB.coverage()
        XCTAssertEqual(coverageAfterResume, .current(total: 2))
        let retrieval = try await semanticB.retrieve(question: "trip", chat: 91, limit: 5, store: storeB)
        XCTAssertEqual(retrieval.ordered.first?.uid, "u1")
        XCTAssertEqual(retrieval.ordered.first?.id, 201)

        let rowsB = try storeB.topicsRead(chat: 91, start: start, end: end).rows
        let saved = LocalAI.savedTopics(rows: rowsB, chatID: 91, chatJID: chatA.jid, archiveScope: scope, days: 30,
                                        periodStart: start, periodEnd: end, modelID: "apple", cache: cache, store: storeB)
        XCTAssertEqual(saved?.isCurrent, true)
        XCTAssertEqual(saved?.points.first?.sources.first?.uid, "u1")
        XCTAssertEqual(saved?.points.first?.sources.first?.messageID, 201)
        let topicCalls = await topicEngine.count()
        XCTAssertEqual(topicCalls, 1, "a reopen must not call the model again")

        let scan = try ReplyResponsibility.find(store: storeB, quietDays: 1,
                                                now: Date(timeIntervalSince1970: 2_000 + 86_400 + 10))
        let candidate = try XCTUnwrap(scan.candidates.first { $0.chatJID == chatB.jid })
        XCTAssertEqual(candidate.id, "u2")
        XCTAssertEqual(candidate.source.messageID, 202)
        let resolved = storeB.resolve(uids: [candidate.id])
        XCTAssertEqual(resolved[candidate.id]?.id, 202)
    }

    // MARK: - archive scope

    /// Semantic vectors and topic lists share one archive identity. A different vault must see neither,
    /// while the deterministic reply rule (which stores nothing) is unaffected.
    func testArchiveScopeIsSharedAndCachesAreIsolatedPerArchive() async throws {
        let chats = [ChatSpec(id: 1, jid: "111@s.whatsapp.net", name: "Example", isGroup: 0, person: "111")]
        let idx = try makeIndex(chats: chats, messages: [
            (1, 1, 1_000, "u1", "planning the demo trip", 0, 0),
            (2, 1, 2_000, "u2", "did you book the cab for saturday?", 0, 0),
        ])
        let vaultA = try makeVault(id: "archive-a")
        let vaultB = try makeVault(id: "archive-b")
        let scopeA = VaultStore.archiveScope(vaultURL: vaultA, indexPath: idx)
        let scopeB = VaultStore.archiveScope(vaultURL: vaultB, indexPath: idx)
        XCTAssertEqual(scopeA, "vault:archive-a")
        XCTAssertEqual(scopeB, "vault:archive-b")
        XCTAssertNotEqual(scopeA, scopeB)

        let vectors = try SemanticStore(path: tmp("vec"))
        let engine = IntegrationEmbedding(map: ["planning the demo trip": [1, 0, 0, 0], "trip": [1, 0, 0, 0]])
        _ = try await SemanticSearch(indexPath: idx, archiveScope: scopeA, store: vectors, engine: engine).build()
        let semanticB = SemanticSearch(indexPath: idx, archiveScope: scopeB, store: vectors, engine: engine)
        let coverageB = try semanticB.coverage()
        XCTAssertEqual(coverageB, .missing)
        let hitsB = try await semanticB.search("trip")
        XCTAssertTrue(hitsB.isEmpty)

        let cache = try AICache(path: tmp("cache"))
        let store = try VaultStore(path: idx)
        let rows = try store.topicsRead(chat: 1, start: start, end: end).rows
        _ = try await LocalAI.topics(rows, chatID: 1, chatJID: chats[0].jid, chatName: chats[0].name, isGroup: false,
                                     archiveScope: scopeA, days: 30, periodStart: start, periodEnd: end,
                                     model: .apple, cache: cache, engine: IntegrationTopicEngine())
        XCTAssertNotNil(LocalAI.savedTopics(rows: rows, chatID: 1, chatJID: chats[0].jid, archiveScope: scopeA, days: 30,
                                            periodStart: start, periodEnd: end, modelID: "apple", cache: cache, store: store))
        XCTAssertNil(LocalAI.savedTopics(rows: rows, chatID: 1, chatJID: chats[0].jid, archiveScope: scopeB, days: 30,
                                         periodStart: start, periodEnd: end, modelID: "apple", cache: cache, store: store))

        let replies = try ReplyResponsibility.find(store: store, quietDays: 1,
                                                   now: Date(timeIntervalSince1970: 2_000 + 86_400 + 10))
        XCTAssertFalse(replies.candidates.isEmpty)
    }

    // MARK: - privacy / no source mutation

    /// Every feature runs on a read-only VaultStore. The source index must be byte-identical afterwards,
    /// and the vector cache must hold no message text or contact name.
    func testFeaturesLeaveTheIndexUntouchedAndTheVectorCacheStoresNoText() async throws {
        let marker = "quasar picnic plans"
        let chats = [ChatSpec(id: 1, jid: "111@s.whatsapp.net", name: "Private Example Name", isGroup: 0, person: "111")]
        let idx = try makeIndex(chats: chats, messages: [
            (1, 1, 1_000, "u1", marker, 0, 0),
            (2, 1, 2_000, "u2", "did you book the cab for saturday?", 0, 0),
        ])
        let before = try Data(contentsOf: URL(fileURLWithPath: idx))

        let vectorPath = tmp("vec")
        let vectors = try SemanticStore(path: vectorPath)
        let engine = IntegrationEmbedding(map: [marker: [1, 0, 0, 0]])
        _ = try await SemanticSearch(indexPath: idx, archiveScope: scope, store: vectors, engine: engine).build()

        let cachePath = tmp("cache")
        let cache = try AICache(path: cachePath)
        let store = try VaultStore(path: idx)
        let rows = try store.topicsRead(chat: 1, start: start, end: end).rows
        _ = try await LocalAI.topics(rows, chatID: 1, chatJID: chats[0].jid, chatName: chats[0].name, isGroup: false,
                                     archiveScope: scope, days: 30, periodStart: start, periodEnd: end,
                                     model: .apple, cache: cache, engine: IntegrationTopicEngine())
        _ = try ReplyResponsibility.find(store: store, quietDays: 1, now: Date(timeIntervalSince1970: 2_000 + 86_400 + 10))

        let after = try Data(contentsOf: URL(fileURLWithPath: idx))
        XCTAssertEqual(before, after, "AI features must never write the index")
        let vectorBytes = try Data(contentsOf: URL(fileURLWithPath: vectorPath))
        XCTAssertNil(vectorBytes.range(of: Data(marker.utf8)), "the vector cache must not store message text")
        XCTAssertNil(vectorBytes.range(of: Data(chats[0].name.utf8)), "the vector cache must not store contact names")
        let cacheBytes = try Data(contentsOf: URL(fileURLWithPath: cachePath))
        XCTAssertNil(cacheBytes.range(of: Data(marker.utf8)), "the AI cache stores model output and uids, not the transcript")
    }

    // MARK: - hybrid Ask

    func testHybridAskOnlyCitesSuppliedMessagesAndFallsBackVisibly() async throws {
        let chats = [
            ChatSpec(id: 1, jid: "111@s.whatsapp.net", name: "One", isGroup: 0, person: "111"),
            ChatSpec(id: 2, jid: "222@s.whatsapp.net", name: "Two", isGroup: 0, person: "222"),
        ]
        let idx = try makeIndex(chats: chats, messages: [
            (1, 1, 1_000, "u1", "planning the demo trip", 0, 0),
            (2, 1, 2_000, "u2", "dinner on friday", 1, 0),
            (3, 2, 1_500, "u3", "the demo trip photos are here", 0, 0),
        ])
        let store = try VaultStore(path: idx)
        let vectors = try SemanticStore(path: tmp("vec"))
        let engine = IntegrationEmbedding(map: [
            "planning the demo trip": [1, 0, 0, 0],
            "dinner on friday": [0, 1, 0, 0],
            "the demo trip photos are here": [1, 0, 0, 0],
            "trip": [1, 0, 0, 0],
        ])
        let semantic = SemanticSearch(indexPath: idx, archiveScope: scope, store: vectors, engine: engine)
        _ = try await semantic.build()

        let hybrid = try await LocalAI.askResult("trip", store: store, chat: 1, model: .apple,
                                                 engine: IntegrationAnswerEngine(), semantic: semantic)
        guard case .hybrid(let keywordSeeds, let semanticSeeds) = hybrid.retrieval else {
            return XCTFail("expected hybrid retrieval, got \(hybrid.retrieval)")
        }
        XCTAssertGreaterThan(keywordSeeds, 0)
        XCTAssertGreaterThan(semanticSeeds, 0)
        XCTAssertGreaterThan(hybrid.searched, 0)
        XCTAssertTrue(hybrid.points.flatMap(\.sources).allSatisfy { $0.chatID == 1 },
                      "a chat-scoped Ask must not cite another chat")

        let offline = SemanticSearch(indexPath: idx, archiveScope: scope,
                                     store: try SemanticStore(path: tmp("vec")), engine: OfflineEmbedding())
        let fallback = try await LocalAI.askResult("trip", store: store, chat: nil, model: .apple,
                                                   engine: IntegrationAnswerEngine(), semantic: offline)
        guard case .keywordFallback = fallback.retrieval else {
            return XCTFail("semantic failure must be a visible keyword fallback")
        }
        XCTAssertFalse(fallback.points.isEmpty, "keyword results must survive a semantic failure")
    }

    // MARK: - demo fixture + real backend

    /// The synthetic demo must exercise all three data paths without private data: one direct chat ends
    /// on an unanswered question, topics can read its period, and semantic indexing has text to work on.
    func testDemoArchiveFeedsReplyTopicsAndSemanticInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoVault.generate(at: root)

        let store = try VaultStore(path: root.appendingPathComponent("vault_index.db").path)
        let now = DemoFixture.day("2026-11-07").addingTimeInterval(12 * 3_600)
        let scan = try ReplyResponsibility.find(store: store, quietDays: 3, now: now)
        let priya = try XCTUnwrap(scan.candidates.first { $0.chatJID == "demo-priya@lid" },
                                  "the demo should end one direct chat on an unanswered question")
        XCTAssertTrue(priya.preview.contains("?"))
        XCTAssertGreaterThanOrEqual(priya.quietDays, 3)
        let resolved = store.resolve(uids: [priya.id])
        XCTAssertNotNil(resolved[priya.id])

        let chats = try store.chats(kind: .all, sort: .recent, limit: 50)
        let chat = try XCTUnwrap(chats.first { $0.jid == "demo-priya@lid" })
        let read = try store.topicsRead(chat: chat.id, start: chat.last.addingTimeInterval(-30 * 86_400), end: chat.last)
        XCTAssertGreaterThan(read.readCount, 0)
        XCTAssertFalse(read.capped)
        let eligible = try store.semanticEligibleCount()
        XCTAssertGreaterThan(eligible, 10_000)
    }

    /// Exercises the real Apple sentence-embedding backend when this Mac has it, instead of only the fake engine.
    func testRealAppleSentenceEmbeddingsCoverASmallArchiveWhenAvailable() async throws {
        guard let provider = await SemanticSearch.providers().first(where: { $0.choice == .apple }) else {
            throw XCTSkip("Apple sentence embeddings are not available on this Mac")
        }
        let chats = [ChatSpec(id: 1, jid: "111@s.whatsapp.net", name: "Example", isGroup: 0, person: "111")]
        let idx = try makeIndex(chats: chats, messages: [
            (1, 1, 1_000, "u1", "we planned the train journey to the coast", 0, 0),
            (2, 1, 2_000, "u2", "the bakery on the corner opens early", 0, 0),
        ])
        let search = SemanticSearch(indexPath: idx, archiveScope: "vault:real-backend",
                                    store: try SemanticStore(path: tmp("vec")), provider: provider)
        let summary = try await search.build()
        XCTAssertGreaterThan(summary.embedded, 0)
        let coverage = try search.coverage()
        XCTAssertEqual(coverage, .current(total: 2))
    }

    /// Opt-in real-model check: generate topics for the demo's Priya Menon chat with Apple Intelligence.
    /// Run with `SAGA_AI_REAL=1 swift test --filter testRealAppleTopicsOnTheDemoWhenOptedIn`.
    func testRealAppleTopicsOnTheDemoWhenOptedIn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAGA_AI_REAL"] == "1",
                          "set SAGA_AI_REAL=1 to run one real on-device topics generation")
        guard case .available = LocalAI.appleStatus else {
            throw XCTSkip("Apple Intelligence is not available in this test process")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-real-topics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoVault.generate(at: root)

        let store = try VaultStore(path: root.appendingPathComponent("vault_index.db").path)
        let chats = try store.chats(kind: .all, sort: .recent, limit: 50)
        let chat = try XCTUnwrap(chats.first { $0.jid == "demo-priya@lid" })
        let end = chat.last
        let start = end.addingTimeInterval(-30 * 86_400)
        let read = try store.topicsRead(chat: chat.id, start: start, end: end)
        XCTAssertGreaterThan(read.readCount, 0)

        let cache = try AICache(path: tmp("cache"))
        let scope = VaultStore.archiveScope(vaultURL: root.appendingPathComponent("vault"),
                                            indexPath: root.appendingPathComponent("vault_index.db").path)
        let points = try await LocalAI.topics(read.rows, chatID: chat.id, chatJID: chat.jid, chatName: chat.name,
                                              isGroup: chat.isGroup, archiveScope: scope, days: 30,
                                              periodStart: start, periodEnd: end, model: .apple, cache: cache)
        XCTAssertFalse(points.isEmpty)
        XCTAssertLessThanOrEqual(points.count, LocalAI.maxTopics)
        XCTAssertTrue(points.allSatisfy { !$0.sources.isEmpty && $0.sources.count <= 3 })
        let sourceUIDs = points.flatMap { $0.sources.map(\.uid) }
        let resolved = store.resolve(uids: sourceUIDs)
        XCTAssertEqual(resolved.count, Set(sourceUIDs).count)
        print("REAL-TOPICS points=\(points.count) sources=\(sourceUIDs.count) resolved=\(resolved.count)")
    }
}
