import Foundation

/// Music and video links people shared in chats, turned into playable embeds.
public enum MediaService: String, Sendable, CaseIterable {
    case spotify = "Spotify", appleMusic = "Apple Music", youtube = "YouTube", youtubeMusic = "YouTube Music", soundCloud = "SoundCloud"
    public var symbol: String { self == .soundCloud ? "cloud.fill" : self == .spotify ? "waveform" : self == .appleMusic ? "music.note" : self == .youtube ? "play.rectangle.fill" : "music.note.tv" }
}

public struct SharedLink: Identifiable, Hashable, Sendable {
    public var id: String { "\(messageID)|\(url)" }
    public let messageID: Int64, chatID: Int64, uid: String, ts: Date
    public let sender: String, fromMe: Bool, chatName: String
    public let url: String                 // the link as shared (cleaned of tracking)
    public let service: MediaService
    public let kind: String                // track, album, playlist, episode, video, short, ...
    public let embedURL: String            // official embed page
    public let key: String                 // stable id of the thing shared (to count repeats)
    public let youtubeID: String?          // for building a YouTube playlist
    public let slugTitle: String?          // best-effort title read from the URL itself (Apple Music)
}

public struct LinkMeta: Sendable { public let title: String, author: String, thumbnail: String? }

public enum MediaLinks {
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#, options: [.caseInsensitive])

