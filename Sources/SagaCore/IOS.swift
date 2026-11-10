import Foundation

/// WhatsApp on iPhone, read from a local iOS backup (the folder `idevicebackup2` or Finder writes).
/// ChatStorage.sqlite (a Core Data store) is converted to the same shape as Android's msgstore.db, so everything downstream
/// (the vault, merging with an Android archive, the library, search, Wrapped) is unchanged.
public enum IOSBackup {
    public struct Found: Sendable {
        public let folder: URL                 // the folder holding Manifest.db
        public let deviceName: String, iosVersion: String, lastBackup: Date?
        public let encrypted: Bool
    }
    public enum Failure: LocalizedError {
        case notABackup, encrypted, noWhatsApp, badDB(String)
        public var errorDescription: String? {
            switch self {
            case .notABackup: return "That folder doesn't look like an iPhone backup (no Manifest.db)."
            case .encrypted: return "This backup is encrypted with a password. Saga can't read it yet. Make a new backup with “Encrypt local backup” turned off (the iPhone's Finder setting), or use the 'saga phone' wizard path."
            case .noWhatsApp: return "WhatsApp's data isn't in this backup. Is WhatsApp installed and signed in on that iPhone?"
            case .badDB(let m): return "Couldn't read WhatsApp's database: \(m)"
            }
        }
    }
    public static let domain = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"

