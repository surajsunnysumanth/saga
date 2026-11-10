import XCTest
@testable import SagaCore

private actor TopicEngine: AIEngine {
    var calls = 0
    var fail = false
    var many = 0
    func setFail(_ f: Bool) { fail = f }
    func setMany(_ n: Int) { many = n }
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        calls += 1
        if fail { throw AIError(message: "synthetic failure") }
        if many > 0 { return EngineOut(points: (0..<many).map { AIParse.Point(text: "Topic \(calls)-\($0)", refs: [1]) }) }
        return EngineOut(points: [AIParse.Point(text: "Synthetic planning", refs: [1, 2]),
                                  AIParse.Point(text: "Unsupported", refs: [99999]),
                                  AIParse.Point(text: "No evidence", refs: [])])
    }
    func count() -> Int { calls }
}

private final class Box: @unchecked Sendable { var v = 0 }
private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
private struct FlakyEngine: AIEngine {
    let c = Counter()
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        if await c.next() == 1 { throw AIError(message: "synthetic failure") }
        return EngineOut(points: [AIParse.Point(text: "Planning", refs: [1])])
    }
}
private struct SlowEngine: AIEngine {
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        try await Task.sleep(nanoseconds: 5_000_000_000); return EngineOut(points: [])
    }
}

final class TopicsTests: XCTestCase {
    func rows(_ count: Int = 3, text: String = "Synthetic planning message", sender: String = "Example") -> [MessageRow] {
        (0..<count).map { i in
            var r = MessageRow(id: Int64(i + 1), ts: Date(timeIntervalSince1970: Double(1000 + i)), fromMe: false, sender: sender, personKey: "p", text: "\(text) \(i)", mediaKind: nil)
            r.uid = "topic-\(i)"; return r
        }
    }
    func tmp(_ n: String = "db") -> String { FileManager.default.temporaryDirectory.appendingPathComponent("topics-\(UUID().uuidString).\(n)").path }
    private func run(_ r: [MessageRow], chat: Int64 = 1, jid: String = "example", scope: String = "archive", start: Date = .distantPast, end: Date = .distantFuture,
                     model: AIModel = .apple, cache: AICache?, engine: any AIEngine, progress: @Sendable (LocalAI.TopicsProgress) -> Void = { _ in }) async throws -> [SummaryPoint] {
        try await LocalAI.topics(r, chatID: chat, chatJID: jid, chatName: "Example", isGroup: false, archiveScope: scope, days: 30, periodStart: start, periodEnd: end, model: model, cache: cache, engine: engine, progress: progress)
    }
    private func saved(_ r: [MessageRow], chat: Int64, scope: String = "archive", cache: AICache, store: VaultStore) -> LocalAI.SavedTopics? {
        LocalAI.savedTopics(rows: r, chatID: chat, chatJID: "example", archiveScope: scope, days: 30, periodStart: .distantPast, periodEnd: .distantFuture, modelID: "apple", cache: cache, store: store)
    }

