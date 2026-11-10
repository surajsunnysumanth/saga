import Foundation

public struct UpdateProgress: Sendable { public let message: String }

/// "Update from phone": pull the latest WhatsApp backup over ADB, decrypt it into the archive, and rebuild the merged index.
public enum Updater {
    public static func archiveDir(_ support: URL) -> URL {
        let d = support.appendingPathComponent("archive"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    static func stateFile(_ support: URL) -> URL { support.appendingPathComponent("archive/last-pulled-backup.txt") }

    /// Backup timestamp (device-local "yyyy-MM-dd HH:mm") of the last backup that was pulled into the archive.
    public static func lastPulledBackup(support: URL) -> String? {
        try? String(contentsOf: stateFile(support), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Newest archive (by latest message) is the base; the rest are merged underneath it.
    public static func primaryAndOthers(archive: URL) -> (String, [String])? {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "db" }
        let ranked = urls.map { u -> (String, Int64) in
            (u.path, (try? SQLiteDB(path: u.path, readOnly: true))?.scalarIntOrZero("SELECT max(timestamp) FROM message") ?? 0)
        }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first else { return nil }
        return (first.0, ranked.dropFirst().map(\.0))
    }

    public enum Failure: Error, CustomStringConvertible {
        case noPhone(String), noBackup, pullFailed, alreadyCurrent(String)
        public var description: String {
            switch self {
            case .noPhone(let m): return m
            case .noBackup: return "No WhatsApp backup found on the phone. Open WhatsApp › Settings › Chats › Chat backup › Back up."
            case .pullFailed: return "Copying from the phone failed. Keep it unlocked and plugged in, then try again."
            case .alreadyCurrent(let d): return "Already up to date (phone's latest backup: \(d)). Run “Back up” in WhatsApp first to get newer messages."
            }
        }
    }

    /// Moves a legacy `archive/` folder (full msgstore-*.db and retained-*.db files) into a vault. Partial files first, then full
    /// snapshots oldest to newest, so "gone from phone" detection sees the right history.
    public static func migrateLegacyArchive(_ archive: URL, into vault: Vault, label: String) throws -> Int {
        let files = ((try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "db" }
        let partial = files.filter { $0.lastPathComponent.hasPrefix("retained-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let full = files.filter { !$0.lastPathComponent.hasPrefix("retained-") }
            .map { u in (u, (try? SQLiteDB(path: u.path, readOnly: true))?.scalarIntOrZero("SELECT max(timestamp) FROM message") ?? 0) }
            .sorted { $0.1 < $1.1 }.map { $0.0 }
        var added = 0
        for u in partial { added += try vault.ingest(msgstore: u.path, label: label, source: "legacy-retained", fullSnapshot: false).added }
        for u in full { added += try vault.ingest(msgstore: u.path, label: label, source: "legacy-archive", fullSnapshot: true).added }
        return added
    }

    /// - Parameter force: re-pull even if the phone's backup time matches the last one pulled.
    public static func run(support: URL, vault: Vault, indexOut: URL, keyHex: String, vcfPath: String? = nil, force: Bool = false,
                           label: String = "mac", progress: @Sendable (String) -> Void = { _ in }) async throws -> ImportSummary {
        progress("Looking for your phone…")
        switch await Adb.state() {
        case .ready: break
        case .unauthorized: throw Failure.noPhone("Allow USB debugging on the phone, then try again.")
        default: throw Failure.noPhone("Plug in your phone (USB debugging on) and try again.")
        }
        guard let info = await Adb.backupInfo() else { throw Failure.noBackup }
        if !force, let last = info.lastBackup, last == lastPulledBackup(support: support) { throw Failure.alreadyCurrent(last) }

        progress("Copying the latest backup from your phone…")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-pull-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }       // encrypted copy and the decrypted temp file are always removed
        guard await Adb.pullDatabases(from: info, to: tmp) else { throw Failure.pullFailed }

        progress("Unlocking it…")
        let plain = tmp.appendingPathComponent("msgstore.db")
        let crypt = tmp.appendingPathComponent("msgstore.db.crypt15")
        try await Task.detached {
            let data = try Data(contentsOf: crypt, options: .mappedIfSafe)
            try Crypt15.decrypt(file: data, rootKeyHex: keyHex.filter { $0.isHexDigit }).write(to: plain)
        }.value

        progress("Adding new messages to your archive…")
        let r = try await Task.detached { try vault.ingest(msgstore: plain.path, label: label) }.value
        progress(r.added == 0 ? "No new messages; refreshing…" : "Added \(r.added.formatted()) new messages…")

        progress("Reading names from your phone…")
        let names = await Adb.phoneContacts()
        progress("Building your library…")
        let summary = try await Task.detached { try VaultIndexer.build(vault: vault, out: indexOut.path, vcfPath: vcfPath, extraContacts: names) }.value
        if let t = info.lastBackup { try? t.write(to: stateFile(support), atomically: true, encoding: .utf8) }
        return summary
    }
}