    /// Finds the backup folder: `root` itself or a child (one level) containing Manifest.db. Newest child wins.
    public static func locate(_ root: URL) throws -> Found {
        let fm = FileManager.default
        var cands = [root]
        cands += ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let withManifest = cands.filter { fm.fileExists(atPath: $0.appendingPathComponent("Manifest.db").path) }
            .sorted { ((try? $0.appendingPathComponent("Manifest.db").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.appendingPathComponent("Manifest.db").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let f = withManifest.first else { throw Failure.notABackup }
        let info = NSDictionary(contentsOf: f.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let man = NSDictionary(contentsOf: f.appendingPathComponent("Manifest.plist")) as? [String: Any] ?? [:]
        return Found(folder: f, deviceName: info["Device Name"] as? String ?? "iPhone", iosVersion: info["Product Version"] as? String ?? "?",
                     lastBackup: info["Last Backup Date"] as? Date, encrypted: (man["IsEncrypted"] as? NSNumber)?.boolValue ?? false)
    }

    /// Path of a file inside the backup: Manifest.db maps (domain, relativePath) to a hashed name stored as <xx>/<fileID>.
    public static func file(_ b: Found, domain: String = domain, relativePath: String) throws -> URL? {
        guard !b.encrypted else { throw Failure.encrypted }
        let m = try SQLiteDB(path: b.folder.appendingPathComponent("Manifest.db").path, readOnly: true)
        let st = try m.prepare("SELECT fileID FROM Files WHERE domain=? AND relativePath=? LIMIT 1")
        sqlite3_bindText(st, domain); sqlite3_bindText(st, relativePath, at: 2)
        guard try st.step(), let id = st.text(0) else { return nil }
        let u = b.folder.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static func chatStorage(_ b: Found) throws -> URL {
        guard let u = try file(b, relativePath: "ChatStorage.sqlite") else { throw Failure.noWhatsApp }
        return u
    }

    // MARK: conversion
    static let appleEpoch = 978_307_200.0                      // 2001-01-01 in Unix seconds

    static func splitJID(_ raw: String) -> (user: String, server: String) {
        guard let at = raw.lastIndex(of: "@") else { return (raw, "") }
        var user = String(raw[..<at]); let server = String(raw[raw.index(after: at)...])
        if let c = user.firstIndex(of: ":") { user = String(user[..<c]) }                      // device suffix "123:5@..."
        return (user, server)
    }

    /// Android message_type codes (what the rest of Saga understands) from WhatsApp iOS's ZMESSAGETYPE.
    static func androidType(_ ios: Int64, hasMedia: Bool) -> Int64 {
        switch ios {
        case 0: return 0
        case 1: return 1          // image
        case 2: return 3          // video
        case 3: return 2          // voice note / audio
        case 4: return 4          // contact card
        case 5: return 5          // location
        case 6: return 7          // system notice
        case 7: return 0          // link preview: plain text
        case 8: return 9          // document
        case 11: return 13        // gif
        case 14: return 15        // deleted
        case 15: return 20        // sticker
        default: return hasMedia ? 9 : 7
        }
    }
    static let mimeByExt = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "heic": "image/heic", "gif": "image/gif",
                            "mp4": "video/mp4", "mov": "video/quicktime", "m4a": "audio/mp4", "opus": "audio/ogg", "mp3": "audio/mpeg", "aac": "audio/aac", "caf": "audio/x-caf", "ogg": "audio/ogg",
                            "pdf": "application/pdf", "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "xlsx": "application/vnd.ms-excel", "zip": "application/zip"]

    public struct ConvertResult: Sendable { public var chats = 0, messages = 0, media = 0, pushNames = 0 }

    /// Writes an Android-shaped msgstore.db from ChatStorage.sqlite. Tolerant of WhatsApp versions: columns are looked up by name.
    public static func convert(chatStorage: String, to out: String) throws -> ConvertResult {
        let src = try SQLiteDB(path: chatStorage, readOnly: true)
        func cols(_ t: String) -> Set<String> {
            var s = Set<String>(); try? src.query("SELECT name FROM pragma_table_info('\(t)')") { s.insert($0.text(0) ?? "") }; return s
        }
        let msgC = cols("ZWAMESSAGE"), chatC = cols("ZWACHATSESSION"), mediaC = cols("ZWAMEDIAITEM")
        guard !msgC.isEmpty, !chatC.isEmpty else { throw Failure.badDB("ZWAMESSAGE / ZWACHATSESSION not found") }
        func pick(_ set: Set<String>, _ names: String...) -> String? { names.first { set.contains($0) } }

        try? FileManager.default.removeItem(atPath: out)
        let dst = try SQLiteDB(path: out, readOnly: false)
        try dst.exec("""
        PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE jid_map(lid_row_id INTEGER PRIMARY KEY, jid_row_id INT, sort_id INT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER PRIMARY KEY, display_name TEXT, username TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        BEGIN;
        """)
        var jidRow: [String: Int64] = [:]; var nextJid: Int64 = 0
        let insJid = try dst.prepare("INSERT INTO jid VALUES(?,?,?,0,0,0,?)")
        func jid(_ raw: String) -> Int64 {
            let key = raw.lowercased()
            if let r = jidRow[key] { return r }
            nextJid += 1; let (u, s) = splitJID(raw)
            try? insJid.run([.int(nextJid), .text(u), .text(s), .text(u + (s.isEmpty ? "" : "@" + s))]); jidRow[key] = nextJid; return nextJid
        }

        var res = ConvertResult()
        // chats (skip WhatsApp Status "chat" and broadcast lists)
        var chatRow: [Int64: Int64] = [:]
        let insChat = try dst.prepare("INSERT INTO chat VALUES(?,?,?)")
        let nameCol = pick(chatC, "ZPARTNERNAME") ?? "NULL"
        try src.query("SELECT Z_PK, ZCONTACTJID, \(nameCol) FROM ZWACHATSESSION WHERE ZCONTACTJID IS NOT NULL AND ZCONTACTJID <> ''") { r in
            guard let raw = r.text(1), !raw.hasPrefix("status@"), !raw.hasSuffix("@broadcast") else { return }
            let j = jid(raw); chatRow[r.int(0)] = j
            let isGroup = raw.hasSuffix("@g.us")
            try insChat.run([.int(r.int(0)), .int(j), isGroup ? (r.text(2).map { .text($0) } ?? .null) : .null]); res.chats += 1
        }

        // group members (for sender names in groups)
        var memberJID: [Int64: String] = [:], memberName: [Int64: String] = [:]
        let gmC = cols("ZWAGROUPMEMBER")
        if let jc = pick(gmC, "ZMEMBERJID") {
            let nc = pick(gmC, "ZCONTACTNAME") ?? "NULL"
            try? src.query("SELECT Z_PK, \(jc), \(nc) FROM ZWAGROUPMEMBER") { memberJID[$0.int(0)] = $0.text(1) ?? ""; if let n = $0.text(2), !n.isEmpty { memberName[$0.int(0)] = n } }
        }
        // push names (what people call themselves) -> display names
        var pushed = Set<Int64>()
        let insName = try dst.prepare("INSERT OR REPLACE INTO lid_display_name VALUES(?,?,NULL)")
        let pnC = cols("ZWAPROFILEPUSHNAME")
        if let jc = pick(pnC, "ZJID"), let nc = pick(pnC, "ZPUSHNAME") {
            try? src.query("SELECT \(jc), \(nc) FROM ZWAPROFILEPUSHNAME WHERE \(jc) IS NOT NULL AND \(nc) IS NOT NULL AND \(nc) <> ''") { r in
                let row = jid(r.text(0) ?? ""); try insName.run([.int(row), .text(r.text(1) ?? "")]); pushed.insert(row); res.pushNames += 1
            }
        }

        // media
        var media: [Int64: (path: String?, caption: String?, size: Int64?, hash: String?)] = [:]
        if let mm = pick(mediaC, "ZMESSAGE") {
            let pc = pick(mediaC, "ZMEDIALOCALPATH") ?? "NULL", tc = pick(mediaC, "ZTITLE") ?? "NULL", sc = pick(mediaC, "ZFILESIZE") ?? "NULL", hc = pick(mediaC, "ZMEDIAKEY") ?? "NULL"
            _ = hc
            try? src.query("SELECT \(mm), \(pc), \(tc), \(sc) FROM ZWAMEDIAITEM WHERE \(mm) IS NOT NULL") { r in
                media[r.int(0)] = (r.text(1), r.text(2), r.isNull(3) ? nil : r.int(3), nil)
            }
        }

        // messages
        let dateC = pick(msgC, "ZMESSAGEDATE", "ZSENTDATE") ?? "ZMESSAGEDATE"
        let q = """
        SELECT Z_PK, ZCHATSESSION, ZISFROMME, \(dateC), \(pick(msgC, "ZTEXT") ?? "NULL"), \(pick(msgC, "ZMESSAGETYPE") ?? "0"),
               \(pick(msgC, "ZSTANZAID") ?? "NULL"), \(pick(msgC, "ZGROUPMEMBER") ?? "NULL"), \(pick(msgC, "ZFROMJID") ?? "NULL")
        FROM ZWAMESSAGE WHERE ZCHATSESSION IS NOT NULL AND \(dateC) IS NOT NULL ORDER BY Z_PK
        """
        let insMsg = try dst.prepare("INSERT INTO message VALUES(?,?,?,?,?,?,?,?)")
        let insMed = try dst.prepare("INSERT INTO message_media VALUES(?,?,?,?,?,NULL,?)")
        try src.query(q) { r in
            guard let cj = chatRow[r.int(1)] else { return }
            let pk = r.int(0), fromMe = r.int(2) != 0 ? Int64(1) : 0
            let ts = Int64((r.double(3) + appleEpoch) * 1000)
            let md = media[pk]
            let type = androidType(r.int(5), hasMedia: md != nil)
            var sender: SQLValue = .null
            if fromMe == 0 {
                let isGroup = (try? dst.scalarInt("SELECT count(*) FROM jid WHERE _id=\(cj) AND server='g.us'")) == 1
                if isGroup {
                    if !r.isNull(7), let mj = memberJID[r.int(7)], !mj.isEmpty {
                        let row = jid(mj); sender = .int(row)
                        if !pushed.contains(row), let n = memberName[r.int(7)] { try insName.run([.int(row), .text(n)]) }
                    }
                }
            }
            let key = r.text(6) ?? "ios-\(pk)"
            try insMsg.run([.int(pk), .int(r.int(1)), .int(fromMe), sender, .int(ts), .int(type), r.text(4).map { .text($0) } ?? .null, .text(key)])
            res.messages += 1
            if let md {
                let ext = (md.path ?? "").split(separator: ".").last.map { $0.lowercased() } ?? ""
                try insMed.run([.int(pk), .int(r.int(1)), mimeByExt[ext].map { .text($0) } ?? .null, md.path.map { .text($0) } ?? .null, md.size.map { .int($0) } ?? .null, md.caption.map { .text($0) } ?? .null])
                res.media += 1
            }
        }
        try dst.exec("COMMIT")
        return res
    }
}

/// Talks to a plugged-in iPhone through libimobiledevice (`brew install libimobiledevice`). Like Adb for Android.
public enum Idevice {
    public enum State: Sendable { case missingTools, noPhone, ready(udid: String) }
    static func tool(_ n: String) -> String? { ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + n }.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func run(_ exe: String, _ args: [String], timeout: Double = 20) async -> (code: Int32, out: String) {
        await withCheckedContinuation { cont in
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async { let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self))) }
        }
    }
    public static func state() async -> State {
        guard let id = tool("idevice_id") else { return .missingTools }
        let r = await run(id, ["-l"])
        let udid = r.out.split(whereSeparator: \.isNewline).first.map(String.init)
        return udid.map { .ready(udid: $0) } ?? .noPhone
    }
    public static func info(_ udid: String) async -> (name: String, version: String)? {
        guard let t = tool("ideviceinfo") else { return nil }
        async let n = run(t, ["-u", udid, "-k", "DeviceName"]), v = run(t, ["-u", udid, "-k", "ProductVersion"])
        let (a, b) = await (n, v)
        return a.code == 0 ? (a.out.trimmingCharacters(in: .whitespacesAndNewlines), b.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }
}

extension Idevice {
    public enum BackupResult: Sendable { case ok, locked, failed(String) }

    /// Runs `idevicebackup2 backup` into `folder` (first time: the whole phone, often 5-20 GB over USB; afterwards only changes).
    /// `progress` gets (percent, text). Needs the phone unlocked; the user may have to enter the passcode on it.
    public static func backup(udid: String, to folder: URL, progress: @escaping @Sendable (Int, String) -> Void) async -> BackupResult {
        guard let exe = tool("idevicebackup2") else { return .failed("libimobiledevice is not installed.") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return await withCheckedContinuation { cont in
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["-u", udid, "backup", folder.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            final class Box: @unchecked Sendable { var text = ""; var buf = "" }
            let box = Box()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; guard !d.isEmpty else { return }
                box.buf += String(decoding: d, as: UTF8.self)
                let parts = box.buf.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
                box.buf = parts.last ?? ""
                for l in parts.dropLast() where !l.isEmpty {
                    box.text += l + "\n"
                    if let r = l.range(of: #"\]\s+(\d+)%\s+\(([^)]+)\)"#, options: .regularExpression) {
                        let seg = String(l[r]); let pct = Int(seg.split(separator: "%").first?.filter(\.isNumber) ?? "") ?? 0
                        let inner = seg.components(separatedBy: "(").last?.replacingOccurrences(of: ")", with: "") ?? ""
                        progress(pct, inner)
                    } else if l.contains("Waiting for passcode") { progress(-1, "Unlock your iPhone and enter its passcode") }
                }
            }
            p.terminationHandler = { pr in
                pipe.fileHandleForReading.readabilityHandler = nil
                if pr.terminationStatus == 0 { cont.resume(returning: .ok) }
                else if box.text.contains("Device locked") || box.text.contains("208") { cont.resume(returning: .locked) }
                else { cont.resume(returning: .failed(box.text.split(separator: "\n").last.map(String.init) ?? "backup failed")) }
            }
            do { try p.run() } catch { cont.resume(returning: .failed("\(error)")) }
        }
    }
}

/// "Update from iPhone": back up the phone over USB, read WhatsApp's database out of the backup, add the new messages to the vault.
public enum IOSUpdater {
    public enum Failure: LocalizedError {
        case tools, noPhone, locked, backup(String)
        public var errorDescription: String? {
            switch self {
            case .tools: return "iPhone support needs a small free tool. In Terminal run:  brew install libimobiledevice"
            case .noPhone: return "Plug in your iPhone, unlock it and tap Trust."
            case .locked: return "The iPhone is locked. Unlock it (and keep the screen on), then try again."
            case .backup(let m): return "The iPhone backup failed: \(m)"
            }
        }
    }
    public static func backupFolder(_ support: URL) -> URL { support.appendingPathComponent("ios-backup") }

    public static func run(support: URL, vault: Vault, indexOut: URL, label: String, vcfPath: String? = nil,
                           progress: @escaping @Sendable (String) -> Void) async throws -> ImportSummary {
        progress("Looking for your iPhone…")
        let udid: String
        switch await Idevice.state() {
        case .missingTools: throw Failure.tools
        case .noPhone: throw Failure.noPhone
        case .ready(let u): udid = u
        }
        progress("Backing up your iPhone (the first time can take a while)…")
        switch await Idevice.backup(udid: udid, to: backupFolder(support), progress: { pct, txt in
            progress(pct < 0 ? txt : "Backing up your iPhone… \(pct)% (\(txt))")
        }) {
        case .ok: break
        case .locked: throw Failure.locked
        case .failed(let m): throw Failure.backup(m)
        }
        progress("Reading WhatsApp from the backup…")
        let found = try IOSBackup.locate(backupFolder(support))
        let cs = try IOSBackup.chatStorage(found)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-ios-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try IOSBackup.convert(chatStorage: cs.path, to: tmp.path)
        progress("Adding new messages to your archive…")
        let r = try await Task.detached { try vault.ingest(msgstore: tmp.path, label: label, source: "ios-backup", fullSnapshot: false) }.value
        progress(r.added == 0 ? "No new messages; refreshing…" : "Added \(r.added.formatted()) new messages…")
        progress("Building your library…")
        return try await Task.detached { try VaultIndexer.build(vault: vault, out: indexOut.path, vcfPath: vcfPath) }.value
    }
}
