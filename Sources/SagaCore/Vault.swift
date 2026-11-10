import Foundation
import CryptoKit

public struct IngestResult: Sendable {
    public var added = 0, skipped = 0, gone = 0, segment: String? = nil
    /// Media rows already in the archive that gained a path in this backup (the file was
    /// downloaded after the message was first imported).
    public var pathsUpdated = 0
    /// Reaction records this import added. Zero on a repeat pull of a backup whose reactions the
    /// vault already holds — that is what keeps a refresh from rewriting 50,000 identical rows.
    public var reactionsAdded = 0
    /// Which named source this import was filed under, and what the check concluded.
    public var profileID: String? = nil
    public var verdict: ProfileVerdict? = nil
    public var matchedProfile: VaultProfile? = nil
}

/// A vault is a plain folder holding the user's archive in open formats:
///   vault.json            format + id
///   segments/*.ndjson.gz  one per import; only messages not already present (append-only, safe on NAS/cloud folders)
///   media/ config/        reserved for media files and user rules
/// The SQLite index is a rebuildable cache and must live on a local disk.
public final class Vault: @unchecked Sendable {   // immutable URL only; methods are stateless
    public let url: URL
    public var segmentsDir: URL { url.appendingPathComponent("segments") }
    let meta: VaultMeta
    public let unlockContext: VaultUnlockContext?
    public var protection: VaultProtection { meta.protection }
    public var id: String { meta.id }

    public convenience init(url: URL, create: Bool = true, unlockContext: VaultUnlockContext? = nil) throws {
        try self.init(url: url, create: create, unlockContext: unlockContext, ignoreJournal: false)
    }

