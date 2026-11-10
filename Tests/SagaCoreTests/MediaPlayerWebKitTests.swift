import XCTest
import WebKit
@testable import SagaCore

@MainActor private final class PlaybackFixture: NSObject, WKNavigationDelegate {
    let coordinator = MediaPlayerCoordinator()
    let web: WKWebView
    private var ready: CheckedContinuation<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "sagaPlayback")
        config.userContentController.addUserScript(WKUserScript(source: MediaPlayerPage.mediaEvents, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        coordinator.webView = web
        // A network-free URL that can also be restored by the fallback reload button.
        coordinator.load(url: "about:blank", height: 100)
    }

    func load(_ html: String) async {
        await withCheckedContinuation { continuation in
            ready = continuation
            web.loadHTMLString(html, baseURL: URL(string: "https://saga.app"))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready?.resume(); ready = nil
    }
    func evaluate(_ script: String) async throws -> Bool {
        var lastError: Error?
        // A web view created moments ago can still be bringing its content process
        // up and reports a transient InvalidTransition instead of running the script.
        for attempt in 0..<4 {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    web.evaluateJavaScript(script) { value, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (value as? Bool) == true) }
                    }
                }
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
            }
        }
        throw lastError ?? URLError(.unknown)
    }
    func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws -> Bool {
        for _ in 0..<150 {
            if (try? await condition()) == true { return true }   // a cold content process reports errors, not false
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

final class MediaPlayerWebKitTests: XCTestCase {
    @MainActor func testStartPausesAPIPlayerUnloadsFallbackAndPreservesStartingPlayer() async throws {
        let first = PlaybackFixture(), fallback = PlaybackFixture(), current = PlaybackFixture()
        defer { first.coordinator.dismantle(); fallback.coordinator.dismantle(); current.coordinator.dismantle() }
        await first.load("<script>var pauses = 0; window.sagaPause = function() { pauses++; return true; };</script>")
        await fallback.load("<audio></audio>")
        await current.load("<audio id='audio'></audio><script>var pauses=0; window.sagaPause=function(){pauses++;return true;};</script>")
        _ = try await current.evaluate("document.getElementById('audio').dispatchEvent(new Event('playing')); true")
        let paused = try await first.waitUntil { try await first.evaluate("pauses === 1") }
        XCTAssertTrue(paused)
        let unloaded = try await fallback.waitUntil { fallback.coordinator.stopped }
        XCTAssertTrue(unloaded)
        XCTAssertFalse(current.coordinator.stopped)
        let untouched = try await current.evaluate("pauses === 0 && !!document.getElementById('audio')")
        XCTAssertTrue(untouched)
        let reloadReady = try await fallback.waitUntil { try await fallback.evaluate("!!document.querySelector('button')") }
        XCTAssertTrue(reloadReady)
        _ = try await fallback.evaluate("document.querySelector('button').click(); true")
        let reloaded = try await fallback.waitUntil { !fallback.coordinator.stopped }
        XCTAssertTrue(reloaded)
    }

    @MainActor func testCrossFrameStartsAreObservedAndDismantlingUnregistersPlayer() async throws {
        let old = PlaybackFixture(), current = PlaybackFixture()
        defer { old.coordinator.dismantle(); current.coordinator.dismantle() }
        await old.load("<script>var pauses=0; window.sagaPause=function(){pauses++;return true;};</script>")
        // Sandboxing makes this frame a distinct origin: the native all-frame
        // user script must observe it without parent-page DOM access.
        await current.load("<iframe sandbox='allow-scripts' srcdoc=\"<audio></audio><script>setTimeout(function(){document.querySelector('audio').dispatchEvent(new Event('playing'));},100);</script>\"></iframe>")
        let paused = try await old.waitUntil { try await old.evaluate("pauses === 1") }
        XCTAssertTrue(paused)
        old.coordinator.dismantle()
        _ = try await current.evaluate("window.webkit.messageHandlers.sagaPlayback.postMessage('started'); true")
        XCTAssertNil(old.coordinator.webView)
        XCTAssertFalse(current.coordinator.stopped)
    }
}
