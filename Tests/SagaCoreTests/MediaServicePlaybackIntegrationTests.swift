import XCTest
import JavaScriptCore
@testable import SagaCore

/// Cross-feature checks for the music & video panel: the service list and the
/// one-player-at-a-time rule were built separately, so these tests hold the seam:
/// every service the panel now lists must mount through the same safe player page,
/// and the new short-link shapes must not create rows or players that break it.
final class MediaServicePlaybackIntegrationTests: XCTestCase {
    private func shared(_ raw: String, id: Int64 = 1, chat: Int64 = 2) throws -> SharedLink {
        let c = try XCTUnwrap(MediaLinks.classify(raw), raw)
        return SharedLink(messageID: id, chatID: chat, uid: "synthetic-\(id)", ts: Date(timeIntervalSince1970: 0),
                          sender: "Example", fromMe: false, chatName: "Example chat", url: c.clean, service: c.service,
                          kind: c.kind, embedURL: c.embed, key: c.key, youtubeID: c.ytID, slugTitle: c.slug)
    }

    private func playerScript(_ html: String) throws -> String {
        let parts = html.components(separatedBy: "<script>")
        return try XCTUnwrap(parts.count > 1 ? parts[1].components(separatedBy: "</script>")[0] : nil)
    }

    private func pageContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var window=this, reports=[]; var document={getElementById:function(){return {};}}; var webkit={messageHandlers:{sagaPlayback:{postMessage:function(m){reports.push(m);}}}};")
        return context
    }

    // MARK: - Every listed service mounts the same safe player page

    func testEverySupportedServiceMountsANonAutoplayingPlayerWithASafeFallback() throws {
        let cases: [(raw: String, service: MediaService)] = [
            ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", .spotify),
            ("https://open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC", .spotify),
            ("https://music.apple.com/us/album/example/123?i=456", .appleMusic),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90", .youtube),
            ("https://www.youtube.com/playlist?list=PLabcdefghijklmnop", .youtube),
            ("https://music.youtube.com/watch?v=dQw4w9WgXcQ", .youtubeMusic),
            ("https://soundcloud.com/example-artist/example-track", .soundCloud),
            ("https://soundcloud.com/example-artist/sets/example-set", .soundCloud),
        ]
        for item in cases {
            let link = try shared(item.raw)
            XCTAssertEqual(link.service, item.service, item.raw)
            XCTAssertFalse(link.embedURL.isEmpty, item.raw)

            let page = MediaPlayerPage.html(url: link.embedURL, height: 200)
            XCTAssertTrue(page.contains("<iframe"), "\(item.raw): the player must stay a plain embed")
            XCTAssertFalse(page.lowercased().contains("autoplay=1"), "\(item.raw): mounting must not start playback")
            XCTAssertFalse(page.lowercased().contains("auto_play=true"), "\(item.raw): mounting must not start playback")

            let context = try pageContext()
            context.evaluateScript(try playerScript(page))
            XCTAssertNil(context.exception, item.raw)
            XCTAssertEqual(context.evaluateScript("reports.length")?.toInt32(), 0, "\(item.raw): loading must not report playback")
            XCTAssertFalse(context.evaluateScript("sagaPause()")!.toBool(), "\(item.raw): without an official API the coordinator must unload")
        }
    }

    func testResolvedShortLinksKeepTheirServiceAndSafePlayer() async throws {
        let spotifyShort = try shared("https://spotify.link/Example")
        let spotify = await MediaLinks.resolve(spotifyShort, allowNetwork: true, cache: nil) { _ in
            (URL(string: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=example")!, 200)
        }
        XCTAssertEqual(spotify.service, .spotify)
        XCTAssertEqual(spotify.uid, spotifyShort.uid)
        let spotifyPage = MediaPlayerPage.html(url: spotify.embedURL, height: 152)
        XCTAssertTrue(spotifyPage.contains("https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertTrue(spotifyPage.contains("controller.pause()"), "the expanded Spotify item keeps its official pause API")

        let soundShort = try shared("https://on.soundcloud.com/AbC123", id: 2)
        let sound = await MediaLinks.resolve(soundShort, allowNetwork: true, cache: nil) { _ in
            (URL(string: "https://soundcloud.com/example-artist/example-track?utm_source=clipboard")!, 200)
        }
        XCTAssertEqual(sound.service, .soundCloud)
        XCTAssertEqual(sound.uid, soundShort.uid)
        let soundPage = MediaPlayerPage.html(url: sound.embedURL, height: 166)
        XCTAssertTrue(soundPage.contains("w.soundcloud.com/player"))
        XCTAssertTrue(soundPage.contains("auto_play=false"), "an expanded share link must not autoplay either")
        let context = try pageContext()
        context.evaluateScript(try playerScript(soundPage))
        XCTAssertNil(context.exception)
        XCTAssertFalse(context.evaluateScript("sagaPause()")!.toBool(), "SoundCloud has no pause adapter, so it is unloaded instead")
    }

    // MARK: - One row per item after expansion

    func testShortLinkRowsFoldIntoTheRowThatAlreadyShowsTheItem() throws {
        let short = try shared("https://on.soundcloud.com/AbC123", id: 1)
        let full = try shared("https://soundcloud.com/example-artist/example-track", id: 2)
        let other = try shared("https://soundcloud.com/example-artist/other-track", id: 3)
        let items = [(link: short, times: 1), (link: full, times: 2), (link: other, times: 1)]

        XCTAssertEqual(MediaLinkFolding.duplicateIndex(of: full.key, in: items, resolved: [:], excluding: short.id, chatID: short.chatID), 1)
        XCTAssertNil(MediaLinkFolding.duplicateIndex(of: full.key, in: items, resolved: [:], excluding: full.id, chatID: full.chatID),
                     "a row never folds into itself")
        XCTAssertNil(MediaLinkFolding.duplicateIndex(of: "sc:nobody/nothing", in: items, resolved: [:], excluding: short.id, chatID: short.chatID))

        // Two short links that expand to the same item fold too, once the first has learned its key.
        let second = try shared("https://on.soundcloud.com/DeF456", id: 4)
        let withResolved = [(link: short, times: 1), (link: second, times: 1)]
        XCTAssertEqual(MediaLinkFolding.duplicateIndex(of: full.key, in: withResolved, resolved: [short.id: full.key], excluding: second.id, chatID: second.chatID), 0)

        // "Everywhere" keeps one row per chat, so the same item in another chat stays its own row.
        let elsewhere = try shared("https://soundcloud.com/example-artist/example-track", id: 5, chat: 9)
        XCTAssertNil(MediaLinkFolding.duplicateIndex(of: full.key, in: [(link: short, times: 1), (link: elsewhere, times: 1)],
                                                     resolved: [:], excluding: short.id, chatID: short.chatID))
    }

    // MARK: - Wrapped soundtrack (the other surface that renders these links)

    func testWrappedSoundtrackOffersNoPlayerForUnresolvedShortLinks() throws {
        let short = try shared("https://spotify.link/Example")
        let playable = try shared("https://soundcloud.com/example-artist/example-track", id: 2)

        var duo = DuoWrapped(me: "Sam", them: "Asha", chatID: 1)
        duo.linksTotal = 2
        duo.tracks = [
            DuoWrapped.Track(service: short.service, kind: short.kind, url: short.url, embed: short.embedURL, title: nil,
                             firstDate: Date(timeIntervalSince1970: 0), firstBy: "Sam", sharedBy: ["Sam"], times: 1,
                             landed: 0, reaction: "", reactionBy: "", messageID: 1, role: "The first one"),
            DuoWrapped.Track(service: playable.service, kind: playable.kind, url: playable.url, embed: playable.embedURL, title: nil,
                             firstDate: Date(timeIntervalSince1970: 10), firstBy: "Asha", sharedBy: ["Asha"], times: 1,
                             landed: 0, reaction: "", reactionBy: "", messageID: 2, role: "Along the way"),
        ]
        let duoPage = DuoWrappedHTML.render(duo, interactive: true)
        XCTAssertTrue(duoPage.contains("Open in Spotify"))
        XCTAssertTrue(duoPage.contains("Open in SoundCloud"))
        XCTAssertEqual(duoPage.components(separatedBy: "▶ Play here").count - 1, 1,
                       "only the item with an embed gets a player; a short link is opened in the service")

        var group = GroupWrapped(chatID: 1, name: "Example", total: 10, contributors: [], monthly: [], first: nil, last: nil)
        group.linksTotal = 1
        group.linkSharers = [GroupWrapped.Contributor(key: "self", name: "Sam", messages: 1)]
        group.tracks = [GroupWrapped.Track(service: short.service, kind: short.kind, url: short.url, embed: short.embedURL,
                                           title: nil, firstDate: Date(timeIntervalSince1970: 0), firstBy: "Example",
                                           times: 1, messageID: 1)]
        let groupPage = GroupWrappedHTML.render(group, interactive: true)
        XCTAssertTrue(groupPage.contains("Open in Spotify"))
        XCTAssertFalse(groupPage.contains("Play here"), "a group Wrapped must not offer a blank player either")
    }

    func testWrappedPlayerIgnoresEmptyEmbedsAndKeepsOnePlayerAtATime() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var appended = [], removed = 0;
        var existing = [{remove: function() { removed++; }}];
        var target = {querySelector: function() { return null; }, appendChild: function(f) { appended.push(f); }};
        var document = {
          getElementById: function() { return target; },
          createElement: function() { return {style:{}, setAttribute: function() {}}; },
          querySelectorAll: function(selector) { return selector === '.player iframe' ? existing : []; },
          addEventListener: function() {}
        };
        var IntersectionObserver = function() { this.observe = function() {}; this.unobserve = function() {}; };
        """)
        context.evaluateScript(DuoWrappedHTML.js)
        XCTAssertNil(context.exception)

        context.evaluateScript("play('p1', '', 200)")
        XCTAssertEqual(context.evaluateScript("appended.length")?.toInt32(), 0, "an unresolved link must not mount a blank player")

        context.evaluateScript("play('p1', 'https://w.soundcloud.com/player/?url=https://soundcloud.com/a/b', 166)")
        XCTAssertEqual(context.evaluateScript("appended.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("appended[0].src")?.toString(), "https://w.soundcloud.com/player/?url=https://soundcloud.com/a/b")
        XCTAssertEqual(context.evaluateScript("removed")?.toInt32(), 1, "starting one track closes any other open player")
    }
}
