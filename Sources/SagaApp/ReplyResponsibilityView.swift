import SwiftUI
import SagaCore

/// State for one presentation of the reply sheet. Everything is recomputed on an explicit
/// Scan, held by UID, and thrown away when the sheet closes: no cache, no stored names.
@MainActor @Observable
final class ReplyResponsibilityModel {
    var quietDays = ReplyResponsibility.defaultQuietDays
    /// How far back a question may be asked and still be worth showing.
    var windowMonths = ReplyResponsibility.defaultWindowMonths
    var results: [ReplyCandidate] = []
    /// Unanswered questions the window left out — counted so the sheet can say so.
    var beyondWindow = 0
    var windowStart: Date?
    var scanning = false
    var hasScanned = false
    var message = ""
    var error = ""

    /// Questions handled on this Mac. The archive is never touched and the list is
    /// reversible, so "I answered this on my phone" has somewhere to go until the next
    /// import brings the reply in. Stored per Mac, not in the vault.
    private(set) var dismissed: Set<String> = []
    /// The last row dismissed, so Undo can name it.
    private(set) var lastDismissed: (uid: String, name: String)?
    private static let dismissedKey = "replyDismissedUIDs"
    private var task: Task<Void, Never>?
    private var run = UUID()

    /// What the sheet draws: the candidates that have not been dismissed.
    var visible: [ReplyCandidate] { results.filter { !dismissed.contains($0.id) } }

    /// Newest first, under the heading that says how old the question is.
    enum Bucket: String, CaseIterable, Identifiable {
        case week = "This week", month = "This month", earlier = "Earlier"
        var id: String { rawValue }
    }

    struct Group: Identifiable {
        let bucket: Bucket
        let rows: [ReplyCandidate]
        var id: String { bucket.rawValue }
    }

    func buckets(now: Date = Date()) -> [Group] {
        var cal = Calendar.current
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        var out: [Bucket: [ReplyCandidate]] = [:]
        for c in visible.sorted(by: { $0.questionDate > $1.questionDate }) {
            let age = now.timeIntervalSince(c.questionDate)
            let bucket: Bucket
            if age <= 7 * 86_400 { bucket = .week }
            else if cal.isDate(c.questionDate, equalTo: now, toGranularity: .month) || age <= 31 * 86_400 { bucket = .month }
            else { bucket = .earlier }
            out[bucket, default: []].append(c)
        }
        return Bucket.allCases.compactMap { b in out[b].map { Group(bucket: b, rows: $0) } }
    }

    func loadDismissed() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    /// Marks one question handled and keeps an undo target.
    func dismiss(_ candidate: ReplyCandidate) {
        dismissed.insert(candidate.id)
        lastDismissed = (candidate.id, candidate.chatName)
        saveDismissed()
    }

    func undoDismiss() {
        guard let last = lastDismissed else { return }
        dismissed.remove(last.uid)
        lastDismissed = nil
        saveDismissed()
    }

    private func saveDismissed() {
        var list = Array(dismissed)
        if list.count > 2_000 { list = Array(list.suffix(2_000)) }
        UserDefaults.standard.set(list, forKey: Self.dismissedKey)
    }

    /// Reads every chat's last word on a private connection, off the main thread, and keeps
    /// the result only if it still belongs to this scan and this library generation.
    func scan(app: AppModel, now: Date = Date()) {
        guard app.store != nil else {
            results = []
            message = "Open or create an archive first."
            return
        }
        guard !scanning else { return }
        let path = app.indexURL.path
        let days = quietDays
        let months = windowMonths
        let stamp = Self.indexStamp(path)
        let id = UUID()
        run = id
        scanning = true; message = ""; error = ""
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (found: ReplyScan?, failure: String?) in
                do {
                    let fresh = try VaultStore(path: path)
                    return (try ReplyResponsibility.find(store: fresh, quietDays: days, windowMonths: months, now: now), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            guard run == id else { return }
            scanning = false
            guard let found = outcome.found else {
                results = []
                error = "Couldn't read your archive: \(outcome.failure ?? "unknown error"). Rebuild your library and try again."
                return
            }
            guard Self.indexStamp(path) == stamp else {
                results = []
                message = "Your library was rebuilt while this ran, so the result was discarded. Press Scan again."
                return
            }
            results = found.candidates
            beyondWindow = found.beyondWindow
            windowStart = found.windowStart
            hasScanned = true
        }
    }

    func stop() {
        run = UUID()
        task?.cancel()
        scanning = false
        message = "Stopped."
    }

    /// Resolves the question's UID against the current index so a rebuilt library still lands
    /// on the right message, and refuses to jump to a row id that no longer exists.
    func open(_ candidate: ReplyCandidate, app: AppModel) -> Bool {
        guard let store = app.store, let hit = (try? store.resolve(uids: [candidate.id]))?[candidate.id] else {
            message = "That question isn't in your library any more. Press Scan to refresh the list."
            return false
        }
        app.jump(toMessage: hit.id, in: hit.chatID)
        return true
    }

    func close() {
        run = UUID()
        task?.cancel()
    }

    /// File identity and modification time: enough to notice a rebuild replacing the index.
    nonisolated private static func indexStamp(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let ino = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(ino)|\(size)|\(mtime)"
    }
}

/// "Might need your reply": the questions in one-to-one chats that the archive shows are
/// still unanswered, quiet for a threshold the person chooses. Deterministic and local —
/// no model is involved, and the copy never claims the other person owes anything.
struct ReplyResponsibilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var replies = ReplyResponsibilityModel()

