import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String)
    public var description: String {
        switch self { case .open(let m), .prepare(let m), .step(let m): return m }
    }
}

public enum SQLValue { case null, int(Int64), text(String) }

/// Thin wrapper over the system SQLite C API.
public final class SQLiteDB {
    let db: OpaquePointer

    public init(path: String, readOnly: Bool) throws {
        var h: OpaquePointer?
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let target = readOnly ? "file:\(path)?mode=ro" : path
        guard sqlite3_open_v2(target, &h, flags, nil) == SQLITE_OK, let h else {
            throw SQLiteError.open("cannot open \(path)")
        }
        db = h
    }
    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.step(m)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return Statement(s, db)
    }

    /// Run a query and hand each row to `body`.
    public func query(_ sql: String, _ body: (Statement) throws -> Void) throws {
        let st = try prepare(sql)
        while try st.step() { try body(st) }
    }

    public func scalarIntOrZero(_ sql: String) -> Int64 { (try? scalarInt(sql)) ?? 0 }

    public func scalarInt(_ sql: String) throws -> Int64 {
        var v: Int64 = 0
        try query(sql) { v = $0.int(0) }
        return v
    }
}

public final class Statement {
    let s: OpaquePointer; let db: OpaquePointer
    init(_ s: OpaquePointer, _ db: OpaquePointer) { self.s = s; self.db = db }
    deinit { sqlite3_finalize(s) }

    public func step() throws -> Bool {
        switch sqlite3_step(s) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
    }
    public func run(_ args: [SQLValue]) throws {
        sqlite3_reset(s); sqlite3_clear_bindings(s)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(s, n)
            case .int(let v): sqlite3_bind_int64(s, n, v)
            case .text(let t): sqlite3_bind_text(s, n, t, Int32(t.utf8.count), SQLITE_TRANSIENT)  // explicit length: keeps embedded NULs
            }
        }
        _ = try step()
    }
    public var columnNames: [String] { (0..<sqlite3_column_count(s)).map { String(cString: sqlite3_column_name(s, $0)) } }
    public func int(_ c: Int32) -> Int64 { sqlite3_column_int64(s, c) }
    public func double(_ c: Int32) -> Double { sqlite3_column_double(s, c) }
    public func isNull(_ c: Int32) -> Bool { sqlite3_column_type(s, c) == SQLITE_NULL }
    public func text(_ c: Int32) -> String? {
        guard let p = sqlite3_column_text(s, c) else { return nil }
        let n = Int(sqlite3_column_bytes(s, c))  // byte length: do not truncate at embedded NUL
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
    public func value(_ c: Int32) -> SQLValue {
        isNull(c) ? .null : (sqlite3_column_type(s, c) == SQLITE_INTEGER ? .int(int(c)) : .text(text(c) ?? ""))
    }
}

/// Bind a single text parameter (1-based index 1) on a prepared statement.
func sqlite3_bindText(_ st: Statement, _ text: String, at index: Int32 = 1) {
    sqlite3_bind_text(st.s, index, text, Int32(text.utf8.count), SQLITE_TRANSIENT)
}
