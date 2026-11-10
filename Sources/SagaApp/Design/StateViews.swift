import SwiftUI

/// The app's empty and error surfaces (DESIGN.md, App › "Empty and error states:
/// line-art illustration + one sentence + one button. No raw error strings.").
///
/// One illustration style, used everywhere: a soft accent plate, two hand-drawn
/// orbit strokes and the state's SF Symbol in the module gradient. Full size for
/// a detail pane, `compact` for a sidebar or a side panel.
///
/// Rules
/// - A state never shows a raw error string as its headline. Personalised,
///   plain-language copy is the headline; the technical text only appears behind
///   a "Details" disclosure, where it helps when someone reports a problem.
/// - Motion goes through `AppTheme.Motion` (`themeAnimation` /
///   `themeCrossfadeAnimation`), so Reduce Motion turns the spring into a short
///   cross-fade and nothing here animates on its own.
/// - Colours, radii, type and spacing all come from `AppTheme`.
struct StateIllustration: View {
    /// SF Symbol that names the state.
    let symbol: String
    /// Two or more colour stops, always a `Module` gradient or the error pair.
    var colors: [Color] = AppTheme.Module.chats.colors
    /// Diameter of the plate; the orbit rings add ~36% around it.
    var size: CGFloat = 92

    @State private var settled = false

    private var stroke: CGFloat { max(1, (size * 0.018).rounded()) }
    private var canvas: CGFloat { size * 1.38 }

    private var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            // Orbit: two open arcs, so the mark reads as drawn rather than geometric.
            Circle()
                .trim(from: 0.02, to: 0.40)
                .stroke(gradient, style: StrokeStyle(lineWidth: stroke * 1.7, lineCap: .round))
                .frame(width: size * 1.14, height: size * 1.14)
            Circle()
                .trim(from: 0.55, to: 0.88)
                .stroke(colors[0].opacity(0.34), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: size * 1.34, height: size * 1.34)

            // Plate and its hairline edge.
            Circle()
                .fill(LinearGradient(colors: colors.map { $0.opacity(0.14) },
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
            Circle()
                .strokeBorder(colors[0].opacity(0.22), lineWidth: stroke)
                .frame(width: size, height: size)

            // A quiet inner disc lifts the symbol off the wash.
            Circle()
                .fill(AppTheme.Surface.card.opacity(0.72))
                .frame(width: size * 0.68, height: size * 0.68)
            Image(systemName: symbol)
                .font(.system(size: size * 0.30, weight: .semibold))
                .foregroundStyle(gradient)
                .accessibilityHidden(true)

            // Two drawn dots on the orbit.
            Circle().fill(colors[0]).frame(width: stroke * 3.4, height: stroke * 3.4)
                .offset(x: size * 0.40, y: -size * 0.34)
            Circle().fill(colors[min(1, colors.count - 1)].opacity(0.7))
                .frame(width: stroke * 2.4, height: stroke * 2.4)
                .offset(x: -size * 0.50, y: size * 0.30)
        }
        .frame(width: canvas, height: canvas)
        .scaleEffect(settled ? 1 : 0.94)
        .opacity(settled ? 1 : 0)
        .themeCrossfadeAnimation(AppTheme.Motion.standard, value: settled)
        .onAppear { settled = true }
        .accessibilityHidden(true)
    }
}

/// A small hand-drawn underline used by the full-size empty state (DESIGN.md:
/// "small hand-drawn marks that stop it feeling corporate").
struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY, amp = rect.height / 2
        p.move(to: CGPoint(x: rect.minX, y: mid))
        p.addCurve(to: CGPoint(x: rect.midX, y: mid),
                   control1: CGPoint(x: rect.width * 0.24, y: mid - amp),
                   control2: CGPoint(x: rect.width * 0.24, y: mid + amp))
        p.addCurve(to: CGPoint(x: rect.maxX, y: mid),
                   control1: CGPoint(x: rect.width * 0.76, y: mid - amp),
                   control2: CGPoint(x: rect.width * 0.76, y: mid + amp))
        return p
    }
}

// MARK: - Empty state

