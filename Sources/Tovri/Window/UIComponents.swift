import AppKit

/// Small borderless icon/text button with hover and toggle states, themed from the active theme.
final class ToolButton: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    var symbol: String? { didSet { needsDisplay = true } }
    var title: String? { didSet { needsDisplay = true } }
    var symbolSize: CGFloat = 12
    var titleFont: NSFont = .systemFont(ofSize: 11.5, weight: .medium)
    private var hovering = false
    private var pressed = false

    init(symbol: String? = nil, title: String? = nil, tooltip: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var ownTrackingArea: NSTrackingArea?


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only replace our own area: removing every tracking area also kills AppKit's tooltip tracking.
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Only keyboard navigation (Tab) focuses a button. A click must leave focus where it was, so
    /// typing, Return and the find field's shortcuts keep working.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func accessibilityLabel() -> String? {
        toolTip?.components(separatedBy: "\n").first ?? title ?? symbol
    }

    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityValue() -> Any? { isOn ? "On" : nil }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        if NSApp.currentEvent?.type == .leftMouseDown { return false }
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    var intrinsicWidth: CGFloat {
        if let t = title { return ceil((t as NSString).size(withAttributes: [.font: titleFont]).width) + 14 }
        return 24
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isOn {
            theme.accent.withAlphaComponent(0.24).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        } else if hovering || pressed {
            theme.foreground.withAlphaComponent(pressed ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
        let color = isOn ? theme.accent.mix(theme.foreground, 0.25) : theme.chromeForeground.withAlphaComponent(0.85)
        if let name = symbol, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium).applying(.init(paletteColors: [color]))) {
            let s = img.size
            img.draw(in: NSRect(x: round((bounds.width - s.width) / 2), y: round((bounds.height - s.height) / 2), width: s.width, height: s.height))
        } else if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
            let s = (t as NSString).size(withAttributes: attrs)
            (t as NSString).draw(at: NSPoint(x: round((bounds.width - s.width) / 2), y: round((bounds.height - s.height) / 2)), withAttributes: attrs)
        }
    }
}

/// Bordered button for floating cards: an icon, a title, or both.
final class PillButton: NSView {
    static let height: CGFloat = 24
    var onClick: (() -> Void)?
    let symbol: String?
    let title: String?
    /// Colors the icon and title with a token color, e.g. red for Revert.
    var tintKind: TokenKind? { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private var hovering = false
    private var pressed = false

    init(symbol: String? = nil, title: String? = nil, tooltip: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: PillButton.height, height: PillButton.height))
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        guard let title else { return PillButton.height }
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return w + (symbol == nil ? 18 : 34)
    }

    private var ownTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func accessibilityLabel() -> String? { toolTip?.components(separatedBy: "\n").first ?? title ?? symbol }
    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (hovering || pressed ? theme.fieldBackground.mix(theme.foreground, pressed ? 0.14 : 0.08) : theme.fieldBackground).setFill()
        path.fill()
        theme.chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        let color = tintKind.flatMap { theme.color($0) } ?? theme.foreground
        var img: NSImage?
        if let symbol {
            img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold).applying(.init(paletteColors: [color])))
        }
        guard let title else {
            if let img {
                let s = img.size
                img.draw(in: NSRect(x: round((bounds.width - s.width) / 2), y: round((bounds.height - s.height) / 2), width: s.width, height: s.height))
            }
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ts = (title as NSString).size(withAttributes: attrs)
        var x: CGFloat = 9
        if let img {
            let s = img.size
            img.draw(in: NSRect(x: x, y: round((bounds.height - s.height) / 2), width: s.width, height: s.height))
            x += 16
        }
        (title as NSString).draw(at: NSPoint(x: x, y: round((bounds.height - ts.height) / 2)), withAttributes: attrs)
    }
}

