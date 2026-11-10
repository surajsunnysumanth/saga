import Foundation
import CryptoKit

/// Builds `vault_index.db` from a decrypted msgstore.db. Same schema and name-resolution rules as the Python reference.
public struct ImportOptions: Sendable {
    public var sourceDB: String, outputDB: String
    public var vcfPath: String?, overridesPath: String?
    /// Extra contact names (normalised phone -> name), e.g. from the Mac Contacts app. Only fills numbers the vCard lacks.
    public var extraContacts: [String: String]
    /// Older (or other) decrypted msgstore.db files whose messages are merged in when the primary lacks them
    /// (e.g. messages since deleted on the phone). Messages are matched by chat JID + WhatsApp key id.
    public var additionalSources: [String]
    public init(sourceDB: String, outputDB: String, vcfPath: String? = nil, overridesPath: String? = nil, extraContacts: [String: String] = [:], additionalSources: [String] = []) {
        self.sourceDB = sourceDB; self.outputDB = outputDB; self.vcfPath = vcfPath; self.overridesPath = overridesPath; self.extraContacts = extraContacts; self.additionalSources = additionalSources
    }
}

public struct ImportSummary: Sendable {
    public var messages = 0, chats = 0, people = 0, namedPeople = 0, media = 0, mergedMessages = 0, prunedMessages = 0
    /// Emoji reactions stored (one row per message + reactor). Zero when the backup predates them.
    public var reactions = 0
    /// Media rows that had no path in any source and recovered one from an identical file
    /// (equal SHA-256) recorded under another message. Zero means nothing was recoverable.
    public var mediaPathsRecovered = 0
}

/// Resolves JID rows of one msgstore.db to people (LID -> phone via jid_map -> contacts/overrides -> LID display name).
final class Resolver {
    struct JID { let user: String, server: String, raw: String }
    struct P { let key: String, name: String, resolved: Int }
    var jids: [Int64: JID] = [:]
    var lid2jid: [Int64: Int64] = [:]
    var lidNames: [Int64: String] = [:]
    var cache: [Int64: P] = [:]
    let vcf: [String: String], overrides: [String: String]
    /// The owner's address book, keyed by person key (last ten digits). Empty when the vault has no export.
    let saved: [String: String]

    init(_ src: SQLiteDB, vcf: [String: String], overrides: [String: String], saved: [String: String] = [:]) throws {
        self.vcf = vcf; self.overrides = overrides; self.saved = saved
        try src.query("SELECT _id,user,server,raw_string FROM jid") {
            jids[$0.int(0)] = JID(user: $0.text(1) ?? "", server: $0.text(2) ?? "", raw: $0.text(3) ?? "")
        }
        try? src.query("SELECT lid_row_id, jid_row_id FROM jid_map") { lid2jid[$0.int(0)] = $0.int(1) }
        try? src.query("SELECT lid_row_id, display_name, username FROM lid_display_name") {
            let dn = $0.text(1) ?? "", un = $0.text(2) ?? ""
            if !dn.isEmpty && !dn.contains("∙") { lidNames[$0.int(0)] = dn } else if !un.isEmpty { lidNames[$0.int(0)] = "@" + un }
        }
    }
    /// Pure name resolution for an (already LID-mapped) JID. Shared with the vault indexer.
    ///
    /// Precedence, strongest first: an explicit per-chat override (the owner typed it), the name the number is
    /// saved under in the owner's address book, names imported from an older vCard or another address book, the
    /// WhatsApp profile name, then the number itself. Same inputs always give the same name, and nothing here
    /// reads or writes outside the dictionaries it is handed.
    static func resolve(_ j: JID, lidName: String?, vcf: [String: String], overrides: [String: String],
                        saved: [String: String] = [:]) -> P {
        if j.server == "s.whatsapp.net" {
            let n = normalizePhone(j.user)
            let key = n.isEmpty ? j.user : n
            let nm = Importer.nonEmpty(overrides[j.raw]) ?? Importer.nonEmpty(saved[n]) ?? Importer.nonEmpty(vcf[n]) ?? Importer.nonEmpty(lidName)
            return P(key: key, name: nm ?? "+\(j.user)", resolved: nm != nil ? 1 : 0)
        } else if j.server == "lid" || j.server == "hosted.lid" {
            // A LID carries no phone number, so a saved contact cannot identify it — never guess. An
            // override is the exception: it is the owner themselves typing a name for this exact chat,
            // which is the strongest evidence the archive can hold and the only way to name a LID.
            let typed = Importer.nonEmpty(overrides[j.raw])
            let profile = Importer.nonEmpty(lidName)
            return P(key: "lid:" + j.user, name: typed ?? profile ?? "Unknown (\(j.user.suffix(4)))",
                     resolved: (typed ?? profile) != nil ? 1 : 0)
        }
        return P(key: "\(j.server):\(j.user)", name: j.user, resolved: 0)
    }
    func person(_ row: Int64) -> P {
        if let c = cache[row] { return c }
        let res: P
        if var j = jids[row] {
            let lidName = lidNames[row]
            if (j.server == "lid" || j.server == "hosted.lid"), let m = lid2jid[row], let mj = jids[m] { j = mj }
            res = Resolver.resolve(j, lidName: lidName, vcf: vcf, overrides: overrides, saved: saved)
        } else { res = P(key: "unknown", name: "Unknown", resolved: 0) }
        cache[row] = res
        return res
    }
}

