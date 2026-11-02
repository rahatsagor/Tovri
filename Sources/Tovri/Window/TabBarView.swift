import AppKit

struct TabItem {
    var title: String
    var icon: NSImage?
    var detail: String?
    var dirty: Bool
    var missing: Bool
    var tooltip: String
}

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int)
    func tabBarDidDoubleClickEmpty(_ bar: TabBarView)
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu?
}

/// Custom-drawn tab strip. Drawing everything in one view keeps hundreds of tabs cheap.
final class TabBarView: NSView, NSViewToolTipOwner {
    static let height: CGFloat = 38

    weak var delegate: TabBarDelegate?
    var items: [TabItem] = [] { didSet { relayout(); syncAccessibility() } }
    var selectedIndex = -1 {
        didSet {
            ensureSelectedVisible()
            needsDisplay = true
            guard oldValue != selectedIndex else { return }
            syncAccessibility()
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }
    var isActiveGroup = true { didSet { needsDisplay = true } }
    var leadingInset: CGFloat = 8 { didSet { if oldValue != leadingInset { relayout() } } }
    /// Space reserved at the right edge for accessory buttons.
    var trailingInset: CGFloat = 8 { didSet { if oldValue != trailingInset { relayout() } } }

    private var frames: [NSRect] = []
    private var scrollOffset: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var hoverIndex: Int?
    private var hoverClose = false
    private var pressedClose: Int?
    private var dragIndex: Int?
    private var dragStartX: CGFloat = 0
    private var dragMouseOffset: CGFloat = 0
    private var dragX: CGFloat = 0
    private var isDragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    private let activeFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        let available = max(0, bounds.width - leadingInset - trailingInset)
        var widths: [CGFloat] = items.map { item in
            var w = (item.title as NSString).size(withAttributes: [.font: activeFont]).width + 48 + (item.icon != nil ? 18 : 0)
            if let d = item.detail { w += (d as NSString).size(withAttributes: [.font: detailFont]).width + 6 }
            return min(max(w, 96), 240)
        }
        let total = widths.reduce(0, +)
        if total > available && !widths.isEmpty {
            let target = max(84, available / CGFloat(widths.count))
            let maxW = widths.max() ?? target
            if maxW > target {
                widths = widths.map { min($0, max(target, 84)) }
            }
        }
        var x = leadingInset
        frames = widths.map { w in
            defer { x += w }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
        contentWidth = x - leadingInset
        scrollOffset = min(scrollOffset, max(0, contentWidth - available))
        updateToolTips()
        needsDisplay = true
    }

    private func visibleFrame(_ i: Int) -> NSRect {
        var f = frames[i].offsetBy(dx: -scrollOffset, dy: 0)
        if isDragging, i == dragIndex { f.origin.x = dragX }
        return f
    }

    private func ensureSelectedVisible() {
        guard selectedIndex >= 0, selectedIndex < frames.count else { return }
        let f = frames[selectedIndex]
        let available = bounds.width - leadingInset - trailingInset
        if f.minX - leadingInset < scrollOffset { scrollOffset = f.minX - leadingInset }
        else if f.maxX - leadingInset > scrollOffset + available { scrollOffset = f.maxX - leadingInset - available }
        scrollOffset = max(0, scrollOffset)
        updateToolTips()
    }

    private func updateToolTips() {
        removeAllToolTips()
        for i in frames.indices { addToolTip(visibleFrame(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = index(at: point) else { return "" }
        return items[i].tooltip
    }

    private func index(at p: NSPoint) -> Int? {
        for i in frames.indices where visibleFrame(i).contains(p) { return i }
        return nil
    }

    private func closeRect(_ f: NSRect) -> NSRect {
        NSRect(x: f.maxX - 26, y: round(f.midY - 8) + 2, width: 16, height: 16)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.chromeBackground.setFill()
        bounds.fill()
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: leadingInset - 2, y: 0, width: bounds.width - leadingInset + 2, height: bounds.height).clip()

        let order = frames.indices.sorted { a, b in (a == dragIndex ? 1 : 0) < (b == dragIndex ? 1 : 0) }
        for i in order {
            let f = visibleFrame(i)
            guard f.maxX >= dirtyRect.minX - 2, f.minX <= dirtyRect.maxX + 2 else { continue }
            drawTab(i, frame: f, theme: theme)
        }
        NSGraphicsContext.restoreGraphicsState()

        if contentWidth > bounds.width - leadingInset - trailingInset {
            let fade = NSGradient(starting: theme.chromeBackground.withAlphaComponent(0), ending: theme.chromeBackground)
            if scrollOffset < contentWidth - (bounds.width - leadingInset - trailingInset) - 1 {
                fade?.draw(in: NSRect(x: bounds.width - trailingInset - 20, y: 0, width: 28, height: bounds.height - 1), angle: 0)
            }
            if scrollOffset > 0 {
                fade?.draw(in: NSRect(x: leadingInset - 2, y: 0, width: 24, height: bounds.height - 1), angle: 180)
            }
        }
    }

    private func drawTab(_ i: Int, frame f: NSRect, theme: Theme) {
        let item = items[i]
        let active = i == selectedIndex
        let hover = i == hoverIndex
        let body = NSRect(x: f.minX + 2, y: 5, width: f.width - 4, height: f.height - 5)

        if active {
            let path = NSBezierPath()
            let r: CGFloat = 7
            path.move(to: NSPoint(x: body.minX - 2, y: body.maxY))
            path.appendArc(from: NSPoint(x: body.minX, y: body.maxY), to: NSPoint(x: body.minX, y: body.maxY - 2), radius: 2)
            path.line(to: NSPoint(x: body.minX, y: body.minY + r))
            path.appendArc(from: NSPoint(x: body.minX, y: body.minY), to: NSPoint(x: body.minX + r, y: body.minY), radius: r)
            path.line(to: NSPoint(x: body.maxX - r, y: body.minY))
            path.appendArc(from: NSPoint(x: body.maxX, y: body.minY), to: NSPoint(x: body.maxX, y: body.minY + r), radius: r)
            path.line(to: NSPoint(x: body.maxX, y: body.maxY - 2))
            path.appendArc(from: NSPoint(x: body.maxX, y: body.maxY), to: NSPoint(x: body.maxX + 2, y: body.maxY), radius: 2)
            path.close()
            theme.tabActiveBackground.setFill()
            path.fill()
            theme.chromeBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            theme.tabActiveBackground.setFill()
            NSRect(x: body.minX + 0.5, y: body.maxY - 1.5, width: body.width - 1, height: 2).fill()
            if isActiveGroup {
                theme.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: body.minX + 10, y: body.minY + 0.5, width: body.width - 20, height: 2), xRadius: 1, yRadius: 1).fill()
            }
        } else if hover {
            theme.tabHoverBackground.setFill()
            NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 3).offsetBy(dx: 0, dy: -1), xRadius: 6, yRadius: 6).fill()
        } else if i + 1 != selectedIndex && i + 1 < items.count {
            theme.chromeBorder.setFill()
            NSRect(x: f.maxX - 0.5, y: 14, width: 1, height: f.height - 24).fill()
        }

