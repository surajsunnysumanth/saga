import Foundation

public struct CompactResult: Sendable { public var kept: Int = 0, folded: Int = 0, bytesBefore: Int64 = 0, bytesAfter: Int64 = 0 }

/// Folds older full archives into small "retained" databases that hold only the messages the newest backup lacks.
/// The Importer merges `retained-*.db` exactly like a full older archive, so results are identical (verified before anything is removed).
public enum Compactor {
    static let tables = ["jid", "jid_map", "lid_display_name", "chat", "message", "message_media"]

    static func size(_ p: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? 0 }

    /// Writes `retained-<name>.db` next to `older` containing only messages not present in `primary`.
    static func makeRetained(primary: String, older: String, out: String) throws -> Int {
        let p = try SQLiteDB(path: primary, readOnly: true)
        var pJid: [Int64: String] = [:], pChatRaw: [Int64: String] = [:]
        try p.query("SELECT _id, raw_string FROM jid") { pJid[$0.int(0)] = $0.text(1) ?? "" }
        try p.query("SELECT _id, jid_row_id FROM chat") { pChatRaw[$0.int(0)] = pJid[$0.int(1)] ?? "" }
        var seen = Set<String>()
        try p.query("SELECT chat_row_id, from_me, key_id FROM message WHERE timestamp > 0") {
            seen.insert("\(pChatRaw[$0.int(0)] ?? "")|\($0.text(2) ?? "")|\($0.int(1))")
        }

        try? FileManager.default.removeItem(atPath: out)
        let o = try SQLiteDB(path: out, readOnly: false)
        try o.exec("ATTACH DATABASE '\(older.replacingOccurrences(of: "'", with: "''"))' AS src")
        // same schema as the source tables, so the Importer treats it as a normal msgstore.db
        let create = try SQLiteDB(path: older, readOnly: true)
        try create.query("SELECT name, sql FROM sqlite_master WHERE type='table' AND name IN ('jid','jid_map','lid_display_name','chat','message','message_media')") {
            if let sql = $0.text(1) { try o.exec(sql) }
        }
        for t in ["jid", "jid_map", "lid_display_name", "chat"] { try? o.exec("INSERT INTO main.\(t) SELECT * FROM src.\(t)") }

        var exJid: [Int64: String] = [:], exChatRaw: [Int64: String] = [:]
        try create.query("SELECT _id, raw_string FROM jid") { exJid[$0.int(0)] = $0.text(1) ?? "" }
        try create.query("SELECT _id, jid_row_id FROM chat") { exChatRaw[$0.int(0)] = exJid[$0.int(1)] ?? "" }
        var keep: [Int64] = []
        try create.query("SELECT _id, chat_row_id, from_me, key_id FROM message WHERE timestamp > 0") {
            if !seen.contains("\(exChatRaw[$0.int(1)] ?? "")|\($0.text(3) ?? "")|\($0.int(2))") { keep.append($0.int(0)) }
        }
        try o.exec("CREATE TEMP TABLE keepids(id INTEGER PRIMARY KEY)")
        try o.exec("BEGIN")
        let ins = try o.prepare("INSERT INTO keepids VALUES(?)")
        for id in keep { try ins.run([.int(id)]) }
        try o.exec("INSERT INTO main.message SELECT * FROM src.message WHERE _id IN (SELECT id FROM keepids)")
        try? o.exec("INSERT INTO main.message_media SELECT * FROM src.message_media WHERE message_row_id IN (SELECT id FROM keepids)")
        try o.exec("COMMIT")
        try o.exec("DETACH DATABASE src")
        try o.exec("VACUUM")
        return keep.count
    }

    /// Compacts `archive`: newest full DB stays; every older full DB becomes a retained-*.db and is moved to the Trash.
    /// - Parameter verify: re-merges before/after and aborts (keeping everything) if counts differ.
    public static func run(archive: URL, scratch: URL) throws -> CompactResult {
        guard let (primary, others) = Updater.primaryAndOthers(archive: archive) else { return CompactResult() }
        var res = CompactResult()
        let fulls = others.filter { !($0 as NSString).lastPathComponent.hasPrefix("retained-") && size($0) > 80_000_000 }
        guard !fulls.isEmpty else { return res }
        res.bytesBefore = ([primary] + others).reduce(0) { $0 + size($1) }

        // baseline: merged message count with everything in place
        let base = scratch.appendingPathComponent("compact-base.db"), after = scratch.appendingPathComponent("compact-after.db")
        let extras = { (paths: [String]) in ImportOptions(sourceDB: primary, outputDB: base.path, additionalSources: paths) }
        let before = try Importer.run(extras(others))

        var retainedPaths: [String] = [], newFiles: [String] = []
        for f in fulls {
            let name = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
            let out = archive.appendingPathComponent("retained-\(name.replacingOccurrences(of: "msgstore-", with: "")).db").path
            res.kept += try makeRetained(primary: primary, older: f, out: out)
            retainedPaths.append(out); newFiles.append(out)
        }
        // verify: primary + retained + (already-small others) must merge to the same totals
        let small = others.filter { !fulls.contains($0) }
        var o2 = ImportOptions(sourceDB: primary, outputDB: after.path, additionalSources: small + retainedPaths)
        o2.vcfPath = nil
        let check = try Importer.run(o2)
        guard check.messages == before.messages, check.media == before.media, check.chats == before.chats else {
            for f in newFiles { try? FileManager.default.removeItem(atPath: f) }
            throw SQLiteError.step("compaction check failed (\(check.messages) vs \(before.messages) messages); nothing was changed")
        }
        for f in fulls { try FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil); res.folded += 1 }
        res.bytesAfter = ([primary] + small + retainedPaths).reduce(0) { $0 + size($1) }
        try? FileManager.default.removeItem(at: base); try? FileManager.default.removeItem(at: after)
        return res
    }
}
