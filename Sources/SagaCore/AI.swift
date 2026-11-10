import Foundation
import CryptoKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A language model Saga can use. Everything here runs on this Mac: Apple's on-device model, or a server on localhost
/// (Ollama, LM Studio). Nothing is sent to the internet.
public struct AIModel: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case apple, ollama, openai }
    public let id: String                 // "apple" | "ollama|<base>|<model>" | "openai|<base>|<model>"
    public let name: String
    public let kind: Kind
    public let base: String, model: String
    public var detail: String { kind == .apple ? "Apple on-device" : kind == .ollama ? "Ollama" : "LM Studio" }
    /// Parameters parsed from the model tag ("qwen2.5:3b" → 3). Nil when the tag doesn't say.
    public var parameters: Double? {
        guard kind != .apple else { return nil }
        let tag = model.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        guard let re = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)b"#),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return Double(tag[r])
    }
    /// A 3B local model needs shorter prompts, fewer rules and a smaller transcript than a 30B one.
    public var isSmall: Bool { (parameters ?? 99) <= 7 }
    /// How much transcript fits in one request. Apple's model has a ~4k-token window; small local models lose the thread
    /// on long inputs, so they get less; larger local servers get the full 8k window.
    var chunkChars: Int { kind == .apple ? 6000 : isSmall ? 6000 : 14000 }

    public static let apple = AIModel(id: "apple", name: "Apple Intelligence", kind: .apple, base: "", model: "")
    static func server(_ kind: Kind, base: String, model: String) -> AIModel {
        AIModel(id: "\(kind.rawValue)|\(base)|\(model)", name: model, kind: kind, base: base, model: model)
    }
}

public struct MessageRef: Hashable, Sendable {
    public let messageID: Int64, chatID: Int64; public var uid: String = ""
    public init(messageID: Int64, chatID: Int64, uid: String = "") { self.messageID = messageID; self.chatID = chatID; self.uid = uid }
}

public struct SummaryPoint: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let sources: [MessageRef]       // messages that support this point (verified to exist)
    /// True when the model answered in prose and the text was kept as-is; citations may be missing.
    public let unstructured: Bool
    public init(text: String, sources: [MessageRef], unstructured: Bool = false) {
        self.text = text; self.sources = sources; self.unstructured = unstructured
    }
}

public struct AIError: LocalizedError { public let message: String; public var errorDescription: String? { message } }

/// What one model call produced, plus how literal it was.
public struct EngineOut: Sendable {
    public let points: [AIParse.Point]
    /// The JSON needed a repair (fence removal, quotes, commas, truncation).
    public let repaired: Bool
    /// Only prose could be recovered; the text is kept but shown as unstructured.
    public let unstructured: Bool
    public init(points: [AIParse.Point], repaired: Bool = false, unstructured: Bool = false) {
        self.points = points; self.repaired = repaired; self.unstructured = unstructured
    }
}

/// A model backend that turns a prompt into short points, each citing numbered messages.
/// `instruction` and `body` are separate so the engine can shrink the instruction for small models
/// while keeping the numbered transcript intact; `compact` is the one-line version of the instruction.
protocol AIEngine: Sendable {
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut
}

public enum LocalAI {
    public enum Status: Equatable, Sendable { case available, unavailable(String) }

