import XCTest
@testable import SagaCore

final class MediaServiceExpansionTests: XCTestCase {
    func testSpotifyShortLinksAreVisibleWithoutNetwork() throws {
        for host in ["spotify.link", "spotify.app.link"] {
            let link = try XCTUnwrap(MediaLinks.classify("https://\(host)/AbC123?si=tracking"))
            XCTAssertEqual(link.service, .spotify)
            XCTAssertEqual(link.kind, "short link")
            XCTAssertEqual(link.clean, "https://\(host)/AbC123")
            XCTAssertEqual(link.embed, "")
        }
        for raw in ["https://spotify.link", "https://spotify.app.link/a/b", "https://spotify.link.evil.test/a", "https://example.com/a"] {
            XCTAssertNil(MediaLinks.classify(raw))
        }
    }

    private func shared(_ raw: String) throws -> SharedLink {
        let c = try XCTUnwrap(MediaLinks.classify(raw))
        return SharedLink(messageID: 1, chatID: 2, uid: "synthetic", ts: Date(timeIntervalSince1970: 0), sender: "Example", fromMe: false, chatName: "Example chat", url: c.clean, service: c.service, kind: c.kind, embedURL: c.embed, key: c.key, youtubeID: c.ytID, slugTitle: c.slug)
    }

