import XCTest
import JavaScriptCore
@testable import SagaCore

final class MediaPlaybackTests: XCTestCase {
    func testFramePlaybackReportsStartsButNotPauses() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("""
        var listeners = {}, reports = [];
        var document = {addEventListener: function(n, f) {listeners[n] = f;}};
        var window = {webkit: {messageHandlers: {sagaPlayback: {postMessage: function(m) {reports.push(m);}}}}};
        """)
        js.evaluateScript(MediaPlayerPage.mediaEvents)
        XCTAssertNil(js.exception)
        js.evaluateScript("listeners.playing({target: {tagName: 'VIDEO'}}); listeners.playing({target: {tagName: 'AUDIO'}});")
        XCTAssertEqual(js.evaluateScript("reports.join(',')")?.toString(), "started,started")
        XCTAssertTrue(js.evaluateScript("listeners.pause === undefined")!.toBool())
    }

    func testPlayerPagePreservesEmbedAndUsesOfficialPauseAPIs() {
        let html = MediaPlayerPage.html(url: "https://www.youtube.com/embed/example?start=90&list=PLabc", height: 190)
        XCTAssertTrue(html.contains("start=90&amp;list=PLabc"))
        XCTAssertTrue(html.contains("enablejsapi=1"))
        XCTAssertTrue(html.contains("pauseVideo"))
        let spotify = MediaPlayerPage.html(url: "https://open.spotify.com/embed/track/1234567890", height: 152)
        XCTAssertTrue(spotify.contains("controller.pause()"))
        XCTAssertTrue(spotify.contains("playback_update"))
        XCTAssertTrue(spotify.contains("<iframe")) // API failure still leaves an ordinary playable embed
    }

    func testOfficialAdaptersReportPlaybackTransitionsAndPauseWithoutAutoplay() throws {
        for (url, setup, ready, play, paused) in [
            ("https://www.youtube.com/embed/abcdefghijk", "var events; var YT={Player:function(id, options){events=options.events;this.pauseVideo=function(){pauses++;};}};", "onYouTubeIframeAPIReady(); events.onReady();", "events.onStateChange({data:1}); events.onStateChange({data:2});", "pauses === 1"),
            ("https://open.spotify.com/embed/track/1234567890", "var update; var controller={pause:function(){pauses++;},addListener:function(name,f){update=f;}}; var api={createController:function(el,options,cb){cb(controller);}};", "onSpotifyIframeApiReady(api);", "update({data:{isPaused:false,isBuffering:false}}); update({data:{isPaused:false,isBuffering:false}}); update({data:{isPaused:true,isBuffering:false}});", "pauses === 1")
        ] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("var window=this, pauses=0, reports=[]; var document={getElementById:function(){return {};}}; var webkit={messageHandlers:{sagaPlayback:{postMessage:function(m){reports.push(m);}}}};" + setup)
            let html = MediaPlayerPage.html(url: url, height: 200)
            let script = html.components(separatedBy: "<script>")[1].components(separatedBy: "</script>")[0]
            context.evaluateScript(script)
            XCTAssertNil(context.exception)
            XCTAssertFalse(context.evaluateScript("sagaPause()")!.toBool(), "Before API readiness, unload must be used")
            context.evaluateScript(ready)
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("reports.length")?.toInt32(), 0, "Loading must not start playback")
            context.evaluateScript(play)
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("reports.join(',')")?.toString(), "started")
            XCTAssertTrue(context.evaluateScript("sagaPause()")!.toBool())
            XCTAssertTrue(context.evaluateScript(paused)!.toBool())
        }
    }

    func testAPIUnavailableServiceKeepsPlayableEmbedAndRequestsUnload() throws {
        let html = MediaPlayerPage.html(url: "https://embed.music.apple.com/us/album/example/123?i=456", height: 175)
        XCTAssertTrue(html.contains("https://embed.music.apple.com/us/album/example/123?i=456"))
        XCTAssertTrue(html.contains("<iframe"))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var window=this;")
        context.evaluateScript(html.components(separatedBy: "<script>")[1].components(separatedBy: "</script>")[0])
        XCTAssertNil(context.exception)
        XCTAssertFalse(context.evaluateScript("sagaPause()")!.toBool())
    }

    func testStartingPlayerStopsOnlyOtherRegisteredPlayers() {
        var session = MediaPlaybackSession()
        session.register("first")
        session.register("second")
        session.register("third")
        XCTAssertEqual(session.started("second"), ["first", "third"])
        XCTAssertEqual(session.started("second"), ["first", "third"])
        session.unregister("first")
        XCTAssertEqual(session.started("third"), ["second"])
        XCTAssertEqual(session.started("removed"), [])
    }
}
