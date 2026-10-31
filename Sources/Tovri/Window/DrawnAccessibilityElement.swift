import AppKit

/// Accessibility stand-in for a region that a custom view draws itself, so VoiceOver can find, read and press it.
final class DrawnAccessibilityElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let rectInView: () -> NSRect?
    var onPress: (() -> Void)?

    init(in view: NSView, role: NSAccessibility.Role, rect: @escaping () -> NSRect?) {
        self.view = view
        rectInView = rect
        super.init()
        setAccessibilityRole(role)
        setAccessibilityParent(view)
    }

    override func accessibilityFrame() -> NSRect {
        guard let view, view.window != nil, let r = rectInView()?.intersection(view.visibleRect), !r.isNull, !r.isEmpty else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: r)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return onPress != nil }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    /// Hit test for the owning view; `point` is in screen coordinates.
    static func element(at point: NSPoint, in elements: [DrawnAccessibilityElement]) -> DrawnAccessibilityElement? {
        elements.last { NSPointInRect(point, $0.accessibilityFrame()) }
    }
}
