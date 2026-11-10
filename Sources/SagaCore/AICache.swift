import Foundation

/// Remembers AI results on disk so a summary survives closing the sheet, restarting the app and rebuilding the library.
/// Two levels: finished summaries (so reopening is instant) and per-part results (so a stopped or interrupted run resumes
/// where it left off). References to messages are stored as stable uids, not row ids, because row ids change on rebuild.
public final class AICache: @unchecked Sendable {
    public struct StoredPoint: Sendable { public let text: String; public let uids: [String] }
    public struct StoredSummary: Sendable { public let created: Date, lastTS: Int64, messageCount: Int; public let points: [StoredPoint] }

    let db: SQLiteDB
    let lock = NSLock()

    public init(path: String) throws {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS summaries(key TEXT PRIMARY KEY, created INT, last_ts INT, n INT, points TEXT);
        CREATE TABLE IF NOT EXISTS chunks(hash TEXT PRIMARY KEY, created INT, points TEXT);
        CREATE TABLE IF NOT EXISTS captions(key TEXT PRIMARY KEY, created INT, text TEXT);
        """)
    }

    /// One-line caption for a dated card. Keyed by date + the message it describes, so
    /// a caption is generated once and then reused even after a restart or a rebuild.
    public func caption(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT text FROM captions WHERE key=?") else { return nil }
        sqlite3_bindText(st, key)
        guard (try? st.step()) == true else { return nil }
        return st.text(0)
    }
    public func saveCaption(key: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO captions(key,created,text) VALUES(?,?,?)")
            .run([.text(key), .int(Int64(Date().timeIntervalSince1970)), .text(text)])
    }

    static func encode(_ pts: [StoredPoint]) -> String {
        let arr = pts.map { ["t": $0.text, "u": $0.uids] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    static func decode(_ s: String) -> [StoredPoint] {
        guard let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { p in (p["t"] as? String).map { StoredPoint(text: $0, uids: p["u"] as? [String] ?? []) } }
    }

    public func summary(key: String) -> StoredSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT created, last_ts, n, points FROM summaries WHERE key=?") else { return nil }
        sqlite3_bindText(st, key)
        guard (try? st.step()) == true else { return nil }
        return StoredSummary(created: Date(timeIntervalSince1970: Double(st.int(0))), lastTS: st.int(1), messageCount: Int(st.int(2)), points: Self.decode(st.text(3) ?? "[]"))
    }

    /// Newest saved summary among the keys of one conversation (every number of a merged person), with a stable
    /// key tie-break so the same choice is made on every read. Nothing is moved or overwritten.
    public func latestSummary(keys: [String]) -> (key: String, summary: StoredSummary)? {
        var best: (String, StoredSummary)? = nil
        for key in keys where !key.isEmpty {
            guard let s = summary(key: key) else { continue }
            if let current = best {
                if s.created > current.1.created || (s.created == current.1.created && key < current.0) { best = (key, s) }
            } else { best = (key, s) }
        }
        return best
    }
    public func saveSummary(key: String, lastTS: Int64, messageCount: Int, points: [StoredPoint]) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO summaries VALUES(?,?,?,?,?)").run([.text(key), .int(Int64(Date().timeIntervalSince1970)), .int(lastTS), .int(Int64(messageCount)), .text(Self.encode(points))])
    }
    public func chunk(hash: String) -> [StoredPoint]? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT points FROM chunks WHERE hash=?") else { return nil }
        sqlite3_bindText(st, hash)
        guard (try? st.step()) == true else { return nil }
        return Self.decode(st.text(0) ?? "[]")
    }
    public func saveChunk(hash: String, points: [StoredPoint]) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO chunks VALUES(?,?,?)").run([.text(hash), .int(Int64(Date().timeIntervalSince1970)), .text(Self.encode(points))])
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? db.exec("DELETE FROM summaries; DELETE FROM chunks; VACUUM;")
    }
}