    public static func urls(in text: String) -> [String] {
        let ns = text as NSString
        return urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            var u = ns.substring(with: m.range)
            while let l = u.last, ".,;:!?*_".contains(l) { u.removeLast() }          // WhatsApp markup / punctuation glued to the link
            return u
        }
    }

    /// Parses one URL into an embeddable item, or nil if it isn't a music/video link we can play.
    public static func classify(_ raw: String) -> (service: MediaService, kind: String, embed: String, key: String, clean: String, ytID: String?, slug: String?)? {
        guard let c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.user == nil, c.password == nil, let host = c.host?.lowercased() else { return nil }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = c.path.split(separator: "/").map(String.init)
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }

        if h == "spotify.link" || h == "spotify.app.link" {
            guard parts.count == 1, parts[0].range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            let clean = "https://\(h)/\(parts[0])"
            return (.spotify, "short link", "", "sp-short:\(h)/\(parts[0])", clean, nil, nil)
        }
        if h == "on.soundcloud.com" {
            guard parts.count == 1, parts[0].range(of: #"^[A-Za-z0-9_-]{2,}$"#, options: .regularExpression) != nil else { return nil }
            return (.soundCloud, "short link", "", "sc-short:\(parts[0])", "https://on.soundcloud.com/\(parts[0])", nil, nil)
        }
        if h == "w.soundcloud.com", parts == ["player"], let target = q("url"), let host = URLComponents(string: target)?.host, ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(host.lowercased()) {
            return classify(target)
        }
        if h == "soundcloud.com" || h == "m.soundcloud.com" {
            let reserved = ["discover", "stream", "charts", "search", "you", "upload", "pages", "settings", "terms-of-use"]
            guard !reserved.contains(parts.first ?? ""), parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) else { return nil }
            let isSet = parts.count == 3 && parts[1] == "sets"
            guard isSet || (parts.count == 2 && !["likes", "sets", "tracks", "albums", "reposts", "popular-tracks", "followers", "following"].contains(parts[1])) else { return nil }
            let clean = "https://soundcloud.com/" + parts.joined(separator: "/")
            var embed = URLComponents(string: "https://w.soundcloud.com/player/")!
            embed.queryItems = [URLQueryItem(name: "url", value: clean), URLQueryItem(name: "auto_play", value: "false")]
            return (.soundCloud, isSet ? "playlist" : "track", embed.string!, "sc:" + parts.joined(separator: "/"), clean, nil, nil)
        }
        if h == "open.spotify.com" || h == "play.spotify.com" {
            var p = parts; if p.first?.hasPrefix("intl-") == true { p.removeFirst() }
            if p.first == "embed" { p.removeFirst() }
            guard p.count >= 2, ["track", "album", "playlist", "episode", "show", "artist"].contains(p[0]), p[1].range(of: #"^[A-Za-z0-9]{10,30}$"#, options: .regularExpression) != nil else { return nil }
            return (.spotify, p[0], "https://open.spotify.com/embed/\(p[0])/\(p[1])", "sp:\(p[1])", "https://open.spotify.com/\(p[0])/\(p[1])", nil, nil)
        }
        if h == "music.apple.com" || h == "embed.music.apple.com" {
            guard parts.count >= 3, ["album", "playlist", "song", "music-video", "station"].contains(parts[1]) else { return nil }
            let slug = parts.count >= 3 ? parts[2].replacingOccurrences(of: "-", with: " ").removingPercentEncoding : nil
            var embed = "https://embed.music.apple.com\(c.path)"; if let i = q("i") { embed += "?i=\(i)" }
            let id = q("i") ?? parts.last!
            let clean = "https://music.apple.com\(c.path)" + (q("i").map { "?i=\($0)" } ?? "")
            return (.appleMusic, (parts[1] == "song" || q("i") != nil) ? "track" : parts[1], embed, "am:\(id)", clean, nil, slug.map { $0.capitalized })
        }
        let isYT = h == "youtube.com" || h == "m.youtube.com" || h == "music.youtube.com" || h == "youtu.be" || h == "youtube-nocookie.com"
        if isYT {
            let svc: MediaService = h == "music.youtube.com" ? .youtubeMusic : .youtube
            var vid: String?, kind = "video"
            if h == "youtu.be" { vid = parts.first }
            else if parts.first == "watch" { vid = q("v") }
            else if parts.first == "shorts" || parts.first == "live" || parts.first == "embed" || parts.first == "v", parts.count >= 2 { vid = parts[1]; kind = parts.first == "shorts" ? "short" : "video" }
            else if parts.first == "playlist", let list = q("list") {
                return (svc, "playlist", "https://www.youtube.com/embed/videoseries?list=\(list)", "ytl:\(list)", "https://www.youtube.com/playlist?list=\(list)", nil, nil)
            }
            guard let v = vid, v.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            var embed = "https://www.youtube.com/embed/\(v)"
            var extra: [String] = []
            if let t = q("t") ?? q("start"), let secs = Int(t.filter(\.isNumber)), secs > 0 { extra.append("start=\(secs)") }
            if let l = q("list") { extra.append("list=\(l)") }
            if !extra.isEmpty { embed += "?" + extra.joined(separator: "&") }
            let clean = svc == .youtubeMusic ? "https://music.youtube.com/watch?v=\(v)" : "https://www.youtube.com/watch?v=\(v)"
            return (svc, svc == .youtubeMusic ? "track" : kind, embed, "yt:\(v)", clean, v, nil)
        }
        return nil
    }

    /// Finds playable links in one message's text.
    public static func links(in text: String) -> [(service: MediaService, kind: String, embed: String, key: String, clean: String, ytID: String?, slug: String?)] {
        urls(in: text).compactMap(classify)
    }

    // MARK: metadata (only fetched when the user asks)
    public static func oembedURL(for l: SharedLink) -> URL? {
        let enc = l.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? l.url
        switch l.service {
        case .spotify: return URL(string: "https://open.spotify.com/oembed?url=\(enc)")
        case .youtube, .youtubeMusic: return URL(string: "https://www.youtube.com/oembed?format=json&url=\(enc)")
        case .soundCloud: return URL(string: "https://soundcloud.com/oembed?format=json&url=\(enc)")
        case .appleMusic: return nil                       // Apple has no public oEmbed; the title comes from the URL itself
        }
    }
    public static func fetchMeta(_ l: SharedLink) async -> LinkMeta? {
        if l.service == .appleMusic {
            // Apple has no public oEmbed, but its catalogue lookup needs no key and answers
            // with the real track name, artist and artwork for a released song. The id is in
            // the URL: a song link ends in it, and an album link carries it as `?i=`.
            if let id = appleMusicID(l.url), let meta = await itunesLookup(id) { return meta }
            return l.slugTitle.map { LinkMeta(title: $0, author: "", thumbnail: nil) }
        }
        guard let u = oembedURL(for: l) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let title = j["title"] as? String else { return nil }
        return LinkMeta(title: title, author: (j["author_name"] as? String) ?? "", thumbnail: j["thumbnail_url"] as? String)
    }

    /// The numeric song id in an Apple Music URL. Album links point at the release and carry
    /// the shared song in `?i=`, so that wins when present.
    public static func appleMusicID(_ url: String) -> String? {
        guard let c = URLComponents(string: url) else { return nil }
        if let i = c.queryItems?.first(where: { $0.name == "i" })?.value, !i.isEmpty, i.allSatisfy(\.isNumber) { return i }
        if let last = c.path.split(separator: "/").last, !last.isEmpty, last.allSatisfy(\.isNumber) { return String(last) }
        return nil
    }

    /// iTunes lookup: the catalogue record behind an Apple Music id, including artwork at any
    /// size we ask for. One request per link, cached by LinkMetaLoader like every other answer.
    public static func itunesLookup(_ id: String) async -> LinkMeta? {
        guard let u = URL(string: "https://itunes.apple.com/lookup?id=\(id)") else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 10
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let results = j["results"] as? [[String: Any]], let first = results.first else { return nil }
        let title = (first["trackName"] as? String) ?? (first["collectionName"] as? String)
        guard let title, !title.isEmpty else { return nil }
        let art = (first["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100", with: "600x600")
        return LinkMeta(title: title, author: (first["artistName"] as? String) ?? "", thumbnail: art)
    }

    /// Expands Spotify and SoundCloud short share links only with consent; cached targets are usable offline.
    /// The injected transport keeps tests deterministic and avoids contacting real services.
    public static func resolve(_ link: SharedLink, allowNetwork: Bool, cache: LinkMetaCache?,
                               request: (@Sendable (URLRequest) async throws -> (URL, Int))? = nil) async -> SharedLink {
        guard link.embedURL.isEmpty, link.service == .spotify || link.service == .soundCloud else { return link }
        func resolved(_ target: String) -> SharedLink? {
            guard let c = classify(target), c.service == link.service, !c.embed.isEmpty else { return nil }
            return SharedLink(messageID: link.messageID, chatID: link.chatID, uid: link.uid, ts: link.ts, sender: link.sender,
                              fromMe: link.fromMe, chatName: link.chatName, url: c.clean, service: c.service, kind: c.kind,
                              embedURL: c.embed, key: c.key, youtubeID: c.ytID, slugTitle: c.slug)
        }
        if let target = cache?.resolution(link.key), let result = resolved(target) { return result }
        guard allowNetwork, let url = URL(string: link.url) else { return link }
        var req = URLRequest(url: url); req.httpMethod = "HEAD"; req.timeoutInterval = 10
        let hosts = redirectHosts(for: link.service)
        let follow: @Sendable (URLRequest) async throws -> (URL, Int) = request ?? { try await followShortLink($0, allowedHosts: hosts) }
        guard let (target, status) = try? await follow(req), (200..<300).contains(status), let result = resolved(target.absoluteString) else { return link }
        cache?.putResolution(link.key, result.url)
        return result
    }

    /// Hosts a short-link redirect is allowed to reach, so a share link can never bounce to an unrelated host.
    static func redirectHosts(for service: MediaService) -> Set<String> {
        switch service {
        case .spotify: return ["spotify.link", "spotify.app.link", "open.spotify.com", "play.spotify.com"]
        case .soundCloud: return ["on.soundcloud.com", "soundcloud.com", "m.soundcloud.com", "w.soundcloud.com"]
        default: return []
        }
    }

    public static func followShortLink(_ request: URLRequest, allowedHosts: Set<String> = ["spotify.link", "spotify.app.link", "open.spotify.com", "play.spotify.com"]) async throws -> (URL, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: ShortLinkRedirectGuard(hosts: allowedHosts), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let target = response.url else { throw URLError(.badServerResponse) }
        return (target, http.statusCode)
    }

    /// A temporary YouTube playlist for the given video ids (YouTube accepts up to 50). No account needed.
    public static func youtubePlaylistURL(ids: [String]) -> URL? {
        var seen = Set<String>(); let uniq = ids.filter { seen.insert($0).inserted }.prefix(50)
        return uniq.isEmpty ? nil : URL(string: "https://www.youtube.com/watch_videos?video_ids=\(uniq.joined(separator: ","))")
    }
}

