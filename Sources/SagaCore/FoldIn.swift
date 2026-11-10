import Foundation

public enum DBFormat: String, Sendable {
    case plain = "Unencrypted database"
    case crypt15 = "Encrypted (crypt15, needs your 64-digit key)"
    case crypt14 = "Encrypted (crypt14, needs the old key file)"
    case crypt12 = "Encrypted (crypt12 or older, needs the old key file)"
    case increment = "Incremental backup (not supported yet)"
    case other = "Not a chat database"
}

public struct FoundDB: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL, format: DBFormat, size: Int64, date: Date
    public var usable: Bool { format == .plain || format == .crypt15 }
}
public struct MediaCategory: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var files = 0, bytes: Int64 = 0
}
public struct ScanReport: Sendable {
    public var root: URL
    public var databases: [FoundDB] = []
    public var media: [MediaCategory] = []
    public var quirks: [String] = []
    public var totalFiles = 0, emptyFolders = 0, duplicateFiles = 0
    public var oldestMedia: Date?, newestMedia: Date?
}

/// Reads a folder of manual WhatsApp backups (read-only) and reports what's inside, so old copies can be folded into a vault.
public enum FoldIn {
    static let categories = ["WhatsApp Images", "WhatsApp Video", "WhatsApp Audio", "WhatsApp Documents", "WhatsApp Animated Gifs",
                             "WhatsApp Stickers", "WhatsApp Voice Notes", "WhatsApp Video Notes", "WhatsApp Profile Photos", "WallPaper", ".Statuses", ".Links"]

    static func dbFormat(_ url: URL) -> DBFormat? {
        let n = url.lastPathComponent.lowercased()
        guard n.hasPrefix("msgstore") else { return nil }
        if n.contains("increment") { return .increment }
        if let r = n.range(of: ".crypt") {
            let v = Int(n[r.upperBound...].prefix { $0.isNumber }) ?? 0
            return v >= 15 ? .crypt15 : v == 14 ? .crypt14 : .crypt12
        }
        if n.hasSuffix(".db") {   // sniff the SQLite header
            if let fh = try? FileHandle(forReadingFrom: url), let d = try? fh.read(upToCount: 15), String(decoding: d, as: UTF8.self) == "SQLite format 3" { try? fh.close(); return .plain }
            return .other
        }
        return nil
    }

