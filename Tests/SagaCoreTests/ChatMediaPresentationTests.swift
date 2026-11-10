import XCTest
@testable import SagaCore

final class ChatMediaPresentationTests: XCTestCase {
    private func m(_ kind: String, _ path: String? = "Media/x") -> ChatMedia { ChatMedia(uid: "u", kind: kind, filePath: path) }
    func testKindsMapToPresentation() {
        XCTAssertEqual(ChatMediaPresentation(m("image")), .thumbnail)
        XCTAssertEqual(ChatMediaPresentation(m("video")), .thumbnail)
        XCTAssertEqual(ChatMediaPresentation(m("audio")), .audio)
        XCTAssertEqual(ChatMediaPresentation(m("doc")), .file)
        XCTAssertEqual(ChatMediaPresentation(m("sticker")), .thumbnail)
    }
    func testNoPathOrMediaIsLabelOnly() {
        XCTAssertEqual(ChatMediaPresentation(m("image", nil)), .labelOnly)
        XCTAssertEqual(ChatMediaPresentation(m("image", "")), .labelOnly)
        XCTAssertEqual(ChatMediaPresentation(nil), .labelOnly)
    }
    func testOnlyThumbnailsLoadOnAppear() {
        XCTAssertTrue(ChatMediaPresentation.thumbnail.loadsOnAppear)
        for p in [ChatMediaPresentation.audio, .file, .labelOnly] { XCTAssertFalse(p.loadsOnAppear) }
    }
}
