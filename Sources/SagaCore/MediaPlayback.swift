import Foundation

/// Tracks mounted players, not just the last one heard: an iframe may resume itself.
public struct MediaPlaybackSession: Sendable {
    private var players = Set<String>()
    public init() {}
    public mutating func register(_ id: String) { players.insert(id) }
    public mutating func unregister(_ id: String) { players.remove(id) }
    public func started(_ id: String) -> Set<String> {
        players.contains(id) ? players.subtracting([id]) : []
    }
}

/// Official API adapters live in the wrapper, while the all-frame script also
/// observes HTML media inside cross-origin embeds (including API-free services).
public enum MediaPlayerPage {
    public static let mediaEvents = """
    document.addEventListener('playing', function(e) {
      if (e.target.tagName === 'VIDEO' || e.target.tagName === 'AUDIO')
        window.webkit.messageHandlers.sagaPlayback.postMessage('started');
    }, true);
    """

    public static func html(url: String, height: Int) -> String {
        var components = URLComponents(string: url)
        let host = components?.host ?? ""
        let youtube = ["www.youtube.com", "youtube.com", "www.youtube-nocookie.com"].contains(host)
        let spotify = host == "open.spotify.com"
        if youtube {
            var query = components?.queryItems ?? []
            query.removeAll { $0.name == "enablejsapi" || $0.name == "origin" }
            query += [URLQueryItem(name: "enablejsapi", value: "1"), URLQueryItem(name: "origin", value: "https://saga.app")]
            components?.queryItems = query
        }
        let source = escape(components?.string ?? url)
        let frame = "<iframe id=\"player\" src=\"\(source)\" width=\"100%\" height=\"\(height)\" frameborder=\"0\" style=\"border:0;border-radius:12px\" allow=\"autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture\" allowfullscreen referrerpolicy=\"strict-origin-when-cross-origin\"></iframe>"
        var adapter = ""
        if youtube {
            adapter = """
            window.onYouTubeIframeAPIReady = function() {
              var player = new YT.Player('player', {events: {
                onReady: function() { window.sagaPause = function() { player.pauseVideo(); return true; }; },
                onStateChange: function(e) { if (e.data === 1) started(); }
              }});
            };
            """
        } else if spotify {
            let parts = components?.path.split(separator: "/").map(String.init) ?? []
            if parts.count >= 3 {
                let uri = "spotify:\(parts[1]):\(parts[2])"
                let json = String(data: try! JSONEncoder().encode(uri), encoding: .utf8)!
                adapter = """
                window.onSpotifyIframeApiReady = function(api) {
                  api.createController(document.getElementById('spotify'), {uri: \(json), width: '100%', height: \(height)}, function(controller) {
                    window.sagaPause = function() { controller.pause(); return true; };
                    controller.addListener('playback_update', function(e) {
                      var playing = !e.data.isPaused && !e.data.isBuffering;
                      if (playing && !window.sagaWasPlaying) started();
                      window.sagaWasPlaying = playing;
                    });
                  });
                };
                """
            }
        }
        let api = youtube ? "https://www.youtube.com/iframe_api" : spotify ? "https://open.spotify.com/embed/iframe-api/v1" : nil
        return """
        <html><head><meta name="viewport" content="width=device-width"></head><body style="margin:0;background:transparent">
        \(spotify && !adapter.isEmpty ? "<div id=\"spotify\">\(frame)</div>" : frame)
        <script>
        function started() { window.webkit.messageHandlers.sagaPlayback.postMessage('started'); }
        window.sagaPause = function() { return false; };
        \(adapter)
        </script>
        \(api.map { "<script src=\"\($0)\"></script>" } ?? "")
        </body></html>
        """
    }

    public static let stoppedHTML = """
    <html><body style="font:14px system-ui;color:gray"><p>Stopped because another player started.</p>
    <button onclick="window.webkit.messageHandlers.sagaPlayback.postMessage('reload')">Reload player</button></body></html>
    """

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
