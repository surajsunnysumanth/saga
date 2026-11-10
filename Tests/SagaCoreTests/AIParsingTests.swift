import XCTest
@testable import SagaCore

/// Feeds the parser the exact bad replies small models send (see AIParserFixtures) and asserts a usable
/// answer comes back. No network, no model, no real messages.
final class AIParsingTests: XCTestCase {

    // MARK: parser

    func testFencedJSONWrappedInChatterIsRead() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.fencedWithChatter))
        XCTAssertEqual(r.points.count, 2)
        XCTAssertEqual(r.points.first?.text, "Dinner is on Friday")
        XCTAssertEqual(r.points.first?.refs, [3])
        XCTAssertFalse(r.unstructured)
    }

    func testProseBeforeAndAfterTheObjectIsIgnored() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.proseThenObject))
        XCTAssertEqual(r.points.map(\.text), ["Flights booked by Friday"])
        XCTAssertEqual(r.points.first?.refs, [2])
    }

    func testTrailingCommasAreRepaired() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.trailingCommas))
        XCTAssertEqual(r.points.count, 1)
        XCTAssertEqual(r.points.first?.text, "Second week of December chosen")
        XCTAssertEqual(r.points.first?.refs, [4])
    }

    func testSingleQuotedJSONIsRepaired() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.singleQuotes))
        XCTAssertEqual(r.points.first?.text, "Ravi cannot come the first week")
        XCTAssertEqual(r.points.first?.refs, [3])
        XCTAssertTrue(r.repaired)
    }

    func testUnquotedKeysAndPythonLiteralsAreRepaired() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.unquotedKeysAndLiterals))
        XCTAssertEqual(r.points.first?.text, "Hotels checked this weekend")
        XCTAssertEqual(r.points.first?.refs, [5])
    }

    func testTruncatedObjectKeepsThePointsThatArrived() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.truncatedObject))
        XCTAssertEqual(r.points.count, 2)                                  // first point kept, cut second kept as text
        XCTAssertEqual(r.points.first?.text, "Dinner moved to Friday")
        XCTAssertTrue(r.points.allSatisfy { !$0.text.isEmpty })
        XCTAssertTrue(r.repaired)
    }

    func testMissingRefsDoesNotDiscardAGoodAnswer() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.missingRefs))
        XCTAssertEqual(r.points.count, 2)
        XCTAssertEqual(r.points.first?.text, "The trip moved to the second week of December")
        XCTAssertEqual(r.points.first?.refs, [])                          // no citations, but the answer survives
    }

    func testAlternateKeysAndStringRefsAreUnderstood() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.alternateKeys))
        XCTAssertEqual(r.points.map(\.text), ["Ravi has exams the first week", "Hotels this weekend"])
        XCTAssertEqual(r.points[0].refs, [3, 4])
        XCTAssertEqual(r.points[1].refs, [5])
    }

    func testAnswerWithCitationsShapeIsRead() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.answerWithCitations))
        XCTAssertEqual(r.points.count, 1)
        XCTAssertTrue(r.points[0].text.hasPrefix("You planned Goa"))
        XCTAssertEqual(r.points[0].refs, [2, 4])
    }

    func testStringListWithInlineCitationsIsRead() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.stringList))
        XCTAssertEqual(r.points.count, 3)
        XCTAssertEqual(r.points.map(\.text), ["Goa in December", "Book flights by Friday", "Ravi joins the second week"])
        XCTAssertEqual(r.points[2].refs, [3, 4])                          // "[n]" markers become refs, not text
    }

    func testLiveQwenShapeEchoingSpeakersIsCleaned() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.stringListEchoingSpeakers))
        XCTAssertEqual(r.points.map(\.text), ["yes, book flights by Friday",
                                              "ok second week then",
                                              "I will check hotels this weekend"])
        XCTAssertEqual(r.points[0].refs, [2, 3])                          // the echoed "[2]" and the real "[3]" are kept
        XCTAssertEqual(r.points[1].refs, [4])
    }

    func testDoubleEncodedPointsAreUnwrapped() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.doubleEncodedPoints))
        XCTAssertEqual(r.points.map(\.text), ["Goa in December?", "book flights by Friday"])
    }

    func testBareArrayOfPointObjectsIsRead() throws {
        let r = try XCTUnwrap(AIParse.json(from: AIParserFixtures.bareArray))
        XCTAssertEqual(r.points.count, 2)
        XCTAssertEqual(r.points[1].refs, [4])
    }

    func testCitationOnlyReplyIsNotAnAnswer() {
        XCTAssertNil(AIParse.json(from: AIParserFixtures.citationsOnly))     // "[2], [4]" is not a point
        XCTAssertNil(AIParse.plainText(from: AIParserFixtures.citationsOnly))
    }

    func testNotAnAnswerIsRejected() {
        XCTAssertNil(AIParse.json(from: AIParserFixtures.numbersOnly))
        XCTAssertNil(AIParse.json(from: AIParserFixtures.emptyReply))
        XCTAssertNil(AIParse.json(from: AIParserFixtures.apologyOnly))
    }

    func testProseIsReadAsUnstructuredPoints() throws {
        let r = try XCTUnwrap(AIParse.plainText(from: AIParserFixtures.proseWithCitations))
        XCTAssertTrue(r.unstructured)
        XCTAssertEqual(r.points.count, 3)
        XCTAssertTrue(r.points.allSatisfy { !$0.text.isEmpty && !$0.text.hasPrefix("[") })
        XCTAssertTrue(r.points[0].text.contains("Goa"))
        XCTAssertEqual(r.points[1].refs, [3, 4])                          // mid-prose citations still resolve
        // a single prose paragraph is still an answer
        let one = try XCTUnwrap(AIParse.plainText(from: AIParserFixtures.proseAnswer))
        XCTAssertEqual(one.points.count, 1)
        XCTAssertTrue(one.points[0].text.contains("second week of December"))
    }

    func testDiagnoseNamesWhatFailed() {
        XCTAssertTrue(AIParse.diagnose(AIParserFixtures.proseAnswer).contains("prose"))
        XCTAssertTrue(AIParse.diagnose(AIParserFixtures.truncatedObject).contains("incomplete"))
        XCTAssertEqual(AIParse.diagnose(AIParserFixtures.emptyReply), "the reply was empty")
        XCTAssertTrue(AIParse.diagnose(AIParserFixtures.numbersOnly).contains("no list of points"))
    }

    // MARK: small-model detection and prompting

    func testModelSizeIsReadFromTheOllamaTag() {
        let small = AIModel.server(.ollama, base: "http://127.0.0.1:11434", model: "qwen2.5:3b")
        XCTAssertEqual(small.parameters, 3)
        XCTAssertTrue(small.isSmall)
        XCTAssertEqual(small.chunkChars, 6000)
        XCTAssertTrue(AIModel.server(.ollama, base: "", model: "deepseek-r1:1.5b").isSmall)
        XCTAssertTrue(AIModel.server(.ollama, base: "", model: "llama3.2:7b").isSmall)
        XCTAssertFalse(AIModel.server(.ollama, base: "", model: "llama3.1:8b").isSmall)
        XCTAssertFalse(AIModel.server(.ollama, base: "", model: "qwen2.5:14b").isSmall)
        XCTAssertFalse(AIModel.server(.ollama, base: "", model: "unknown-model").isSmall)   // no tag: keep old behaviour
        XCTAssertFalse(AIModel.apple.isSmall)
        XCTAssertEqual(AIModel.server(.ollama, base: "", model: "qwen2.5:14b").chunkChars, 14000)
    }

    func testCompactPromptCarriesOneExampleAndTheShortInstruction() {
        let p = HTTPEngine.smallPrompt("List 3 points.", "[1] Synthetic message")
        XCTAssertTrue(p.contains(#"{"points": ["The boiler is fixed on Monday [3]""#))
        XCTAssertTrue(p.contains("Example only, from a different conversation"))
        XCTAssertTrue(p.contains("List 3 points."))
        XCTAssertTrue(p.contains("Messages:\n[1] Synthetic message"))
        XCTAssertLessThan(p.count, 600)
    }

    // MARK: engine flow (network replaced by a test seam)

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String]
        private(set) var seen: [(system: String, user: String, schema: [String: Any]?)] = []
        init(_ queue: [String]) { self.queue = queue }
        func next(system: String, user: String, schema: [String: Any]?) -> String {
            lock.lock(); defer { lock.unlock() }
            seen.append((system, user, schema))
            return queue.isEmpty ? "" : queue.removeFirst()
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
    }

    private func engine(_ model: String, _ replies: Replies) -> HTTPEngine {
        var e = HTTPEngine(model: .server(.ollama, base: "http://127.0.0.1:9", model: model), style: .ollama)
        e.completeOverride = { system, user, schema, _ in replies.next(system: system, user: user, schema: schema) }
        return e
    }

    func testSmallModelGetsShortPromptAndOneRepairRoundThenStructuredJSON() async throws {
        let replies = Replies([AIParserFixtures.proseWithCitations,
                               #"{"points": ["Goa in December [1]", "Flights by Friday [2]"]}"#])
        let out = try await engine("qwen2.5:3b", replies).points(
            system: "LONG SYSTEM RULES", instruction: "LONG INSTRUCTION that a 3B should not have to read",
            body: "[1] Synthetic message", compact: "SHORT INSTRUCTION")
        XCTAssertEqual(out.points.count, 2)
        XCTAssertEqual(out.points[1].refs, [2])
        XCTAssertFalse(out.unstructured)
        XCTAssertTrue(out.repaired)
        XCTAssertEqual(replies.calls, 2)

        let first = replies.seen[0]
        XCTAssertEqual(first.system, HTTPEngine.smallSystem)               // not the long system prompt
        XCTAssertTrue(first.user.contains("SHORT INSTRUCTION"))
        XCTAssertFalse(first.user.contains("LONG INSTRUCTION"))
        XCTAssertTrue(first.user.contains(#""points": ["#))                  // the list-of-strings contract

        let repair = replies.seen[1]
        XCTAssertTrue(repair.user.contains("could not be read as JSON"))
        XCTAssertTrue(repair.user.contains("prose"))                       // the exact parse error
        XCTAssertTrue(repair.user.contains("Goa in December"))             // the payload it must rewrite
    }

    func testLargeModelKeepsTheRichPromptAndSchema() async throws {
        let replies = Replies([#"[{"text": "Dinner", "refs": [1]}]"#])
        let out = try await engine("llama3.1:70b", replies).points(
            system: "LONG SYSTEM RULES", instruction: "LONG INSTRUCTION", body: "[1] Synthetic", compact: "SHORT")
        XCTAssertEqual(out.points.first?.text, "Dinner")
        XCTAssertEqual(replies.calls, 1)
        XCTAssertEqual(replies.seen[0].system, "LONG SYSTEM RULES")
        XCTAssertTrue(replies.seen[0].user.contains("LONG INSTRUCTION"))
        let props = (replies.seen[0].schema?["properties"] as? [String: Any])?["points"] as? [String: Any]
        XCTAssertEqual((props?["items"] as? [String: Any])?["type"] as? String, "object")   // rich object schema
    }

    func testEchoedExampleIsDroppedAndTheRepairRoundIsUsed() async throws {
        let echo = #"{"points": ["The boiler is fixed on Monday [3]", "Priya sends the invoice [5]"]}"#
        let real = #"{"points": ["Goa in December [1]"]}"#
        let replies = Replies([echo, real])
        let out = try await engine("qwen2.5:3b", replies).points(system: "s", instruction: "i", body: "b", compact: "c")
        XCTAssertEqual(out.points.map(\.text), ["Goa in December"])     // the example is never shown as an answer
        XCTAssertTrue(out.repaired)
    }

    func testWhenJSONNeverArrivesTheProseAnswerIsKeptNotAnError() async throws {
        let replies = Replies([AIParserFixtures.proseWithCitations, "still not json, sorry"])
        let out = try await engine("qwen2.5:3b", replies).points(
            system: "s", instruction: "i", body: "b", compact: "c")
        XCTAssertTrue(out.unstructured)
        XCTAssertEqual(out.points.count, 3)
        XCTAssertTrue(out.points.contains { $0.text.contains("Goa") })
    }

    func testUnreadableReplyGivesActionableCopyNotHardwareBlame() async throws {
        let replies = Replies(["", ""])
        do {
            _ = try await engine("qwen2.5:3b", replies).points(system: "s", instruction: "i", body: "b", compact: "c")
            XCTFail("expected an error")
        } catch {
            let m = error.localizedDescription
            XCTAssertTrue(m.contains("qwen2.5:3b"))
            XCTAssertTrue(m.contains("couldn't turn into points"))
            XCTAssertTrue(m.contains("ollama pull"))                       // says what to try
            XCTAssertFalse(m.lowercased().contains("hardware"))
            XCTAssertFalse(m.contains("Try a larger model."))              // the old dead-end copy is gone
        }
    }

    func testUnstructuredPointsAreMarkedForTheUI() {
        let p = SummaryPoint(text: "Plain answer", sources: [], unstructured: true)
        XCTAssertTrue(p.unstructured)
        XCTAssertFalse(SummaryPoint(text: "Cited", sources: []).unstructured)
    }

    func testLongLocalGenerationIsNotCutShortByAShortTimeout() {
        XCTAssertGreaterThanOrEqual(HTTPEngine.session.configuration.timeoutIntervalForRequest, 600)
        XCTAssertGreaterThanOrEqual(HTTPEngine.session.configuration.timeoutIntervalForResource, 3600)
    }

    func testASlowGenerationCanBeCancelled() async {
        var e = HTTPEngine(model: .server(.ollama, base: "http://127.0.0.1:9", model: "qwen2.5:3b"), style: .ollama)
        e.completeOverride = { _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)      // a 3B grinding on CPU
            return #"{"points": ["never reached [1]"]}"#
        }
        let task = Task { try await e.points(system: "s", instruction: "i", body: "b", compact: "c") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the cancelled call to stop")
        } catch is CancellationError {
            // expected: cancellation reaches the model call, it does not wait out the watchdog
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
