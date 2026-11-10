import XCTest
@testable import SagaCore

final class Crypt15Tests: XCTestCase {
    func testRootKeyParsing() throws {
        XCTAssertEqual(try Crypt15.rootKey(hex: String(repeating: "ab", count: 32)).count, 32)
        XCTAssertThrowsError(try Crypt15.rootKey(hex: "zz"))
    }
    func testProtobufField() {
        // field 3 (length-delimited) containing field 1 = 0x01 0x02
        let inner = Data([0x0a, 0x02, 0x01, 0x02])
        let msg = Data([0x1a, UInt8(inner.count)]) + inner
        XCTAssertEqual(Crypt15.field(3, in: msg), inner)
        XCTAssertEqual(Crypt15.field(1, in: inner), Data([1, 2]))
    }
}