/// Redirects stay on the link's own service; never follow a share link to an unrelated host or local address.
private final class ShortLinkRedirectGuard: NSObject, URLSessionTaskDelegate {
    let hosts: Set<String>
    init(hosts: Set<String>) { self.hosts = hosts }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && hosts.contains(url?.host?.lowercased() ?? "")
        completionHandler(allowed ? request : nil)
    }
}

public final class LinkMetaCache: @unchecked Sendable {
    let db: SQLiteDB, lock = NSLock()
    public init(path: String) throws {
        db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, title TEXT, author TEXT, thumb TEXT, fetched INT)")
        try db.exec("CREATE TABLE IF NOT EXISTS resolutions(key TEXT PRIMARY KEY, url TEXT NOT NULL)")
    }
    public func resolution(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT url FROM resolutions WHERE key=?") else { return nil }
        sqlite3_bindText(st, key)
        return (try? st.step()) == true ? st.text(0) : nil
    }
    public func putResolution(_ key: String, _ url: String) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO resolutions(key,url) VALUES(?,?)").run([.text(key), .text(url)])
    }
    /// Every cached title in one query. The Gallery needs them all at once to label a grid
    /// of thousands of cards, and one SELECT beats thousands of point lookups.
    public func all() -> [String: LinkMeta] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: LinkMeta] = [:]
        try? db.query("SELECT key, title, author, thumbnail FROM meta") { r in
            out[r.text(0) ?? ""] = LinkMeta(title: r.text(1) ?? "", author: r.text(2) ?? "", thumbnail: r.text(3))
        }
        return out
    }

    public func get(_ key: String) -> LinkMeta? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT title, author, thumb FROM meta WHERE key=?") else { return nil }
        sqlite3_bindText(st, key)
        guard (try? st.step()) == true else { return nil }
        return LinkMeta(title: st.text(0) ?? "", author: st.text(1) ?? "", thumbnail: st.text(2))
    }
    public func put(_ key: String, _ m: LinkMeta) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO meta VALUES(?,?,?,?,?)").run([.text(key), .text(m.title), .text(m.author), m.thumbnail.map { .text($0) } ?? .null, .int(Int64(Date().timeIntervalSince1970))])
    }
}