    // MARK: detection
    public static var appleStatus: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let why):
                switch why {
                case .deviceNotEligible: return .unavailable("This Mac doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in System Settings to use it.")
                case .modelNotReady: return .unavailable("The on-device model is still downloading. Try again soon.")
                @unknown default: return .unavailable("The on-device model isn't available.")
                }
            }
        }
        #endif
        return .unavailable("Apple Intelligence needs macOS 26 or later.")
    }
    public static var status: Status { appleStatus }

    public struct Detection: Sendable { public var models: [AIModel] = []; public var hints: [String] = [] }

    /// Finds usable models: Apple's, plus anything served on localhost by Ollama (11434) or LM Studio (1234).
    public static func detect() async -> Detection {
        var d = Detection()
        if appleStatus == .available { d.models.append(.apple) }
        else if case .unavailable(let why) = appleStatus { d.hints.append(why) }

        let ollama = "http://127.0.0.1:11434"
        if let tags = await getJSON("\(ollama)/api/tags"), let list = tags["models"] as? [[String: Any]] {
            let names = list.compactMap { $0["name"] as? String }.filter { !$0.lowercased().contains("embed") }
            d.models += names.map { AIModel.server(.ollama, base: ollama, model: $0) }
            if names.isEmpty { d.hints.append("Ollama is running but has no models. In Terminal: ollama pull qwen2.5:3b") }
        } else if ["/Applications/Ollama.app", "/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"].contains(where: FileManager.default.fileExists) {
            d.hints.append("Ollama is installed but not running. Open the Ollama app to use its models.")
        }
        let lm = "http://127.0.0.1:1234"
        if let m = await getJSON("\(lm)/v1/models"), let list = m["data"] as? [[String: Any]] {
            d.models += list.compactMap { $0["id"] as? String }.filter { !$0.lowercased().contains("embed") }.map { AIModel.server(.openai, base: lm, model: $0) }
        }
        return d
    }

    static func getJSON(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func engine(for m: AIModel) throws -> AIEngine {
        switch m.kind {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return AppleEngine() }
            #endif
            throw AIError(message: "Apple Intelligence needs macOS 26 or later.")
        case .ollama: return HTTPEngine(model: m, style: .ollama)
        case .openai: return HTTPEngine(model: m, style: .openai)
        }
    }

    // MARK: transcript preparation
    struct Entry { let line: String; let ref: MessageRef }

    /// "Name: text" entries for the model. Drops media/empties and filler (very short replies, emoji-only, bare links) so long
    /// chats need fewer parts; long messages are clipped.
    static func entries(_ rows: [MessageRow], chatID: Int64, clipTo: Int = 400) -> [Entry] {
        var out: [Entry] = []; var last = ""
        for r in rows {
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 4, t.contains(where: { $0.isLetter || $0.isNumber }), !Pruner.isLinkOnly(t) else { continue }
            let line = "\(r.fromMe ? "Me" : r.sender): \(clip(t, clipTo))"
            if line == last { continue }; last = line
            out.append(Entry(line: line, ref: MessageRef(messageID: r.id, chatID: chatID, uid: r.uid)))
        }
        return out
    }
    static func clip(_ t: String, _ n: Int) -> String { t.count > n ? String(t.prefix(n)) + "…" : t }

    /// Splits entries into parts that fit the model; each part is numbered from 1 so its text (and cache key) doesn't depend on
    /// what came before it.
    static func parts(_ entries: [Entry], maxChars: Int) -> [(text: String, refs: [Int: MessageRef])] {
        var out: [(String, [Int: MessageRef])] = [], cur = "", refs: [Int: MessageRef] = [:], n = 0
        for e in entries {
            let line = "[\(n + 1)] \(e.line)\n"
            if cur.count + line.count > maxChars, !cur.isEmpty { out.append((cur, refs)); cur = ""; refs = [:]; n = 0 }
            n += 1; cur += "[\(n)] \(e.line)\n"; refs[n] = e.ref
        }
        if !cur.isEmpty { out.append((cur, refs)) }
        return out
    }

    static let system = "You work with WhatsApp messages. Use only what is in the text. Never invent names, dates or facts. Messages are numbered like [12]; cite them by number."
    static let promptVersion = "v4"

    static func hash(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// quick: at most `quickMaxParts` parts, shorter excerpts and an even sample of messages for very long periods. full: everything.
    public enum Detail: String, Sendable, CaseIterable { case quick = "Quick", full = "Full detail" }
    public static let quickMaxParts = 10

    static func prepared(_ rows: [MessageRow], chatID: Int64, model: AIModel, detail: Detail) -> [(text: String, refs: [Int: MessageRef])] {
        var ents = entries(rows, chatID: chatID)
        var p = parts(ents, maxChars: model.chunkChars)
        guard detail == .quick, p.count > quickMaxParts else { return p }
        ents = entries(rows, chatID: chatID, clipTo: 160); p = parts(ents, maxChars: model.chunkChars)
        if p.count > quickMaxParts {
            let stride = Int((Double(p.count) / Double(quickMaxParts)).rounded(.up))
            ents = ents.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            p = parts(ents, maxChars: model.chunkChars)
        }
        return p
    }

    public struct SummaryProgress: Sendable { public let done: Int, total: Int, fromCache: Int, merging: Bool }

    /// How many parts a summary needs and how many are already saved (so the UI can warn about long runs).
    public static func plan(_ rows: [MessageRow], chatID: Int64, chatName: String, isGroup: Bool, model: AIModel, detail: Detail = .full, cache: AICache?) -> (parts: Int, cached: Int, messages: Int) {
        let p = prepared(rows, chatID: chatID, model: model, detail: detail)
        let kind = kindText(chatName: chatName, isGroup: isGroup)
        let cached = cache == nil ? 0 : p.filter { cache!.chunk(hash: hash(model.id, promptVersion, kind, $0.text)) != nil }.count
        return (p.count, cached, p.reduce(0) { $0 + $1.refs.count })
    }
    static func kindText(chatName: String, isGroup: Bool) -> String { isGroup ? "a group chat called \"\(chatName)\"" : "a chat between Me and \(chatName)" }

    // MARK: summaries
    /// Map-reduce summary. Newest parts are done first, results stream out through `onPartial`, every finished part is saved so a
    /// stopped or interrupted run resumes, and the finished summary is saved under `cacheKey`.
    public static func summarize(_ rows: [MessageRow], chatID: Int64, chatName: String, isGroup: Bool, model: AIModel = .apple, detail: Detail = .full,
                                 cache: AICache? = nil, cacheKey: String? = nil,
                                 onPartial: @Sendable ([SummaryPoint]) -> Void = { _ in },
                                 progress: @Sendable (SummaryProgress) -> Void = { _ in }) async throws -> [SummaryPoint] {
        let eng = try engine(for: model)
        let parts = prepared(rows, chatID: chatID, model: model, detail: detail)
        guard !parts.isEmpty else { return [] }
        let ents: [Entry] = []
        let kind = kindText(chatName: chatName, isGroup: isGroup)
        var byUID: [String: MessageRef] = [:]
        for p in parts { for r in p.refs.values where !r.uid.isEmpty { byUID[r.uid] = r } }
        _ = ents

        var done: [Int: [SummaryPoint]] = [:]
        var skipped = 0, hits = 0; var lastError: Error?
        func ordered() -> [SummaryPoint] { done.keys.sorted().flatMap { done[$0]! } }
        for idx in parts.indices.reversed() {                              // newest first: if you stop early you have the recent past
            try Task.checkCancellation()
            let p = parts[idx]
            let h = hash(model.id, promptVersion, kind, p.text)
            if let stored = cache?.chunk(hash: h) {
                hits += 1
                done[idx] = stored.map { SummaryPoint(text: $0.text, sources: $0.uids.compactMap { byUID[$0] }) }
            } else {
                do {
                    let out = try await withRetry(model) { try await eng.points(
                        system: system,
                        instruction: "This is one part of \(kind). List the main topics, decisions, plans and open questions in 3 to 6 short points, in the order they happened. For each point give the numbers of the one to three messages that best support it.",
                        body: p.text,
                        compact: "List 3 to 6 short points in the order they happened. Put the message numbers that support each point in square brackets at its end.") }
                    let pts = out.points.map { pt in SummaryPoint(text: pt.text, sources: pt.refs.filter { p.refs[$0] != nil }.prefix(3).compactMap { p.refs[$0] }, unstructured: out.unstructured) }
                    done[idx] = pts
                    // Prose-only replies are shown but not saved: the next run gets another chance at structured output.
                    if !out.unstructured {
                        cache?.saveChunk(hash: h, points: pts.map { .init(text: $0.text, uids: $0.sources.map(\.uid)) })
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; lastError = error }
            }
            progress(SummaryProgress(done: parts.count - idx, total: parts.count, fromCache: hits, merging: false))
            onPartial(ordered())
        }
        var points = ordered()
        if points.isEmpty, let e = lastError { throw AIError(message: friendly(e)) }

        // reduce: merge related points in batches until a short list remains, mapping each merged point back to its sources' messages
        var round = 0
        while points.count > 10, round < 4 {
            round += 1
            progress(SummaryProgress(done: parts.count, total: parts.count, fromCache: hits, merging: true))
            try Task.checkCancellation()
            var merged: [SummaryPoint] = []
            var i = 0
            while i < points.count {
                var batch: [SummaryPoint] = [], size = 0
                while i < points.count, size + points[i].text.count + 8 < model.chunkChars - 1500, batch.count < 60 { batch.append(points[i]); size += points[i].text.count + 8; i += 1 }
                if batch.isEmpty { batch = [points[i]]; i += 1 }
                let final = points.count <= 60 && i >= points.count && merged.isEmpty
                let limit = final ? 8 : 6
                let listing = batch.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")
                let merges = try? await eng.points(
                    system: system,
                    instruction: "These numbered notes are about \(kind). Combine related ones into at most \(limit) points in chronological order, keeping decisions and plans. For each combined point give the numbers of the notes it is based on.",
                    body: listing,
                    compact: "Combine these numbered notes into at most \(limit) points, in order. Put the note numbers each point uses in square brackets at its end.")
                if batch.count > limit, let m = merges?.points, !m.isEmpty {
                    for mp in m {
                        let src = mp.refs.filter { $0 >= 1 && $0 <= batch.count }
                        let refs = Array(Set(src.flatMap { batch[$0 - 1].sources })).sorted { $0.messageID < $1.messageID }
                        merged.append(SummaryPoint(text: mp.text, sources: Array(refs.prefix(3)), unstructured: merges?.unstructured ?? false))
                    }
                } else if batch.count > limit {                              // merge failed: keep evenly spread points rather than only the first ones
                    let step = Double(batch.count) / Double(limit)
                    merged += (0..<limit).map { batch[Int(Double($0) * step)] }
                } else { merged += batch }
            }
            if merged.count >= points.count { points = Array(merged.prefix(10)); break }
            points = merged
            onPartial(points)
        }
        if skipped > 0 { points.append(SummaryPoint(text: "\(skipped) of \(parts.count) parts couldn't be summarized" + (lastError.map { ": " + friendly($0) } ?? "") + ". Press Continue to retry them.", sources: [])) }
        if let cache, let cacheKey, skipped == 0 {
            cache.saveSummary(key: cacheKey, lastTS: Int64((rows.last?.ts.timeIntervalSince1970 ?? 0) * 1000), messageCount: rows.count,
                              points: points.map { .init(text: $0.text, uids: $0.sources.map(\.uid)) })
        }
        return points
    }

    /// One short line from a local model, e.g. a caption for a dated card. Uses the same
    /// engines and privacy boundary as summaries; callers cache the result themselves.
    public static func oneLine(system: String, prompt: String, model: AIModel) async throws -> String {
        let eng = try engine(for: model)
        let out = try await withRetry(model) { try await eng.points(system: system, instruction: prompt, body: "", compact: prompt) }
        let text = out.points.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AIError(message: "\(model.name) sent back an empty reply. Try again; if it keeps happening, pull a different model (for example ollama pull qwen2.5:3b).")
        }
        return text
    }

    // MARK: ask your archive
    /// How Ask found its messages. `keywordFallback` is a visible, non-fatal degradation: meaning search was requested but
    /// unavailable, so the answer still comes from keywords.
    public enum AskRetrieval: Sendable, Equatable {
        case keyword
        case hybrid(keywordSeeds: Int, semanticSeeds: Int)
        case keywordFallback(String)
    }

    public struct AskOutcome: Sendable {
        public let points: [SummaryPoint]
        /// Messages actually supplied to the model (not the corpus or vector count).
        public let searched: Int
        public let retrieval: AskRetrieval
        /// True when the model answered in prose; the answer is shown, but its citations may be incomplete.
        public let unstructured: Bool
        public init(points: [SummaryPoint], searched: Int, retrieval: AskRetrieval, unstructured: Bool = false) {
            self.points = points; self.searched = searched; self.retrieval = retrieval; self.unstructured = unstructured
        }
    }

    /// Answers a question from messages found by full-text search (all chats, or one). Retrieval is keyword-based, so ask with
    /// the words people would have used; the answer cites the messages it used. Passing `semantic` (only when the user has
    /// opted in and the local index is ready) adds meaning-based retrieval fused with the keyword results.
    public static func ask(_ question: String, store: VaultStore, chat: Int64?, model: AIModel = .apple,
                           semantic: SemanticSearch? = nil,
                           progress: @Sendable (String) -> Void = { _ in }) async throws -> (points: [SummaryPoint], searched: Int) {
        let r = try await askResult(question, store: store, chat: chat, model: model, semantic: semantic, progress: progress)
        return (r.points, r.searched)
    }

    /// Same as `ask`, plus how retrieval went, so the caller can say plainly when meaning search fell back to keywords.
    public static func askResult(_ question: String, store: VaultStore, chat: Int64?, model: AIModel = .apple,
                                 semantic: SemanticSearch? = nil,
                                 progress: @Sendable (String) -> Void = { _ in }) async throws -> AskOutcome {
        try await askResult(question, store: store, chat: chat, model: model, engine: try engine(for: model), semantic: semantic, progress: progress)
    }

    /// Deterministic seam for tests: the model can be any `AIEngine`.
    static func askResult(_ question: String, store: VaultStore, chat: Int64?, model: AIModel,
                          engine eng: any AIEngine, semantic: SemanticSearch?,
                          progress: @Sendable (String) -> Void = { _ in }) async throws -> AskOutcome {
        progress("Searching your archive…")
        var mode: AskRetrieval = .keyword
        var ctx: [VaultStore.ContextMessage]
        if let semantic {
            do {
                let r = try await semantic.retrieve(question: question, chat: chat, limit: 30, store: store)
                ctx = r.ordered
                mode = .hybrid(keywordSeeds: r.keywordSeeds, semanticSeeds: r.semanticSeeds)
            } catch is CancellationError {
                throw CancellationError()                       // a stopped Ask is not a fallback
            } catch {
                ctx = try store.retrieve(question: question, chat: chat, maxHits: 30, context: 2)
                mode = .keywordFallback("Meaning search isn't available right now, so this answer uses keywords only. Check the local index in the search options, or ask with words people would have typed.")
            }
        } else {
            ctx = try store.retrieve(question: question, chat: chat, maxHits: 30, context: 2)
        }
        guard !ctx.isEmpty else { return AskOutcome(points: [], searched: 0, retrieval: mode) }
        var lines: [String] = [], refFor: [Int: MessageRef] = [:], used = 0
        var lastChat: Int64 = -1
        for (i, m) in ctx.enumerated() {
            if m.chatID != lastChat { lines.append("— chat: \(m.chat) —"); lastChat = m.chatID }
            let line = "[\(i + 1)] \(day.string(from: m.ts)) \(m.fromMe ? "Me" : m.sender): \(clip(m.text, 300))"
            if used + line.count > model.chunkChars { break }
            used += line.count; lines.append(line); refFor[i + 1] = MessageRef(messageID: m.id, chatID: m.chatID, uid: m.uid)
        }
        progress("Reading \(refFor.count) messages…")
        let out = try await eng.points(
            system: system,
            instruction: "Question: \(question)\n\nAnswer using only the messages below, in 1 to 5 short points. Give the numbers of the messages each point is based on. If the messages don't answer the question, say so in one point with no numbers.",
            body: lines.joined(separator: "\n"),
            compact: "Question: \(question)\n\nAnswer from these numbered messages in 1 to 5 short points. Put the message numbers each point uses in square brackets at its end. If they don't answer it, say so once.")
        let pts = out.points.map { pt in SummaryPoint(text: pt.text, sources: pt.refs.prefix(3).compactMap { refFor[$0] }, unstructured: out.unstructured) }
        return AskOutcome(points: pts, searched: refFor.count, retrieval: mode, unstructured: out.unstructured)
    }
    nonisolated(unsafe) static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// Small local models occasionally return malformed JSON; one more try usually works. (Apple's refusals are deterministic.)
    static func withRetry<T>(_ model: AIModel, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch { if model.kind == .apple { throw error }; return try await body() }
    }

    static func friendly(_ e: Error) -> String {
        let s = "\(e)"
        if s.contains("sensitive") || s.lowercased().contains("guardrail") { return "Apple's on-device safety filter declined to process this text. Try a different model." }
        return (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }
}

// MARK: - Apple Foundation Models
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable struct RawPoint {
    @Guide(description: "One short sentence. Only facts stated in the messages.")
    var text: String
    @Guide(description: "The numbers in square brackets of the one to three messages that best support this point.")
    var refs: [Int]
}
@available(macOS 26.0, *)
@Generable struct RawPoints {
    @Guide(description: "The points, in order.")
    var points: [RawPoint]
}
@available(macOS 26.0, *)
struct AppleEngine: AIEngine {
    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        guard case .available = LocalAI.appleStatus else { throw AIError(message: "Apple Intelligence isn't available.") }
        let prompt = body.isEmpty ? instruction : instruction + "\n\n" + body
        let r = try await LanguageModelSession(instructions: system).respond(to: prompt, generating: RawPoints.self)
        return EngineOut(points: r.content.points.map { AIParse.Point(text: $0.text, refs: $0.refs) })
    }
}
#endif