        let fg: NSColor = active ? theme.chromeForeground : theme.chromeSecondary
        let font = active ? activeFont : titleFont
        let close = closeRect(f)
        let textMaxX = close.minX - 4
        var textX = f.minX + 16
        if let icon = item.icon, f.width > 100 {
            let s = icon.size
            icon.draw(in: NSRect(x: textX - 2, y: round(f.midY - s.height / 2) + 2, width: s.width, height: s.height),
                      from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.75, respectFlipped: true, hints: nil)
            textX += 17
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var title = NSMutableAttributedString(string: item.title, attributes: [
            .font: font, .foregroundColor: item.missing ? theme.color(.deleted) ?? fg : fg, .paragraphStyle: para,
            .strikethroughStyle: item.missing ? NSUnderlineStyle.single.rawValue : 0])
        if let d = item.detail {
            title.append(NSAttributedString(string: "  " + d, attributes: [.font: detailFont, .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8), .paragraphStyle: para]))
        }
        if item.title.isEmpty { title = NSMutableAttributedString(string: " ") }
        let h = title.size().height
        title.draw(with: NSRect(x: textX, y: round(f.midY - h / 2) + 2, width: max(0, textMaxX - textX), height: h + 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let showClose = hover || active
        if hover && hoverClose {
            theme.foreground.withAlphaComponent(pressedClose == i ? 0.18 : 0.1).setFill()
            NSBezierPath(roundedRect: close, xRadius: 4, yRadius: 4).fill()
        }
        if item.dirty && !(hover && hoverClose) {
            theme.dirty.setFill()
            NSBezierPath(ovalIn: NSRect(x: close.midX - 4, y: close.midY - 4, width: 8, height: 8)).fill()
        } else if showClose {
            let c = hover && hoverClose ? theme.chromeForeground : theme.chromeSecondary
            c.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.3
            p.lineCapStyle = .round
            let inset: CGFloat = 4.5
            p.move(to: NSPoint(x: close.minX + inset, y: close.minY + inset))
            p.line(to: NSPoint(x: close.maxX - inset, y: close.maxY - inset))
            p.move(to: NSPoint(x: close.maxX - inset, y: close.minY + inset))
            p.line(to: NSPoint(x: close.minX + inset, y: close.maxY - inset))
            p.stroke()
        }
    }

    // MARK: Mouse

    private var ownTrackingArea: NSTrackingArea?


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only replace our own area: removing every tracking area also kills AppKit's tooltip tracking.
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverClose = false; needsDisplay = true }

