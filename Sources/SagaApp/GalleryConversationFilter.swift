import SwiftUI
import SagaCore

/// The Gallery's conversation filter: a chip that becomes a search field. The archive holds
/// thousands of chats, so a menu of every one of them is neither usable nor cheap to build;
/// typing narrows the list to a handful of rows and an empty field means "All conversations".
struct GalleryConversationFilter: View {
    /// Built once per chat list, not per keystroke.
    let index: ChatFilterIndex?
    let selection: Int64?
    let onPick: (Int64?) -> Void

    @State private var expanded = false
    @State private var query = ""
    @FocusState private var focused: Bool

    /// Snapshot runs need the open, mid-typing state to photograph; nothing else sets these.
    private static var seedQuery: String? {
        let env = ProcessInfo.processInfo.environment
        guard let q = env["SAGA_GALLERY_FILTER_QUERY"], !q.isEmpty else { return nil }
        return q
    }

    private var matches: [ChatFilterIndex.Entry] {
        index?.matches(query, limit: 8) ?? []
    }

    private var selectedName: String? {
        guard let selection else { return nil }
        return index?.name(for: selection)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            control
            if expanded, !matches.isEmpty {
                results.offset(y: 31)
            } else if expanded, !trimmed.isEmpty, matches.isEmpty {
                noMatches.offset(y: 31)
            }
        }
        .zIndex(2)
        .onAppear(perform: seed)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: control

    @ViewBuilder private var control: some View {
        if expanded {
            field
        } else {
            Button { expand() } label: { FilterChip(text: selectedName ?? "All conversations", active: selection != nil) }
                .buttonStyle(.plain)
                .help("Filter by conversation")
                .accessibilityLabel("Filter by conversation. Currently \(selectedName ?? "all conversations")")
        }
    }

    private var field: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Surface.textTertiary)
            TextField("Search conversations", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .focused($focused)
                .frame(width: 168)
                .onSubmit { pickFirst() }
                .onExitCommand { clear() }
            if !trimmed.isEmpty || selection != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                }
                .buttonStyle(.plain)
                .help(trimmed.isEmpty ? "Show every conversation" : "Clear the search")
                .accessibilityLabel("Clear conversation filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            Capsule().fill(AppTheme.Glass.fill.opacity(0.12))
                .overlay(Capsule().strokeBorder(AppTheme.Glass.fill.opacity(0.22), lineWidth: 1))
        }
    }

    // MARK: results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selection != nil {
                row(title: "All conversations", detail: nil, active: false) { onPick(nil); collapse() }
                Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
                    .padding(.horizontal, 8)
            }
            ForEach(matches) { entry in
                row(title: entry.name,
                    detail: numberLabel(entry),
                    active: entry.id == selection) {
                    onPick(entry.id)
                    collapse()
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 236, alignment: .leading)
        .cardSurface(radius: 10)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation matches")
    }

    private var noMatches: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
            Text("No conversation matches “\(trimmed)”")
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(AppTheme.Surface.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 236, alignment: .leading)
        .cardSurface(radius: 10)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func row(title: String, detail: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                        .monospacedDigit()
                }
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(active ? AppTheme.Surface.selection.opacity(0.5) : .clear)
    }

    /// A number only when the row's name does not already carry one: the filter matches
    /// digits, so the digits it matched should be visible.
    private func numberLabel(_ entry: ChatFilterIndex.Entry) -> String? {
        let user = entry.jid.split(separator: "@").first.map(String.init) ?? ""
        let digits = user.filter(\.isNumber)
        guard digits.count >= 6, !entry.name.filter(\.isNumber).contains(digits.suffix(4)) else { return nil }
        return "+" + digits
    }

    // MARK: actions

    private func seed() {
        guard let q = Self.seedQuery else { return }
        query = q
        expanded = true
        focused = true
    }

    private func expand() {
        expanded = true
        query = ""
        focused = true
    }

    private func collapse() {
        expanded = false
        query = ""
        focused = false
    }

    private func clear() {
        if trimmed.isEmpty {
            onPick(nil)
            collapse()
        } else {
            query = ""
            focused = true
        }
    }

    private func pickFirst() {
        guard let first = matches.first else { return }
        onPick(first.id)
        collapse()
    }
}