/// Rounded, themed single-line text field.
final class ThemedTextField: NSView {
    let field = FocusTextField()
    /// Set this rather than the field's placeholderString, which the themed placeholder overrides.
    var placeholder: String { didSet { applyTheme() } }
    var fontSize: CGFloat = 13 { didSet { applyTheme(); needsLayout = true } }
    /// Optional icon before the text, e.g. a magnifying glass.
    var leadingSymbol: String? { didSet { applyTheme(); needsLayout = true } }
    /// Optional muted label at the right edge, e.g. the palette's mode.
    var trailingText: String = "" { didSet { trailingLabel.stringValue = trailingText; needsLayout = true } }
    private let iconView = NSImageView()
    private let trailingLabel = NSTextField(labelWithString: "")

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.onFocusChange = { [weak self] _ in self?.applyTheme() }
        addSubview(field)
        trailingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        trailingLabel.alignment = .right
        addSubview(iconView)
        addSubview(trailingLabel)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        layer?.backgroundColor = theme.fieldBackground.cgColor
        let focused = field.currentEditor() != nil
        layer?.borderColor = (focused ? theme.accent.withAlphaComponent(0.8) : theme.chromeBorder).cgColor
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = theme.foreground
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: theme.chromeSecondary, .font: NSFont.systemFont(ofSize: fontSize)])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = theme.caret
        trailingLabel.textColor = theme.chromeSecondary
        iconView.image = leadingSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fontSize - 1, weight: .medium).applying(.init(paletteColors: [theme.chromeSecondary])))
    }

    override func layout() {
        super.layout()
        let h = ceil((field.font ?? .systemFont(ofSize: fontSize)).boundingRectForFont.height) + 2
        var x: CGFloat = 8
        iconView.isHidden = iconView.image == nil
        if let img = iconView.image {
            iconView.frame = NSRect(x: 10, y: round((bounds.height - img.size.height) / 2), width: img.size.width, height: img.size.height)
            x = iconView.frame.maxX + 8
        }
        var right = bounds.width - 8
        trailingLabel.isHidden = trailingText.isEmpty
        if !trailingText.isEmpty {
            let w = ceil(trailingLabel.fittingSize.width)
            trailingLabel.frame = NSRect(x: bounds.width - 12 - w, y: round((bounds.height - 15) / 2), width: w, height: 15)
            right = trailingLabel.frame.minX - 10
        }
        field.frame = NSRect(x: x, y: round((bounds.height - h) / 2), width: max(0, right - x), height: h)
    }
}

final class FocusTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            DispatchQueue.main.async { self.onFocusChange?(true) }
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// Table row with a rounded, theme-colored selection.
class ThemedRowView: NSTableRowView {
    var selectionColor: NSColor { ThemeManager.shared.active.sidebarSelection }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

extension NSView {
    func roundCorners(_ radius: CGFloat, background: NSColor, border: NSColor? = nil) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = background.cgColor
        if let b = border {
            layer?.borderWidth = 1
            layer?.borderColor = b.cgColor
        }
    }
}

/// Thin, theme-colored overlay scroller. It thickens while hovered and fades out with the
/// standard overlay behavior.
final class ThemedScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { self == ThemedScroller.self }

    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var ownTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var isVertical: Bool { bounds.height >= bounds.width }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard hovering else { return }
        let theme = ThemeManager.shared.active
        theme.foreground.withAlphaComponent(theme.isDark ? 0.05 : 0.04).setFill()
        bounds.fill()
    }

    override func drawKnob() {
        let theme = ThemeManager.shared.active
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let thickness: CGFloat = hovering ? 9 : 6
        let inset: CGFloat = 2.5
        let r: NSRect
        if isVertical {
            r = NSRect(x: bounds.maxX - inset - thickness, y: knob.minY + 2, width: thickness, height: max(thickness, knob.height - 4))
        } else {
            r = NSRect(x: knob.minX + 2, y: bounds.maxY - inset - thickness, width: max(thickness, knob.width - 4), height: thickness)
        }
        let alpha: CGFloat = hovering ? (theme.isDark ? 0.42 : 0.38) : (theme.isDark ? 0.26 : 0.24)
        theme.foreground.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}

/// Scroll view that always uses themed overlay scrollers, even when the system prefers
/// always-visible scroll bars (e.g. with a mouse connected).
class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        verticalScroller = ThemedScroller()
        horizontalScroller = ThemedScroller()
        super.scrollerStyle = .overlay
        autohidesScrollers = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    @objc private func themeDidChange() {
        verticalScroller?.needsDisplay = true
        horizontalScroller?.needsDisplay = true
    }
}
