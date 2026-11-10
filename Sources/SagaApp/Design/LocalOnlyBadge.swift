import SwiftUI

/// The mint "Local only" pill from `docs/DESIGN.md` (App › Sidebar).
///
/// It sits in a status line, so it has a fixed 18pt height and never grows the
/// row it lives in: the badge can appear, disappear or change its accessibility
/// label without moving anything around it.
///
/// Colour comes from `AppTheme.Badge`, which resolves per appearance — 9.0:1 in
/// light, 9.7:1 in dark — so the label stays readable in both.
struct LocalOnlyBadge: View {
    /// Height the badge always occupies; callers reserve the same height in
    /// their status line so nothing jumps when the badge is shown.
    static let height: CGFloat = 18

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Local only")
                .font(AppTheme.Typography.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AppTheme.Badge.localOnlyText)
        .padding(.horizontal, AppTheme.Spacing.s)
        .frame(height: Self.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(AppTheme.Badge.localOnlyFill))
        .overlay(Capsule().strokeBorder(AppTheme.Badge.localOnlyBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Local only. Nothing leaves this Mac.")
        .help("Everything stays on this Mac. Nothing is uploaded.")
    }
}

/// The thin gradient rule that closes the sidebar header (DESIGN.md: App › Sidebar).
struct SidebarRule: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.Module.sidebarRule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A quiet hairline used between rows and panes.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.Surface.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