// MARK: - Ollama and LM Studio (localhost servers)
struct HTTPEngine: AIEngine {
    enum Style { case ollama, openai }
    let model: AIModel, style: Style
    /// Test seam: when set, replaces the network call (never set by the app).
    var completeOverride: (@Sendable (String, String, [String: Any]?, Int) async throws -> String)?

    /// The rich shape larger models handle.
    nonisolated(unsafe) static let pointsSchema: [String: Any] = [
        "type": "object",
        "properties": ["points": ["type": "array", "items": [
            "type": "object",
            "properties": ["text": ["type": "string"], "refs": ["type": "array", "items": ["type": "integer"]]],
            "required": ["text", "refs"]]]],
        "required": ["points"]]

    /// The smallest shape a 3B can emit reliably: one array of one-line strings, each ending with its citations.
    nonisolated(unsafe) static let listSchema: [String: Any] = [
        "type": "object",
        "properties": ["points": ["type": "array", "items": ["type": "string"]]],
        "required": ["points"]]

    static let smallSystem = "You read WhatsApp messages. Use only what is in them and never invent facts. Messages have numbers like [3]. Write each point as a sentence, never only numbers. Reply with JSON only, with no explanation."

    /// The example is deliberately about a different conversation: a 3B will sometimes copy its wording.
    static let exampleSentences = ["The boiler is fixed on Monday", "Priya sends the invoice", "one short sentence"]

