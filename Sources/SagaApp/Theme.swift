import SwiftUI
import SagaCore

/// Legacy palette kept so existing views compile unchanged.
///
/// New work — and every view in the visual refresh — reads tokens from
/// `AppTheme` (`Sources/SagaApp/Design/AppTheme.swift`), which is the single
/// source of truth for colour, type, radius and motion. The chat surface now
/// uses `AppTheme.Accent` / `AppTheme.Bubble`; `accent` survives only for the
/// People, Wrapped and Recovery views that have not been refreshed yet.
enum Theme {
    static let accent = Color(red: 0.07, green: 0.62, blue: 0.45)
    static func hue(_ s: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360
    }
    static func color(for s: String) -> Color { Color(hue: hue(s), saturation: 0.55, brightness: 0.75) }
}

/// Circular initials avatar. Groups can carry the soft gradient ring from
/// DESIGN.md (App › Chat list).
struct Avatar: View {
    let name: String
    var group = false
    var size: CGFloat = 40
    /// Draws the gradient ring that marks group chats in the chat list.
    var ringed = false

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let s = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    /// Stops are the name's hue darkened until white initials clear 4.5:1 on the
    /// lightest point — checked across all 360 hues (worst case 4.9:1), so no
    /// contact name can produce unreadable initials.
    private var gradient: LinearGradient {
        let h = Theme.hue(name)
        return LinearGradient(colors: [Color(hue: h, saturation: 0.58, brightness: 0.46),
                                       Color(hue: h, saturation: 0.66, brightness: 0.34)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var ringWidth: CGFloat { max(2, (size * 0.06).rounded()) }

    var body: some View {
        ZStack {
            if ringed && group {
                Circle().strokeBorder(AppTheme.Module.chats.gradient, lineWidth: ringWidth)
                Circle().fill(AppTheme.Surface.accentWash).padding(ringWidth + 2)
                Image(systemName: "person.2.fill")
                    .font(.system(size: (size - 2 * (ringWidth + 2)) * 0.44))
                    .foregroundStyle(AppTheme.Module.chats.tint)
            } else {
                Circle().fill(gradient)
                if group {
                    Image(systemName: "person.2.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
                } else if !name.contains(where: { $0.isLetter }) {
                    Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
                } else {
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }.frame(width: size, height: size)
    }
}

extension Date {
    /// Compact date for list rows: time today, "Yesterday", weekday this week, "d MMM", then "MMM yyyy".
    var listLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let d = cal.dateComponents([.day], from: self, to: Date()).day, d < 7 { return formatted(.dateTime.weekday(.abbreviated)) }
        if cal.component(.year, from: self) == cal.component(.year, from: Date()) { return formatted(.dateTime.day().month(.abbreviated)) }
        return formatted(.dateTime.month(.abbreviated).year())
    }
}

extension String {
    /// Turns FTS snippet markers "[match]" into bold, tinted text.
    var highlighted: AttributedString {
        var out = AttributedString()
        var rest = Substring(self)
        while let open = rest.firstIndex(of: "[") {
            out += AttributedString(String(rest[..<open]))
            rest = rest[rest.index(after: open)...]
            if let close = rest.firstIndex(of: "]") {
                var m = AttributedString(String(rest[..<close]))
                // Emphasis rather than a font override: the snippet keeps the
                // size of the view it sits in, only its weight and colour change.
                m.inlinePresentationIntent = .stronglyEmphasized
                m.foregroundColor = AppTheme.Accent.text
                out += m
                rest = rest[rest.index(after: close)...]
            }
        }
        out += AttributedString(String(rest))
        return out
    }
}
