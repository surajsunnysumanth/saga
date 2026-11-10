import Foundation

/// Rebuilds the local SQLite index from a vault's segments. Same schema as `Importer`, so the app doesn't care which path built it.
public enum VaultIndexer {
    struct Msg {
        var uid: String, chat: String, fm: Int64, ts: Int64, ty: Int64, text: String?
        var sj: String?, sl: String?, sn: String?
        var mime: String?, path: String?, size: Int64?, hash: String?, cap: String?, hasMedia = false
    }
    struct Chat { var jid: String, group: Bool, j: String, l: String?, n: String?, sub: String? }

    static func jid(_ raw: String) -> Resolver.JID {
        if let at = raw.lastIndex(of: "@") { return Resolver.JID(user: String(raw[..<at]), server: String(raw[raw.index(after: at)...]), raw: raw) }
        return Resolver.JID(user: raw, server: "", raw: raw)
    }

    public static func build(vault: Vault, out: String, vcfPath: String? = nil, overridesPath: String? = nil,
                             extraContacts: [String: String] = [:]) throws -> ImportSummary {
        // Contact names live in the vault (config/contacts.json, overrides.csv) so a rebuild never loses them.
        let cfg = vault.url.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        let overridesFile = cfg.appendingPathComponent("overrides.csv")
        var vcf = try vault.readConfig("contacts.json").flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
        let before = vcf
        let fromVCF: [String: String] = vcfPath.map(ContactSources.loadVCF) ?? [:]   // explicit type: `?? [:]` alone is ambiguous on some toolchains
        for (k, v) in fromVCF { vcf[k] = v }
        for (k, v) in extraContacts { vcf[k] = v }
        if vcf != before, let d = try? JSONSerialization.data(withJSONObject: vcf, options: [.sortedKeys]) { try vault.writeConfig(d, name: "contacts.json") }
        if let o = overridesPath, o != overridesFile.path { try? FileManager.default.removeItem(at: overridesFile); try? FileManager.default.copyItem(atPath: o, toPath: overridesFile.path) }
        let overrides = ContactSources.loadOverrides(path: overridesFile.path)
        // The phone's own address book: the only name evidence that comes from the owner rather than from
        // WhatsApp. Keyed by person key, so it slots straight into resolution.
        let saved = PhoneContacts.names(in: vault)

        var chats: [String: Chat] = [:]
        var msgs: [String: Msg] = [:]
        var mediaUpdates: [String: [String: Any]] = [:]
        var gone: [String: String] = [:]
        var extraJids: [(j: String, l: String?, n: String?)] = []
        var replies: [String: String] = [:]
        var reactionRecords: [(u: String, j: String?, n: String?, me: Bool, e: String, ts: Int64)] = []
        try vault.readAll { r in
            switch r["k"] as? String {
            case "chat":
                guard let jid = r["jid"] as? String, let j = r["j"] as? String else { return }
                chats[jid] = Chat(jid: jid, group: (r["g"] as? NSNumber)?.intValue == 1, j: j, l: r["l"] as? String, n: r["n"] as? String, sub: r["sub"] as? String)
            case "m":
                guard let u = r["u"] as? String, msgs[u] == nil, let c = r["c"] as? String else { return }
                var m = Msg(uid: u, chat: c, fm: (r["fm"] as? NSNumber)?.int64Value ?? 0, ts: (r["ts"] as? NSNumber)?.int64Value ?? 0,
                            ty: (r["ty"] as? NSNumber)?.int64Value ?? 0, text: r["tx"] as? String)
                if let s = r["s"] as? [String: Any] { m.sj = s["j"] as? String; m.sl = s["l"] as? String; m.sn = s["n"] as? String }
                if let md = r["md"] as? [String: Any] {
                    m.hasMedia = true; m.mime = md["mime"] as? String; m.path = md["path"] as? String
                    m.size = (md["size"] as? NSNumber)?.int64Value; m.hash = md["hash"] as? String; m.cap = md["cap"] as? String
                }
                msgs[u] = m
            case "q":
                if let u = r["u"] as? String, let t = r["t"] as? String { replies[u] = t }
            case "r":
                // A reaction names one message and one reactor; it is never folded into text.
                if let u = r["u"] as? String, let e = r["e"] as? String, !e.isEmpty {
                    reactionRecords.append((u, r["j"] as? String, r["n"] as? String,
                                            (r["me"] as? NSNumber)?.intValue == 1, e,
                                            (r["ts"] as? NSNumber)?.int64Value ?? 0))
                }
            case "md":
                // A later backup learned where a file lives (it was downloaded after the first import).
                // The message record is append-only and already stored, so the path arrives as its own
                // record and is folded in below.
                if let u = r["u"] as? String, let md = r["md"] as? [String: Any] { mediaUpdates[u] = md }
            case "gone":
                if let u = r["u"] as? String, let at = r["at"] as? String { gone[u] = at }
            case "j":
                if let j = r["j"] as? String { extraJids.append((j, r["l"] as? String, r["n"] as? String)) }
            default: break
            }
        }

        // Fold media updates into the messages they belong to. An update only ever fills or replaces
        // media metadata — it never resurrects a message that no segment holds.
        for (u, md) in mediaUpdates {
            guard msgs[u] != nil else { continue }
            msgs[u]?.hasMedia = true
            if let v = md["mime"] as? String { msgs[u]?.mime = v }
            if let v = MediaPathIndex.cleanPath(md["path"] as? String) { msgs[u]?.path = v }
            if let v = (md["size"] as? NSNumber)?.int64Value { msgs[u]?.size = v }
            if let v = md["hash"] as? String { msgs[u]?.hash = v }
            if let v = md["cap"] as? String { msgs[u]?.cap = v }
        }
        // Same content, recorded twice: the copy the phone did download knows where the file is,
        // so a row that has no path can borrow that one. Only an equal SHA-256 counts.
        var mediaPaths = MediaPathIndex()
        for m in msgs.values { mediaPaths.record(hash: m.hash, path: m.path) }
        var pathsRecovered = 0
        for u in msgs.keys {
            guard let m = msgs[u], m.hasMedia, MediaPathIndex.needsPath(m.path, hash: m.hash),
                  let p = mediaPaths.path(for: m.hash) else { continue }
            msgs[u]?.path = p
            pathsRecovered += 1
        }

        try? FileManager.default.removeItem(atPath: out)
        let dst = try SQLiteDB(path: out, readOnly: false)
        try dst.exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
        try dst.exec(Importer.schema)
        try dst.exec("BEGIN")

        var people: [String: (String, Int)] = [:]
        var aliases: [String: String] = [:]
        var groupOf: [String: PersonMerge] = [:]
        let merges = try MergeConfig.loadChecked(vault)
        for g in merges { for k in g.keys { groupOf[k] = g } }
        // Person before merges are applied, so the original key is never lost.
        func basePerson(_ j: String, _ l: String?, _ n: String?) -> Resolver.P {
            Resolver.resolve(jid(j), lidName: n, vcf: vcf, overrides: overrides, saved: saved)
        }
        /// A name the owner typed for one of these raw JIDs outranks every source, whichever JID the resolver
        /// happened to look up: a `lid` chat that maps through a phone JID would otherwise accept a typed
        /// name and silently ignore it.
        func typed(_ raws: [String]) -> String? {
            for raw in raws where !raw.isEmpty { if let n = Importer.nonEmpty(overrides[raw]) { return n } }
            return nil
        }
        func person(_ j: String, _ l: String?, _ n: String?, typedIn raws: [String] = []) -> Resolver.P {
            var p = basePerson(j, l, n)
            if let typed = typed(raws) { p = Resolver.P(key: p.key, name: typed, resolved: 1) }
            if let g = groupOf[p.key] { p = Resolver.P(key: g.keys[0], name: g.name, resolved: 1) }      // merged: shown as one person
            if p.resolved == 1 { aliases[jid(j).user] = p.name; if let l { aliases[jid(l).user] = p.name } }
            return p
        }

        // Every original DM identity, collected before merged chats collapse into one row. Disposable: the table is
        // recreated on every rebuild and an index without it behaves as a singleton view.
        var members: [MergeMember] = []
        var memberJIDs: [String: [String]] = [:]
        for (chatJID, chat) in chats where !chat.group {
            var base = basePerson(chat.j, chat.l, chat.n)
            if let typed = typed([chatJID, chat.l ?? ""]) { base = Resolver.P(key: base.key, name: typed, resolved: 1) }
            let primary = groupOf[base.key]?.keys[0] ?? base.key
            members.append(MergeIdentity.member(person: primary, member: base.key, rawJID: chatJID, resolvedJID: chat.j))
            memberJIDs[primary, default: []].append(chatJID)
        }
        try dst.exec(MergeIdentity.indexSchema)
        let insMember = try dst.prepare("INSERT OR REPLACE INTO merge_members VALUES(?,?,?,?,?)")
        for m in members {
            try insMember.run([.text(m.person), .text(m.member), .text(m.jid),
                               m.phone.map { .text($0) } ?? .null, m.lid.map { .text($0) } ?? .null])
        }

        // Rules use the original chat JIDs. A merged conversation accepts any of its members' rules (Boolean OR),
        // and sender exclusions resolve to the person key the index actually stores. `prune.json` is untouched.
        let rules = try PruneConfig.loadChecked(vault)
        var pruner = Pruner(rules: MergeIdentity.effectiveRules(rules, merges: merges, conversationMembers: memberJIDs))
        var pruned = 0
        var chatId: [String: Int64] = [:], chatPerson: [String: String] = [:], dmByPerson: [String: Int64] = [:]
        let insChat = try dst.prepare("INSERT INTO chats VALUES(?,?,?,?,?,?)")
        for (i, jid) in chats.keys.sorted().enumerated() {
            if pruner.hidesChat(jid) { continue }
            let c = chats[jid]!, id = Int64(i + 1)
            if !c.group {                                       // chats with the same (merged) person share one chat
                let p = person(c.j, c.l, c.n, typedIn: [jid, c.l ?? ""])
                if let first = dmByPerson[p.key] { chatId[jid] = first; chatPerson[jid] = p.key; people[p.key] = (p.name, p.resolved); continue }
                dmByPerson[p.key] = id
            }
            chatId[jid] = id
            if c.group {
                let sub = c.sub ?? ""
                try insChat.run([.int(id), .text(jid), .int(1), .text(sub.isEmpty ? "(unnamed group)" : sub), .int(sub.isEmpty ? 0 : 1), .null])
            } else {
                let p = person(c.j, c.l, c.n, typedIn: [jid, c.l ?? ""]); people[p.key] = (p.name, p.resolved); chatPerson[jid] = p.key
                try insChat.run([.int(id), .text(jid), .int(0), .text(p.name), .int(Int64(p.resolved)), .text(p.key)])
            }
        }

        let ordered = msgs.values.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.uid < $1.uid }
        let insMsg = try dst.prepare("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?)")
        let insMed = try dst.prepare("INSERT OR IGNORE INTO media VALUES(?,?,?,?,?,?,?,?,?,NULL)")
        var next: Int64 = 0, merged = 0
        var indexID: [String: Int64] = [:], indexChat: [String: Int64] = [:]
        for m in ordered {
            guard let cid = chatId[m.chat] else { if pruner.hidesChat(m.chat) { pruned += 1 }; continue }
            let key: String, nm: String
            if m.fm != 0 { key = "me"; nm = "me" }
            else if let sj = m.sj { let p = person(sj, m.sl, m.sn, typedIn: [sj, m.sl ?? ""]); people[p.key] = (p.name, p.resolved); key = p.key; nm = p.name }
            else { key = chatPerson[m.chat] ?? "unknown"; nm = people[key]?.0 ?? "Unknown" }
            let verdict = pruner.judge(chat: m.chat, text: m.text, hasMedia: m.hasMedia, fileHash: m.hash, person: key, fromMe: m.fm != 0)
            if verdict == .drop { pruned += 1; continue }
            let keepMedia = m.hasMedia && verdict == .keep
            next += 1
            indexID[m.uid] = next; indexChat[m.uid] = cid
            try insMsg.run([.int(next), .int(cid), .int(m.fm), .text(nm), .text(key), .int(m.ts), .int(m.ty), m.text.map { .text($0) } ?? .null, .text(m.uid)])
            if keepMedia {
                try insMed.run([.int(next), .int(cid), .int(m.ts), m.mime.map { .text($0) } ?? .null, .text(Importer.kindOf(mime: m.mime, path: m.path, type: m.ty)),
                                m.path.map { .text($0) } ?? .null, m.size.map { .int($0) } ?? .null, m.hash.map { .text($0) } ?? .null, m.cap.map { .text($0) } ?? .null])
            }
            if gone[m.uid] != nil { merged += 1 }
        }
        let insR = try dst.prepare("INSERT OR IGNORE INTO message_replies(uid,target_uid) VALUES(?,?)")
        for (u, t) in replies where msgs[u] != nil { try insR.run([.text(u), .text(t)]) }
        var reactionRows: [MessageReaction] = []
        for rec in reactionRecords {
            guard let id = indexID[rec.u], let chat = indexChat[rec.u] else { continue }
            let sender: String, name: String
            if rec.me { sender = "me"; name = "me" }
            else if let j = rec.j, !j.isEmpty { let p = person(j, nil, rec.n); sender = p.key; name = p.name }
            else { sender = "unknown"; name = "Unknown" }     // a JID row this backup no longer holds
            reactionRows.append(MessageReaction(messageID: id, chatID: chat, sender: sender, senderName: name, emoji: rec.e, ts: rec.ts))
        }
        try MessageReactions.insert(MessageReactions.dedupe(reactionRows), into: dst)
        for j in extraJids { _ = person(j.j, j.l, j.n) }
        let insP = try dst.prepare("INSERT INTO people VALUES(?,?,?)")
        for (k, v) in people { try insP.run([.text(k), .text(v.0), .int(Int64(v.1))]) }
        let insG = try dst.prepare("INSERT OR IGNORE INTO gone VALUES(?,?)")
        for (u, at) in gone where msgs[u] != nil { try insG.run([.text(u), .text(at)]) }
        try dst.exec("CREATE TABLE aliases(alias TEXT PRIMARY KEY, name TEXT)")
        let insA = try dst.prepare("INSERT OR IGNORE INTO aliases VALUES(?,?)")
        for (a, n) in aliases { try insA.run([.text(a), .text(n)]) }
        try dst.exec("COMMIT")
        try dst.exec(Importer.finish)

        var s = ImportSummary()
        s.messages = Int(next); s.chats = chats.count; s.people = people.count
        s.namedPeople = people.values.filter { $0.1 == 1 }.count
        s.media = Int(try dst.scalarInt("SELECT count(*) FROM media")); s.mergedMessages = merged; s.prunedMessages = pruned
        s.reactions = Int(try dst.scalarInt("SELECT count(*) FROM reactions"))
        s.mediaPathsRecovered = pathsRecovered
        return s
    }
}
