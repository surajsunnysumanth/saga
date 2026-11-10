import Foundation

/// Plain-text exports of a shared-link list. Titles come only from the caller (cache), never from the network.
public enum MediaLinkExport {
    static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }

    /// M3U-like text: `#EXTM3U`, then `#EXTINF:-1,<title>` and the URL per item.
    public static func m3u(_ items: [(link: SharedLink, title: String?)]) -> String {
        var out = ["#EXTM3U"]
        for it in items {
            out.append("#EXTINF:-1," + oneLine(it.title ?? "\(it.link.service.rawValue) \(it.link.kind)"))
            out.append(oneLine(it.link.url))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 CSV; cells starting with = + - @ are prefixed with an apostrophe to defuse spreadsheet formulas.
    public static func csv(_ items: [(link: SharedLink, title: String?, times: Int)]) -> String {
        func cell(_ s: String) -> String {
            var v = s
            if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
            return v.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        let f = ISO8601DateFormatter()
        var rows = ["date,service,kind,title,url,chat,sender,times"]
        for it in items {
            let l = it.link
            rows.append([f.string(from: l.ts), l.service.rawValue, l.kind, it.title ?? "", l.url, l.chatName, l.sender, String(it.times)].map(cell).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
