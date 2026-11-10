import XCTest
@testable import SagaCore

final class MCPTests: XCTestCase {
    func server(blocked: [String] = []) throws -> MCPServer {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),(2,'1203630000','g.us',0,0,0,'1203630000@g.us');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,'Secret Club');
        INSERT INTO message VALUES (1,10,0,NULL,1700000000000,0,'dinner on friday?','a'),(2,10,1,NULL,1700000060000,0,'yes friday works','b'),(3,11,1,NULL,1700000100000,0,'friday plan is secret','c');
        INSERT INTO jid VALUES (3,'919800000001','s.whatsapp.net',0,0,0,'919800000001@s.whatsapp.net');
        INSERT INTO chat VALUES (12,3,NULL);
        INSERT INTO message VALUES (4,12,1,NULL,1700000200000,7,NULL,'d'),(5,12,0,NULL,1700000300000,7,NULL,'e');
        """)
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: dir.appendingPathComponent("i.db").path, extraContacts: ["9833052771": "Asha"]))
        var c = MCPServer.Config(); c.blockedChats = blocked
        return try MCPServer(indexPath: dir.appendingPathComponent("i.db").path, config: c)
    }
    func rpc(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let line = String(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]), encoding: .utf8)!
        return try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(s.handle(line: line)).utf8)) as! [String: Any]
    }
    func text(_ r: [String: Any]) -> String { ((r["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String }
    func toolNames(_ s: MCPServer) throws -> [String] {
        (((try rpc(s, "tools/list"))["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    func testProtocolAndSearch() throws {
        let s = try server()
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertTrue(try toolNames(s).contains("sql_query"))
        let hit = text(try rpc(s, "tools/call", ["name": "search_messages", "arguments": ["query": "friday"]]))
        XCTAssertTrue(hit.contains("Asha")); XCTAssertTrue(hit.contains("Secret Club"))
        XCTAssertNotNil((try rpc(s, "nope"))["error"])
        let bad = try rpc(s, "tools/call", ["name": "sql_query", "arguments": ["sql": "delete from messages"]])
        XCTAssertEqual((bad["result"] as! [String: Any])["isError"] as? Bool, true)
    }

    func testBlockListHidesChatsAndDisablesSQL() throws {
        let s = try server(blocked: ["secret"])
        let hit = text(try rpc(s, "tools/call", ["name": "search_messages", "arguments": ["query": "friday"]]))
        XCTAssertTrue(hit.contains("Asha")); XCTAssertFalse(hit.contains("Secret Club"))
        XCTAssertFalse(text(try rpc(s, "tools/call", ["name": "list_chats", "arguments": ["sort": "name"]])).contains("Secret"))
        XCTAssertFalse(try toolNames(s).contains("sql_query"))
    }

    func testChatsWithOnlySystemNoticesAreHidden() throws {
        let s = try server()
        XCTAssertEqual(try s.store.chats(minMessages: 1).count, 2)
        XCTAssertEqual(try s.store.chats(minMessages: 1, includeEmpty: true).count, 3)
    }
}
