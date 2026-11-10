import Foundation
import SQLite3

extension Statement {
    /// Binds several values before stepping a SELECT (the shared `run` helper is for one-shot writes).
    func bindAll(_ args: [SQLValue]) {
        sqlite3_reset(s); sqlite3_clear_bindings(s)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(s, n)
            case .int(let v): sqlite3_bind_int64(s, n, v)
            case .text(let t): sqlite3_bind_text(s, n, t, Int32(t.utf8.count), SQLITE_TRANSIENT)
            }
        }
    }

    /// The raw bytes of a BLOB column, valid until the statement is stepped or finalized.
    func blob(_ c: Int32) -> UnsafeRawBufferPointer? {
        guard sqlite3_column_type(s, c) == SQLITE_BLOB, let p = sqlite3_column_blob(s, c) else { return nil }
        return UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(s, c)))
    }
}

/// The local vector cache behind meaning-based search.
///
/// It lives in the app support folder (`semantic_cache.db`), beside `ai_cache.db`, and never inside the vault or the
/// message index: the index is disposable and rebuilt, the vault is the user's only copy of the source. A row keeps the
/// archive scope, the embedding identity, the message uid (already a hash of chat + WhatsApp key + direction), an input
/// hash, the vector and its dimension. Message text, contact names and numbers are never stored here.
///
/// Everything is keyed by a unique `(scope, identity, uid)` so two archives, or two embedding models, can never be
/// compared by mistake.
public final class SemanticStore: @unchecked Sendable {
    public struct Record: Sendable {
        public let uid: String
        public let hash: String
        public let dim: Int
        public let vector: [Float]
        public init(uid: String, hash: String, dim: Int, vector: [Float]) {
            self.uid = uid; self.hash = hash; self.dim = dim; self.vector = vector
        }
    }

    /// What a finished (or stopped) build covered. `total` is the eligible message count when it ran,
    /// and `stamp` is the index generation it was built against (nil for rows written before this was recorded).
    public struct Coverage: Sendable, Equatable {
        public let total: Int
        public let indexed: Int
        public let skipped: Int
        public let complete: Bool
        public let updated: Date
        public let stamp: String?
    }

    let db: SQLiteDB
    let lock = NSLock()