/// Stable message identity: survives re-imports, new backups and platform changes (chat JID + WhatsApp key id + direction).
public enum Uid {
    public static func make(chat: String, keyId: String, fromMe: Int64) -> String {
        let d = SHA256.hash(data: Data("\(chat)|\(keyId)|\(fromMe)".utf8))
        return d.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Importer {
    typealias JID = Resolver.JID
    typealias P = Resolver.P

    static let schema = """
    CREATE TABLE chats(chat_id INTEGER PRIMARY KEY, jid TEXT, is_group INT, name TEXT, resolved INT, person TEXT);
    CREATE TABLE people(person TEXT PRIMARY KEY, name TEXT, resolved INT);
    CREATE TABLE messages(id INTEGER PRIMARY KEY, chat_id INT, from_me INT, sender TEXT, person TEXT, ts INT, type INT, text TEXT, uid TEXT);
    CREATE TABLE gone(uid TEXT PRIMARY KEY, seen_gone TEXT);
    CREATE TABLE media(msg_id INTEGER PRIMARY KEY, chat_id INT, ts INT, mime TEXT, kind TEXT, file_path TEXT, size INT, file_hash TEXT, caption TEXT, rel TEXT);
    CREATE TABLE IF NOT EXISTS message_replies(uid TEXT PRIMARY KEY, target_uid TEXT NOT NULL);
    """ + MessageReactions.schema
    static let finish = """
    CREATE INDEX ix_msg_chat ON messages(chat_id, ts);
    CREATE INDEX ix_msg_ts ON messages(ts);
    CREATE INDEX ix_msg_person ON messages(person);
    CREATE INDEX ix_msg_uid ON messages(uid);
    CREATE INDEX ix_media_chat ON media(chat_id, ts);
    CREATE INDEX ix_media_hash ON media(file_hash);
    CREATE VIRTUAL TABLE msg_fts USING fts5(text, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
    INSERT INTO msg_fts(rowid, text) SELECT id, text FROM messages WHERE text IS NOT NULL;
    INSERT INTO msg_fts(msg_fts) VALUES('optimize');
    CREATE TABLE chat_stats AS SELECT m.chat_id AS chat_id, count(*) AS n, min(m.ts) AS first_ts, max(m.ts) AS last_ts,
      -- content = messages a person would recognise (text, media, or any non-system type); chats with 0 are just encryption/system notices
      sum(m.type NOT IN (7,27,36,55,90) AND (COALESCE(m.text,'')<>'' OR EXISTS(SELECT 1 FROM media x WHERE x.msg_id=m.id))) AS content,
      -- last_real_ts ignores system notices (security code changed, encryption, "you joined"): those must not push a chat up the list
      max(CASE WHEN m.type NOT IN (7,27,36,55,90) AND (COALESCE(m.text,'')<>'' OR EXISTS(SELECT 1 FROM media x WHERE x.msg_id=m.id)) THEN m.ts END) AS last_real_ts,
      (SELECT COALESCE(NULLIF(m2.text,''), CASE WHEN md.kind IS NOT NULL THEN '📎 ' || md.kind END)
         FROM messages m2 LEFT JOIN media md ON md.msg_id = m2.id WHERE m2.chat_id = m.chat_id
          AND m2.type NOT IN (7,27,36,55,90) AND (COALESCE(m2.text,'')<>'' OR md.kind IS NOT NULL)
         ORDER BY m2.ts DESC LIMIT 1) AS last_text
      FROM messages m GROUP BY m.chat_id;
    CREATE UNIQUE INDEX ix_chat_stats ON chat_stats(chat_id);
    CREATE TABLE person_stats AS SELECT m.person AS person, count(*) AS n, sum(c.is_group=0) AS dm, sum(c.is_group=1) AS grp,
      min(m.ts) AS first_ts, max(m.ts) AS last_ts FROM messages m JOIN chats c USING(chat_id) WHERE m.from_me=0 GROUP BY m.person;
    CREATE UNIQUE INDEX ix_person_stats ON person_stats(person);
    CREATE VIEW v_msg AS SELECT m.id, datetime(m.ts/1000,'unixepoch','localtime') AS at, c.name AS chat, c.is_group, m.sender, m.from_me, m.type, m.text FROM messages m JOIN chats c USING(chat_id);
    """

    static let mediaExt: [String: String] = [
        "jpg": "image", "jpeg": "image", "png": "image", "gif": "image", "webp": "image", "heic": "image",
        "mp4": "video", "mov": "video", "3gp": "video", "mkv": "video", "avi": "video", "webm": "video",
        "mp3": "audio", "m4a": "audio", "aac": "audio", "opus": "audio", "ogg": "audio", "wav": "audio", "amr": "audio",
        "pdf": "doc", "doc": "doc", "docx": "doc", "xls": "doc", "xlsx": "doc", "ppt": "doc", "pptx": "doc",
        "txt": "doc", "zip": "doc", "rar": "doc", "csv": "doc", "apk": "doc",
    ]
    static func kindOf(mime: String?, path: String?, type: Int64? = nil) -> String {
        // WhatsApp stickers are ordinary image/webp files in the archive, so mime alone would
        // file them as photos. The message type (20) and the phone's own folder are the two
        // pieces of evidence that say otherwise; an older export that has neither stays an image.
        if type == 20 { return "sticker" }
        let lowerPath = (path ?? "").lowercased()
        if lowerPath.contains("whatsapp stickers/") || lowerPath.hasSuffix("/stickers") || lowerPath.contains("/stickers/") {
            return "sticker"
        }
        if let m = mime, !m.isEmpty {
            let top = m.lowercased().split(separator: "/").first.map(String.init) ?? ""
            return ["image", "video", "audio"].contains(top) ? top : "doc"
        }
        let ext = (path ?? "").split(separator: ".").last.map { $0.lowercased() } ?? ""
        return mediaExt[ext] ?? "other"
    }

    public static func run(_ o: ImportOptions) throws -> ImportSummary {
        var vcf = o.vcfPath.map(ContactSources.loadVCF) ?? [:]
        for (k, v) in o.extraContacts where vcf[k] == nil { vcf[k] = v }
        let overrides = o.overridesPath.map(ContactSources.loadOverrides) ?? [:]
        let src = try SQLiteDB(path: o.sourceDB, readOnly: true)

        let rp = try Resolver(src, vcf: vcf, overrides: overrides)
        let jids = rp.jids
        func person(_ row: Int64) -> P { rp.person(row) }

        try? FileManager.default.removeItem(atPath: o.outputDB)
        let dst = try SQLiteDB(path: o.outputDB, readOnly: false)
        try dst.exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        try dst.exec(schema)
        try dst.exec("BEGIN")

        var people: [String: (String, Int)] = [:]
        var chatPerson: [Int64: String] = [:]
        var chatIdByRaw: [String: Int64] = [:]
        var chatRaw: [Int64: String] = [:]
        var maxChatId: Int64 = 0
        let insChat = try dst.prepare("INSERT INTO chats VALUES(?,?,?,?,?,?)")
        var chatCount = 0
        try src.query("SELECT c._id, c.subject, c.jid_row_id, j.server FROM chat c JOIN jid j ON j._id=c.jid_row_id") { r in
            let cid = r.int(0), jrow = r.int(2), subj = r.text(1) ?? ""
            let raw = jids[jrow]?.raw ?? ""
            chatCount += 1; chatIdByRaw[raw] = cid; chatRaw[cid] = raw; maxChatId = max(maxChatId, cid)
            if r.text(3) == "g.us" {
                try insChat.run([.int(cid), .text(raw), .int(1), .text(subj.isEmpty ? "(unnamed group)" : subj), .int(subj.isEmpty ? 0 : 1), .null])
            } else {
                let p = person(jrow); people[p.key] = (p.name, p.resolved); chatPerson[cid] = p.key
                try insChat.run([.int(cid), .text(raw), .int(0), .text(p.name), .int(Int64(p.resolved)), .text(p.key)])
            }
        }

        let insMsg = try dst.prepare("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?)")
        var msgCount = 0, maxMsgId: Int64 = 0
        var seen = Set<String>()
        /// Source key -> index id, so a reaction from another backup can find the message the
        /// primary already holds (and never lands on a row with the same number but other text).
        var idByKey: [String: (id: Int64, chat: Int64)] = [:]
        var importedIDs = Set<Int64>()
        try src.query("SELECT _id, chat_row_id, from_me, sender_jid_row_id, timestamp, message_type, text_data, key_id FROM message WHERE timestamp > 0 ORDER BY _id") { r in
            let cid = r.int(1), fm = r.int(2)
            let key: String, nm: String
            if fm != 0 { key = "me"; nm = "me" }
            else if !r.isNull(3), r.int(3) != 0, jids[r.int(3)] != nil {
                let p = person(r.int(3)); people[p.key] = (p.name, p.resolved); key = p.key; nm = p.name
            } else {
                key = chatPerson[cid] ?? "unknown"; nm = people[key]?.0 ?? "Unknown"
            }
            msgCount += 1; maxMsgId = max(maxMsgId, r.int(0))
            let sourceKey = "\(chatRaw[cid] ?? "")|\(r.text(7) ?? "")|\(fm)"
            seen.insert(sourceKey); idByKey[sourceKey] = (r.int(0), cid); importedIDs.insert(r.int(0))
            try insMsg.run([.int(r.int(0)), .int(cid), .int(fm), .text(nm), .text(key), r.value(4), r.value(5), r.value(6), .text(Uid.make(chat: chatRaw[cid] ?? "", keyId: r.text(7) ?? "", fromMe: fm))])
        }
        // Reactions live in their own tables. A backup that never had them yields none; the
        // guard is inside `source`, so an old archive still imports cleanly.
        var reactions: [MessageReaction] = []
        for r in (try? MessageReactions.source(src, person: person)) ?? [] where importedIDs.contains(r.messageID) {
            reactions.append(MessageReaction(messageID: r.messageID, chatID: r.chatID, sender: r.sender,
                                             senderName: r.senderName, emoji: r.emoji, ts: r.ts))
        }

        // Media metadata only (file matching against a media folder is a later step: `rel` stays NULL).
        // A file whose own row has no path may still be on record under another message (a forward,
        // a re-save); equal SHA-256 means equal bytes, so that path is recorded instead of none.
        var sourceMediaPaths = MediaPathIndex()
        try src.query("SELECT file_hash, file_path FROM message_media") { r in
            sourceMediaPaths.record(hash: r.text(0), path: r.text(1))
        }
        var mediaPathsRecovered = 0
        let insMed = try dst.prepare("INSERT OR IGNORE INTO media VALUES(?,?,?,?,?,?,?,?,?,NULL)")
        try src.query("""
            SELECT mm.message_row_id, mm.chat_row_id, m.timestamp, mm.mime_type, mm.file_path, mm.file_length, mm.file_hash, mm.media_caption, m.message_type
            FROM message_media mm JOIN message m ON m._id=mm.message_row_id
            """) { r in
            var path = r.text(4)
            if MediaPathIndex.needsPath(path, hash: r.text(6)), let p = sourceMediaPaths.path(for: r.text(6)) {
                path = p; mediaPathsRecovered += 1
            }
            try insMed.run([r.value(0), r.value(1), r.value(2), r.value(3), .text(kindOf(mime: r.text(3), path: path, type: r.isNull(8) ? nil : r.int(8))), path.map { .text($0) } ?? .null, r.value(5), r.value(6), r.value(7)])
        }
        try? MessageReplies.insert(MessageReplies.source(src), into: dst)
        // Merge older/other archives: add only messages the primary lacks (matched by chat JID + key id + direction)
        var merged = 0
        var extraResolvers: [Resolver] = []
        for path in o.additionalSources {
            guard let ex = try? SQLiteDB(path: path, readOnly: true), let rx = try? Resolver(ex, vcf: vcf, overrides: overrides) else { continue }
            extraResolvers.append(rx)
            var exChat: [Int64: (raw: String, group: Bool, subject: String)] = [:]
            try ex.query("SELECT c._id, c.subject, c.jid_row_id, j.server FROM chat c JOIN jid j ON j._id=c.jid_row_id") {
                exChat[$0.int(0)] = (rx.jids[$0.int(2)]?.raw ?? "", $0.text(3) == "g.us", $0.text(1) ?? "")
            }
            func chatFor(_ exCid: Int64, _ jrow: Int64?) throws -> Int64? {
                guard let c = exChat[exCid], !c.raw.isEmpty else { return nil }
                if let id = chatIdByRaw[c.raw] { return id }
                maxChatId += 1; let id = maxChatId
                chatIdByRaw[c.raw] = id; chatCount += 1
                if c.group {
                    try insChat.run([.int(id), .text(c.raw), .int(1), .text(c.subject.isEmpty ? "(unnamed group)" : c.subject), .int(c.subject.isEmpty ? 0 : 1), .null])
                } else if let jrow {
                    let p = rx.person(jrow); if people[p.key] == nil { people[p.key] = (p.name, p.resolved) }
                    chatPerson[id] = p.key
                    try insChat.run([.int(id), .text(c.raw), .int(0), .text(p.name), .int(Int64(p.resolved)), .text(p.key)])
                }
                return id
            }
            var exChatJid: [Int64: Int64] = [:]
            try ex.query("SELECT _id, jid_row_id FROM chat") { exChatJid[$0.int(0)] = $0.int(1) }
            var idMap: [Int64: (new: Int64, chat: Int64)] = [:]
            try ex.query("SELECT _id, chat_row_id, from_me, sender_jid_row_id, timestamp, message_type, text_data, key_id FROM message WHERE timestamp > 0 ORDER BY _id") { r in
                let fm = r.int(2)
                guard let raw = exChat[r.int(1)]?.raw else { return }
                let k = "\(raw)|\(r.text(7) ?? "")|\(fm)"
                if seen.contains(k) {
                    // Already in the index from the primary: map the source row so its
                    // reactions still land on that message instead of being dropped.
                    if let existing = idByKey[k] { idMap[r.int(0)] = (existing.id, existing.chat) }
                    return
                }
                guard let cid = try chatFor(r.int(1), exChatJid[r.int(1)]) else { return }
                seen.insert(k)
                let key: String, nm: String
                if fm != 0 { key = "me"; nm = "me" }
                else if !r.isNull(3), r.int(3) != 0, rx.jids[r.int(3)] != nil {
                    let p = rx.person(r.int(3)); if people[p.key] == nil { people[p.key] = (p.name, p.resolved) }; key = p.key; nm = p.name
                } else { key = chatPerson[cid] ?? "unknown"; nm = people[key]?.0 ?? "Unknown" }
                maxMsgId += 1; merged += 1; msgCount += 1
                idMap[r.int(0)] = (maxMsgId, cid); idByKey[k] = (maxMsgId, cid)
                try insMsg.run([.int(maxMsgId), .int(cid), .int(fm), .text(nm), .text(key), r.value(4), r.value(5), r.value(6), .text(Uid.make(chat: raw, keyId: r.text(7) ?? "", fromMe: fm))])
            }
            var exMediaPaths = MediaPathIndex()
            try? ex.query("SELECT file_hash, file_path FROM message_media") { r in
                exMediaPaths.record(hash: r.text(0), path: r.text(1))
            }
            try? ex.query("""
                SELECT mm.message_row_id, m.timestamp, mm.mime_type, mm.file_path, mm.file_length, mm.file_hash, mm.media_caption, m.message_type
                FROM message_media mm JOIN message m ON m._id=mm.message_row_id
                """) { r in
                guard let m = idMap[r.int(0)] else { return }
                var path = r.text(3)
                if MediaPathIndex.needsPath(path, hash: r.text(5)), let p = exMediaPaths.path(for: r.text(5)) {
                    path = p; mediaPathsRecovered += 1
                }
                try insMed.run([.int(m.new), .int(m.chat), r.value(1), r.value(2), .text(kindOf(mime: r.text(2), path: path, type: r.isNull(7) ? nil : r.int(7))), path.map { .text($0) } ?? .null, r.value(4), r.value(5), r.value(6)])
            }
            for r in (try? MessageReactions.source(ex, person: { rx.person($0) })) ?? [] {
                guard let m = idMap[r.messageID] else { continue }
                reactions.append(MessageReaction(messageID: m.new, chatID: m.chat, sender: r.sender,
                                                 senderName: r.senderName, emoji: r.emoji, ts: r.ts))
            }
        }
        let insP = try dst.prepare("INSERT INTO people VALUES(?,?,?)")
        for (k, v) in people { try insP.run([.text(k), .text(v.0), .int(Int64(v.1))]) }
        // @mention resolution: every JID user (phone or LID digits) -> display name
        try dst.exec("CREATE TABLE aliases(alias TEXT PRIMARY KEY, name TEXT)")
        let insAlias = try dst.prepare("INSERT OR IGNORE INTO aliases VALUES(?,?)")
        for (row, j) in jids where j.server == "lid" || j.server == "s.whatsapp.net" || j.server == "hosted.lid" {
            let p = person(row)
            if p.resolved == 1 { try insAlias.run([.text(j.user), .text(p.name)]) }
        }
        for rx in extraResolvers {
            for (row, j) in rx.jids where j.server == "lid" || j.server == "s.whatsapp.net" || j.server == "hosted.lid" {
                let p = rx.person(row)
                if p.resolved == 1 { try insAlias.run([.text(j.user), .text(p.name)]) }
            }
        }
        try MessageReactions.insert(MessageReactions.dedupe(reactions), into: dst)
        try dst.exec("COMMIT")
        try dst.exec(finish)

        var s = ImportSummary()
        s.mergedMessages = merged; s.messages = msgCount; s.chats = chatCount; s.people = people.count
        s.namedPeople = people.values.filter { $0.1 == 1 }.count
        s.media = Int(try dst.scalarInt("SELECT count(*) FROM media"))
        s.reactions = Int(try dst.scalarInt("SELECT count(*) FROM reactions"))
        s.mediaPathsRecovered = mediaPathsRecovered
        return s
    }

    static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}
