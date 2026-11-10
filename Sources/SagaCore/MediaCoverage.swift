import Foundation

/// Answers the only media question a person actually asks: "do you have my photos?"
///
/// The archive itself only records the path a file had on the phone. Whether that file exists
/// here depends on the folders the owner has pointed at, which is why this check walks the
/// folders once and compares names, instead of trusting the index.
public enum MediaCoverage {
    public struct Report: Sendable, Equatable {
        public var total: Int
        public var present: Int
        public var byKind: [String: Int]        // kind -> present
        public var totalsByKind: [String: Int]
        public var checkedFolders: Int

        public var missing: Int { max(0, total - present) }
        public var fraction: Double { total == 0 ? 0 : Double(present) / Double(total) }
    }

    /// A folder that looks like a WhatsApp media backup: the phone's own folder layout, on a
    /// disk, in iCloud or inside a synced Google Drive.
    public struct Candidate: Sendable, Identifiable, Hashable {
        public var url: URL
        public var kind: String       // "Phone export", "Google Drive", "iCloud Drive"
        public var id: String { url.path }
    }

    /// Finds folders that carry WhatsApp's media subfolders. Only looks at places a person
    /// would plausibly have put an export: their home folder, external volumes and the
    /// cloud-provider mounts, and never more than a couple of levels down.
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  cloudRoots: [URL]? = nil) -> [Candidate] {
        let fm = FileManager.default
        var roots: [(URL, String)] = [(home, "This Mac")]
        let clouds = cloudRoots ?? defaultCloudRoots()
        for c in clouds {
            let provider = c.deletingLastPathComponent().lastPathComponent
            let name = provider.contains("GoogleDrive") ? "Google Drive"
                : provider.contains("iCloud") ? "iCloud Drive"
                : provider.contains("Dropbox") ? "Dropbox" : provider
            roots.append((c, name))
        }
        var out: [Candidate] = []
        var seen = Set<String>()
        for (root, label) in roots {
            for folder in searchBases(root: root) {
                if let hit = looksLikeWhatsAppMedia(folder), seen.insert(hit.path).inserted {
                    out.append(Candidate(url: hit, kind: label))
                }
            }
        }
        return out
    }

    private static func defaultCloudRoots() -> [URL] {
        // ~/Library/CloudStorage/<Provider>/My Drive — the shape macOS uses for Drive,
        // iCloud Drive and Dropbox when they are mounted by the system.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        guard let providers = try? FileManager.default.contentsOfDirectory(at: base,
                                                                          includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for provider in providers {
            guard let children = try? FileManager.default.contentsOfDirectory(at: provider, includingPropertiesForKeys: nil) else { continue }
            out.append(contentsOf: children)
        }
        return out
    }

    private static func searchBases(root: URL) -> [URL] {
        var bases: [URL] = [root]
        for name in ["Downloads", "Documents", "Desktop", "My Drive", "WhatsApp", "BACKUP", "Backups"] {
            bases.append(root.appendingPathComponent(name))
        }
        return bases
    }

    /// A folder is a media export if it holds at least two of WhatsApp's own folder names.
    static func looksLikeWhatsAppMedia(_ folder: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let known: Set<String> = ["WhatsApp Images", "WhatsApp Video", "WhatsApp Audio",
                                  "WhatsApp Documents", "WhatsApp Voice Notes", "WhatsApp Animated Gifs",
                                  "WhatsApp Stickers", "Media"]
        // WhatsApp's own layout nests the media folders under Media/; a hand-made export
        // often puts them at the top level. Accept either, but require two of the names so a
        // stray folder cannot masquerade as an archive.
        if items.contains("Media") {
            let media = folder.appendingPathComponent("Media")
            let inner = (try? fm.contentsOfDirectory(atPath: media.path)) ?? []
            if inner.filter({ known.contains($0) }).count >= 1 { return media }
        }
        guard items.filter({ known.contains($0) }).count >= 2 else { return nil }
        return folder
    }

    /// Walks the chosen folders once, then counts how many indexed rows have a file there.
    public static func check(store: VaultStore, sources: [URL], driveRoots: [URL] = []) throws -> Report {
        var names = Set<String>()
        var folders = 0
        for root in sources + driveRoots {
            guard let walk = FileManager.default.enumerator(at: root,
                                                            includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            folders += 1
            for case let file as URL in walk {
                if Task.isCancelled { break }
                names.insert(file.lastPathComponent)
            }
        }
        var totals: [String: Int] = [:]
        var present: [String: Int] = [:]
        var total = 0, found = 0
        try store.db.query("SELECT kind, coalesce(file_path,'') FROM media") { r in
            let kind = r.text(0) ?? "other"
            let name = (r.text(1) ?? "").split(separator: "/").last.map(String.init) ?? ""
            totals[kind, default: 0] += 1
            total += 1
            if !name.isEmpty, names.contains(name) {
                present[kind, default: 0] += 1
                found += 1
            }
        }
        return Report(total: total, present: found, byKind: present, totalsByKind: totals, checkedFolders: folders)
    }
}

extension MediaCoverage {
    /// Coverage split by location, plus what is still missing after all of them. A file found
    /// in the phone export is not also claimed by the cloud archive, so the numbers add up to
    /// the combined total instead of double-counting.
    public struct Detailed: Sendable {
        public var combined: Report
        public var byLocation: [(location: MediaLocation, present: Int)]
        public var missingByChat: [(chat: String, count: Int)]
    }

    public static func checkDetailed(store: VaultStore, locations: [MediaLocation]) throws -> Detailed {
        var nameSets: [(MediaLocation, Set<String>)] = []
        for location in locations {
            guard let walk = FileManager.default.enumerator(at: location.url,
                                                            includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            var names = Set<String>()
            for case let file as URL in walk { names.insert(file.lastPathComponent) }
            nameSets.append((location, names))
        }
        var totals: [String: Int] = [:]
        var present: [String: Int] = [:]
        var perLocation = [Int](repeating: 0, count: nameSets.count)
        var missingChats: [String: Int] = [:]
        var total = 0, found = 0
        try store.db.query("""
            SELECT m.kind, coalesce(m.file_path,''), coalesce(nullif(c.name,''), nullif(c.person,''), 'Unknown')
            FROM media m LEFT JOIN chats c ON c.chat_id = m.chat_id
            """) { r in
            let kind = r.text(0) ?? "other"
            let name = (r.text(1) ?? "").split(separator: "/").last.map(String.init) ?? ""
            let chat = r.text(2) ?? "Unknown"
            totals[kind, default: 0] += 1
            total += 1
            if name.isEmpty { missingChats[chat, default: 0] += 1; return }
            for (i, entry) in nameSets.enumerated() where entry.1.contains(name) {
                present[kind, default: 0] += 1
                perLocation[i] += 1
                found += 1
                return
            }
            missingChats[chat, default: 0] += 1
        }
        let combined = Report(total: total, present: found, byKind: present,
                              totalsByKind: totals, checkedFolders: nameSets.count)
        let byLocation = zip(nameSets.map(\.0), perLocation).map { (location: $0, present: $1) }
        let missing = missingChats.sorted { $0.value > $1.value }.map { (chat: $0.key, count: $0.value) }
        return Detailed(combined: combined, byLocation: byLocation, missingByChat: missing)
    }
}
