import XCTest
@testable import SagaCore

final class MediaLinksTests: XCTestCase {
    func one(_ u: String) -> (service: MediaService, kind: String, embed: String, key: String, clean: String, ytID: String?, slug: String?)? { MediaLinks.classify(u) }

    func testSpotify() throws {
        let t = try XCTUnwrap(one("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc123"))
        XCTAssertEqual(t.service, .spotify); XCTAssertEqual(t.kind, "track")
        XCTAssertEqual(t.embed, "https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(t.clean, "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")           // tracking id removed
        XCTAssertEqual(one("https://open.spotify.com/intl-fr/album/1DFixLWuPkv3KT3TnV35m3")?.kind, "album")
        XCTAssertEqual(one("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")?.kind, "playlist")
        XCTAssertNil(one("https://open.spotify.com/user/someone"))
    }

    func testYouTubeVariants() throws {
        let id = "dQw4w9WgXcQ"
        for u in ["https://www.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)?si=xyz", "https://m.youtube.com/watch?v=\(id)&feature=share", "https://youtube.com/shorts/\(id)", "https://www.youtube.com/live/\(id)"] {
            let c = try XCTUnwrap(one(u), u); XCTAssertEqual(c.ytID, id, u); XCTAssertEqual(c.key, "yt:\(id)")
        }
        XCTAssertEqual(one("https://youtu.be/\(id)?t=90")?.embed, "https://www.youtube.com/embed/\(id)?start=90")
        let m = try XCTUnwrap(one("https://music.youtube.com/watch?v=\(id)&si=a"))
        XCTAssertEqual(m.service, .youtubeMusic); XCTAssertEqual(m.clean, "https://music.youtube.com/watch?v=\(id)")
        XCTAssertEqual(one("https://www.youtube.com/playlist?list=PLabc123")?.embed, "https://www.youtube.com/embed/videoseries?list=PLabc123")
        XCTAssertNil(one("https://www.youtube.com/@somechannel"))
        XCTAssertNil(one("https://www.youtube.com/watch?v=short"))
    }

    func testAppleMusic() throws {
        let a = try XCTUnwrap(one("https://music.apple.com/in/album/blinding-lights/1499378108?i=1499378112&uo=4"))
        XCTAssertEqual(a.service, .appleMusic); XCTAssertEqual(a.kind, "track")                  // ?i= means one song from the album
        XCTAssertEqual(one("https://music.apple.com/in/album/after-hours/1499378108")?.kind, "album")
        XCTAssertEqual(a.embed, "https://embed.music.apple.com/in/album/blinding-lights/1499378108?i=1499378112")
        XCTAssertEqual(a.key, "am:1499378112"); XCTAssertEqual(a.slug, "Blinding Lights")
        XCTAssertNil(one("https://music.apple.com/in/browse"))
    }

    func testFindsLinksInMessyText() {
        let t = "*listen* https://youtu.be/dQw4w9WgXcQ. and (https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x), also https://example.com/a"
        let l = MediaLinks.links(in: t)
        XCTAssertEqual(l.map(\.service), [.youtube, .spotify])
    }

    func testStoreListsOldestFirstAndCountsRepeats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        INSERT INTO message VALUES (1,10,0,NULL,3000,0,'https://youtu.be/dQw4w9WgXcQ','a'),(2,10,1,NULL,1000,0,'try this https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC','b'),
          (3,10,1,NULL,5000,0,'https://www.youtube.com/watch?v=dQw4w9WgXcQ again!','c'),(4,10,0,NULL,6000,0,'no links here','d');
        """)
        let idx = dir.appendingPathComponent("i.db").path
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: idx))
        let st = try VaultStore(path: idx)
        let all = try st.sharedLinks(chat: nil)
        XCTAssertEqual(all.map(\.link.service), [.spotify, .youtube])                    // oldest first
        XCTAssertEqual(all[1].times, 2)                                                  // same video shared twice, listed once
        XCTAssertEqual(try st.sharedLinks(chat: nil, services: [.youtube]).count, 1)
        XCTAssertEqual(MediaLinks.youtubePlaylistURL(ids: ["a", "a", "b"])?.absoluteString, "https://www.youtube.com/watch_videos?video_ids=a,b")
    }
}
