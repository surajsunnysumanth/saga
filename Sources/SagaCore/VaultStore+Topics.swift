import Foundation

/// Messages of one chat inside a period, read for topic discovery.
public struct TopicsRead: Sendable {
    public let rows: [MessageRow]
    /// Visible messages (text or media) in the period, before any cap. Empty/system notices are not topics evidence.
    public let inPeriod: Int
    /// Messages actually returned, after the cap and after skipping empty/system notices.
    public var readCount: Int { rows.count }
    /// True when the period held more than the cap, so only the most recent `rows` were read.
    public var capped: Bool { inPeriod > readCount }
}

extension VaultStore {
    public static let topicsMaxMessages = 12000

    /// Milliseconds for a Date, rounded rather than truncated: a millisecond timestamp read back into a Date must map to the
    /// same millisecond, or a paging cursor walks backwards and re-reads rows.
    static func topicsMS(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// Same visibility rule as the conversation list: empty/system-only rows are hidden, text and media are kept.
    private static let topicsVisible = "(COALESCE(m.text,'') <> '' OR md.kind IS NOT NULL)"

    /// Reads the chat's visible messages with `start <= ts <= end`, oldest first, paging by `(ts, id)` so timestamp ties are
    /// never lost. Periods larger than `cap` are clipped to their most recent `cap` visible messages; `TopicsRead.capped` says so.
    public func topicsRead(chat: Int64, start: Date, end: Date, cap: Int = VaultStore.topicsMaxMessages, pageSize: Int = 2000) throws -> TopicsRead {
        let s = Self.topicsMS(start), e = Self.topicsMS(end)
        let whereSQL = "FROM messages m LEFT JOIN media md ON md.msg_id=m.id WHERE m.chat_id=\(chat) AND m.ts>=\(s) AND m.ts<=\(e) AND \(Self.topicsVisible)"
        let total = Int(try db.scalarInt("SELECT count(*) \(whereSQL)"))
        guard total > 0 else { return TopicsRead(rows: [], inPeriod: 0) }
        var afterTs = s - 1, afterId = Int64.max
        if total > cap {                                              // start at the (total-cap)th visible message: keep the newest
            var ts: Int64 = s - 1, id: Int64 = Int64.max
            try db.query("SELECT m.ts, m.id \(whereSQL) ORDER BY m.ts, m.id LIMIT 1 OFFSET \(total - cap)") { ts = $0.int(0); id = $0.int(1) }
            afterTs = ts; afterId = id - 1
        }
        var out: [MessageRow] = []
        while out.count < cap {
            try Task.checkCancellation()
            let page = try exportPage(chat: chat, afterTs: afterTs, afterId: afterId, limit: min(pageSize, cap - out.count))
            if page.rows.isEmpty { break }
            var reachedEnd = false
            for r in page.rows {
                if Self.topicsMS(r.ts) > e { reachedEnd = true; break }
                out.append(r)
            }
            if reachedEnd { break }
            guard let last = out.last else { break }
            afterId = last.id
            afterTs = Int64(try db.scalarInt("SELECT ts FROM messages WHERE id=\(last.id)"))
        }
        return TopicsRead(rows: out, inPeriod: total)
    }

    /// The archive's identity for local caches: the `id` in vault.json (read-only, never created), else a hash of the index path.
    public static func archiveScope(vaultURL: URL?, indexPath: String) -> String {
        if let vaultURL, let d = try? Data(contentsOf: vaultURL.appendingPathComponent("vault.json")),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let id = o["id"] as? String, !id.isEmpty { return "vault:" + id }
        return "index:" + LocalAI.hash(URL(fileURLWithPath: indexPath).resolvingSymlinksInPath().path)
    }
}