    var body: some View {
        @Bindable var r = replies
        VStack(spacing: 0) {
            header
            Hairline()
            controls
            Hairline()
            ruleNote
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(minWidth: 660, minHeight: 520)
        .background(AppTheme.Surface.page)
        .onAppear { replies.loadDismissed(); replies.scan(app: model) }
        .onChange(of: replies.quietDays) { _, _ in replies.scan(app: model) }
        .onChange(of: replies.windowMonths) { _, _ in replies.scan(app: model) }
        .onDisappear {
            replies.close()
            // Home's card counts the same rule; recount now so a dismissal shows there too.
            model.replyWaitingCount = nil
            model.loadReplyWaitingCount()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.primaryFill)
            VStack(alignment: .leading, spacing: 2) {
                Text("Might need your reply").font(AppTheme.Typography.title)
                // The order is stated once, in the rule note below, with the window and the
                // threshold it depends on. Saying "newest first" here said it twice.
                Text(countLine)
                    .font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
            }
            Spacer()
            LocalOnlyBadge()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.vertical, AppTheme.Spacing.l)
    }

    /// "3 questions · last 6 months", counted against what is on screen after dismissals.
    private var countLine: String {
        if replies.scanning { return "Reading the last message in each chat…" }
        guard replies.hasScanned else { return "Questions in your one-to-one chats that your archive shows unanswered." }
        let n = replies.visible.count
        let questions = n == 1 ? "1 question" : "\(n.formatted()) questions"
        return "\(questions) · \(windowPhrase)"
    }

