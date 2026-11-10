import Foundation

/// Reads what a local model actually sends back.
///
/// Small models wrap JSON in prose, fence it, use single quotes, leave trailing commas,
/// invent key names, or stop mid-object. None of that makes the answer unusable, so this
/// reader is deliberately forgiving: it finds the first balanced object or array anywhere
/// in the reply, applies the repairs small models need, understands several common shapes,
/// and only then falls back to reading the reply as plain prose (flagged as unstructured).
public enum AIParse {
    public struct Point: Sendable, Equatable {
        public let text: String
        public let refs: [Int]
        public init(text: String, refs: [Int]) { self.text = text; self.refs = refs }
    }

    public struct Result: Sendable, Equatable {
        public let points: [Point]
        /// The JSON needed a repair (fence, single quotes, trailing comma, truncation).
        public let repaired: Bool
        /// Recovered from prose, not JSON: useful text, but citations may be missing.
        public let unstructured: Bool
    }

    // MARK: - entry points

    /// Points from JSON found anywhere in `raw`. Returns nil when no JSON yields usable text.
    public static func json(from raw: String) -> Result? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for candidate in candidates(text) {
            if let pts = decode(candidate), !pts.isEmpty { return Result(points: pts, repaired: false, unstructured: false) }
            for fixed in repairs(candidate) where fixed != candidate {
                if let pts = decode(fixed), !pts.isEmpty { return Result(points: pts, repaired: true, unstructured: false) }
            }
        }
        return nil
    }

    /// Last resort: read prose as points, one line per point, keeping any trailing [n] citations.
    public static func plainText(from raw: String) -> Result? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var points: [Point] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.range(of: #"^[\{\}\[\],;:]+$"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^(```|~~~)"#, options: .regularExpression) != nil { line = line.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces); if line.isEmpty || line.lowercased() == "json" { continue } }
            if line.range(of: #"^(here (are|is)|sure|certainly|of course|okay|ok[,:]|based on the (messages|text))[,.! ]"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            line = line.replacingOccurrences(of: #"^(answer|summary|points?|reply)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            var leading: [Int] = []
            while leading.count < 3, let m = line.range(of: #"^\[([0-9][0-9,\s]*)\]\s*"#, options: .regularExpression) {
                leading += numbersIn(String(line[m]))
                line.removeSubrange(m)
            }
            line = line.replacingOccurrences(of: #"^(?:[-*•·]\s+|\d+[.)]\s+|#+\s*)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^"(.*)"[,]?$"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\{?"?text"?\s*:\s*"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\" ,{}"))
            // Structural leftovers from a broken JSON reply ("points": [) are not points.
            if line.range(of: #"^"?[A-Za-z_ ]+"?\s*:\s*[\[\{\"]?\s*$"#, options: .regularExpression) != nil { continue }
            var refs = leading + refsIn(line, allowLeading: false)
            line = stripCitations(line)
            guard line.count >= 4, line.filter({ $0.isLetter }).count >= 3 else { continue }
            if let last = points.last, last.text == line { continue }
            refs = Array(Set(refs)).sorted()
            if refs.count > 8 { refs = Array(refs.prefix(8)) }
            points.append(Point(text: line, refs: refs))
            if points.count == 12 { break }
        }
        return points.isEmpty ? nil : Result(points: points, repaired: false, unstructured: true)
    }

    /// A short, plain-language reason the reply could not be read. Used in the repair prompt and in error copy.
    public static func diagnose(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "the reply was empty" }
        guard t.contains("{") else {
            // No object at all: "[1] and [2] discussed ..." is prose, while "[1, 2, 3]" is JSON with nothing in it.
            if t.hasPrefix("["), (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil {
                return "the JSON had no list of points"
            }
            return "the reply was prose, not JSON"
        }
        if let s = spans(t).first(where: { $0.hasPrefix("{") }) {
            if (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) != nil {
                return "the JSON had no list of points"
            }
            return "the JSON has a syntax error"
        }
        return "the JSON is incomplete"
    }

    // MARK: - candidates

    /// Fenced blocks first, then every balanced object/array in the text, then the tail from the first brace.
    static func candidates(_ s: String) -> [String] {
        var out: [String] = []
        for block in fences(s) { out.append(block); out.append(contentsOf: spans(block)) }
        out.append(contentsOf: spans(s))
        if let i = s.firstIndex(where: { $0 == "{" || $0 == "[" }) { out.append(String(s[i...])) }
        out.append(s)
        var seen = Set<String>()
        return out.filter { $0.count > 1 && seen.insert($0).inserted }
    }

    /// Contents of ``` fences, with the language tag dropped.
    static func fences(_ s: String) -> [String] {
        let pieces = s.components(separatedBy: "```")
        guard pieces.count > 1 else { return [] }
        return stride(from: 1, to: pieces.count, by: 2).map { pieces[$0] }
            .map { piece in
                var lines = piece.components(separatedBy: "\n")
                if let f = lines.first, f.count < 12, !f.contains("{"), !f.contains("[") { lines.removeFirst() }
                return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// Every balanced `{...}` / `[...]` span, in order, ignoring braces inside strings.
    static func spans(_ s: String) -> [String] {
        let c = Array(s)
        var out: [String] = []
        var stack: [Character] = []
        var start = 0
        var quote: Character?
        var i = 0
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                if ch == "\\" { i += 2; continue }
                if ch == q { quote = nil }
            } else if ch == "\"" || (ch == "'" && quoteIsStructural(c, i)) {
                quote = ch
            } else if ch == "{" || ch == "[" {
                if stack.isEmpty { start = i }
                stack.append(ch)
            } else if ch == "}" || ch == "]" {
                if !stack.isEmpty {
                    stack.removeLast()
                    if stack.isEmpty { out.append(String(c[start...i])) }
                }
            }
            i += 1
        }
        return out
    }

    /// Apostrophes in prose ("don't") must not open a string; only a quote after `: , [ { ` or at the start does.
    static func quoteIsStructural(_ c: [Character], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, c[j] == " " || c[j] == "\n" || c[j] == "\t" { j -= 1 }
        guard j >= 0 else { return true }
        return [":", ",", "[", "{", "("].contains(c[j])
    }

    // MARK: - repair

    /// Variants of `s`, each with more small-model repairs applied. First one that decodes wins.
    static func repairs(_ s: String) -> [String] {
        let quoted = normalizeQuotes(s)
        let loose = fixLiterals(fixUnquotedKeys(fixTrailingCommas(quoted)))
        let closed = closeTruncated(loose)
        return [quoted, loose, closed]
    }

    /// Smart quotes to straight ones, and structural single-quoted strings to double-quoted.
    static func normalizeQuotes(_ s: String) -> String {
        let t = s
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard t.contains("'") else { return t }
        let c = Array(t)
        var out: [Character] = []; out.reserveCapacity(c.count)
        var i = 0, inDouble = false
        while i < c.count {
            let ch = c[i]
            if inDouble {
                out.append(ch)
                if ch == "\\", i + 1 < c.count { out.append(c[i + 1]); i += 2; continue }
                if ch == "\"" { inDouble = false }
                i += 1; continue
            }
            if ch == "\"" { inDouble = true; out.append(ch); i += 1; continue }
            if ch == "'", quoteIsStructural(c, i) {
                var k = i + 1, buf: [Character] = [], closed = false
                while k < c.count {
                    if c[k] == "\\", k + 1 < c.count { buf.append(c[k]); buf.append(c[k + 1]); k += 2; continue }
                    if c[k] == "'" { closed = true; break }
                    buf.append(c[k]); k += 1
                }
                if closed {
                    out.append("\"")
                    for b in buf { if b == "\"" { out.append("\\") }; out.append(b) }
                    out.append("\"")
                    i = k + 1; continue
                }
            }
            out.append(ch); i += 1
        }
        return String(out)
    }

    static func fixUnquotedKeys(_ s: String) -> String {
        replace(s, #"([\{\,]\s*)([A-Za-z_][A-Za-z0-9_\- ]*?)\s*:"#, #"$1"$2":"#)
    }
    static func fixTrailingCommas(_ s: String) -> String {
        replace(s, #",\s*([\]\}])"#, "$1")
    }
    static func fixLiterals(_ s: String) -> String {
        s.replacingOccurrences(of: ": True", with: ": true").replacingOccurrences(of: ": False", with: ": false")
            .replacingOccurrences(of: ": None", with: ": null")
    }

    /// Closes brackets and strings left open by a reply that hit the token limit, after dropping a dangling comma.
    static func closeTruncated(_ s: String) -> String {
        let c = Array(s)
        var stack: [Character] = [], quote: Character?
        var i = 0
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                if ch == "\\" { i += 2; continue }
                if ch == q { quote = nil }
            } else if ch == "\"" || (ch == "'" && quoteIsStructural(c, i)) {
                quote = ch
            } else if ch == "{" || ch == "[" {
                stack.append(ch)
            } else if ch == "}" || ch == "]" {
                if !stack.isEmpty { stack.removeLast() }
            }
            i += 1
        }
        guard !stack.isEmpty || quote != nil else { return s }
        var out = s.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t"))
        if let q = quote { out.append(q) }
        while let last = out.last, last == "," || last == " " || last == "\n" || last == "\t" { out.removeLast() }
        if out.last == ":" { out += " null" }
        for open in stack.reversed() { out.append(open == "{" ? "}" : "]") }
        return fixTrailingCommas(out)
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    // MARK: - decoding

    static func decode(_ s: String) -> [Point]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let body = String(t[start...])
        guard let data = body.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return decodePoints(any)
    }

    static func decodePoints(_ any: Any) -> [Point]? {
        if let s = any as? String {
            if let inner = embedded(s) { return inner }                 // a point that is itself JSON, as a string
            let refs = refsIn(s, allowLeading: true)
            let text = stripCitations(s)
            guard let p = point(text, refs: refs) else { return nil }
            return [p]
        }
        if let arr = any as? [Any] {
            let pts = arr.compactMap(element)
            return pts.isEmpty ? nil : pts
        }
        if let dict = any as? [String: Any] { return points(fromObject: dict) }
        return nil
    }

    /// Shapes models actually use: {"points": [...]}, {"topics": [...]}, {"answer": "..."}, or one point object.
    static func points(fromObject dict: [String: Any]) -> [Point]? {
        let lists = ["points", "topics", "items", "notes", "bullets", "results", "answers", "highlights",
                     "key_points", "keyPoints", "takeaways", "list", "lines", "summary", "summaries"]
        for k in lists {
            if let v = dict[k], let p = decodePoints(v), !p.isEmpty { return p }
        }
        if let p = element(dict) { return [p] }
        for (_, v) in dict {
            if v is [Any], let p = decodePoints(v), !p.isEmpty { return p }
        }
        return nil
    }

    /// Models sometimes double-encode: an array whose items are strings containing JSON.
    static func embedded(_ s: String) -> [Point]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 2, t.hasPrefix("{") || t.hasPrefix("["),
              let d = t.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return nil }
        return decodePoints(inner)
    }

    static func element(_ any: Any) -> Point? {
        if let s = any as? String {
            if let pts = embedded(s), pts.count == 1 { return pts[0] }
            let refs = refsIn(s, allowLeading: true)
            return point(stripCitations(s), refs: refs)
        }
        if let pair = any as? [Any], pair.count == 2, let s = pair[0] as? String {
            return point(s, refs: parseRefs(pair[1]))
        }
        guard let d = any as? [String: Any] else { return nil }
        let textKeys = ["text", "point", "topic", "answer", "summary", "line", "sentence", "content",
                        "takeaway", "title", "note", "description", "desc", "value", "message"]
        var text: String?
        for k in textKeys {
            if let v = d[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = v; break }
        }
        guard var t = text else { return nil }
        let refKeys = ["refs", "ref", "citations", "citation", "messages", "message_ids", "messageIDs", "messageIds",
                       "sources", "source", "ids", "id", "numbers", "number", "indices", "note_numbers", "cites"]
        var refs: [Int] = []
        for k in refKeys {
            if let v = d[k] { refs = parseRefs(v); if !refs.isEmpty { break } }
        }
        if refs.isEmpty { refs = refsIn(t, allowLeading: true) }
        t = stripCitations(t)
        return point(t, refs: refs)
    }

    static func point(_ text: String, refs: [Int]) -> Point? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model echoing the transcript writes "[2] Me: yes, book flights [3]" — keep the numbers, drop the echo.
        var echoed = false
        while let m = t.range(of: #"^\[[0-9][0-9,\s]*\]\s*"#, options: .regularExpression) { echoed = true; t.removeSubrange(m) }
        if echoed, let m = t.range(of: #"^[A-Z][\p{L}'’.\-]*(?: [A-Z][\p{L}'’.\-]*){0,2}:\s+"#, options: .regularExpression) { t.removeSubrange(m) }
        t = t.replacingOccurrences(of: #"^(?:[-*•·]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"“”"))
        // "2, 4" is a citation list, not a point: a point has words.
        guard t.contains(where: { $0.isLetter }) else { return nil }
        return Point(text: t, refs: refs.filter { $0 > 0 && $0 < 100_000 })
    }

    /// Numbers from `[3]`, `[3, 4]`, `[#3]`, "3", [3, "4"] or [{"number": 3}].
    static func parseRefs(_ any: Any) -> [Int] {
        if let n = any as? NSNumber { return [n.intValue] }
        if let s = any as? String { return numbersIn(s) }
        if let arr = any as? [Any] { return arr.flatMap { parseRefs($0) } }
        if let d = any as? [String: Any] {
            for k in ["number", "id", "index", "ref", "message"] {
                if let v = d[k] { let r = parseRefs(v); if !r.isEmpty { return r } }
            }
        }
        return []
    }

    static func numbersIn(_ s: String) -> [Int] {
        var out: [Int] = []
        for token in s.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted) where !token.isEmpty {
            if let n = Int(token), n > 0, n < 100_000 { out.append(n) }
        }
        return Array(Set(out)).sorted()
    }

    /// Citation markers like `[3]` or `[3, 4]`, skipping a bare number at the start of a line (that is list numbering).
    static func refsIn(_ s: String, allowLeading: Bool) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\[([0-9][0-9,\s]*)\]"#) else { return [] }
        let ns = s as NSString
        var out: [Int] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if !allowLeading, m.range.location == 0 { continue }
            out += numbersIn(ns.substring(with: m.range(at: 1)))
        }
        return Array(Set(out)).sorted()
    }

    static func stripCitations(_ s: String) -> String {
        var t = replace(s, #"(\s*\[[0-9][0-9,\s]*\])+\s*[.!]?\s*$"#, "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }
}
