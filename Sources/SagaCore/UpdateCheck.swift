import Foundation

/// The app's release feed. One host (`api.github.com`), one request, once a day.
///
/// The DMG and the release page are links the person opens — Saga never fetches them, so a
/// check is a single `GET` that sends nothing but the request itself: no query string, no
/// cookies, no identifier, no body. See `PRIVACY.md` and `site/privacy.html`.
public enum UpdateSource {
    public static let releasesAPI = URL(string: "https://api.github.com/repos/surajsunnysumanth/saga/releases/latest")!
    /// Where "Download" points and where the release notes live, when the API gives no better link.
    public static let releasePage = URL(string: "https://github.com/surajsunnysumanth/saga/releases/latest")!
    public static let download = URL(string: "https://github.com/surajsunnysumanth/saga/releases/latest/download/Saga.dmg")!
    /// The asset name the marketing site links to; used to pick the DMG out of `assets`.
    public static let assetName = "Saga.dmg"
    /// At most one automatic check a day. Manual checks are always allowed.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
}

// MARK: - Versions

/// A release number compared the way a person reads it: numeric components, so
/// `1.0.10 > 1.0.9` (string comparison gets that backwards). A leading `v` and a
/// pre-release suffix (`1.0.3-beta.1`) are accepted and ignored, because the tag on a
/// release is not the version the app compares against.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var parts: [Int] = []
        for chunk in text.split(separator: ".", omittingEmptySubsequences: false) {
            // "-beta.1" / "+build" end the numeric part of a component.
            let digits = chunk.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            parts.append(value)
            if digits.count < chunk.count { break }        // suffix: stop parsing here
        }
        guard !parts.isEmpty else { return nil }
        components = parts
    }

    /// `1.2` and `1.2.0` are the same release, so short versions are padded with zeros.
    private var padded: [Int] {
        components.count >= 3 ? components : components + Array(repeating: 0, count: 3 - components.count)
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let (l, r) = (a.padded, b.padded)
        for i in 0..<max(l.count, r.count) {
            let x = i < l.count ? l[i] : 0, y = i < r.count ? r[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// `1.2` equals `1.2.0` — padding, not spelling, decides — so `==` agrees with `<`.
    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { a.padded == b.padded }

    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

// MARK: - What the check returns

public struct UpdateRelease: Sendable, Equatable {
    public let version: SemanticVersion
    /// The release tag exactly as GitHub spells it (`v1.0.3`), for the reply and the skip rule.
    public let tag: String
    public let pageURL: URL
    public let downloadURL: URL
    public var versionText: String { version.description }

    public init(version: SemanticVersion, tag: String, pageURL: URL, downloadURL: URL) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.downloadURL = downloadURL
    }
}

/// Every way a check can end. Only `.available` puts something on screen.
public enum UpdateOutcome: Sendable, Equatable {
    case upToDate
    case available(UpdateRelease)
    /// A newer release exists but the person dismissed this version; Settings still says so.
    case skipped(UpdateRelease)
    /// Checked within the last 24 hours; nothing was asked of the network.
    case throttled
    /// Update checks are switched off.
    case disabled
    /// Offline, no releases published, a non-200, or unreadable JSON. Silent by design.
    case failed

    /// The release on screen, if any.
    public var release: UpdateRelease? {
        switch self {
        case .available(let r), .skipped(let r): return r
        default: return nil
        }
    }

    /// True only for a release the person has not dismissed.
    public var shouldAnnounce: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum UpdateTrigger: Sendable { case automatic, manual }

// MARK: - Injectable seams

/// One HTTP GET, reduced to what the checker needs. Tests hand back a canned body; nobody
/// else implements this in the app.
public struct UpdateResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public typealias UpdateFetcher = @Sendable (URL) async throws -> UpdateResponse

/// The small amount of state a check needs to remember. Backed by `UserDefaults` in the
/// app; an in-memory store is enough in a test.
public protocol UpdatePreferenceStore: AnyObject, Sendable {
    /// Off means no request at all. Defaults to on.
    var checksEnabled: Bool { get set }
    /// When the last attempt happened (success or failure), so a launch is at most one a day.
    var lastCheckAt: Date? { get set }
    /// The newest release version seen at the last successful check.
    var lastSeenVersion: String? { get set }
    /// "Skip this version": the release the person dismissed from the banner.
    var skippedVersion: String? { get set }
}

public enum UpdatePreferenceKey {
    public static let enabled = "updateChecksEnabled"
    public static let lastCheckAt = "updateLastCheckAt"
    public static let lastSeenVersion = "updateLastSeenVersion"
    public static let skippedVersion = "updateSkippedVersion"
}

public final class UserDefaultsUpdateStore: UpdatePreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Absent means on: a fresh install checks, and an old install gains the feature.
    public var checksEnabled: Bool {
        get { (defaults.object(forKey: UpdatePreferenceKey.enabled) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: UpdatePreferenceKey.enabled) }
    }

    public var lastCheckAt: Date? {
        get { (defaults.object(forKey: UpdatePreferenceKey.lastCheckAt) as? Double).map { Date(timeIntervalSince1970: $0) } }
        set {
            if let newValue { defaults.set(newValue.timeIntervalSince1970, forKey: UpdatePreferenceKey.lastCheckAt) }
            else { defaults.removeObject(forKey: UpdatePreferenceKey.lastCheckAt) }
        }
    }

    public var lastSeenVersion: String? {
        get { defaults.string(forKey: UpdatePreferenceKey.lastSeenVersion) }
        set {
            if let newValue { defaults.set(newValue, forKey: UpdatePreferenceKey.lastSeenVersion) }
            else { defaults.removeObject(forKey: UpdatePreferenceKey.lastSeenVersion) }
        }
    }

    public var skippedVersion: String? {
        get { defaults.string(forKey: UpdatePreferenceKey.skippedVersion) }
        set {
            if let newValue { defaults.set(newValue, forKey: UpdatePreferenceKey.skippedVersion) }
            else { defaults.removeObject(forKey: UpdatePreferenceKey.skippedVersion) }
        }
    }
}

// MARK: - The check

public enum UpdateCheckError: Error, Equatable {
    case malformedJSON
    case noVersionTag
}

/// Asks GitHub for the latest release and decides one of three things: up to date, a newer
/// release, or nothing to say. It never throws: a check that cannot complete is `.failed`,
/// which the UI treats as "no news".
public struct UpdateChecker: Sendable {
    public let currentVersion: SemanticVersion
    public let store: any UpdatePreferenceStore
    public let fetcher: UpdateFetcher
    public let now: @Sendable () -> Date

    public init(currentVersion: SemanticVersion,
                store: any UpdatePreferenceStore,
                now: @escaping @Sendable () -> Date = { Date() },
                fetcher: @escaping UpdateFetcher = UpdateChecker.github) {
        self.currentVersion = currentVersion
        self.store = store
        self.now = now
        self.fetcher = fetcher
    }

    public func check(_ trigger: UpdateTrigger = .automatic) async -> UpdateOutcome {
        guard store.checksEnabled else { return .disabled }
        let started = now()
        if trigger == .automatic, let last = store.lastCheckAt {
            let since = started.timeIntervalSince(last)
            // A timestamp in the future means the clock moved; treat it as stale rather than
            // locking the feature out until the calendar catches up.
            if since >= 0, since < UpdateSource.checkInterval { return .throttled }
        }
        // Recorded before the request, so a machine that is offline at launch does not ask
        // again on the next launch an hour later.
        store.lastCheckAt = started

        do {
            let response = try await fetcher(UpdateSource.releasesAPI)
            guard response.status == 200 else { return .failed }
            let release = try Self.parse(response.body)
            store.lastSeenVersion = release.versionText
            guard release.version > currentVersion else { return .upToDate }
            if store.skippedVersion == release.versionText { return .skipped(release) }
            return .available(release)
        } catch {
            return .failed
        }
    }

    // MARK: Parsing

    private struct Payload: Decodable {
        let tag: String?
        let page: String?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let url: String
            enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
        }

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", page = "html_url", assets
        }
    }

    /// `tag_name` is the version; `assets` is used only to find the DMG the site already links
    /// to, so a release that names its asset differently still gets a working URL.
    public static func parse(_ data: Data) throws -> UpdateRelease {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UpdateCheckError.malformedJSON
        }
        guard let tag = payload.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty,
              let version = SemanticVersion(tag) else { throw UpdateCheckError.noVersionTag }
        let dmg = payload.assets?.first { $0.name == UpdateSource.assetName }?.url
        let page = payload.page.flatMap(URL.init(string:))
        return UpdateRelease(version: version,
                             tag: tag,
                             pageURL: page ?? UpdateSource.releasePage,
                             downloadURL: dmg.flatMap(URL.init(string:)) ?? UpdateSource.download)
    }

    // MARK: The one real request

    /// A plain `GET` with `URLSession`'s own defaults: no cookies, no credentials, no custom
    /// headers, no query string. The only thing GitHub learns is that someone asked.
    public static func github(_ url: URL) async throws -> UpdateResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        return UpdateResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