    func testGenerationValidatesCitationsAndReopenedCacheAvoidsModelCalls() async throws {
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let engine = TopicEngine()
        let a = try await run(rows(), cache: AICache(path: path), engine: engine)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].sources.map(\.uid), ["topic-0", "topic-1"])
        let b = try await run(rows(), chat: 8, cache: AICache(path: path), engine: engine)
        let calls = await engine.count()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(b[0].sources.map(\.chatID), [8, 8])
    }

    func testChangedInputWithSameCountAndLatestTimestampInvalidates() async throws {
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try AICache(path: path), engine = TopicEngine()
        _ = try await run(rows(), cache: cache, engine: engine)
        _ = try await run(rows(text: "Different synthetic wording"), cache: cache, engine: engine)
        _ = try await run(rows(sender: "Renamed"), cache: cache, engine: engine)
        let n1 = await engine.count(); XCTAssertEqual(n1, 3)
    }

    func testIsolationByArchiveChatModelAndPeriod() async throws {
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try AICache(path: path), engine = TopicEngine()
        _ = try await run(rows(), cache: cache, engine: engine)
        _ = try await run(rows(), scope: "other", cache: cache, engine: engine)
        _ = try await run(rows(), jid: "other-chat", cache: cache, engine: engine)
        _ = try await run(rows(), model: .server(.ollama, base: "http://127.0.0.1:11434", model: "m"), cache: cache, engine: engine)
        _ = try await run(rows(), start: Date(timeIntervalSince1970: 5), cache: cache, engine: engine)
        let n = await engine.count(); XCTAssertEqual(n, 5)
        _ = try await run(rows(), cache: cache, engine: engine)
        let m = await engine.count(); XCTAssertEqual(m, 5)
    }

    func testCapsAtEightTopicsAndMergesLongLists() async throws {
        let engine = TopicEngine(); await engine.setMany(20)
        let out = try await run(rows(5), cache: nil, engine: engine)
        XCTAssertLessThanOrEqual(out.count, LocalAI.maxTopics)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { !$0.sources.isEmpty && $0.sources.count <= 3 })
    }

    func testFailureThrowsAndPartialRunIsNotSavedAsComplete() async throws {
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try AICache(path: path), engine = TopicEngine()
        await engine.setFail(true)
        do { _ = try await run(rows(), cache: cache, engine: engine); XCTFail("should throw") } catch is AIError {}
        let big = (0..<60).map { i -> MessageRow in
            var r = MessageRow(id: Int64(i + 1), ts: Date(timeIntervalSince1970: Double(1000 + i)), fromMe: false, sender: "S", personKey: "p", text: "message \(i) " + String(repeating: "long synthetic words ", count: 20), mediaKind: nil)
            r.uid = "big-\(i)"; return r
        }
        let skipped = Box()
        let pts = try await run(big, cache: cache, engine: FlakyEngine(), progress: { skipped.v = $0.skipped })
        XCTAssertFalse(pts.isEmpty); XCTAssertGreaterThan(skipped.v, 0)
        XCTAssertNil(saved(big, chat: 1, cache: cache, store: try makeIndex(rows: [])))
    }

    func testCancellationPropagates() async throws {
        let r = rows()
        let t = Task { try await LocalAI.topics(r, chatID: 1, chatJID: "j", chatName: "E", isGroup: false, archiveScope: "a", periodStart: .distantPast, periodEnd: .distantFuture, model: .apple, cache: nil, engine: SlowEngine()) }
        t.cancel()
        do { _ = try await t.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }

    // MARK: store

    typealias Row = (id: Int, chat: Int, ts: Int64, uid: String, text: String)
    func makeIndex(rows: [Row]) throws -> VaultStore {
        let path = tmp("sqlite")
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        let ins = try db.prepare("INSERT INTO messages(id, chat_id, from_me, sender, person, ts, type, text, uid) VALUES(?,?,0,'S','p',?,0,?,?)")
        try db.exec("BEGIN")
        for r in rows { try ins.run([.int(Int64(r.id)), .int(Int64(r.chat)), .int(r.ts), .text(r.text), .text(r.uid)]) }
        try db.exec("COMMIT")
        return try VaultStore(path: path)
    }

    func testSavedTopicsResolveFreshAndDropPrunedCitationsAndShowStale() async throws {
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try AICache(path: path), engine = TopicEngine()
        let r = rows()
        _ = try await run(r, cache: cache, engine: engine)
        let rebuilt = try makeIndex(rows: r.enumerated().map { (id: 500 + $0.offset, chat: 77, ts: Int64($0.element.ts.timeIntervalSince1970 * 1000), uid: $0.element.uid, text: $0.element.text) })
        let cur = saved(r, chat: 77, cache: cache, store: rebuilt)
        XCTAssertEqual(cur?.isCurrent, true)
        XCTAssertEqual(cur?.points[0].sources.map(\.messageID), [500, 501])
        XCTAssertEqual(cur?.points[0].sources.map(\.chatID), [77, 77])
        var x = MessageRow(id: 9, ts: Date(timeIntervalSince1970: 2000), fromMe: false, sender: "Example", personKey: "p", text: "A brand new message", mediaKind: nil); x.uid = "new"
        XCTAssertEqual(saved(r + [x], chat: 77, cache: cache, store: rebuilt)?.isCurrent, false)
        let pruned = try makeIndex(rows: [(id: 1, chat: 1, ts: 1000, uid: "unrelated", text: "x")])
        XCTAssertNil(saved(r, chat: 1, cache: cache, store: pruned))
        XCTAssertNil(saved(r, chat: 77, scope: "elsewhere", cache: cache, store: rebuilt))
    }

    func testPeriodReadIsBoundedInclusiveAndTieSafe() throws {
        var data: [Row] = []
        for i in 0..<50 { data.append((id: i + 1, chat: 1, ts: Int64(1000 + i / 5), uid: "u\(i)", text: "m\(i)")) }
        data.append((id: 100, chat: 2, ts: 1001, uid: "other-chat", text: "x"))
        let st = try makeIndex(rows: data)
        let all = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 1.0), end: Date(timeIntervalSince1970: 1.009), pageSize: 7)
        XCTAssertEqual(all.rows.count, 50); XCTAssertFalse(all.capped)
        XCTAssertEqual(Set(all.rows.map(\.uid)).count, 50)
        let window = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 1.002), end: Date(timeIntervalSince1970: 1.004), pageSize: 4)
        XCTAssertEqual(window.rows.count, 15)
        let capped = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2), cap: 12, pageSize: 5)
        XCTAssertTrue(capped.capped); XCTAssertEqual(capped.inPeriod, 50)
        XCTAssertEqual(capped.rows.map(\.uid), (38..<50).map { "u\($0)" })
    }

    func testPeriodReadCountsOnlyVisibleMessages() throws {
        var data: [Row] = []
        for i in 0..<10 { data.append((id: i + 1, chat: 1, ts: 1000 + Int64(i), uid: "v\(i)", text: "visible \(i)")) }
        for i in 0..<5 { data.append((id: 100 + i, chat: 1, ts: 1000 + Int64(i), uid: "e\(i)", text: "")) }
        let st = try makeIndex(rows: data)
        let read = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 1.0), end: Date(timeIntervalSince1970: 1.02))
        XCTAssertEqual(read.inPeriod, 10); XCTAssertEqual(read.readCount, 10); XCTAssertFalse(read.capped)
        XCTAssertFalse(read.rows.contains { $0.uid.hasPrefix("e") })
        let capped = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2), cap: 4, pageSize: 3)
        XCTAssertTrue(capped.capped); XCTAssertEqual(capped.inPeriod, 10); XCTAssertEqual(capped.readCount, 4)
        XCTAssertEqual(capped.rows.map(\.uid), ["v6", "v7", "v8", "v9"])
    }

    func testArchiveScopeReadsVaultIDWithoutCreatingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(VaultStore.archiveScope(vaultURL: dir, indexPath: "/x/index.db").hasPrefix("index:"))
        try Data(#"{"app":"saga","format":1,"id":"abc-123"}"#.utf8).write(to: dir.appendingPathComponent("vault.json"))
        XCTAssertEqual(VaultStore.archiveScope(vaultURL: dir, indexPath: "/x/index.db"), "vault:abc-123")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["vault.json"])
    }

    func testHundredThousandMessageThroughput() async throws {
        let n = 100_000
        let data: [Row] = (0..<n).map { (id: $0 + 1, chat: 1, ts: Int64(1_000_000 + $0 * 1000), uid: "p\($0)", text: "synthetic words about plan number \($0) and other things") }
        let st = try makeIndex(rows: data)
        let t0 = Date()
        let read = try st.topicsRead(chat: 1, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1e9))
        let readT = Date().timeIntervalSince(t0)
        XCTAssertEqual(read.rows.count, VaultStore.topicsMaxMessages); XCTAssertTrue(read.capped); XCTAssertEqual(read.inPeriod, n)
        let path = tmp(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cache = try AICache(path: path), engine = TopicEngine()
        let t1 = Date()
        let first = try await run(read.rows, cache: cache, engine: engine)
        let genT = Date().timeIntervalSince(t1)
        let calls1 = await engine.count()
        let t2 = Date()
        _ = try await run(read.rows, cache: try AICache(path: path), engine: engine)
        let hitT = Date().timeIntervalSince(t2)
        let calls2 = await engine.count()
        XCTAssertEqual(calls1, calls2); XCTAssertFalse(first.isEmpty)
        XCTAssertLessThanOrEqual(calls1, LocalAI.quickMaxParts + 1)
        print("TOPICS-BENCH messages=\(n) read=\(read.rows.count) read_s=\(String(format: "%.2f", readT)) fake_engine_calls=\(calls1) generate_s=\(String(format: "%.2f", genT)) cache_hit_s=\(String(format: "%.2f", hitT)) (fake engine; not real model speed)")
    }
}