/// An illustrated empty state: mark, headline, one sentence, at most one action.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var colors: [Color] = AppTheme.Module.chats.colors
    var actionTitle: String?
    var action: (() -> Void)?
    /// Sidebar / panel scale: smaller mark, shorter copy block, no squiggle.
    var compact = false

    var body: some View {
        VStack(spacing: compact ? AppTheme.Spacing.xs : AppTheme.Spacing.m) {
            StateIllustration(symbol: symbol, colors: colors, size: compact ? 56 : 92)
                .padding(.bottom, compact ? 0 : AppTheme.Spacing.xxs)
            Text(title)
                .font(compact ? AppTheme.Typography.section : AppTheme.Typography.title)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .multilineTextAlignment(.center)
            if !compact {
                Squiggle()
                    .stroke(AppTheme.Accent.primary.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 46, height: 5)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(compact ? AppTheme.Typography.caption : AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .multilineTextAlignment(.center)
                // No `.fixedSize(vertical:)`: with a maxWidth frame it makes the text
                // report a huge ideal height when SwiftUI measures at zero width, which
                // in a NavigationSplitView detail pane inflates the whole window.
                .frame(maxWidth: compact ? 230 : 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Accent.primaryFill)
                    .controlSize(compact ? .small : .regular)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
        }
        // Padding goes inside the flexible frame: a frame that claims all the space
        // and then adds padding reports an ever-growing ideal size to a split view.
        .padding(compact ? AppTheme.Spacing.m : AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Error state

/// The failure variant: same illustration in the error pair, plain-language
/// headline, the next step, and a retry. Technical text stays behind "Details".
struct ErrorStateView: View {
    let title: String
    let message: String
    /// The raw error, shown only when the person asks for it.
    var detail: String?
    var retryTitle = "Try again"
    var retry: (() -> Void)?
    var compact = false

    @State private var showDetail = false

    private var colors: [Color] { [AppTheme.Feedback.error, AppTheme.Feedback.error.opacity(0.72)] }

    var body: some View {
        VStack(spacing: compact ? AppTheme.Spacing.xs : AppTheme.Spacing.m) {
            StateIllustration(symbol: "exclamationmark.triangle", colors: colors, size: compact ? 56 : 92)
            Text(title)
                .font(compact ? AppTheme.Typography.section : AppTheme.Typography.title)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(compact ? AppTheme.Typography.caption : AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: compact ? 230 : 340)
            if let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Accent.primaryFill)
                    .controlSize(compact ? .small : .regular)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
            if let detail, !detail.isEmpty {
                Button(showDetail ? "Hide details" : "Details") { showDetail.toggle() }
                    .buttonStyle(.plain)
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Accent.text)
                    .help("Show the technical message")
                if showDetail {
                    Text(detail)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: compact ? 230 : 380)
                }
            }
        }
        .themeCrossfadeAnimation(AppTheme.Motion.quick, value: showDetail)
        .padding(compact ? AppTheme.Spacing.m : AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Inline banners

/// A one-line status strip for failures that belong to a pane rather than to the
/// whole window: a wash, a symbol, plain copy, and the next step.
struct StatusBanner: View {
    enum Level { case warning, error, success
        var tint: Color {
            switch self {
            case .warning: AppTheme.Feedback.warning
            case .error: AppTheme.Feedback.error
            case .success: AppTheme.Feedback.success
            }
        }
        var wash: Color {
            switch self {
            case .warning: AppTheme.Feedback.warningWash
            case .error: AppTheme.Feedback.errorWash
            case .success: AppTheme.Surface.accentWash
            }
        }
        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .success: "checkmark.circle.fill"
            }
        }
    }

    var level: Level = .warning
    let message: String
    var retryTitle: String?
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
            Image(systemName: level.symbol)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(level.tint)
                .accessibilityHidden(true)
            Text(message)
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppTheme.Spacing.xs)
            if let retryTitle, let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(.plain)
                    .font(AppTheme.Typography.callout.weight(.semibold))
                    .foregroundStyle(level.tint)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
        .background(AppTheme.Radius.controlShape.fill(level.wash))
        .overlay(AppTheme.Radius.controlShape.strokeBorder(level.tint.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
