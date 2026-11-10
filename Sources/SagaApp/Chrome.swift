import SwiftUI

/// The window's chrome: five places in a pill at the top, one search field, one Ask
/// pill, and a field of light for everything to sit on. Ported from the chrome mockup
/// (`docs/mockups/chrome-opus/`), whose NOTES carries the values used here.
enum Place: String, CaseIterable, Identifiable {
    case home = "Home"
    case chats = "Chats"
    case gallery = "Gallery"
    case insights = "Insights"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .chats: "bubble.left.and.bubble.right"
        case .gallery: "square.grid.2x2"
        case .insights: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

/// One radial light behind everything, a second at the trailing corner, over a soft base.
struct FieldBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppTheme.Field.baseTop, AppTheme.Field.baseBottom],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                let size = proxy.size
                RadialGradient(
                    colors: [AppTheme.Field.glow.opacity(scheme == .dark ? 0.78 : AppTheme.Field.glowStrengthLight), .clear],
                    center: UnitPoint(x: 0.16, y: -0.16),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.62)
                RadialGradient(
                    colors: [AppTheme.Field.warmGlowLight.opacity(scheme == .dark ? 0.10 : 0.55), .clear],
                    center: UnitPoint(x: 0.72, y: 0.18),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.55)
                RadialGradient(
                    colors: [AppTheme.Field.glowTrailing.opacity(scheme == .dark ? 0.16 : 0.08), .clear],
                    center: UnitPoint(x: 1.05, y: 1.1),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}


/// A real vibrancy blur behind the content — the difference between "glass" and a
/// grey rectangle. `ultraThinMaterial` already carries its own tint, so the fill we
/// add on top must stay light or the panel turns opaque.
struct VibrancyBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// `.withinWindow` samples what this app draws — the field — instead of the desktop
    /// behind the window, which is the difference between real glass and a grey slab.
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blending; v.state = .active
    }
}

/// Glass: vibrancy, a light tint, hairline, top highlight, and a soft cast shadow.
struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = AppTheme.Radius.card

    /// A translucent fill over the field is what glass *is* here: the field is a smooth
    /// gradient, so showing it through a 7% panel already reads as blurred light. Stacking
    /// a system material on top was what turned every panel opaque.
    private var fillOpacity: Double { scheme == .dark ? 0.07 : 0.55 }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(AppTheme.Glass.fill.opacity(fillOpacity))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(scheme == .dark ? 0.045 : 0.35), .clear],
                                startPoint: .top, endPoint: .bottom)
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.16 : 0.95), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 1)
                    .padding(.horizontal, radius * 0.45)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.07), radius: 22, y: 12)
    }
}

extension View {
    func glassSurface(radius: CGFloat = AppTheme.Radius.card) -> some View {
        modifier(GlassSurface(radius: radius))
    }
}

/// A glass panel: one level deep, hairline, top inner highlight.
struct GlassPanel<Content: View>: View {
    var radius: CGFloat = AppTheme.Radius.card
    var padding: CGFloat = AppTheme.Spacing.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassSurface(radius: radius)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    private let controlHeight: CGFloat = 32

