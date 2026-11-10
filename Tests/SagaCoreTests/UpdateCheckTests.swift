import XCTest
@testable import SagaCore

/// The update check has to be boring: a version comparison that reads numbers, a request at
/// most once a day, and nothing at all on screen when the network, the API or the JSON fails.
/// Every test here runs offline against a stub fetcher.
final class UpdateCheckTests: XCTestCase {

    // MARK: - Fixtures

    /// Stands in for `UserDefaultsUpdateStore` and counts nothing but what the checker stores.
    final class MemoryStore: UpdatePreferenceStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _enabled: Bool
        private var _lastCheckAt: Date?
        private var _lastSeenVersion: String?
        private var _skippedVersion: String?

        init(enabled: Bool = true, lastCheckAt: Date? = nil,
             lastSeenVersion: String? = nil, skippedVersion: String? = nil) {
            _enabled = enabled
            _lastCheckAt = lastCheckAt
            _lastSeenVersion = lastSeenVersion
            _skippedVersion = skippedVersion
        }

        var checksEnabled: Bool {
            get { locked { _enabled } }
            set { locked { _enabled = newValue } }
        }
        var lastCheckAt: Date? {
            get { locked { _lastCheckAt } }
            set { locked { _lastCheckAt = newValue } }
        }
        var lastSeenVersion: String? {
            get { locked { _lastSeenVersion } }
            set { locked { _lastSeenVersion = newValue } }
        }
        var skippedVersion: String? {
            get { locked { _skippedVersion } }
            set { locked { _skippedVersion = newValue } }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }
    }

    /// Records how many requests the checker made, so "throttled" and "disabled" are proven,
    /// not assumed.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private static func payload(tag: String, page: String = "https://github.com/surajsunnysumanth/saga/releases/tag/v1.0.3",
                                dmg: String? = nil) -> Data {
        var assetList = ""
        if let dmg {
            assetList = #""assets": [{"name": "Saga.dmg", "browser_download_url": "\#(dmg)"}],"#
        }
        return Data("""
        {"tag_name": "\(tag)", "html_url": "\(page)", \(assetList) "name": "Saga 1.0.3", "draft": false}
        """.utf8)
    }

    private func checker(current: String = "1.0.2",
                         store: MemoryStore = MemoryStore(),
                         at now: Date = noon,
                         counter: Counter? = nil,
                         body: Data? = nil,
                         status: Int = 200) -> UpdateChecker {
        let counter = counter ?? Counter()
        let data = body ?? Self.payload(tag: "v1.0.3")
        return UpdateChecker(currentVersion: SemanticVersion(current)!,
                             store: store,
                             now: { now },
                             fetcher: { url in
                                 XCTAssertEqual(url, UpdateSource.releasesAPI)
                                 counter.bump()
                                 return UpdateResponse(status: status, body: data)
                             })
    }

    // MARK: - Version comparison

    func testVersionTenBeatsNine() throws {
        let nine = try XCTUnwrap(SemanticVersion("1.0.9"))
        let ten = try XCTUnwrap(SemanticVersion("1.0.10"))
        XCTAssertGreaterThan(ten, nine)
        XCTAssertLessThan(nine, ten)
        XCTAssertNotEqual(nine, ten)
    }

    func testVersionEqualIgnoringPrefixAndMissingPatch() throws {
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("1.0.3")), try XCTUnwrap(SemanticVersion("v1.0.3")))
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("1.2")), try XCTUnwrap(SemanticVersion("1.2.0")))
        XCTAssertFalse(try XCTUnwrap(SemanticVersion("v1.0.3")) < (try XCTUnwrap(SemanticVersion("1.0.3"))))
    }

    func testVersionOlderAndOrdering() throws {
        let old = try XCTUnwrap(SemanticVersion("v0.9.9"))
        let current = try XCTUnwrap(SemanticVersion("1.0.2"))
        XCTAssertLessThan(old, current)
        XCTAssertGreaterThan(try XCTUnwrap(SemanticVersion("1.1")), current)
        XCTAssertGreaterThan(try XCTUnwrap(SemanticVersion("2.0.0")), try XCTUnwrap(SemanticVersion("1.99.99")))
    }

    func testVersionNormalisationAndRejectsJunk() throws {
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("V1.0.3")).description, "1.0.3")
        XCTAssertEqual(try XCTUnwrap(SemanticVersion(" v1.0.3\n")).description, "1.0.3")
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("1.0.3-beta.1")).description, "1.0.3")
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion("1.x.3"))
    }

    // MARK: - The happy path and its neighbours

    func testNewerReleaseIsAvailableWithBothURLs() async throws {
        let store = MemoryStore()
        let outcome = await checker(store: store,
                                    body: Self.payload(tag: "v1.0.3",
                                                       dmg: "https://github.com/surajsunnysumanth/saga/releases/download/v1.0.3/Saga.dmg"))
            .check(.automatic)
        guard case .available(let release) = outcome else { return XCTFail("expected an available update, got \(outcome)") }
        XCTAssertEqual(release.versionText, "1.0.3")
        XCTAssertEqual(release.tag, "v1.0.3")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/surajsunnysumanth/saga/releases/tag/v1.0.3")
        XCTAssertEqual(release.downloadURL.absoluteString,
                       "https://github.com/surajsunnysumanth/saga/releases/download/v1.0.3/Saga.dmg")
        XCTAssertTrue(outcome.shouldAnnounce)
        XCTAssertEqual(store.lastSeenVersion, "1.0.3")
        XCTAssertEqual(store.lastCheckAt, Self.noon)
    }

    func testMissingAssetsFallsBackToTheCanonicalDMG() async throws {
        let outcome = await checker(body: Self.payload(tag: "v1.0.3", dmg: nil)).check(.manual)
        XCTAssertEqual(outcome.release?.downloadURL, UpdateSource.download)
    }

    func testSameVersionIsUpToDate() async {
        let outcome = await checker(current: "1.0.3").check(.automatic)
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertFalse(outcome.shouldAnnounce)
    }

    func testOlderReleaseIsUpToDate() async {
        let outcome = await checker(current: "1.0.4", body: Self.payload(tag: "v1.0.3")).check(.automatic)
        XCTAssertEqual(outcome, .upToDate)
    }

    func testTenIsNewerThanNineThroughTheChecker() async {
        let outcome = await checker(current: "1.0.9", body: Self.payload(tag: "v1.0.10")).check(.automatic)
        XCTAssertEqual(outcome.release?.versionText, "1.0.10")
    }

    // MARK: - Skip this version

    func testSkippedVersionIsNotAnnouncedButStillReported() async {
        let store = MemoryStore(skippedVersion: "1.0.3")
        let outcome = await checker(store: store).check(.automatic)
        guard case .skipped(let release) = outcome else { return XCTFail("expected skipped, got \(outcome)") }
        XCTAssertEqual(release.versionText, "1.0.3")
        XCTAssertFalse(outcome.shouldAnnounce)
    }

    func testSkipIsForOneVersionOnly() async {
        // Dismissing 1.0.3 must not hide 1.0.4.
        let store = MemoryStore(skippedVersion: "1.0.3")
        let outcome = await checker(store: store, body: Self.payload(tag: "v1.0.4")).check(.automatic)
        XCTAssertEqual(outcome.release?.versionText, "1.0.4")
        XCTAssertTrue(outcome.shouldAnnounce)
    }

    // MARK: - The 24-hour throttle

    func testAutomaticCheckWithinADayDoesNotTouchTheNetwork() async {
        let counter = Counter()
        let store = MemoryStore(lastCheckAt: Self.noon.addingTimeInterval(-3600))
        let outcome = await checker(store: store, counter: counter).check(.automatic)
        XCTAssertEqual(outcome, .throttled)
        XCTAssertEqual(counter.calls, 0, "a second check inside 24 h must not make a request")
    }

    func testAutomaticCheckAfterADayRuns() async {
        let counter = Counter()
        let store = MemoryStore(lastCheckAt: Self.noon.addingTimeInterval(-UpdateSource.checkInterval - 1))
        let outcome = await checker(store: store, counter: counter).check(.automatic)
        XCTAssertEqual(outcome.release?.versionText, "1.0.3")
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(store.lastCheckAt, Self.noon)
    }

    func testManualCheckIgnoresTheThrottle() async {
        let counter = Counter()
        let store = MemoryStore(lastCheckAt: Self.noon.addingTimeInterval(-60))
        let outcome = await checker(store: store, counter: counter).check(.manual)
        XCTAssertEqual(outcome.release?.versionText, "1.0.3")
        XCTAssertEqual(counter.calls, 1)
    }

    func testFailureStillStartsTheDay() async {
        // An offline launch must not retry on the next launch an hour later.
        let store = MemoryStore()
        let counter = Counter()
        let failing = UpdateChecker(currentVersion: SemanticVersion("1.0.2")!, store: store, now: { Self.noon },
                                    fetcher: { _ in counter.bump(); throw URLError(.notConnectedToInternet) })
        let first = await failing.check(.automatic)
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(store.lastCheckAt, Self.noon)
        let second = await failing.check(.automatic)
        XCTAssertEqual(second, .throttled)
        XCTAssertEqual(counter.calls, 1)
    }

    func testFutureTimestampDoesNotLockTheFeatureOut() async {
        // A clock that jumped backwards leaves a timestamp ahead of "now"; that is stale, not fresh.
        let store = MemoryStore(lastCheckAt: Self.noon.addingTimeInterval(86_400 * 30))
        let outcome = await checker(store: store).check(.automatic)
        XCTAssertEqual(outcome.release?.versionText, "1.0.3")
    }

    // MARK: - Disabled

    func testDisabledMakesNoRequest() async {
        let counter = Counter()
        let store = MemoryStore(enabled: false)
        let outcome = await checker(store: store, counter: counter).check(.manual)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(counter.calls, 0)
        XCTAssertNil(store.lastCheckAt, "a disabled check leaves no trace")
    }

    // MARK: - Error paths

    func testNon200IsSilentFailure() async {
        let outcome = await checker(body: Data(#"{"message": "Not Found"}"#.utf8), status: 404).check(.automatic)
        XCTAssertEqual(outcome, .failed)
    }

    func testRateLimitedIsSilentFailure() async {
        let outcome = await checker(body: Data(#"{"message": "API rate limit exceeded"}"#.utf8), status: 403).check(.automatic)
        XCTAssertEqual(outcome, .failed)
    }

    func testOfflineIsSilentFailure() async {
        let store = MemoryStore()
        let offline = UpdateChecker(currentVersion: SemanticVersion("1.0.2")!, store: store, now: { Self.noon },
                                    fetcher: { _ in throw URLError(.cannotFindHost) })
        let outcome = await offline.check(.automatic)
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(outcome.release)
    }

    func testMalformedJSONIsSilentFailure() async {
        let outcome = await checker(body: Data("not json at all".utf8)).check(.automatic)
        XCTAssertEqual(outcome, .failed)
    }

    func testNoVersionTagIsSilentFailure() async {
        // What GitHub answers when the repo has no releases yet.
        let outcome = await checker(body: Data(#"{"message": "Not Found", "documentation_url": "https://docs.github.com"}"#.utf8))
            .check(.automatic)
        XCTAssertEqual(outcome, .failed)
    }

    func testEmptyBodyIsSilentFailure() async {
        let outcome = await checker(body: Data()).check(.automatic)
        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - Parsing directly

    func testParseRejectsUntaggedJSON() {
        XCTAssertThrowsError(try UpdateChecker.parse(Data(#"{"tag_name": ""}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .noVersionTag)
        }
        XCTAssertThrowsError(try UpdateChecker.parse(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .malformedJSON)
        }
    }

    func testParseAcceptsAPrefixedTag() throws {
        let release = try UpdateChecker.parse(Self.payload(tag: "v1.0.10"))
        XCTAssertEqual(release.versionText, "1.0.10")
        XCTAssertEqual(release.tag, "v1.0.10")
    }

    func testDefaultsKeyNamesAreStable() {
        // These four keys are the persisted state and are named in PRIVACY.md.
        XCTAssertEqual(UpdatePreferenceKey.enabled, "updateChecksEnabled")
        XCTAssertEqual(UpdatePreferenceKey.lastCheckAt, "updateLastCheckAt")
        XCTAssertEqual(UpdatePreferenceKey.lastSeenVersion, "updateLastSeenVersion")
        XCTAssertEqual(UpdatePreferenceKey.skippedVersion, "updateSkippedVersion")
    }

    func testUserDefaultsStoreDefaultsToEnabled() {
        let suite = "saga-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsUpdateStore(defaults: defaults)
        XCTAssertTrue(store.checksEnabled, "absent key means on")
        store.checksEnabled = false
        XCTAssertFalse(UserDefaultsUpdateStore(defaults: defaults).checksEnabled)
        store.lastCheckAt = Self.noon
        store.skippedVersion = "1.0.3"
        store.lastSeenVersion = "1.0.3"
        let reread = UserDefaultsUpdateStore(defaults: defaults)
        XCTAssertEqual(reread.lastCheckAt, Self.noon)
        XCTAssertEqual(reread.skippedVersion, "1.0.3")
        XCTAssertEqual(reread.lastSeenVersion, "1.0.3")
    }
}
