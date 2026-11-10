import XCTest
@testable import SagaCore

/// Durations under a minute are reported as numbers, because "under a minute" on every
/// quick chat is indistinguishable from a bug.
final class WrappedDurationTests: XCTestCase {
    func testSubMinuteIsExact() {
        XCTAssertEqual(WrappedCopy.duration(37), "37 seconds")
        XCTAssertEqual(WrappedCopy.duration(4), "4 seconds")
        XCTAssertEqual(WrappedCopy.duration(0.4), "1 second")
        XCTAssertEqual(WrappedCopy.duration(59.6), "60 seconds")
    }

    func testMinutesAndHours() {
        XCTAssertEqual(WrappedCopy.duration(75), "about a minute")
        XCTAssertEqual(WrappedCopy.duration(600), "10 min")
        XCTAssertEqual(WrappedCopy.duration(5400), "1.5 hr")
        XCTAssertEqual(WrappedCopy.duration(86_400 * 3), "3 days")
        XCTAssertEqual(WrappedCopy.duration(nil), "a while")
    }
}
