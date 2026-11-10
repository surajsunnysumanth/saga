import Foundation

/// Phone-number normalisation shared by contacts import and JID resolution: last 10 digits.
public func normalizePhone(_ s: String?) -> String {
    let d = (s ?? "").filter { $0.isASCII && $0.isNumber }
    return d.count >= 10 ? String(d.suffix(10)) : d
}

public enum ContactSources {
    /// vCard (.vcf) -> [normalised phone: display name]; first name wins per number.
    public static func loadVCF(path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        var name: String? = nil, tels: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix("FN") {
                name = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("TEL") {
                tels.append(normalizePhone(line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init)))
            } else if line.hasPrefix("END:VCARD") {
                for t in tels where !t.isEmpty { if let n = name, !n.isEmpty, names[t] == nil { names[t] = n } }
                name = nil; tels = []
            }
        }
        return names
    }

    /// CSV with header containing `chat_jid` and `name` -> [jid: name] (rows without a name are ignored).
    public static func loadOverrides(path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        return parseOverrides(text)
    }

    /// The same rule as `loadOverrides(path:)`, for text that came through the vault (so an encrypted
    /// vault's overrides are read too). Rows without a name are not names.
    public static func parseOverrides(_ text: String) -> [String: String] {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return [:] }
        let header = parseCSV(lines.removeFirst())
        guard let ji = header.firstIndex(of: "chat_jid"), let ni = header.firstIndex(of: "name") else { return [:] }
        var out: [String: String] = [:]
        for l in lines {
            let f = parseCSV(l)
            if ji < f.count, ni < f.count, !f[ni].isEmpty { out[f[ji]] = f[ni] }
        }
        return out
    }

    static func parseCSV(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    /// One CSV field. Quotes and commas inside a name (`Rao, Asha`) must survive a round trip, or the
    /// next read splits one person into two columns and the name silently becomes garbage.
    static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum NameOverrideError: Error, LocalizedError {
    /// The file exists but its header has no `chat_jid`/`name` column, so writing into it would corrupt it.
    case invalidHeader
    /// The name was written but a fresh read through the resolver's own loader did not see it.
    case notPersisted

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "The overrides file in your archive has no chat_jid/name columns."
        case .notPersisted: "The name could not be read back from your archive."
        }
    }
}

/// `config/overrides.csv` — the name the owner typed for one chat, and the strongest name evidence the
/// archive has (it outranks the address book, imported contacts and the WhatsApp profile name). This is
/// the only writer for that file: the indexer and `ContactSources.loadOverrides` read what it writes.
///
/// The file is a spreadsheet the owner may have edited by hand, so a write keeps the header and every
/// other column and row intact instead of flattening it to two columns.
public enum NameOverrides {
    public static let fileName = "overrides.csv"
    public static let defaultHeader = ["chat_jid", "name", "phone"]

    struct Table {
        var header: [String]
        var rows: [[String]]

        var jidColumn: Int { header.firstIndex(of: "chat_jid") ?? 0 }
        var nameColumn: Int { header.firstIndex(of: "name") ?? 1 }
    }

    /// `config/overrides.csv` beside the vault. It stays a plain spreadsheet even in an encrypted vault,
    /// by the vault's own contract (the encryption sheet says so), which is why this does not go through
    /// `readConfig` — that only accepts `.json`.
    public static func fileURL(in vault: Vault) -> URL {
        vault.url.appendingPathComponent("config").appendingPathComponent(fileName)
    }

    /// The names in the vault, read the way the resolver reads them.
    public static func load(in vault: Vault) -> [String: String] {
        ContactSources.loadOverrides(path: fileURL(in: vault).path)
    }

    /// Everything in the file, header and unknown columns included.
    static func table(in vault: Vault) throws -> Table {
        guard let text = try? String(contentsOf: fileURL(in: vault), encoding: .utf8) else {
            return Table(header: defaultHeader, rows: [])
        }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return Table(header: defaultHeader, rows: []) }
        let header = ContactSources.parseCSV(lines.removeFirst())
        guard header.contains("chat_jid"), header.contains("name") else { throw NameOverrideError.invalidHeader }
        return Table(header: header, rows: lines.map(ContactSources.parseCSV))
    }

    static func serialise(_ t: Table) -> String {
        var out = t.header.map(ContactSources.csvField).joined(separator: ",")
        for row in t.rows {
            var fields = row
            while fields.count < t.header.count { fields.append("") }
            out += "\n" + fields.map(ContactSources.csvField).joined(separator: ",")
        }
        return out + "\n"
    }

    /// Saves `name` for the chat with this JID, replacing any name it already had. Empty names are
    /// ignored — clearing a name is `clear(for:in:)`, so a stray return key cannot erase one.
    public static func set(_ name: String, for jid: String, in vault: Vault) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !jid.isEmpty else { return }
        try write(trimmed, for: jid, in: vault)
        // Read back through the loader the indexer uses, not through the value we just held: a write
        // that lands in the wrong column must fail here, not after a rebuild silently changes nothing.
        guard load(in: vault)[jid] == trimmed else { throw NameOverrideError.notPersisted }
    }

    /// Removes the manual name for this JID; every other row is untouched.
    public static func clear(for jid: String, in vault: Vault) throws {
        guard !jid.isEmpty else { return }
        var t = try table(in: vault)
        let ji = t.jidColumn
        let before = t.rows.count
        t.rows.removeAll { $0.count > ji && $0[ji] == jid }
        guard t.rows.count != before else { return }
        try save(t, to: vault)
    }

    private static func write(_ name: String, for jid: String, in vault: Vault) throws {
        var t = try table(in: vault)
        let ji = t.jidColumn, ni = t.nameColumn
        var fields: [String]
        if let i = t.rows.firstIndex(where: { $0.count > ji && $0[ji] == jid }) {
            fields = t.rows[i]
            while fields.count < t.header.count { fields.append("") }
            fields[ni] = name
            t.rows[i] = fields
        } else {
            fields = Array(repeating: "", count: max(t.header.count, ni + 1))
            fields[ji] = jid
            fields[ni] = name
            t.rows.append(fields)
        }
        try save(t, to: vault)
    }

    /// One atomic write. Creates `config/` first: a vault that never had an overrides file has no reason
    /// to hold the folder yet.
    static func save(_ t: Table, to vault: Vault) throws {
        let url = fileURL(in: vault)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(serialise(t).utf8).write(to: url, options: .atomic) }
        catch { throw VaultEncryptionError.ioFailure }
    }
}