    public init(path: String) throws {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS embeddings(
            scope TEXT NOT NULL, identity TEXT NOT NULL, uid TEXT NOT NULL,
            hash TEXT NOT NULL, dim INT NOT NULL, vec TEXT NOT NULL, created INT NOT NULL,
            PRIMARY KEY(scope, identity, uid));
        CREATE TABLE IF NOT EXISTS coverage(
            scope TEXT NOT NULL, identity TEXT NOT NULL,
            total INT NOT NULL, indexed INT NOT NULL, skipped INT NOT NULL, complete INT NOT NULL, updated INT NOT NULL,
            stamp TEXT,
            PRIMARY KEY(scope, identity));
        """)
        // Older caches predate the generation stamp; add it without discarding their vectors.
        let hasStamp = ((try? db.scalarInt("SELECT count(*) FROM pragma_table_info('coverage') WHERE name='stamp'")) ?? 0) > 0
        if !hasStamp { try? db.exec("ALTER TABLE coverage ADD COLUMN stamp TEXT") }
    }

    // MARK: vectors

    /// Vectors are stored as raw Float32 blobs: compact, exact, and never readable message content. Older rows written as
    /// base64 text are still readable, so an index built by an earlier run is not thrown away.
    static func encode(_ v: [Float]) -> String {
        v.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }
    static func decode(_ s: String, dim: Int) -> [Float]? {
        guard dim > 0, let d = Data(base64Encoded: s), d.count == dim * MemoryLayout<Float>.size else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    private func bindBlob(_ st: Statement, _ index: Int32, _ v: [Float]) {
        v.withUnsafeBufferPointer {
            sqlite3_bind_blob(st.s, index, $0.baseAddress, Int32($0.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT)
        }
    }

    /// uids already stored for this archive and embedding model, with the hash of the text they were built from.
    public func existingHashes(scope: String, identity: String) -> [String: (hash: String, dim: Int)] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: (String, Int)] = [:]
        guard let st = try? db.prepare("SELECT uid, hash, dim FROM embeddings WHERE scope=? AND identity=?") else { return [:] }
        st.bindAll([.text(scope), .text(identity)])
        while (try? st.step()) == true { out[st.text(0) ?? ""] = (st.text(1) ?? "", Int(st.int(2))) }
        return out
    }

    /// Reads stored vectors one at a time, without copying them into arrays, so a large archive never has to sit in
    /// memory. The buffer is only valid inside `body`; return `false` to stop early. `body` must not call back into this
    /// store (the lock is held).
    public func scan(scope: String, identity: String, _ body: (_ uid: String, _ hash: String, _ dim: Int, _ vector: UnsafeRawBufferPointer) throws -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let st = try db.prepare("SELECT uid, hash, dim, vec FROM embeddings WHERE scope=? AND identity=?")
        st.bindAll([.text(scope), .text(identity)])
        while try st.step() {
            let uid = st.text(0) ?? "", hash = st.text(1) ?? "", dim = Int(st.int(2))
            if let blob = st.blob(3) {
                guard blob.count == dim * MemoryLayout<Float>.size else { continue }   // corrupt row: ignore it
                if try !body(uid, hash, dim, blob) { return }
            } else if let text = st.text(3), let v = Self.decode(text, dim: dim) {          // base64 row from an earlier build
                var copy = v
                if try !copy.withUnsafeBytes({ try body(uid, hash, dim, $0) }) { return }
            }
        }
    }

    public func upsert(scope: String, identity: String, records: [Record]) {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("INSERT OR REPLACE INTO embeddings(scope, identity, uid, hash, dim, vec, created) VALUES(?,?,?,?,?,?,?)") else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? db.exec("BEGIN")
        for r in records {
            sqlite3_reset(st.s); sqlite3_clear_bindings(st.s)
            st.bindAll([.text(scope), .text(identity), .text(r.uid), .text(r.hash), .int(Int64(r.dim))])
            bindBlob(st, 6, r.vector)
            sqlite3_bind_int64(st.s, 7, now)
            _ = try? st.step()
        }
        try? db.exec("COMMIT")
    }

    public func count(scope: String, identity: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT count(*) FROM embeddings WHERE scope=? AND identity=?") else { return 0 }
        st.bindAll([.text(scope), .text(identity)])
        guard (try? st.step()) == true else { return 0 }
        return Int(st.int(0))
    }

    /// Drops vectors whose message no longer exists in the visible index (pruned, merged away or from another archive).
    /// Only ever call this after a full scan of the current index.
    public func reconcile(scope: String, identity: String, keeping uids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT uid FROM embeddings WHERE scope=? AND identity=?") else { return }
        st.bindAll([.text(scope), .text(identity)])
        var stale: [String] = []
        while (try? st.step()) == true {
            let uid = st.text(0) ?? ""
            if !uids.contains(uid) { stale.append(uid) }
        }
        guard !stale.isEmpty, let del = try? db.prepare("DELETE FROM embeddings WHERE scope=? AND identity=? AND uid=?") else { return }
        try? db.exec("BEGIN")
        for uid in stale { try? del.run([.text(scope), .text(identity), .text(uid)]) }
        try? db.exec("COMMIT")
    }

    /// Removes everything this store holds for one archive and model (used when the embedding dimension changed).
    public func clear(scope: String, identity: String) {
        lock.lock(); defer { lock.unlock() }
        for sql in ["DELETE FROM embeddings WHERE scope=? AND identity=?", "DELETE FROM coverage WHERE scope=? AND identity=?"] {
            guard let st = try? db.prepare(sql) else { continue }
            st.bindAll([.text(scope), .text(identity)])
            _ = try? st.step()
        }
    }

    // MARK: coverage

    public func coverage(scope: String, identity: String) -> Coverage? {
        lock.lock(); defer { lock.unlock() }
        guard let st = try? db.prepare("SELECT total, indexed, skipped, complete, updated, stamp FROM coverage WHERE scope=? AND identity=?") else { return nil }
        st.bindAll([.text(scope), .text(identity)])
        guard (try? st.step()) == true else { return nil }
        return Coverage(total: Int(st.int(0)), indexed: Int(st.int(1)), skipped: Int(st.int(2)),
                        complete: st.int(3) != 0, updated: Date(timeIntervalSince1970: Double(st.int(4))),
                        stamp: st.text(5))
    }

    public func saveCoverage(scope: String, identity: String, total: Int, indexed: Int, skipped: Int, complete: Bool,
                             stamp: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("INSERT OR REPLACE INTO coverage(scope, identity, total, indexed, skipped, complete, updated, stamp) VALUES(?,?,?,?,?,?,?,?)")
            .run([.text(scope), .text(identity), .int(Int64(total)), .int(Int64(indexed)), .int(Int64(skipped)),
                  .int(complete ? 1 : 0), .int(Int64(Date().timeIntervalSince1970)),
                  stamp.map { SQLValue.text($0) } ?? .null])
    }
}