    /// Small models do better with one example and one instruction than with a rule book.
    static func smallPrompt(_ instruction: String, _ body: String) -> String {
        var s = """
        Reply with JSON in this shape: one short sentence per point, each ending with the message numbers it uses.
        Example only, from a different conversation:
        {"points": ["The boiler is fixed on Monday [3]", "Priya sends the invoice [5]"]}

        \(instruction)
        """
        if !body.isEmpty { s += "\n\nMessages:\n" + body }
        return s
    }

    /// Drops points that are just the few-shot example echoed back.
    static func withoutExampleEchoes(_ points: [AIParse.Point]) -> [AIParse.Point] {
        let echoes = Set(exampleSentences.map(normalised))
        return points.filter { !echoes.contains(normalised($0.text)) }
    }
    static func normalised(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A parse result the app can actually use; nil when only the example came back.
    static func accept(_ r: AIParse.Result, repaired: Bool = false) -> EngineOut? {
        let pts = withoutExampleEchoes(r.points)
        guard !pts.isEmpty else { return nil }
        return EngineOut(points: pts, repaired: repaired || r.repaired, unstructured: r.unstructured)
    }

    /// 1800s per request: a 3B on CPU can spend minutes on one part and we would rather wait than report a false failure.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1800
        c.timeoutIntervalForResource = 7200
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func points(system: String, instruction: String, body: String, compact: String?) async throws -> EngineOut {
        let small = model.isSmall
        let systemText = small ? Self.smallSystem : system
        let user = small ? Self.smallPrompt(compact ?? instruction, body)
                         : (body.isEmpty ? instruction : instruction + "\n\n" + body)
        let first = try await complete(system: systemText, user: user,
                                       schema: small ? Self.listSchema : Self.pointsSchema,
                                       maxTokens: small ? 450 : 700)
        if let r = AIParse.json(from: first), let out = Self.accept(r) { return out }

        // One repair round: hand back the exact problem and the reply, ask only for the small shape.
        let why = AIParse.diagnose(first)
        var repaired: String?
        if !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let repairUser = """
            This reply could not be read as JSON (\(why)). Here it is:

            \(LocalAI.clip(first, 1800))

            Rewrite the same answer as JSON only, in exactly this shape, with no other text.
            Each point must be a sentence with words, not just numbers. Use the facts above; do not copy this example:
            {"points": ["The boiler is fixed on Monday [3]", "Priya sends the invoice [5]"]}
            """
            do {
                repaired = try await complete(system: "You fix malformed JSON replies. Reply with JSON only.", user: repairUser,
                                              schema: Self.listSchema, maxTokens: 400)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                repaired = nil                    // the repair round is best-effort; the prose fallback still applies
            }
        }
        if let text = repaired, let r = AIParse.json(from: text), let out = Self.accept(r, repaired: true) { return out }

        // Last resort: a plain answer beats an error. It is labelled as unstructured in the UI.
        if let r = AIParse.plainText(from: first) ?? AIParse.plainText(from: repaired ?? ""), let out = Self.accept(r) { return out }
        throw AIError(message: Self.unreadable(model, why))
    }

