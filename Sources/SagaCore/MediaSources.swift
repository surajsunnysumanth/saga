import Foundation

/// One place media can come from: a phone export on this Mac, a folder on a NAS, or a cloud
/// client's mount that downloads files on demand.
public struct MediaLocation: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case local, cloud, network }
    public var id: String { path }
    public var path: String
    public var label: String
    public var kind: Kind

    public init(path: String, label: String? = nil, kind: Kind? = nil) {
        self.path = path
        self.label = label ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind ?? Self.inferKind(path)
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// A file inside a cloud client's mount looks local until it is opened; that read can
    /// take seconds and megabytes, so the UI is allowed to warn about it.
    public static func inferKind(_ path: String) -> Kind {
        if path.contains("/Library/CloudStorage/") || path.contains("/Dropbox/") { return .cloud }
        if path.hasPrefix("/Volumes/") || path.hasPrefix("/Network/") { return .network }
        return .local
    }

    public var kindLabel: String {
        switch kind {
        case .local: return "On this Mac"
        case .cloud: return "Cloud"
        case .network: return "Network"
        }
    }
}

/// Ordered list of media locations. Order is priority: the first folder that has a file wins,
/// which is why the phone export belongs above a cloud archive.
public enum MediaSources {
    static let name = "media-sources.json"

    private struct Stored: Codable {
        var version: Int
        var locations: [MediaLocation]
    }

    public static func loadLocations(in vault: Vault) throws -> [MediaLocation] {
        guard let d = try vault.readConfig(name), !d.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode(Stored.self, from: d), stored.version >= 2 {
            return stored.locations
        }
        // Version 1 was a plain array of paths; keep reading it forever.
        let paths = (try? decoder.decode([String].self, from: d)) ?? []
        return paths.map { MediaLocation(path: $0) }
    }

    public static func save(_ locations: [MediaLocation], in vault: Vault) throws {
        var seen = Set<String>()
        let clean = locations.filter(\.url.isFileURL)
            .map { MediaLocation(path: $0.url.standardizedFileURL.path, label: $0.label, kind: $0.kind) }
            .filter { seen.insert($0.path).inserted }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try vault.writeConfig(try encoder.encode(Stored(version: 2, locations: clean)), name: name)
    }

    /// Paths only, for the resolver and for code written before locations existed.
    public static func load(in vault: Vault) throws -> [URL] {
        try loadLocations(in: vault).map(\.url)
    }

    public static func save(_ sources: [URL], in vault: Vault) throws {
        try save(sources.map { MediaLocation(path: $0.standardizedFileURL.path) }, in: vault)
    }

    /// Path-based entry points; an encrypted vault opened by path has no key, so these throw `.locked` for it.
    public static func load(in vaultURL: URL) throws -> [URL] { try load(in: try Vault(url: vaultURL, create: false)) }
    public static func save(_ sources: [URL], in vaultURL: URL) throws { try save(sources, in: try Vault(url: vaultURL, create: false)) }
    public static func loadLocations(in vaultURL: URL) throws -> [MediaLocation] { try loadLocations(in: try Vault(url: vaultURL, create: false)) }
}
