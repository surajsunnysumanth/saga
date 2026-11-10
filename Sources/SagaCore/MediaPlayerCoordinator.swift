import Foundation
import WebKit

/// Coordinates all mounted inline players, including players in different panels.
@MainActor public final class MediaPlayerCoordinator: NSObject, WKScriptMessageHandler {
    let id = UUID().uuidString
    public weak var webView: WKWebView?
    public private(set) var url = ""
    public private(set) var height = 0
    public private(set) var stopped = false
    private var revision = 0

    public override init() {
        super.init()
        PlayerGroup.shared.add(self)
    }

    public func load(url: String, height: Int) {
        self.url = url; self.height = height; stopped = false; revision += 1
        webView?.loadHTMLString(MediaPlayerPage.html(url: url, height: height), baseURL: URL(string: "https://saga.app"))
    }

    public func dismantle() {
        PlayerGroup.shared.remove(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sagaPlayback")
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        revision += 1
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? String else { return }
        if event == "reload", stopped, message.frameInfo.isMainFrame { load(url: url, height: height) }
        else if event == "started", !stopped {
            revision += 1
            PlayerGroup.shared.started(self)
        }
    }

    private func pauseOrUnload() {
        guard !stopped, let webView else { return }
        let revision = self.revision
        webView.evaluateJavaScript("window.sagaPause ? window.sagaPause() : false") { [weak self] result, error in
            guard let self, self.revision == revision, !self.stopped else { return }
            if error != nil || (result as? Bool) != true {
                self.stopped = true
                webView.loadHTMLString(MediaPlayerPage.stoppedHTML, baseURL: URL(string: "https://saga.app"))
            }
        }
    }

    @MainActor private final class PlayerGroup {
        static let shared = PlayerGroup()
        private var session = MediaPlaybackSession()
        private var players: [String: WeakPlayer] = [:]
        private struct WeakPlayer { weak var value: MediaPlayerCoordinator? }
        func add(_ player: MediaPlayerCoordinator) {
            // SwiftUI dismantles explicitly; also prune any abandoned weak entries.
            for (id, entry) in players where entry.value == nil { session.unregister(id); players[id] = nil }
            session.register(player.id); players[player.id] = WeakPlayer(value: player)
        }
        func remove(_ player: MediaPlayerCoordinator) {
            session.unregister(player.id); players[player.id] = nil
        }
        func started(_ player: MediaPlayerCoordinator) {
            for id in session.started(player.id) { players[id]?.value?.pauseOrUnload() }
        }
    }
}
