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
    static let minTabWidth: CGFloat = 116
    static let maxTabWidth: CGFloat = 240
    static let overflowButtonWidth: CGFloat = 28

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

    private(set) var frames: [NSRect] = []
    private(set) var scrollOffset: CGFloat = 0
    private(set) var contentWidth: CGFloat = 0
    private(set) var isOverflowing = false
    private var hoverIndex: Int?
    private var hoverClose = false
    private var hoverOverflow = false
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

    /// The horizontal region where tabs are drawn and clickable.
    var stripRect: NSRect {
        let reserve = isOverflowing ? TabBarView.overflowButtonWidth : 0
        let w = max(0, bounds.width - leadingInset - trailingInset - reserve)
        return NSRect(x: leadingInset, y: 0, width: w, height: bounds.height)
    }

    /// Button shown at the right edge of the tab strip when tabs overflow, listing every open tab.
    var overflowButtonRect: NSRect? {
        guard isOverflowing else { return nil }
        return NSRect(x: stripRect.maxX + 2, y: 7, width: 24, height: 24)
    }

    private func relayout() {
        let baseAvailable = max(0, bounds.width - leadingInset - trailingInset)
        let naturalWidths: [CGFloat] = items.map { item in
            var w = ceil((item.title as NSString).size(withAttributes: [.font: activeFont]).width) + 48 + (item.icon != nil ? 18 : 0)
            if let d = item.detail { w += ceil((d as NSString).size(withAttributes: [.font: detailFont]).width) + 6 }
            return min(max(w, TabBarView.minTabWidth), TabBarView.maxTabWidth)
        }
        var widths = naturalWidths
        let total = widths.reduce(0, +)
        let minW = TabBarView.minTabWidth
        let overflowsAtMin = CGFloat(widths.count) * minW > baseAvailable + 0.5
        isOverflowing = overflowsAtMin
        let available = max(0, baseAvailable - (isOverflowing ? TabBarView.overflowButtonWidth : 0))

        if total > available && !widths.isEmpty {
            if isOverflowing {
                widths = widths.map { _ in minW }
            } else {
                // Shrink the widest tabs first until the total fits exactly into `available`.
                let sorted = widths.sorted()
                var prefixSum = total
                var cap = sorted.last ?? minW
                for k in stride(from: sorted.count - 1, through: 0, by: -1) {
                    let count = CGFloat(sorted.count - k)
                    let below = prefixSum - sorted[k]
                    let candidate = max(minW, (available - below) / count)
                    if k == 0 || candidate >= sorted[k - 1] {
                        cap = candidate
                        break
                    }
                    prefixSum = below
                }
                widths = widths.map { min($0, floor(cap)) }
            }
        }
        var x = leadingInset
        frames = widths.map { w in
            defer { x += w }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
        contentWidth = x - leadingInset
        if !isOverflowing && contentWidth > available + 0.5 {
            isOverflowing = true
        }
        let maxScroll = max(0, contentWidth - stripRect.width)
        scrollOffset = min(max(0, scrollOffset), maxScroll)
        ensureSelectedVisible()
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
        let available = stripRect.width
        guard available > 0 else { return }
        if f.minX - leadingInset < scrollOffset { scrollOffset = f.minX - leadingInset }
        else if f.maxX - leadingInset > scrollOffset + available { scrollOffset = f.maxX - leadingInset - available }
        scrollOffset = min(max(0, scrollOffset), max(0, contentWidth - available))
        updateToolTips()
    }

    private func updateToolTips() {
        removeAllToolTips()
        let clip = stripRect
        for i in frames.indices {
            let r = visibleFrame(i).intersection(clip)
            if !r.isNull && r.width > 4 { addToolTip(r, owner: self, userData: nil) }
        }
        if let ob = overflowButtonRect { addToolTip(ob, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if overflowButtonRect?.contains(point) == true { return "Show all open tabs" }
        guard let i = index(at: point) else { return "" }
        return items[i].tooltip
    }

    private func index(at p: NSPoint) -> Int? {
        let clip = stripRect
        guard clip.contains(p) else { return nil }
        for i in frames.indices where visibleFrame(i).contains(p) { return i }
        return nil
    }

    private func closeRect(_ f: NSRect) -> NSRect {
        NSRect(x: f.maxX - 24, y: round(f.midY - 8) + 2, width: 16, height: 16)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.chromeBackground.setFill()
        bounds.fill()
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let strip = stripRect
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: max(0, strip.minX - 2), y: 0, width: strip.width + 2, height: bounds.height).clip()

        let order = frames.indices.sorted { a, b in (a == dragIndex ? 1 : 0) < (b == dragIndex ? 1 : 0) }
        for i in order {
            let f = visibleFrame(i)
            guard f.maxX >= strip.minX - 2, f.minX <= strip.maxX + 2,
                  f.maxX >= dirtyRect.minX - 2, f.minX <= dirtyRect.maxX + 2 else { continue }
            drawTab(i, frame: f, theme: theme)
        }

        if contentWidth > strip.width + 0.5 {
            let fadeBase = theme.chromeBackground.alphaComponent > 0.05 ? theme.chromeBackground : theme.windowTint.withAlphaComponent(0.92)
            let fade = NSGradient(starting: fadeBase.withAlphaComponent(0), ending: fadeBase)
            if scrollOffset < contentWidth - strip.width - 1 {
                fade?.draw(in: NSRect(x: strip.maxX - 22, y: 0, width: 22, height: bounds.height - 1), angle: 0)
                theme.chromeBorder.withAlphaComponent(0.7).setFill()
                NSRect(x: strip.maxX - 1, y: 6, width: 1, height: bounds.height - 7).fill()
            }
            if scrollOffset > 0.5 {
                fade?.draw(in: NSRect(x: strip.minX, y: 0, width: 22, height: bounds.height - 1), angle: 180)
                theme.chromeBorder.withAlphaComponent(0.7).setFill()
                NSRect(x: strip.minX, y: 6, width: 1, height: bounds.height - 7).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if let ob = overflowButtonRect {
            if hoverOverflow {
                theme.foreground.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: ob.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let color = hoverOverflow ? theme.chromeForeground : theme.chromeSecondary
            if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "All tabs")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold).applying(.init(paletteColors: [color]))) {
                let s = img.size
                img.draw(in: NSRect(x: round(ob.midX - s.width / 2), y: round(ob.midY - s.height / 2), width: s.width, height: s.height))
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
        let showCloseOrDot = hover || active || item.dirty
        let textMaxX = showCloseOrDot ? close.minX - 4 : f.maxX - 10
        var textX = f.minX + 12
        if let icon = item.icon, f.width >= 108 {
            let s = icon.size
            icon.draw(in: NSRect(x: textX, y: round(f.midY - s.height / 2) + 2, width: s.width, height: s.height),
                      from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.75, respectFlipped: true, hints: nil)
            textX += 17
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
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
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverClose = false; hoverOverflow = false; needsDisplay = true }

    private func updateHover(_ p: NSPoint) {
        let i = index(at: p)
        let c = i.map { closeRect(visibleFrame($0)).insetBy(dx: -2, dy: -2).contains(p) } ?? false
        let o = overflowButtonRect?.contains(p) == true
        if i != hoverIndex || c != hoverClose || o != hoverOverflow {
            hoverIndex = i
            hoverClose = c
            hoverOverflow = o
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let ob = overflowButtonRect, ob.contains(p) {
            showOverflowMenu(at: ob)
            return
        }
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

    private func showOverflowMenu(at rect: NSRect) {
        let m = NSMenu()
        for (i, item) in items.enumerated() {
            var title = item.title
            if let d = item.detail { title += " — " + d }
            if item.dirty { title += "  •" }
            let mi = NSMenuItem(title: title, action: #selector(selectFromOverflowMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = i == selectedIndex ? .on : .off
            mi.image = item.icon
            m.addItem(mi)
        }
        m.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    @objc private func selectFromOverflowMenu(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        delegate?.tabBar(self, didSelect: sender.tag)
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
        let strip = stripRect
        // Auto-scroll when dragging near the edges of an overflowing tab strip.
        let maxScroll = max(0, contentWidth - strip.width)
        if maxScroll > 0 {
            if p.x < strip.minX + 24 { scrollOffset = max(0, scrollOffset - 18) }
            else if p.x > strip.maxX - 24 { scrollOffset = min(maxScroll, scrollOffset + 18) }
        }
        let maxX = max(strip.minX, strip.maxX - frames[di].width)
        dragX = min(max(strip.minX, p.x - dragMouseOffset), maxX)
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
        let available = stripRect.width
        guard contentWidth > available else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset = min(max(0, scrollOffset - delta), contentWidth - available)
        updateToolTips()
        needsDisplay = true
    }

    // MARK: Accessibility

    private var tabElements: [DrawnAccessibilityElement] = []
    private var closeElements: [DrawnAccessibilityElement] = []
    private lazy var overflowElement: DrawnAccessibilityElement = {
        let e = DrawnAccessibilityElement(in: self, role: .popUpButton) { [weak self] in self?.overflowButtonRect }
        e.setAccessibilityLabel("All tabs")
        e.setAccessibilityHelp("Show all open tabs")
        e.onPress = { [weak self] in
            guard let self, let ob = self.overflowButtonRect else { return }
            self.showOverflowMenu(at: ob)
        }
        return e
    }()

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Tabs" }
    override func accessibilityTabs() -> [Any]? { tabElements }
    override func accessibilityValue() -> Any? { selectedIndex >= 0 && selectedIndex < tabElements.count ? tabElements[selectedIndex] : nil }

    override func accessibilityChildren() -> [Any]? {
        var children = zip(tabElements, closeElements).flatMap { [$0, $1] }
        if isOverflowing { children.append(overflowElement) }
        return children
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
                let r = self.visibleFrame(i).intersection(self.stripRect)
                return r.isNull || r.width < 4 ? nil : r
            }
            tab.onPress = { [weak self] in
                guard let self, i < self.items.count else { return }
                self.delegate?.tabBar(self, didSelect: i)
            }
            let close = DrawnAccessibilityElement(in: self, role: .button) { [weak self] in
                guard let self, i < self.frames.count else { return nil }
                let tabRect = self.visibleFrame(i).intersection(self.stripRect)
                guard !tabRect.isNull else { return nil }
                let r = self.closeRect(self.visibleFrame(i)).intersection(self.stripRect)
                return r.isNull || r.width < 4 ? nil : r
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
