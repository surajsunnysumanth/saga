import AppKit
import WebKit

/// Wheel handling for embedded players, kept in SagaCore so it can be tested.

/// An embedded player captures the scroll wheel, so a list of open players
/// cannot be scrolled. The shield sits on top of the web view: wheel events go
/// to the list, and the first click hands the player over and removes the shield.
public final class PlayerScrollShield: NSView {
    public var activate: (() -> Void)?

    public override func scrollWheel(with event: NSEvent) {
        if let next = nextResponder { next.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    public override func mouseDown(with event: NSEvent) { activate?() }
    public override func rightMouseDown(with event: NSEvent) { activate?() }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Use this player")
        setAccessibilityHelp("Scroll to move through the list; click to control the player.")
    }
}

public final class PlayerBoxView: NSView {
    public let web: WKWebView
    public let shield = PlayerScrollShield()

    public init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        addSubview(web)
        addSubview(shield)
        shield.activate = { [weak self] in self?.shield.isHidden = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        web.frame = bounds
        shield.frame = bounds
    }
}