    /// Below this the labelled bar no longer fits with a real gap between the place
    /// capsule and the trailing controls (their own widths are ~350 + ~430). The bar
    /// collapses here instead of painting one control under another: the place chips
    /// lose their words, the search well becomes a button, and Ask keeps its word
    /// because it is the one control that has no second door.
    private let compactWidth: CGFloat = 1080

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < compactWidth
            Group {
                if compact {
                    // One row, laid out left to right: nothing can overlap because nothing
                    // is positioned independently of anything else.
                    HStack(spacing: AppTheme.Spacing.s) {
                        places(compact: true)
                        Spacer(minLength: AppTheme.Spacing.s)
                        if model.phone != .absent { PhonePill(height: controlHeight, compact: true) }
                        SearchPill(height: controlHeight, compact: true)
                        AskPill(height: controlHeight, compact: true)
                    }
                } else {
                    // Wide: the places stay optically centred, which is the approved chrome.
                    ZStack {
                        places(compact: false)
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            PhonePill(height: controlHeight)
                            SearchPill(height: controlHeight)
                            AskPill(height: controlHeight)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .frame(height: 60)
    }

    /// The five places in one capsule. In the compact bar every chip keeps its symbol and
    /// only the current place keeps its word, so the bar still says where you are.
    private func places(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Place.allCases) { place in
                PlaceChip(place: place, selected: model.place == place, compact: compact) { model.go(to: place) }
            }
        }
        .padding(4)
        .background {
            Capsule().fill(AppTheme.Glass.fill.opacity(scheme == .dark ? 0.07 : 0.55))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1))
                .overlay(alignment: .top) {
                    Capsule().fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.14 : 0.9), .clear],
                                                  startPoint: .top, endPoint: .bottom))
                        .frame(height: 1).padding(.horizontal, 14)
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.05), radius: 12, y: 6)
        }
        .fixedSize()
    }

    private struct PlaceChip: View {
        let place: Place
        let selected: Bool
        var compact = false
        let action: () -> Void
        @State private var hovering = false

        private var showsWord: Bool { !compact || selected }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if compact {
                        Image(systemName: place.symbol)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    if showsWord {
                        Text(place.rawValue)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(selected ? AppTheme.Accent.onAccent : (hovering ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary))
                .padding(.horizontal, compact && !selected ? 8 : 13)
                .frame(minWidth: compact && !selected ? 30 : 0, minHeight: 24)
                .background {
                    if selected {
                        Capsule()
                            .fill(AppTheme.Palette.teal)
                            .overlay(
                                Capsule().fill(
                                    LinearGradient(colors: [.white.opacity(0.16), .clear],
                                                   startPoint: .top, endPoint: .bottom))
                            )
                            .shadow(color: AppTheme.Palette.teal.opacity(0.35), radius: 14, y: 4)
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(place.rawValue)
            .accessibilityLabel(place.rawValue)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }


    /// The corner light: whether a cable is offering a backup and the phone's photos.
    private struct PhonePill: View {
        @Environment(AppModel.self) private var model
        @Environment(\.colorScheme) private var scheme
        let height: CGFloat
        var compact = false

        var body: some View {
            Menu {
                switch model.phone {
                case .absent:
                    Text("Plug the phone in and allow USB debugging.")
                case .unauthorised:
                    Text("Accept “Allow USB debugging?” on the phone.")
                case let .connected(model, android):
                    Text("\(model) · Android \(android)")
                    Button("Pull a new backup…") { self.model.updateFromPhone() }
                    Button("Copy photos and videos from the phone…") { self.model.copyPhoneMedia() }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.phone.isConnected ? AppTheme.Accent.primary : AppTheme.Surface.textTertiary.opacity(0.7))
                        .frame(width: 6, height: 6)
                    // The compact bar keeps the state and drops the sentence: the menu still
                    // carries both actions, and "Disconnected" is not a thing to read twice.
                    if !compact {
                        Text(model.phone.summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(model.phone == .absent ? AppTheme.Surface.textSecondary : AppTheme.Surface.textPrimary)
                    }
                }
                .padding(.horizontal, compact ? 0 : 10)
                .frame(width: compact ? height : nil, height: height)
                .background {
                    Capsule().fill(AppTheme.Glass.fill.opacity(scheme == .dark ? 0.07 : 0.55))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.phone.isConnected ? "Phone connected: back it up or copy its media"
                  : model.phone == .unauthorised ? "Phone connected but blocked: accept “Allow USB debugging?” on it"
                  : "No phone detected over USB")
        }
    }

    private struct SearchPill: View {
        @Environment(AppModel.self) private var model
        @Environment(\.colorScheme) private var scheme
        @FocusState private var focused: Bool
        let height: CGFloat
        /// Compact bars show the magnifier alone until it is asked for; the field then
        /// appears in place of the button, so search stays one tap away without a 216pt well.
        var compact = false
        @State private var expanded = false

        private var showsField: Bool { !compact || expanded }

        var body: some View {
            @Bindable var m = model
            Group {
                if showsField {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                        // "Search everything" is the whole difference from the find bar: this field
                        // reads the archive, whatever conversation happens to be open beside it.
                        TextField("Search everything", text: $m.query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(AppTheme.Surface.textPrimary)
                            .focused($focused)
                            .onSubmit { model.runSearch(); model.pane = .search }
                            .onExitCommand { collapse() }
                        Text("⇧⌘F")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                            .opacity(model.query.isEmpty ? 1 : 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(width: compact ? 200 : 216, height: height)
                    .background {
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .fill(AppTheme.Glass.fill.opacity(scheme == .dark ? 0.07 : 0.55))
                            .overlay(RoundedRectangle(cornerRadius: height / 2).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: height / 2))
                    .onTapGesture { focused = true }
                    .onAppear { if compact { focused = true } }
                    .onChange(of: focused) { _, f in
                        // An empty field the reader has left collapses back to the button;
                        // text in it stays visible, because a search in progress is state.
                        if compact, !f, model.query.trimmingCharacters(in: .whitespaces).isEmpty { return }
                        if compact, !f { expanded = false }
                    }
                } else {
                    Button { open() } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                            .frame(width: height, height: height)
                            .background {
                                Circle().fill(AppTheme.Glass.fill.opacity(scheme == .dark ? 0.07 : 0.55))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1))
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Search every conversation (⇧⌘F)")
                    .accessibilityLabel("Search everything")
                }
            }
            // ⇧⌘F has to reach the collapsed button too, or the shortcut silently does nothing
            // at the narrow width exactly where the field is hidden.
            .onChange(of: model.searchFocusTick) { _, _ in open() }
        }

        private func open() {
            expanded = true
            focused = true
        }

        private func collapse() {
            focused = false
            if compact { expanded = false }
        }
    }

    private struct AskPill: View {
        @Environment(AppModel.self) private var model
        let height: CGFloat
        var compact = false

        var body: some View {
            Button { model.aiPanel.openAsk(model: model) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    Text("Ask").font(.system(size: 12.5, weight: .semibold))
                    // The shortcut is a hint, not the label: the compact bar spends its width
                    // on the word every time and on the hint only when there is room.
                    if !compact { Text("⌘K").font(.system(size: 10.5, weight: .medium)).opacity(0.8) }
                }
                .foregroundStyle(AppTheme.Accent.onAccent)
                .padding(.horizontal, 13)
                .frame(height: height)
                // A solid accent fill, not the pale tint: the old one measured 1.68:1 and
                // read as disabled, which is the opposite of what the only Ask door needs.
                .background {
                    Capsule().fill(AppTheme.Accent.primaryFill)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: AppTheme.Palette.teal.opacity(0.30), radius: 10, y: 3)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(model.selected.map { "Ask about \($0.name) (⌘K)" } ?? "Ask about every conversation (⌘K)")
            .accessibilityLabel("Ask")
        }
    }
}

/// A card surface with no shadow. Glass on a card is fine; a soft cast shadow on every tile
/// of a thousand-tile grid is not — it forces an offscreen pass per card while scrolling.
struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = AppTheme.Radius.panel

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AppTheme.Glass.fill.opacity(scheme == .dark ? 0.07 : 0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.09), lineWidth: 1)
            }
    }
}

extension View {
    func cardSurface(radius: CGFloat = AppTheme.Radius.panel) -> some View {
        modifier(CardSurface(radius: radius))
    }
}