    private func updateHover(_ p: NSPoint) {
        let i = index(at: p)
        let c = i.map { closeRect(visibleFrame($0)).insetBy(dx: -2, dy: -2).contains(p) } ?? false
        if i != hoverIndex || c != hoverClose {
            hoverIndex = i
            hoverClose = c
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else {
            if event.clickCount == 2 { delegate?.tabBarDidDoubleClickEmpty(self) } else { window?.performDrag(with: event) }
            return
        }
        if closeRect(visibleFrame(i)).insetBy(dx: -2, dy: -2).contains(p) {
            pressedClose = i
            needsDisplay = true
            return
        }
        delegate?.tabBar(self, didSelect: i)
        dragIndex = i
        dragStartX = p.x
        dragMouseOffset = p.x - visibleFrame(i).minX
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isDragging && abs(p.x - dragStartX) < 5 { return }
        isDragging = true
        drag(to: p)
        needsDisplay = true
    }

    /// Moves the dragged tab past every neighbor its center has crossed, however far the mouse
    /// went since the last event.
    private func drag(to p: NSPoint) {
        guard var di = dragIndex, di < frames.count else { return }
        let maxX = max(leadingInset, bounds.width - trailingInset - frames[di].width)
        dragX = min(max(leadingInset, p.x - dragMouseOffset), maxX)
        // Bounded, in case the delegate doesn't reorder the tabs.
        for _ in 0..<frames.count {
            let center = dragX + frames[di].width / 2 + scrollOffset
            var target = di
            if di > 0 && center < frames[di - 1].midX { target = di - 1 }
            else if di + 1 < frames.count && center > frames[di + 1].midX { target = di + 1 }
            guard target != di else { break }
            delegate?.tabBar(self, didMove: di, to: target)
            guard target < frames.count else { break }
            di = target
            dragIndex = di
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let c = pressedClose {
            pressedClose = nil
            if c < frames.count, closeRect(visibleFrame(c)).insetBy(dx: -3, dy: -3).contains(p) {
                delegate?.tabBar(self, didClose: c)
            }
        }
        if isDragging { drag(to: p) }
        dragIndex = nil
        isDragging = false
        updateHover(p)
        needsDisplay = true
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let i = index(at: convert(event.locationInWindow, from: nil)) {
            delegate?.tabBar(self, didClose: i)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return delegate?.tabBar(self, menuFor: i)
    }

    override func scrollWheel(with event: NSEvent) {
        let available = bounds.width - leadingInset - trailingInset
        guard contentWidth > available else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset = min(max(0, scrollOffset - delta), contentWidth - available)
        updateToolTips()
        needsDisplay = true
    }

    // MARK: Accessibility

    private var tabElements: [DrawnAccessibilityElement] = []
    private var closeElements: [DrawnAccessibilityElement] = []

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Tabs" }
    override func accessibilityTabs() -> [Any]? { tabElements }
    override func accessibilityValue() -> Any? { selectedIndex >= 0 && selectedIndex < tabElements.count ? tabElements[selectedIndex] : nil }

    override func accessibilityChildren() -> [Any]? {
        zip(tabElements, closeElements).flatMap { [$0, $1] }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        DrawnAccessibilityElement.element(at: point, in: accessibilityChildren() as? [DrawnAccessibilityElement] ?? []) ?? self
    }

    private func syncAccessibility() {
        let countChanged = tabElements.count != items.count
        while tabElements.count < items.count {
            let i = tabElements.count
            let tab = DrawnAccessibilityElement(in: self, role: .radioButton) { [weak self] in
                guard let self, i < self.frames.count else { return nil }
                return self.visibleFrame(i)
            }
            tab.onPress = { [weak self] in
                guard let self, i < self.items.count else { return }
                self.delegate?.tabBar(self, didSelect: i)
            }
            let close = DrawnAccessibilityElement(in: self, role: .button) { [weak self] in
                guard let self, i < self.frames.count else { return nil }
                return self.closeRect(self.visibleFrame(i))
            }
            close.onPress = { [weak self] in
                guard let self, i < self.items.count else { return }
                self.delegate?.tabBar(self, didClose: i)
            }
            tabElements.append(tab)
            closeElements.append(close)
        }
        tabElements.removeLast(tabElements.count - items.count)
        closeElements.removeLast(closeElements.count - items.count)
        for (i, item) in items.enumerated() {
            let name = item.title + (item.detail.map { " — " + $0 } ?? "")
            let tab = tabElements[i]
            tab.setAccessibilityLabel(name)
            tab.setAccessibilityValue(NSNumber(value: i == selectedIndex))
            tab.setAccessibilitySelected(i == selectedIndex)
            let state = [item.dirty ? "Edited" : nil, item.missing ? "File deleted" : nil].compactMap { $0 }
            tab.setAccessibilityHelp((state + [item.tooltip]).joined(separator: ". "))
            closeElements[i].setAccessibilityLabel("Close \(name)")
        }
        if countChanged { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }
}
