import XCTest
import AppKit
import WebKit
@testable import SagaCore

/// The Media panel can show a player per row. A web view eats the scroll wheel,
/// which made the list impossible to scroll with players on; these tests pin the
/// shield behaviour that fixes it.
@MainActor
final class PlayerScrollShieldTests: XCTestCase {
    private final class Recorder: NSView {
        var wheels = 0
        override func scrollWheel(with event: NSEvent) { wheels += 1 }
    }

    private func wheelEvent(delta: Int32 = -3) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    private func makeBox() -> (PlayerBoxView, Recorder) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let box = PlayerBoxView(web: web)
        let host = Recorder(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        host.addSubview(box)
        return (box, host)
    }

    func testWheelScrollsTheListInsteadOfThePlayer() {
        let (box, host) = makeBox()
        box.shield.scrollWheel(with: wheelEvent())
        XCTAssertGreaterThan(host.wheels, 0, "the wheel must reach the enclosing list")
    }

    func testFirstClickActivatesThePlayerAndRemovesTheShield() {
        let (box, host) = makeBox()
        XCTAssertFalse(box.shield.isHidden)
        box.shield.mouseDown(with: wheelEvent())
        XCTAssertTrue(box.shield.isHidden, "after one click the player owns the pointer")
        XCTAssertEqual(host.wheels, 0, "a click must not scroll the list")
    }

    func testHiddenShieldLetsThePlayerTakeThePointer() {
        let (box, _) = makeBox()
        box.shield.isHidden = true
        let hit = box.shield.hitTest(NSPoint(x: 10, y: 10))
        XCTAssertNil(hit, "a hidden shield must not swallow clicks meant for the player")
    }

    func testShieldCoversTheWholePlayer() {
        let (box, _) = makeBox()
        box.layoutSubtreeIfNeeded()
        XCTAssertEqual(box.shield.frame, box.bounds)
        XCTAssertEqual(box.web.frame, box.bounds)
    }
}