extension VaultStore {
    /// Music/video links shared in a chat (or everywhere), oldest first. The same item shared again is listed once with a count.
    public func sharedLinks(chat: Int64?, services: Set<MediaService> = Set(MediaService.allCases)) throws -> [(link: SharedLink, times: Int)] {
        let cond = "(m.text LIKE '%spotify.com/%' OR m.text LIKE '%spotify.link/%' OR m.text LIKE '%spotify.app.link/%' OR m.text LIKE '%soundcloud.com/%' OR m.text LIKE '%youtu%' OR m.text LIKE '%music.apple.com%')" + (chat.map { " AND m.chat_id=\($0)" } ?? "")
        var items: [String: (SharedLink, Int)] = [:], order: [String] = []
        try db.query("SELECT m.id, m.chat_id, m.uid, m.ts, m.sender, m.from_me, m.text, c.name FROM messages m JOIN chats c USING(chat_id) WHERE \(cond) ORDER BY m.ts, m.id") { r in
            let text = r.text(6) ?? ""
            for l in MediaLinks.links(in: text) where services.contains(l.service) {
                let scope = chat == nil ? "\(r.int(1))|" : ""
                let k = scope + l.key
                if let e = items[k] { items[k] = (e.0, e.1 + 1); continue }
                items[k] = (SharedLink(messageID: r.int(0), chatID: r.int(1), uid: r.text(2) ?? "", ts: Self.date(r.int(3)), sender: r.text(4) ?? "", fromMe: r.int(5) != 0,
                                       chatName: r.text(7) ?? "", url: l.clean, service: l.service, kind: l.kind, embedURL: l.embed, key: l.key, youtubeID: l.ytID, slugTitle: l.slug), 1)
                order.append(k)
            }
        }
        return order.compactMap { items[$0].map { (link: $0.0, times: $0.1) } }
    }
}
