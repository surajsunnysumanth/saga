import Foundation

/// Local, literal vocabulary settings. Custom phrases are never interpreted as regexes.
public struct WrappedReactionConfiguration: Codable, Sendable {
    public enum Language: String, Codable, Sendable { case english, hinglish }
    public var languages: Set<Language> = [.english, .hinglish]
    public var emojiEnabled = true
    public var additionalLaughPhrases: [String] = []
    public var additionalLikePhrases: [String] = []
    public var excludedPhrases: [String] = []
    public var suppressSarcasm = true
    public init() {}

    /// Missing/invalid settings retain safe defaults. No settings or messages leave the device.
    public static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
}

public struct WrappedReactionDetector: Sendable {
    public let configuration: WrappedReactionConfiguration
    public init(configuration: WrappedReactionConfiguration = .init()) { self.configuration = configuration }

    private static let urls = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+"#, options: .caseInsensitive)
    private static let laughter = try! NSRegularExpression(pattern: #"\b(?:(?:h+a+){2,}h*|(?:h+e+){2,}h*|lo+l+|lm(?:f+)?a+o+|rofl+)\b"#, options: .caseInsensitive)
    private static let sarcasm = try! NSRegularExpression(pattern: #"(?:^|\s)/s\b|#sarcasm\b|\b(?:yeah right|not funny|not laughing|not hilarious|isn't funny|is not funny)\b|🙄"#, options: .caseInsensitive)
    private static let negative = try! NSRegularExpression(pattern: #"\b(?:not|never|don't|dont|do not|isn't|isnt|wasn't|wasnt|hate|dislike|nahi|nahin)\b"#, options: .caseInsensitive)

    /// The one laugh-emoji vocabulary: used for emoji typed inside a message *and* for
    /// WhatsApp reactions on a message. Skin tones and the emoji presentation selector are
    /// stripped before the lookup, so "☠️" and "☠" are the same laugh, and a 👍 with any
    /// skin tone stays a 👍 — never a laugh.
    public static let laughEmoji: Set<Character> = ["😂", "🤣", "😆", "😄", "😹", "💀", "☠", "🥹"]

    /// The love vocabulary, kept apart from the laugh vocabulary on purpose: a ❤️ on a
    /// message is affection, not a punchline, so the two are counted as different things.
    /// The same normalisation applies — "❤️" and "❤" are one heart, and a 👍 never counts.
    public static let heartEmoji: Set<Character> = ["❤", "😍", "🥰", "😘", "💕", "💖", "💗"]

    /// Removes variation selectors and skin-tone modifiers so one emoji has one spelling.
    public static func normalizedEmoji(_ emoji: String) -> String {
        String(emoji.unicodeScalars.filter { scalar in
            scalar.value != 0xFE0F && scalar.value != 0xFE0E && !(0x1F3FB...0x1F3FF).contains(scalar.value)
        }.map(Character.init))
    }

    public static func isLaughEmoji(_ emoji: String) -> Bool {
        let normalized = normalizedEmoji(emoji)
        return normalized.contains { laughEmoji.contains($0) }
    }

    /// True for one emoji from the heart family, and never for a laugh or a 👍.
    public static func isHeartEmoji(_ emoji: String) -> Bool {
        guard !isLaughEmoji(emoji) else { return false }
        let normalized = normalizedEmoji(emoji)
        return normalized.contains { heartEmoji.contains($0) }
    }

    private func text(_ input: String) -> String {
        let unquoted = input.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: " ")
        return Self.urls.stringByReplacingMatches(in: unquoted, range: NSRange(unquoted.startIndex..., in: unquoted), withTemplate: " ").lowercased()
    }
    private func has(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private func contains(_ phrase: String, in text: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: phrase.lowercased()) + #"(?![\p{L}\p{N}_])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    private func excluded(_ text: String) -> Bool {
        (configuration.suppressSarcasm && has(Self.sarcasm, text)) || configuration.excludedPhrases.contains { contains($0, in: text) }
    }
    public func laughScore(_ input: String) -> Int {
        let t = text(input)
        guard !excluded(t) else { return 0 }
        var score = 0
        if configuration.languages.contains(.english) {
            for match in Self.laughter.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                let count = (t as NSString).substring(with: match.range).count
                score += count >= 7 ? 3 : count >= 4 ? 2 : 1
            }
        }
        if configuration.languages.contains(.hinglish) {
            for phrase in ["hasi aa gayi", "hassi aa gayi", "has has ke", "हाहाहा", "हाहाहाहा"] where contains(phrase, in: t) { score += 2 }
        }
        for phrase in configuration.additionalLaughPhrases where contains(phrase, in: t) { score += 2 }
        if configuration.emojiEnabled {
            let plain = Self.normalizedEmoji(t)
            score += plain.filter { Self.laughEmoji.contains($0) }.count
        }
        return min(score, 6)
    }
    public func likes(_ input: String) -> Bool {
        let t = text(input)
        guard !excluded(t), !has(Self.negative, t) else { return false }
        // Collapsing repeats on BOTH vocabulary and input handles "soooo gooood" and "loveee".
        func folded(_ s: String) -> String {
            var out = "", last: Character?
            for c in s { if c != last || !c.isLetter { out.append(c) }; last = c }
            return out
        }
        var phrases = configuration.additionalLikePhrases
        if configuration.languages.contains(.english) {
            phrases += ["love", "loved", "loves", "fire", "banger", "slap", "slaps", "vibe", "vibes", "obsessed", "on repeat", "so good", "amazing", "goated", "perfect", "insane", "beautiful", "masterpiece", "gem", "great song", "great one", "great track", "best"]
        }
        if configuration.languages.contains(.hinglish) { phrases += ["mast", "ekdum mast", "zabardast", "badiya", "badhiya", "kya baat", "बहुत बढ़िया", "मस्त"] }
        let normalized = folded(t)
        if phrases.contains(where: { contains(folded($0.lowercased()), in: normalized) }) { return true }
        return configuration.emojiEnabled && t.contains { ["🔥", "❤️", "❤", "😍", "🎶", "🙌", "🤌", "🥹", "💯", "🎧"].contains(String($0)) }
    }
}