    /// Opens a vault for the CLI/background callers: encrypted vaults use the key remembered in the Keychain,
    /// otherwise fail closed with `.locked`. Never takes secrets from arguments.
    public static func open(url: URL, create: Bool = true, store: VaultKeyStore = SystemVaultKeyStore()) throws -> Vault {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.json").path) {
            let m = try VaultMeta.read(at: url)
            if m.protection == .encrypted {
                guard let ctx = try VaultKeychain.load(vaultID: m.id, store: store) else { throw VaultEncryptionError.locked }
                return try Vault(url: url, create: false, unlockContext: ctx)
            }
        }
        return try Vault(url: url, create: create)
    }

    init(url: URL, create: Bool, unlockContext: VaultUnlockContext?, ignoreJournal: Bool) throws {
        self.url = url
        let fm = FileManager.default
        if !ignoreJournal, ConversionJournal.pending(for: url) { throw VaultEncryptionError.conversionInProgress }
        let metaURL = url.appendingPathComponent("vault.json")
        if fm.fileExists(atPath: metaURL.path) {
            _ = try VaultMeta.read(at: url)                    // validate before creating anything inside an existing vault
        }
        if create {
            for d in ["segments", "media", "config"] { try fm.createDirectory(at: url.appendingPathComponent(d), withIntermediateDirectories: true) }
            if !fm.fileExists(atPath: metaURL.path) {
                let o: [String: Any] = ["app": "saga", "format": 1, "id": UUID().uuidString, "created": ISO8601DateFormatter().string(from: Date())]
                try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: metaURL)
            }
        }
        guard fm.fileExists(atPath: metaURL.path) else { throw SQLiteError.open("not a Saga vault: \(url.path)") }
        let m = try VaultMeta.read(at: url)
        if m.protection == .encrypted, let c = unlockContext, c.vaultID != m.id { throw VaultEncryptionError.wrongVault }
        self.meta = m
        self.unlockContext = m.protection == .encrypted ? unlockContext : nil
    }

    // MARK: storage gateway (segments + config/*.json); the only place that knows about encryption

    var segmentSuffix: String { protection == .encrypted ? ".ndjson.gz.enc" : ".ndjson.gz" }

    func key() throws -> SymmetricKey {
        guard protection == .encrypted else { throw VaultEncryptionError.ioFailure }
        guard let c = unlockContext else { throw VaultEncryptionError.locked }
        return c.key
    }

    func ensureWritable() throws {
        if ConversionRegistry.isActive(url) { throw VaultEncryptionError.conversionInProgress }
        if protection == .encrypted { _ = try key() }
        try checkRepresentation()
    }

    /// Rejects unexpected mixed plaintext/ciphertext protected files instead of silently ignoring one copy.
    func checkRepresentation() throws {
        let fm = FileManager.default
        let wrongSeg = protection == .encrypted ? ".ndjson.gz" : ".ndjson.gz.enc"
        let wrongCfg = protection == .encrypted ? ".json" : ".json.enc"
        for (dir, wrong) in [(segmentsDir, wrongSeg), (url.appendingPathComponent("config"), wrongCfg)] {
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !f.hasPrefix(".") && f.hasSuffix(wrong) {
                throw VaultEncryptionError.invalidMetadata
            }
        }
    }

    func logical(segment file: URL) throws -> String {
        guard file.deletingLastPathComponent().standardizedFileURL.path == segmentsDir.standardizedFileURL.path,
              file.lastPathComponent.hasSuffix(segmentSuffix), !file.lastPathComponent.hasPrefix(".") else { throw VaultEncryptionError.ioFailure }
        let n = file.lastPathComponent
        return "segments/" + (protection == .encrypted ? String(n.dropLast(4)) : n)
    }

    func read(protected file: URL, logicalPath: String) throws -> Data {
        guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw VaultEncryptionError.ioFailure }
        guard protection == .encrypted else { return d }
        return try VaultCrypto.open(d, key: try key(), aad: VaultCrypto.aad(vaultID: id, purpose: .file, path: logicalPath))
    }

    func seal(_ plain: Data, logicalPath: String) throws -> Data {
        try VaultCrypto.seal(plain, key: try key(), aad: VaultCrypto.aad(vaultID: id, purpose: .file, path: logicalPath))
    }

    static func validConfigName(_ name: String) -> Bool {
        !name.isEmpty && name.hasSuffix(".json") && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    func configURL(_ name: String) throws -> URL {
        guard Vault.validConfigName(name) else { throw VaultEncryptionError.ioFailure }
        let dir = url.appendingPathComponent("config")
        if let v = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true { throw VaultEncryptionError.ioFailure }
        let f = dir.appendingPathComponent(name + (protection == .encrypted ? ".enc" : ""))
        if let v = try? f.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true { throw VaultEncryptionError.ioFailure }
        return f
    }

    /// Contents of `config/<name>` (decrypted), or nil if absent. Locked/authentication/I-O failures throw — never an empty result.
    public func readConfig(_ name: String) throws -> Data? {
        let f = try configURL(name)
        try checkRepresentation()
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try read(protected: f, logicalPath: "config/" + name)
    }

    /// Atomically replaces `config/<name>`. Never leaves plaintext for an encrypted vault. If an existing encrypted
    /// file can't be authenticated with the current key, the write is refused rather than overwriting it.
    public func writeConfig(_ data: Data, name: String) throws {
        let f = try configURL(name)
        try ensureWritable()
        if protection == .encrypted, FileManager.default.fileExists(atPath: f.path) {
            _ = try read(protected: f, logicalPath: "config/" + name)
        }
        let payload = protection == .encrypted ? try seal(data, logicalPath: "config/" + name) : data
        do {
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: f, options: .atomic)
        } catch { throw VaultEncryptionError.ioFailure }
    }

    /// Original (still gzip-compressed) bytes of a segment file returned by `segmentFiles()`.
    public func readSegment(_ file: URL) throws -> Data {
        try read(protected: file, logicalPath: try logical(segment: file))
    }

    /// Segment files in the representation matching the vault's protection, in logical order.
    public func segmentFiles() -> [URL] {
        let suffix = segmentSuffix
        return ((try? FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(suffix) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Calls `visit` with each JSON record of every segment, oldest segment first.
    public func readAll(_ visit: ([String: Any]) -> Void) throws {
        try readLines { line in
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { visit(o) }
        }
    }

    /// Calls `visit` with each non-empty NDJSON line, oldest segment first. Segments are inflated in bounded
    /// chunks, so memory doesn't grow with segment size. Errors thrown by `visit` propagate unchanged.
    func readLines(_ visit: (Data) throws -> Void) throws {
        try checkRepresentation()
        if protection == .encrypted { _ = try key() }
        for f in segmentFiles() {
            let gz: Data
            do { gz = try readSegment(f) } catch let e as VaultEncryptionError { throw e } catch { throw SQLiteError.open("unreadable segment: \(f.lastPathComponent)") }
            var carry = Data()
            var failure: Error?
            do {
                try Gzip.forEachChunk(in: gz) { chunk in
                    var pos = 0
                    while pos < chunk.count {
                        let rest = UnsafeRawBufferPointer(rebasing: chunk[pos...])
                        guard let nl = memchr(rest.baseAddress!, 10, rest.count) else { carry.append(contentsOf: rest); return }
                        let len = nl - UnsafeMutableRawPointer(mutating: rest.baseAddress!)
                        if carry.isEmpty {
                            if len > 0 { do { try visit(Data(bytes: rest.baseAddress!, count: len)) } catch { failure = error; throw error } }
                        } else {
                            carry.append(rest.baseAddress!.assumingMemoryBound(to: UInt8.self), count: len)
                            let line = carry; carry = Data()
                            do { try visit(line) } catch { failure = error; throw error }
                        }
                        pos += len + 1
                    }
                }
            } catch {
                if let failure { throw failure }
                throw SQLiteError.open("unreadable segment: \(f.lastPathComponent)")
            }
            if !carry.isEmpty { try visit(carry) }
        }
    }

    /// uid -> timestamp (ms) of every message already in the vault.
    public func knownUIDs() throws -> [String: Int64] {
        try knownSnapshot().timestamps
    }

    /// What the vault already knows, in one pass: when each message arrived, and where the media
    /// it already holds lives. The media map is what lets an import notice that a file it saw
    /// before (pathless, because the phone had not downloaded it) now has a path.
    func knownSnapshot() throws -> (timestamps: [String: Int64], mediaPaths: [String: String]) {
        var times: [String: Int64] = [:]
        var paths: [String: String] = [:]
        try readAll { r in
            guard let u = r["u"] as? String else { return }
            if r["k"] as? String == "m" { times[u] = (r["ts"] as? NSNumber)?.int64Value ?? 0 }
            // A path can also have arrived later as its own `md` record (the file was downloaded
            // after the message was imported). Missing that made every pull re-send the same
            // handful of paths and write a segment that changed nothing.
            if let md = r["md"] as? [String: Any], let p = MediaPathIndex.cleanPath(md["path"] as? String) { paths[u] = p }
        }
        return (times, paths)
    }

    static func line(_ o: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Adds the messages of a decrypted msgstore.db that the vault doesn't have yet as one new segment.
    /// - Parameter fullSnapshot: true for a complete phone backup. Messages the vault has (inside that snapshot's time range)
    ///   but the snapshot lacks are recorded as "gone from phone": kept in the archive, flagged, never deleted.
    public func ingest(msgstore path: String, label: String, source: String = "android-crypt15",
                       fullSnapshot: Bool = true, dryRun: Bool = false,
                       profileName: String? = nil) throws -> IngestResult {
        if !dryRun { try ensureWritable() }
        let src = try SQLiteDB(path: path, readOnly: true)
        let known = try knownSnapshot()

        var jids: [Int64: (user: String, server: String, raw: String)] = [:]
        try src.query("SELECT _id,user,server,raw_string FROM jid") { jids[$0.int(0)] = ($0.text(1) ?? "", $0.text(2) ?? "", $0.text(3) ?? "") }
        var lid2jid: [Int64: Int64] = [:]
        try? src.query("SELECT lid_row_id, jid_row_id FROM jid_map") { lid2jid[$0.int(0)] = $0.int(1) }
        var lidNames: [Int64: String] = [:]
        try? src.query("SELECT lid_row_id, display_name, username FROM lid_display_name") {
            let dn = $0.text(1) ?? "", un = $0.text(2) ?? ""
            if !dn.isEmpty && !dn.contains("∙") { lidNames[$0.int(0)] = dn } else if !un.isEmpty { lidNames[$0.int(0)] = "@" + un }
        }
        func facts(_ row: Int64) -> (j: String, l: String?, n: String?)? {
            guard let jj = jids[row] else { return nil }
            let n = lidNames[row]
            if (jj.server == "lid" || jj.server == "hosted.lid"), let m = lid2jid[row], let mj = jids[m] { return (mj.raw, jj.raw, n) }
            return (jj.raw, nil, n)
        }

        var lines: [Data] = []
        var chatRaw: [Int64: String] = [:]
        try src.query("SELECT c._id, c.subject, c.jid_row_id, j.server FROM chat c JOIN jid j ON j._id=c.jid_row_id") { r in
            guard let f = facts(r.int(2)) else { return }
            chatRaw[r.int(0)] = jids[r.int(2)]?.raw ?? f.j
            var o: [String: Any] = ["k": "chat", "jid": jids[r.int(2)]?.raw ?? f.j, "g": r.text(3) == "g.us" ? 1 : 0, "j": f.j]
            if let l = f.l { o["l"] = l }; if let n = f.n { o["n"] = n }
            if let s = r.text(1), !s.isEmpty { o["sub"] = s }
            if let d = Vault.line(o) { lines.append(d) }
        }

        var mediaByMsg: [Int64: [String: Any]] = [:]
        try src.query("SELECT message_row_id, mime_type, file_path, file_length, file_hash, media_caption FROM message_media") { r in
            var m: [String: Any] = [:]
            if let v = r.text(1) { m["mime"] = v }; if let v = r.text(2) { m["path"] = v }
            if !r.isNull(3) { m["size"] = r.int(3) }; if let v = r.text(4) { m["hash"] = v }; if let v = r.text(5) { m["cap"] = v }
            mediaByMsg[r.int(0)] = m
        }
        // The phone may hold the same bytes under another message (a forward, a re-save) and record
        // the path only there. Equal SHA-256 is proof of equal content, so the pathless copy can
        // point at it instead of shipping a row nothing can resolve.
        var snapshotPaths = MediaPathIndex()
        for m in mediaByMsg.values { snapshotPaths.record(hash: m["hash"] as? String, path: m["path"] as? String) }
        for (row, var m) in mediaByMsg where MediaPathIndex.needsPath(m["path"] as? String, hash: m["hash"] as? String) {
            guard let p = snapshotPaths.path(for: m["hash"] as? String) else { continue }
            m["path"] = p
            mediaByMsg[row] = m
        }

        let replies = (try? MessageReplies.source(src)) ?? [:]
        // Reactions are their own records, not fields of a message: a reaction can arrive long after
        // the message did, and a message row is append-only. Reading them here is what makes a pull
        // able to add reactions to messages the vault already holds.
        let reactionSource = (try? MessageReactions.rawRows(src)) ?? []
        var reactionParent = Set<Int64>()
        for r in reactionSource { reactionParent.insert(r.messageID) }
        var knownReplies = Set<String>()
        var knownReactions = Set<String>()
        if !replies.isEmpty || !reactionSource.isEmpty {
            try readAll { r in
                switch r["k"] as? String {
                case "q": if let u = r["u"] as? String { knownReplies.insert(u) }
                case "r":
                    // Identity as a record carries it: message, reactor ("me", a raw JID, or
                    // "unknown" for a JID row this backup no longer has), emoji. Re-reading the
                    // same backup therefore adds nothing.
                    if let u = r["u"] as? String, let e = r["e"] as? String {
                        let who = (r["me"] as? NSNumber)?.intValue == 1 ? "me" : ((r["j"] as? String) ?? "unknown")
                        knownReactions.insert("\(u)|\(who)|\(e)")
                    }
                default: break
                }
            }
        }
        var replyAdded = 0
        var reactionTargets: [Int64: String] = [:]      // source message row -> vault uid
        var added = 0, skipped = 0, minTs = Int64.max, maxTs = Int64.min, pathsUpdated = 0
        var snapshotUIDs = Set<String>()
        var mentionTokens = Set<String>()
        let mention = try? NSRegularExpression(pattern: "@(\\d{7,})")
        try src.query("SELECT _id, chat_row_id, from_me, sender_jid_row_id, timestamp, message_type, text_data, key_id FROM message WHERE timestamp > 0 ORDER BY _id") { r in
            guard let raw = chatRaw[r.int(1)] else { return }
            let fm = r.int(2), ts = r.int(4)
            let uid = Uid.make(chat: raw, keyId: r.text(7) ?? "", fromMe: fm)
            minTs = min(minTs, ts); maxTs = max(maxTs, ts); snapshotUIDs.insert(uid)
            // Remember this message's vault identity if anything reacted to it, whether or not the
            // message itself is new: a reaction on a message imported years ago still has to land.
            if reactionParent.contains(r.int(0)) { reactionTargets[r.int(0)] = uid }
            if let target = replies[uid], !knownReplies.contains(uid) {      // quote side record; also back-fills messages stored before quotes were read
                knownReplies.insert(uid); replyAdded += 1
                if let d = Vault.line(["k": "q", "u": uid, "t": target]) { lines.append(d) }
            }
            if known.timestamps[uid] != nil {                 // already in the archive
                skipped += 1
                // The vault recorded this message before its file reached the phone. A later backup
                // is the first thing that knows where the file lives, so record the path now — the
                // append-only message row can never be rewritten.
                if let md = mediaByMsg[r.int(0)], let p = MediaPathIndex.cleanPath(md["path"] as? String),
                   known.mediaPaths[uid] == nil, let d = Vault.line(["k": "md", "u": uid, "md": md]) {
                    lines.append(d); pathsUpdated += 1
                }
                return
            }
            var o: [String: Any] = ["k": "m", "u": uid, "c": raw, "fm": fm, "ts": ts, "ty": r.int(5), "kid": r.text(7) ?? ""]
            if let t = r.text(6) {
                o["tx"] = t
                if let mention { let ns = t as NSString; for m in mention.matches(in: t, range: NSRange(location: 0, length: ns.length)) { mentionTokens.insert(ns.substring(with: m.range(at: 1))) } }
            }
            if fm == 0, !r.isNull(3), r.int(3) != 0, let f = facts(r.int(3)) {
                var s: [String: Any] = ["j": f.j]; if let l = f.l { s["l"] = l }; if let n = f.n { s["n"] = n }; o["s"] = s
            }
            if let md = mediaByMsg[r.int(0)] { o["md"] = md }
            if let d = Vault.line(o) { lines.append(d); added += 1 }
        }

        // @mention targets: record the jid facts for numbers mentioned in new messages
        if !mentionTokens.isEmpty {
            var byUser: [String: Int64] = [:]
            for (row, j) in jids where j.server == "lid" || j.server == "s.whatsapp.net" || j.server == "hosted.lid" { byUser[j.user] = row }
            for t in mentionTokens {
                guard let row = byUser[t], let f = facts(row) else { continue }
                var o: [String: Any] = ["k": "j", "j": f.j]; if let l = f.l { o["l"] = l }; if let n = f.n { o["n"] = n }
                if let d = Vault.line(o) { lines.append(d) }
            }
        }

        // Reactions: one record per reaction the vault does not already hold. A changed emoji is a
        // new record (the index keeps the newest by timestamp, so the old one stops counting) and a
        // repeat pull of the same backup adds none.
        var reactionAdded = 0
        if !reactionSource.isEmpty && !reactionTargets.isEmpty {
            var latest: [String: MessageReactions.RawRow] = [:]
            for r in reactionSource {                       // a changed reaction leaves history rows
                let k = "\(r.messageID)|\(r.senderRowID)"
                if let old = latest[k], old.ts > r.ts { continue }
                latest[k] = r
            }
            let ordered = latest.values.sorted { $0.messageID != $1.messageID ? $0.messageID < $1.messageID : $0.senderRowID < $1.senderRowID }
            for r in ordered {
                guard let uid = reactionTargets[r.messageID] else { continue }   // pruned or outside this backup
                var o: [String: Any] = ["k": "r", "u": uid, "e": r.emoji, "ts": r.ts]
                var reactor = "me"
                if r.senderRowID != 0 {
                    if let f = facts(r.senderRowID) {
                        o["j"] = f.j; if let l = f.l { o["l"] = l }; if let n = f.n { o["n"] = n }
                        reactor = f.j
                    } else {
                        // A dangling `sender_jid_row_id`: the backup no longer holds that JID row
                        // (a deleted contact). Somebody still reacted, so the record is kept with no
                        // reactor — the index files it as Unknown, exactly as the direct importer does.
                        reactor = "unknown"
                    }
                } else { o["me"] = 1 }
                guard !knownReactions.contains("\(uid)|\(reactor)|\(r.emoji)") else { continue }
                if let d = Vault.line(o) { lines.append(d); reactionAdded += 1 }
            }
        }

        var gone = 0
        let stamp = ISO8601DateFormatter().string(from: Date())
        if fullSnapshot, minTs != Int64.max {
            // already-known messages inside this snapshot's time window that the snapshot no longer contains
            var alreadyGone = Set<String>()
            try readAll { r in if r["k"] as? String == "gone", let u = r["u"] as? String { alreadyGone.insert(u) } }
            for (u, ts) in known.timestamps where ts >= minTs && ts <= maxTs && !snapshotUIDs.contains(u) && !alreadyGone.contains(u) {
                if let d = Vault.line(["k": "gone", "u": u, "at": stamp]) { lines.append(d); gone += 1 }
            }
        }

        var res = IngestResult(added: added, skipped: skipped, gone: gone, segment: nil)
        res.pathsUpdated = pathsUpdated
        res.reactionsAdded = reactionAdded
        guard !dryRun else { return res }                     // dry run: report counts only
        guard added > 0 || gone > 0 || replyAdded > 0 || pathsUpdated > 0 || reactionAdded > 0 else { return res }
        // File this import under a named source before the segment is written, so the
        // segment header and profiles.json cannot disagree.
        var resolvedProfileID: String? = nil
        if !dryRun, let identity = try? BackupIdentityReader.read(msgstore: path, source: source) {
            let existing = ProfilesStore.load(in: self)
            let (match, verdict) = ProfileMatcher.compare(identity, to: existing)
            res.verdict = verdict
            res.matchedProfile = match
            if let match, verdict.isContinuation {
                var profiles = existing
                if let i = profiles.firstIndex(where: { $0.id == match.id }) {
                    profiles[i].absorb(identity)
                    try? ProfilesStore.save(profiles, in: self)
                }
                resolvedProfileID = match.id
            } else {
                let profile = VaultProfile(name: profileName ?? label, identity: identity)
                var profiles = existing; profiles.append(profile)
                try? ProfilesStore.save(profiles, in: self)
                resolvedProfileID = profile.id
            }
            res.profileID = resolvedProfileID
        }

        let header: [String: Any] = ["k": "seg", "fmt": 1, "created": stamp, "source": source, "label": label,
                                     "profile": resolvedProfileID ?? "default", "mediaUpdated": pathsUpdated,
                                     "reactionsAdded": reactionAdded,
                                     "snapshot": ["min": minTs == Int64.max ? 0 : minTs, "max": maxTs == Int64.min ? 0 : maxTs, "count": snapshotUIDs.count, "full": fullSnapshot]]
        var body = Data(); body.append(Vault.line(header)!); body.append(10)
        for l in lines { body.append(l); body.append(10) }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd'T'HHmmss"; df.timeZone = TimeZone(identifier: "UTC")
        let safe = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let plainName = "seg-\(df.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())-\(safe).ndjson.gz"   // unique even for imports in the same second
        let name = plainName + (protection == .encrypted ? ".enc" : "")
        let tmp = segmentsDir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let gz = Gzip.compress(body)
        try (protection == .encrypted ? seal(gz, logicalPath: "segments/" + plainName) : gz).write(to: tmp)
        do { try FileManager.default.moveItem(at: tmp, to: segmentsDir.appendingPathComponent(name)) } catch { try? FileManager.default.removeItem(at: tmp); throw error }   // atomic rename: readers never see a partial segment
        res.segment = name
        return res
    }

    /// Moves a segment under another profile, for when the owner says "that backup was mine
    /// after all, fold it in" after an import was filed separately.
    public func reassign(segment: String, to profileID: String) throws {
        let plain = try read(protected: segmentsDir.appendingPathComponent(segment),
                             logicalPath: "segments/" + segment.replacingOccurrences(of: ".enc", with: ""))
        guard let ungzipped = try? Gzip.decompress(plain) else { return }
        guard let newline = ungzipped.firstIndex(of: 10),
              var header = try JSONSerialization.jsonObject(with: ungzipped[..<newline]) as? [String: Any] else { return }
        header["profile"] = profileID
        var body = Data()
        body.append(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])); body.append(10)
        body.append(ungzipped[ungzipped.index(after: newline)...])
        let gz = Gzip.compress(body)
        let out = protection == .encrypted ? try seal(gz, logicalPath: "segments/" + segment.replacingOccurrences(of: ".enc", with: "")) : gz
        try out.write(to: segmentsDir.appendingPathComponent(segment), options: .atomic)
    }
}