    func testShortResolutionRequiresConsentAndPersistsCanonicalTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("link_meta.db").path
        let cache = try LinkMetaCache(path: path)
        let link = try shared("https://spotify.app.link/Example")
        let offline = await MediaLinks.resolve(link, allowNetwork: false, cache: cache) { _ in
            XCTFail("No request without consent"); throw URLError(.cancelled)
        }
        XCTAssertEqual(offline, link)
        let target = URL(string: "https://open.spotify.com/intl-en/track/4uLU6hMCjMI75M1A2tKUQC?si=example")!
        let resolved = await MediaLinks.resolve(link, allowNetwork: true, cache: cache) { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.absoluteString, link.url)
            return (target, 200)
        }
        XCTAssertEqual(resolved.kind, "track")
        XCTAssertEqual(resolved.key, "sp:4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(resolved.uid, link.uid)
        let reopened = try LinkMetaCache(path: path)
        let cached = await MediaLinks.resolve(link, allowNetwork: false, cache: reopened) { _ in
            XCTFail("Cached resolution must not request"); throw URLError(.cancelled)
        }
        XCTAssertEqual(cached, resolved)
    }

    func testShortResolutionRejectsUnsupportedAndFailedTargets() async throws {
        let link = try shared("https://spotify.link/Example")
        for target in ["https://example.com/track/4uLU6hMCjMI75M1A2tKUQC", "https://open.spotify.com/user/example", "https://spotify.link/Other", "https://youtu.be/dQw4w9WgXcQ"] {
            let result = await MediaLinks.resolve(link, allowNetwork: true, cache: nil) { _ in (URL(string: target)!, 200) }
            XCTAssertEqual(result, link)
        }
        let failed = await MediaLinks.resolve(link, allowNetwork: true, cache: nil) { _ in throw URLError(.timedOut) }
        XCTAssertEqual(failed, link)
        let missing = await MediaLinks.resolve(link, allowNetwork: true, cache: nil) { _ in (URL(string: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")!, 404) }
        XCTAssertEqual(missing, link)
    }

    func testStoreIncludesNewServicesAndRetainsScopeAndCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE chats(chat_id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE messages(id INTEGER PRIMARY KEY, chat_id INT, uid TEXT, ts INT, sender TEXT, from_me INT, text TEXT);
        INSERT INTO chats VALUES(1,'Example'),(2,'Other');
        INSERT INTO messages VALUES(1,1,'a',1000,'Example',0,'https://spotify.link/Example'),
          (2,1,'b',2000,'Example',0,'https://spotify.app.link/Other'),
          (3,1,'c',3000,'Example',0,'https://soundcloud.com/artist/track'),
          (4,1,'d',4000,'Example',0,'https://soundcloud.com/artist/track?utm_source=share'),
          (5,2,'e',5000,'Example',0,'https://soundcloud.com/artist/track'),
          (6,1,'f',6000,'Example',0,'https://soundcloud.com/discover');
        """)
        let store = try VaultStore(path: path)
        let chat = try store.sharedLinks(chat: 1)
        XCTAssertEqual(chat.map(\.link.service.rawValue), ["Spotify", "Spotify", "SoundCloud"])
        XCTAssertEqual(chat.map(\.times), [1, 1, 2])
        XCTAssertEqual(try store.sharedLinks(chat: nil).count, 4)
        XCTAssertEqual(try store.sharedLinks(chat: 1, services: [.spotify]).count, 2)
        let sound = try shared("https://soundcloud.com/artist/track")
        XCTAssertEqual(MediaLinks.oembedURL(for: sound)?.host, "soundcloud.com")
    }

    func testSoundCloudTracksSetsAndWidget() throws {
        for raw in ["https://soundcloud.com/example-artist/example-track?utm_source=share", "https://www.soundcloud.com/example-artist/example-track", "https://m.soundcloud.com/example-artist/example-track"] {
            let link = try XCTUnwrap(MediaLinks.classify(raw))
            XCTAssertEqual(link.service.rawValue, "SoundCloud")
            XCTAssertEqual(link.clean, "https://soundcloud.com/example-artist/example-track")
            XCTAssertEqual(link.kind, "track")
            let embed = try XCTUnwrap(URLComponents(string: link.embed))
            XCTAssertEqual(embed.host, "w.soundcloud.com")
            XCTAssertEqual(embed.queryItems?.first { $0.name == "url" }?.value, link.clean)
            XCTAssertEqual(embed.queryItems?.first { $0.name == "auto_play" }?.value, "false")
            XCTAssertEqual(MediaLinks.classify(link.embed)?.key, link.key)
        }
        XCTAssertEqual(MediaLinks.classify("https://soundcloud.com/example-artist/sets/example-set")?.kind, "playlist")
        for raw in ["https://soundcloud.com", "https://soundcloud.com/discover", "https://soundcloud.com/example-artist", "https://soundcloud.com/example-artist/likes", "https://soundcloud.com.evil.test/a/b", "file://soundcloud.com/a/b", "https://w.soundcloud.com/player/?url=https://example.com/a/b"] {
            XCTAssertNil(MediaLinks.classify(raw), raw)
        }
    }

    func testSoundCloudShortLinksResolveWithConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("link_meta.db").path
        let cache = try LinkMetaCache(path: path)
        let link = try shared("https://on.soundcloud.com/AbC123?si=example")
        XCTAssertEqual(link.service, .soundCloud)
        XCTAssertEqual(link.kind, "short link")
        XCTAssertEqual(link.url, "https://on.soundcloud.com/AbC123")
        XCTAssertTrue(link.embedURL.isEmpty)

        let offline = await MediaLinks.resolve(link, allowNetwork: false, cache: cache) { _ in
            XCTFail("No request without consent"); throw URLError(.cancelled)
        }
        XCTAssertEqual(offline, link)

        let target = URL(string: "https://soundcloud.com/example-artist/example-track?utm_source=clipboard")!
        let resolved = await MediaLinks.resolve(link, allowNetwork: true, cache: cache) { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.absoluteString, link.url)
            return (target, 200)
        }
        XCTAssertEqual(resolved.kind, "track")
        XCTAssertEqual(resolved.key, "sc:example-artist/example-track")
        XCTAssertEqual(resolved.url, "https://soundcloud.com/example-artist/example-track")
        let embed = try XCTUnwrap(URLComponents(string: resolved.embedURL))
        XCTAssertEqual(embed.host, "w.soundcloud.com")
        XCTAssertEqual(embed.queryItems?.first { $0.name == "url" }?.value, "https://soundcloud.com/example-artist/example-track")
        XCTAssertEqual(resolved.uid, link.uid)

        let reopened = try LinkMetaCache(path: path)
        let cached = await MediaLinks.resolve(link, allowNetwork: false, cache: reopened) { _ in
            XCTFail("Cached resolution must not request"); throw URLError(.cancelled)
        }
        XCTAssertEqual(cached, resolved)

        let playable = try shared("https://soundcloud.com/example-artist/example-track")
        let untouched = await MediaLinks.resolve(playable, allowNetwork: true, cache: cache) { _ in
            XCTFail("Playable links are never resolved"); throw URLError(.cancelled)
        }
        XCTAssertEqual(untouched, playable)
    }

    func testShortLinksRejectWrongServiceAndUnsupportedShapes() async throws {
        let sound = try shared("https://on.soundcloud.com/AbC123")
        for target in ["https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", "https://soundcloud.com/discover",
                       "https://on.soundcloud.com/AnotherShortCode", "https://example.com/a/b"] {
            let result = await MediaLinks.resolve(sound, allowNetwork: true, cache: nil) { _ in (URL(string: target)!, 200) }
            XCTAssertEqual(result, sound, target)
        }
        let spotify = try shared("https://spotify.link/Example")
        let crossed = await MediaLinks.resolve(spotify, allowNetwork: true, cache: nil) { _ in (URL(string: "https://soundcloud.com/example-artist/example-track")!, 200) }
        XCTAssertEqual(crossed, spotify)

        for raw in ["https://on.soundcloud.com", "https://on.soundcloud.com/", "https://on.soundcloud.com/a/b",
                    "https://on.soundcloud.com.evil.test/AbC123", "https://on.soundcloud.com/%3Cscript%3E"] {
            XCTAssertNil(MediaLinks.classify(raw), raw)
        }
        XCTAssertEqual(MediaLinks.redirectHosts(for: .soundCloud), ["on.soundcloud.com", "soundcloud.com", "m.soundcloud.com", "w.soundcloud.com"])
        XCTAssertEqual(MediaLinks.redirectHosts(for: .spotify), ["spotify.link", "spotify.app.link", "open.spotify.com", "play.spotify.com"])
        XCTAssertTrue(MediaLinks.redirectHosts(for: .youtube).isEmpty)
    }
}

final class MediaLinkExportTests: XCTestCase {
    private func link(_ raw: String, chat: String = "Example chat") throws -> SharedLink {
        let c = try XCTUnwrap(MediaLinks.classify(raw))
        return SharedLink(messageID: 1, chatID: 2, uid: "u", ts: Date(timeIntervalSince1970: 0), sender: "Example", fromMe: false, chatName: chat, url: c.clean, service: c.service, kind: c.kind, embedURL: c.embed, key: c.key, youtubeID: c.ytID, slugTitle: c.slug)
    }

    func testM3U() throws {
        let a = try link("https://soundcloud.com/artist/track")
        let b = try link("https://spotify.link/Abc")
        let text = MediaLinkExport.m3u([(a, "Line\nbreak"), (b, nil)])
        XCTAssertEqual(text, "#EXTM3U\n#EXTINF:-1,Line break\nhttps://soundcloud.com/artist/track\n#EXTINF:-1,Spotify short link\nhttps://spotify.link/Abc\n")
        XCTAssertEqual(MediaLinkExport.m3u([]), "#EXTM3U\n")
    }

    func testCSVQuotingAndFormulaGuard() throws {
        let a = try link("https://soundcloud.com/artist/track", chat: "=HYPERLINK(\"x\")")
        let csv = MediaLinkExport.csv([(a, "A, \"B\"", 2)])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "date,service,kind,title,url,chat,sender,times")
        XCTAssertEqual(lines[1], "1970-01-01T00:00:00Z,SoundCloud,track,\"A, \"\"B\"\"\",https://soundcloud.com/artist/track,\"'=HYPERLINK(\"\"x\"\")\",Example,2")
        XCTAssertEqual(lines.count, 3)
    }
}