    func complete(system: String, user: String, schema: [String: Any]?, maxTokens: Int) async throws -> String {
        if let completeOverride { return try await completeOverride(system, user, schema, maxTokens) }
        switch style {
        case .ollama: return try await chatOllama(system: system, user: user, schema: schema, maxTokens: maxTokens)
        case .openai: return try await chatOpenAI(system: system, user: user, schema: schema, maxTokens: maxTokens)
        }
    }

    /// Streams Ollama's NDJSON. Streaming keeps the connection alive while a slow model thinks, so no watchdog
    /// cuts a long local generation short, and cancelling the Task drops the connection.
    func chatOllama(system: String, user: String, schema: [String: Any]?, maxTokens: Int) async throws -> String {
        guard let url = URL(string: model.base + "/api/chat") else { throw AIError(message: "Bad server address.") }
        var body: [String: Any] = ["model": model.model, "stream": true,
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                                   "options": ["num_ctx": 8192, "temperature": 0.2, "num_predict": maxTokens]]
        if let schema { body["format"] = schema }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await Self.session.bytes(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw AIError(message: "Couldn't reach \(model.detail) at \(model.base). Is it running?") }
        guard let http = resp as? HTTPURLResponse else { throw AIError(message: "No response from \(model.detail).") }

        var content = "", raw = ""
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                raw += t + "\n"
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { throw AIError(message: "\(model.detail) said: \(err)") }
                if let part = (obj["message"] as? [String: Any])?["content"] as? String { content += part }
                if (obj["done"] as? Bool) == true { break }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as AIError { throw e }
        catch { if content.isEmpty { throw AIError(message: "\(model.detail) stopped mid-reply (\(error.localizedDescription)).") } }

        if http.statusCode != 200, content.isEmpty {
            let msg = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])
                .flatMap { ($0["error"] as? String) ?? (($0["error"] as? [String: Any])?["message"] as? String) }
            throw AIError(message: "\(model.detail) said: \(msg ?? "error \(http.statusCode)")")
        }
        if content.isEmpty, let whole = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            content = (whole["message"] as? [String: Any])?["content"] as? String ?? content    // server ignored stream:true
        }
        return content
    }

    func chatOpenAI(system: String, user: String, schema: [String: Any]?, maxTokens: Int) async throws -> String {
        guard let url = URL(string: model.base + "/v1/chat/completions") else { throw AIError(message: "Bad server address.") }
        var body: [String: Any] = ["model": model.model, "stream": false, "temperature": 0.2, "max_tokens": maxTokens,
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        if let schema { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "points", "strict": true, "schema": schema]] }
        do {
            return try await post(url: url, body: body, model: model)
        } catch let e as ServerRefusal where e.status == 400 && schema != nil {
            body.removeValue(forKey: "response_format")            // server doesn't do structured output; the parser copes
            return try await post(url: url, body: body, model: model)
        }
    }

    struct ServerRefusal: Error, LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    func post(url: URL, body: [String: Any], model: AIModel) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw AIError(message: "Couldn't reach \(model.detail) at \(model.base). Is it running?") }
        guard let http = resp as? HTTPURLResponse else { throw AIError(message: "No response from \(model.detail).") }
        guard http.statusCode == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"]
                .flatMap { ($0 as? String) ?? (($0 as? [String: Any])?["message"] as? String) }
            throw ServerRefusal(status: http.statusCode, message: "\(model.detail) said: \(msg ?? "error \(http.statusCode)")")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let content = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return content ?? ""
    }

    /// Honest copy: says what failed and what to try, and never blames the Mac.
    static func unreadable(_ model: AIModel, _ why: String) -> String {
        "\(model.name) replied with text Saga couldn't turn into points (\(why)). Running it again often works. If it keeps happening, pull a larger local model — for example `ollama pull qwen2.5:7b` — or ask your question in Ask, which accepts a plain answer."
    }
}