    static func dateFromName(_ name: String, fallback: Date) -> Date {
        // msgstore-2026-03-18.1.db.crypt14  /  msgstore-2026-11-06.1.db.crypt15
        if let r = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: String(name[r])) { return d }
        }
        return fallback
    }
    static func dateFromMediaName(_ name: String) -> Date? {
        // IMG-20240313-WA0015.jpeg
        guard let r = name.range(of: #"-(\d{8})-WA"#, options: .regularExpression) else { return nil }
        let s = name[r].dropFirst().prefix(8)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(s))
    }

    public static func scan(root: URL, progress: @Sendable (Int) -> Void = { _ in }) -> ScanReport {
        var rep = ScanReport(root: root)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return rep }
        var cats: [String: MediaCategory] = [:]
        var seen: [String: Int] = [:]
        var sawSent = false, sawPrivate = false, sawNested = false, sawWeekly = false
        var dirChildren: [String: Int] = [:]
        var n = 0
        for case let u as URL in en {
            let rv = try? u.resourceValues(forKeys: Set(keys))
            let comps = u.pathComponents.dropFirst(root.pathComponents.count)
            if rv?.isDirectory == true {
                let name = u.lastPathComponent
                if name == "Sent" { sawSent = true }; if name == "Private" { sawPrivate = true }
                if name.range(of: #"^\d{4}-W\d{2}$"#, options: .regularExpression) != nil { sawWeekly = true }
                if name == "Media", comps.dropLast().contains("Media") { sawNested = true }
                dirChildren[u.path] = 0
                continue
            }
            n += 1; if n % 500 == 0 { progress(n) }
            dirChildren[u.deletingLastPathComponent().path, default: 0] += 1
            let size = Int64(rv?.fileSize ?? 0), name = u.lastPathComponent
            if name == ".nomedia" || name == ".DS_Store" { continue }
            rep.totalFiles += 1
            if let f = dbFormat(u) {
                rep.databases.append(FoundDB(url: u, format: f, size: size, date: dateFromName(name, fallback: rv?.contentModificationDate ?? Date())))
                continue
            }
            if let cat = comps.first(where: { categories.contains($0) }) {
                var c = cats[cat] ?? MediaCategory(name: cat); c.files += 1; c.bytes += size; cats[cat] = c
                let key = "\(name)|\(size)"; seen[key, default: 0] += 1
                if let d = dateFromMediaName(name) { rep.oldestMedia = min(rep.oldestMedia ?? d, d); rep.newestMedia = max(rep.newestMedia ?? d, d) }
            }
        }
        rep.duplicateFiles = seen.values.filter { $0 > 1 }.reduce(0) { $0 + $1 - 1 }
        rep.emptyFolders = dirChildren.values.filter { $0 == 0 }.count
        rep.media = cats.values.sorted { $0.files > $1.files }
        rep.databases.sort { $0.date < $1.date }
        if sawNested { rep.quirks.append("Nested “Media/Media” folders found. Saga treats them as one library.") }
        if sawSent || sawPrivate { rep.quirks.append("“Sent” and “Private” subfolders found inside media categories. They are included.") }
        if sawWeekly { rep.quirks.append("Weekly voice-note folders (like 2021-W41) found. They are included.") }
        if rep.emptyFolders > 0 { rep.quirks.append("\(rep.emptyFolders) empty folders (leftovers). Ignored.") }
        if rep.duplicateFiles > 0 { rep.quirks.append("\(rep.duplicateFiles) files appear more than once (same name and size). They will be stored once.") }
        let unusable = rep.databases.filter { !$0.usable }
        if !unusable.isEmpty {
            rep.quirks.append("\(unusable.count) chat database(s) can't be opened: older encrypted backups need the old key file that lived inside the phone, and increments aren't supported yet. They are skipped, not deleted.")
        }
        return rep
    }

    public struct Outcome: Sendable { public var file: String, status: String, added: Int }

    /// Folds every usable database from `report` into `vault` (oldest first). Sources are never modified.
    /// - dryRun: decrypts and counts what would be added, writes nothing.
    public static func run(report: ScanReport, vault: Vault, keyHex: String?, dryRun: Bool, label: String = "foldin",
                           progress: @Sendable (String) -> Void = { _ in }) async -> [Outcome] {
        var out: [Outcome] = []
        for db in report.databases {
            guard db.usable else { out.append(Outcome(file: db.url.lastPathComponent, status: "Skipped: \(db.format.rawValue)", added: 0)); continue }
            progress("Reading \(db.url.lastPathComponent)…")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-foldin-\(UUID().uuidString).db")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                var path = db.url.path
                if db.format == .crypt15 {
                    guard let k = keyHex, k.filter({ $0.isHexDigit }).count == 64 else { out.append(Outcome(file: db.url.lastPathComponent, status: "Needs your 64-digit key", added: 0)); continue }
                    let data = try Data(contentsOf: db.url, options: .mappedIfSafe)
                    try Crypt15.decrypt(file: data, rootKeyHex: k).write(to: tmp); path = tmp.path
                }
                let r = try vault.ingest(msgstore: path, label: label, source: "foldin", fullSnapshot: false, dryRun: dryRun)
                out.append(Outcome(file: db.url.lastPathComponent, status: r.added == 0 ? "Nothing new (already in the vault)" : (dryRun ? "Would add \(r.added.formatted()) messages" : "Added \(r.added.formatted()) messages"), added: r.added))
            } catch {
                out.append(Outcome(file: db.url.lastPathComponent, status: "Couldn't read: \(error)", added: 0))
            }
        }
        return out
    }

    /// Remember where the media lives (no copying), so a later media step can read it lazily.
    @discardableResult
    public static func recordMediaSource(_ root: URL, in vault: Vault) -> Bool {
        (try? recordMediaSourceChecked(root, in: vault)) != nil
    }

    /// Same, but surfaces locked/authentication/I-O failures to the caller.
    public static func recordMediaSourceChecked(_ root: URL, in vault: Vault) throws {
        var sources = try MediaSources.load(in: vault)
        sources.append(root)
        try MediaSources.save(sources, in: vault)
    }
}
