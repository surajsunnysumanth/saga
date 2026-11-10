import XCTest
@testable import SagaCore

final class AITests: XCTestCase {
    func testParseAcceptsObjectsFencesStringsAndBareArrays() {
        let a = AIParse.json(from: #"{"points":[{"text":"Dinner on Friday","refs":[3,"4"]}]}"#)
        XCTAssertEqual(a?.points.first?.text, "Dinner on Friday"); XCTAssertEqual(a?.points.first?.refs, [3, 4])
        let b = AIParse.json(from: "Sure! ```json\n{\"points\":[{\"text\":\"x\",\"refs\":[]}]}\n```")
        XCTAssertEqual(b?.points.count, 1)
        let c = AIParse.json(from: #"[{"text":"y","refs":["[7]"]}]"#)
        XCTAssertEqual(c?.points.first?.refs, [7])
        XCTAssertNil(AIParse.json(from: "no json here"))
        XCTAssertNil(AIParse.json(from: #"{"points":[{"text":"  ","refs":[1]}]}"#))   // a blank point is not an answer
    }

    func rows(_ texts: [String]) -> [MessageRow] {
        texts.enumerated().map { i, t in
            var r = MessageRow(id: Int64(i + 1), ts: Date(timeIntervalSince1970: Double(1000 + i)), fromMe: i % 2 == 0, sender: "Asha", personKey: "p", text: t, mediaKind: nil)
            r.uid = "uid\(i + 1)"; return r
        }
    }

    func testEntriesDropFillerAndPartsAreNumberedLocallyWithStableKeys() {
        let r = rows(["ok", "👍👍", "https://a.example/x", "Shall we plan the trip in December?", "Shall we plan the trip in December?", "yes lets book flights"])
        let e = LocalAI.entries(r, chatID: 1)
        XCTAssertEqual(e.count, 3)                                   // filler and link-only are gone (the repeat is from the other person, so it stays)
        let long = LocalAI.entries(rows((1...60).map { "message number \($0) " + String(repeating: "x", count: 100) }), chatID: 1)
        let p = LocalAI.parts(long, maxChars: 1000)
        XCTAssertGreaterThan(p.count, 3)
        XCTAssertTrue(p.allSatisfy { $0.refs.keys.min() == 1 && $0.text.hasPrefix("[1] ") })      // each part restarts at [1]
        XCTAssertEqual(p.reduce(0) { $0 + $1.refs.count }, 60)
        // same messages in a different window give the same part text, so saved results are reused
        let p2 = LocalAI.parts(Array(long.prefix(10)), maxChars: 1000)
        XCTAssertEqual(p.first?.text, p2.first?.text)
        XCTAssertEqual(LocalAI.hash("m", "v", "k", "t"), LocalAI.hash("m", "v", "k", "t"))
        XCTAssertNotEqual(LocalAI.hash("m1", "v", "k", "t"), LocalAI.hash("m2", "v", "k", "t"))
    }

    func testQuickDetailCapsPartsForHugePeriodsAndFullDoesNot() {
        let big = rows((1...3000).map { "message number \($0) about the plan " + String(repeating: "word ", count: 60) })
        let quick = LocalAI.prepared(big, chatID: 1, model: .apple, detail: .quick)
        let full = LocalAI.prepared(big, chatID: 1, model: .apple, detail: .full)
        XCTAssertLessThanOrEqual(quick.count, LocalAI.quickMaxParts)
        XCTAssertGreaterThan(full.count, quick.count * 3)
        XCTAssertEqual(full.reduce(0) { $0 + $1.refs.count }, 3000)
        // a short period is untouched by quick mode
        XCTAssertEqual(LocalAI.prepared(Array(big.prefix(20)), chatID: 1, model: .apple, detail: .quick).count, LocalAI.prepared(Array(big.prefix(20)), chatID: 1, model: .apple, detail: .full).count)
    }

    func testCacheRoundTripsSummariesAndParts() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aic-\(UUID().uuidString).db").path
        let c = try AICache(path: path)
        XCTAssertNil(c.summary(key: "k"))
        c.saveSummary(key: "k", lastTS: 123, messageCount: 7, points: [.init(text: "Dinner \"Friday\" 🍷", uids: ["a", "b"])])
        let again = try AICache(path: path)                             // survives reopening
        let s = try XCTUnwrap(again.summary(key: "k"))
        XCTAssertEqual(s.points.first?.text, "Dinner \"Friday\" 🍷"); XCTAssertEqual(s.points.first?.uids, ["a", "b"]); XCTAssertEqual(s.messageCount, 7)
        XCTAssertNil(again.chunk(hash: "h"))
        again.saveChunk(hash: "h", points: [.init(text: "x", uids: ["u"])])
        XCTAssertEqual(again.chunk(hash: "h")?.first?.uids, ["u"])
    }

    func testRetrievalFindsKeywordMatchesWithContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        INSERT INTO message VALUES (1,10,0,NULL,1000,0,'morning','a'),(2,10,0,NULL,2000,0,'shall we plan the Goa trip in December?','b'),(3,10,1,NULL,3000,0,'yes lets book flights','c'),(4,10,0,NULL,4000,0,'unrelated lunch talk','d');
        """)
        let idx = dir.appendingPathComponent("i.db").path
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: idx))
        let st = try VaultStore(path: idx)
        let r = try st.retrieve(question: "When did we plan the Goa trip?", chat: nil, maxHits: 5, context: 1)
        XCTAssertTrue(r.contains { $0.text.contains("Goa") })
        XCTAssertTrue(r.contains { $0.text == "yes lets book flights" })                 // neighbouring message included as context
        XCTAssertTrue(try st.retrieve(question: "what about it?", chat: nil).isEmpty)    // only stopwords: nothing to search
    }
}
