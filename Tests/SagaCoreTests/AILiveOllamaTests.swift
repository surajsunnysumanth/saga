import XCTest
@testable import SagaCore

/// Opt-in call against the real local Ollama. Skipped unless SAGA_LIVE_OLLAMA=1, so `swift test` stays offline.
/// Synthetic transcript only. Run: SAGA_LIVE_OLLAMA=1 swift test --filter AILiveOllamaTests
final class AILiveOllamaTests: XCTestCase {
    func testQwen3bReturnsUsablePointsThroughTheAppPath() async throws {
        guard ProcessInfo.processInfo.environment["SAGA_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set SAGA_LIVE_OLLAMA=1 to run against the local Ollama")
        }
        let model = AIModel.server(.ollama, base: "http://127.0.0.1:11434", model: "qwen2.5:3b")
        XCTAssertTrue(model.isSmall)
        let body = """
        [1] Asha: Shall we do Goa in December?
        [2] Me: yes, book flights by Friday
        [3] Ravi: I cannot do the first week, exams
        [4] Asha: ok second week then
        [5] Me: I will check hotels this weekend
        """
        let out = try await LocalAI.withRetry(model) { try await HTTPEngine(model: model, style: .ollama).points(
            system: LocalAI.system,
            instruction: "This is one part of a group chat called \"Trip planning\". List the main topics, decisions, plans and open questions in 3 to 6 short points, in the order they happened. For each point give the numbers of the one to three messages that best support it.",
            body: body,
            compact: "List 3 to 6 short points in the order they happened. Put the message numbers that support each point in square brackets at its end.") }
        print("LIVE_MODEL=\(model.name) repaired=\(out.repaired) unstructured=\(out.unstructured) points=\(out.points.count)")
        for p in out.points { print("LIVE_POINT refs=\(p.refs) text=\(p.text)") }
        XCTAssertFalse(out.points.isEmpty)
        XCTAssertTrue(out.points.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertTrue(out.points.contains { !$0.refs.isEmpty }, "the prompt asks for citations; a real model should give some")
    }

    /// Ollama's OpenAI-compatible endpoint is the weaker path: qwen2.5:3b double-encodes each point as a JSON string.
    /// The reply still has to come back as readable points, not an error.
    func testQwen3bOnTheOpenAICompatibleEndpointIsStillReadable() async throws {
        guard ProcessInfo.processInfo.environment["SAGA_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set SAGA_LIVE_OLLAMA=1 to run against the local Ollama")
        }
        let model = AIModel.server(.openai, base: "http://127.0.0.1:11434", model: "qwen2.5:3b")
        let out = try await LocalAI.withRetry(model) { try await HTTPEngine(model: model, style: .openai).points(
            system: LocalAI.system,
            instruction: "List 2 short points from the messages below. Cite message numbers.",
            body: "[1] Asha: Shall we do Goa in December?\n[2] Me: yes, book flights by Friday\n[3] Ravi: I cannot do the first week",
            compact: "List 2 short points and cite the message numbers in square brackets.") }
        print("LIVE_OPENAI_MODEL=\(model.name) repaired=\(out.repaired) unstructured=\(out.unstructured) points=\(out.points.count)")
        for p in out.points { print("LIVE_OPENAI_POINT refs=\(p.refs) text=\(p.text)") }
        XCTAssertFalse(out.points.isEmpty)
        XCTAssertFalse(out.points.contains { $0.text.contains("{") }, "double-encoded JSON must be unwrapped, not shown raw")
    }

    /// Stop must not wait for a 3B to finish: cancelling the task closes the streaming connection.
    func testCancellingALiveGenerationReturnsQuickly() async throws {
        guard ProcessInfo.processInfo.environment["SAGA_LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("set SAGA_LIVE_OLLAMA=1 to run against the local Ollama")
        }
        let model = AIModel.server(.ollama, base: "http://127.0.0.1:11434", model: "qwen2.5:3b")
        let eng = HTTPEngine(model: model, style: .ollama)
        let task = Task {
            try await eng.points(system: "You list things.",
                                 instruction: "List 40 numbered observations, one sentence each, about the message below.",
                                 body: "[1] Synthetic message about a trip", compact: nil)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let t0 = Date()
        task.cancel()
        do { _ = try await task.value } catch {}
        let elapsed = Date().timeIntervalSince(t0)
        print("LIVE_CANCEL_SECONDS=\(String(format: "%.2f", elapsed))")
        XCTAssertLessThan(elapsed, 5, "a cancelled generation should stop promptly, not finish the reply")
    }
}