    private var controls: some View {
        @Bindable var r = replies
        return HStack(spacing: AppTheme.Spacing.m) {
            // A menu, not a stepper: the threshold is a choice between a few sensible
            // waits, and a stepper made it look like a value worth tuning by one.
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Quiet at least").font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Picker("Quiet at least", selection: $r.quietDays) {
                    ForEach(Self.quietChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .disabled(replies.scanning)

            Divider().frame(height: 18)

            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Asked within").font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Picker("Asked within", selection: $r.windowMonths) {
                    ForEach(ReplyResponsibility.windowMonthOptions, id: \.self) { months in
                        Text(Self.windowLabel(months)).tag(months)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .disabled(replies.scanning)

            Spacer()
            if replies.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning archived chats…").font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
                Button("Stop") { replies.stop() }
            } else {
                Button(replies.hasScanned ? "Refresh" : "Scan") { replies.scan(app: model) }
                    .buttonStyle(.bordered)
                    .disabled(model.store == nil)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.vertical, AppTheme.Spacing.m)
        .background(AppTheme.Surface.bar)
    }

    private static let quietChoices = [2, 3, 7, 14]

    /// The rule, in plain words, always on screen: what is listed, in what order, and why
    /// an unanswered question eventually stops being listed at all.
    private var ruleNote: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            Image(systemName: "info.circle")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textTertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Questions from \(windowPhrase), newest first.")
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text("A chat is listed only when its latest archived message is their question and it has been quiet at least \(quietPhrase). A chat quiet for longer than the window is treated as history, not as a reply you owe.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if replies.beyondWindow > 0 {
                    Text(replies.beyondWindow == 1
                         ? "1 older unanswered question sits outside this window."
                         : "\(replies.beyondWindow) older unanswered questions sit outside this window.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Feedback.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.vertical, AppTheme.Spacing.s)
        .background(AppTheme.Surface.page)
    }

    private var windowPhrase: String {
        replies.windowMonths == 1 ? "the last month" : "the last \(replies.windowMonths) months"
    }

    private var quietPhrase: String {
        replies.quietDays == 1 ? "1 day" : "\(replies.quietDays) days"
    }

    static func windowLabel(_ months: Int) -> String {
        months == 1 ? "the last month" : "the last \(months) months"
    }

    @ViewBuilder private var content: some View {
        if !replies.error.isEmpty {
            emptyState(title: "Couldn't check your archive", detail: replies.error, warning: true)
        } else if replies.scanning && replies.results.isEmpty {
            emptyState(title: "Reading the last message in each chat…", detail: "This reads one row per chat, never the whole history.", warning: false)
        } else if replies.results.isEmpty {
            emptyState(title: "Nothing in \(windowPhrase) matches this rule",
                       detail: replies.message.isEmpty
                        ? "That is not the same as everyone having replied: this only sees the messages your archive holds. Group chats, channels and chats without a known person are left out."
                        : replies.message,
                       warning: false)
        } else if replies.visible.isEmpty {
            // Everything the scan found has been dismissed. Say so, and offer the way back:
            // a list that empties itself with no explanation looks like a bug.
            dismissedEmptyState
        } else {
            list
        }
    }

    private var dismissedEmptyState: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "checkmark.bubble")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(AppTheme.Surface.textTertiary)
            Text(replies.results.count == 1
                 ? "The one question here is marked handled."
                 : "All \(replies.results.count) questions here are marked handled.")
                .font(AppTheme.Typography.section).foregroundStyle(AppTheme.Surface.textPrimary)
            Text("Nothing was removed from your archive. This list is the only place the mark lives.")
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let last = replies.lastDismissed {
                Button("Bring back \(last.name)") { replies.undoDismiss() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.gutter)
        .background(AppTheme.Surface.page)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                if !replies.message.isEmpty {
                    Text(replies.message).font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Feedback.warning)
                }
                if let last = replies.lastDismissed {
                    HStack(spacing: AppTheme.Spacing.s) {
                        Image(systemName: "checkmark.circle")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Accent.text)
                        Text("\(last.name) marked handled.")
                            .font(AppTheme.Typography.callout)
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                        Button("Undo") { replies.undoDismiss() }
                            .buttonStyle(.link)
                            .font(AppTheme.Typography.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.s)
                }
                ForEach(replies.buckets()) { group in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Text(group.bucket.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(AppTheme.Surface.textTertiary)
                        ForEach(group.rows) { candidate in
                            row(candidate)
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.gutter)
        }
    }

    /// Name and age on the first line, the question in primary text on the second, and the
    /// two things a person can do on the right. The old row spent its first line saying the
    /// same date twice and left the question as the smallest type on the card.
    private func row(_ candidate: ReplyCandidate) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(candidate.chatName)
                        .font(AppTheme.Typography.rowName)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .lineLimit(1)
                    Text("· asked \(Self.relative(candidate.questionDate))")
                        .font(AppTheme.Typography.rowMeta)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(1)
                }
                Text("“\(candidate.preview)”")
                    .font(AppTheme.Typography.rowPreview)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.s)
            HStack(spacing: AppTheme.Spacing.xs) {
                // The button jumps to the message, so it says so: "Open chat" promised a
                // different place from the one it landed on.
                Button("Show in chat") {
                    if replies.open(candidate, app: model) { dismiss() }
                }
                .buttonStyle(.bordered)
                .help("Jump to their question in the conversation")
                Button("Dismiss") { replies.dismiss(candidate) }
                    .buttonStyle(.plain)
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .help("Mark it handled on this Mac. Your archive is not changed.")
            }
            .fixedSize()
        }
        .padding(AppTheme.Spacing.cardPadding)
        .background(AppTheme.Surface.card, in: AppTheme.Radius.cardShape)
        .overlay(AppTheme.Radius.cardShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
    }

    /// "yesterday", "8 days ago", "2 months ago" — one fact, said once.
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func emptyState(title: String, detail: String, warning: Bool) -> some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: warning ? "exclamationmark.triangle" : "checkmark.bubble")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(warning ? AppTheme.Feedback.warning : AppTheme.Surface.textTertiary)
            Text(title).font(AppTheme.Typography.section).foregroundStyle(AppTheme.Surface.textPrimary)
            Text(detail)
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.gutter)
        .background(AppTheme.Surface.page)
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textTertiary)
            Text("Based on archived messages only. An old backup can't show what you've answered since. Nothing is sent, and nothing is scheduled.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.vertical, AppTheme.Spacing.m)
        .background(AppTheme.Surface.bar)
    }
}
