import AppKit

protocol StatusBarDelegate: AnyObject {
    func statusBar(_ bar: StatusBarView, clicked item: StatusBarView.Item, at rect: NSRect)
}

final class StatusBarView: NSView, NSViewToolTipOwner {
    enum Item: Int, CaseIterable { case branch, position, indentation, encoding, lineEnding, language }
    static let height: CGFloat = 24

    weak var delegate: StatusBarDelegate?
    var values: [Item: String] = [:] {
        didSet {
            needsDisplay = true
            if Set(oldValue.filter { !$0.value.isEmpty }.keys) != Set(values.filter { !$0.value.isEmpty }.keys) {
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
        }
    }
    var message: String? { didSet { needsDisplay = true } }
    private var flashText: String?
    private var flashToken = 0

    /// Shows a short-lived message (e.g. "Saved") that fades after a moment.
    func flash(_ text: String) {
        flashToken += 1
        let token = flashToken
        flashText = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flashText = nil
            self.needsDisplay = true
        }
    }
    private var rects: [Item: NSRect] = [:]
    private var tooltipRects: [Item: NSRect] = [:]
    private var tooltipTags: [NSView.ToolTipTag: Item] = [:]

    private static let help: [Item: String] = [
        .branch: "Current Git branch",
        .position: "Cursor line and column. Click to go to a line (⌃G).",
        .indentation: "Indentation used for new lines. Click to switch between spaces and tabs or change the width.",
        .encoding: "Text encoding used to read and save this file. Click to save with or reopen in another encoding.",
        .lineEnding: "Line endings: LF (macOS, Linux) or CRLF (Windows). Click to change.",
        .language: "Syntax used for highlighting. Click to choose another language.",
    ]

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipTags[tag].flatMap { StatusBarView.help[$0] } ?? ""
    }

    private func updateToolTips() {
        guard rects != tooltipRects else { return }
        tooltipRects = rects
        removeAllToolTips()
        tooltipTags = [:]
        for (item, r) in rects { tooltipTags[addToolTip(r, owner: self, userData: nil)] = item }
    }
    private var hover: Item?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private let font = NSFont.systemFont(ofSize: 11.5)

    private static let names: [Item: String] = [
        .branch: "Git branch", .position: "Cursor position", .indentation: "Indentation",
        .encoding: "Encoding", .lineEnding: "Line ending", .language: "Language",
    ]

    /// Where each item with a value sits; drawing, clicks and accessibility all use this.
    private func itemRects() -> [Item: NSRect] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var result: [Item: NSRect] = [:]
        var x: CGFloat = 14
        if let branch = values[.branch], !branch.isEmpty {
            let r = NSRect(x: x - 6, y: 1, width: (branch as NSString).size(withAttributes: attrs).width + 30, height: bounds.height - 1)
            result[.branch] = r
            x = r.maxX + 10
        }
        if let pos = values[.position] {
            let r = NSRect(x: x - 6, y: 1, width: (pos as NSString).size(withAttributes: attrs).width + 12, height: bounds.height - 1)
            result[.position] = r
        }
        var right = bounds.width - 10
        for item in [Item.language, .lineEnding, .encoding, .indentation] {
            guard let v = values[item], !v.isEmpty else { continue }
            let w = (v as NSString).size(withAttributes: attrs).width
            let r = NSRect(x: right - w - 12, y: 1, width: w + 12, height: bounds.height - 1)
            result[item] = r
            right = r.minX - 4
        }
        return result
    }

    private func messageX(_ rects: [Item: NSRect]) -> CGFloat {
        (rects[.position] ?? rects[.branch]).map { $0.maxX + 10 } ?? 14
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.chromeBackground.setFill()
        bounds.fill()
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        rects = itemRects()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.chromeSecondary]
        let hoverAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.chromeForeground]

        if let r = rects[.branch], let branch = values[.branch] {
            let s = branch as NSString
            let size = s.size(withAttributes: attrs)
            if hover == .branch {
                theme.tabHoverBackground.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            if let img = FileIcons.image("arrow.triangle.branch", color: theme.chromeSecondary, size: 10) {
                img.draw(in: NSRect(x: r.minX + 6, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            s.draw(at: NSPoint(x: r.minX + 22, y: r.minY + round((r.height - size.height) / 2)), withAttributes: hover == .branch ? hoverAttrs : attrs)
        }
        if let m = message ?? flashText {
            let s = m as NSString
            s.draw(at: NSPoint(x: messageX(rects), y: round((bounds.height - s.size(withAttributes: attrs).height) / 2) + 1), withAttributes: attrs)
        }
        for item in [Item.position, .language, .lineEnding, .encoding, .indentation] {
            guard let r = rects[item], let v = values[item] else { continue }
            drawItem(v as NSString, rect: r, attrs: hover == item ? hoverAttrs : attrs, hovered: hover == item, theme: theme)
        }
        updateToolTips()
    }
    private func drawItem(_ s: NSString, rect: NSRect, attrs: [NSAttributedString.Key: Any], hovered: Bool, theme: Theme) {
        if hovered {
            theme.tabHoverBackground.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + round((rect.height - size.height) / 2)), withAttributes: attrs)
    }

    private var ownTrackingArea: NSTrackingArea?


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only replace our own area: removing every tracking area also kills AppKit's tooltip tracking.
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = rects.first(where: { $0.value.contains(p) })?.key
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (item, rect) = rects.first(where: { $0.value.contains(p) }) else { return }
        delegate?.statusBar(self, clicked: item, at: rect)
    }

    // MARK: Accessibility

    private lazy var itemElements: [Item: DrawnAccessibilityElement] = Dictionary(uniqueKeysWithValues: Item.allCases.map { item in
        // Clicking the branch does nothing, so it is read as text rather than offered as a button.
        let e = DrawnAccessibilityElement(in: self, role: item == .branch ? .staticText : .button) { [weak self] in self?.itemRects()[item] }
        if item != .branch {
            e.onPress = { [weak self] in
                guard let self, let r = self.itemRects()[item] else { return }
                self.delegate?.statusBar(self, clicked: item, at: r)
            }
        }
        e.setAccessibilityHelp(StatusBarView.help[item])
        return (item, e)
    })

    private lazy var messageElement = DrawnAccessibilityElement(in: self, role: .staticText) { [weak self] in
        guard let self else { return nil }
        let x = self.messageX(self.itemRects())
        return NSRect(x: x, y: 1, width: max(0, self.bounds.width - x), height: self.bounds.height - 1)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Status bar" }

    override func accessibilityChildren() -> [Any]? {
        var result: [DrawnAccessibilityElement] = []
        for item in Item.allCases {
            if let v = values[item], !v.isEmpty, let e = itemElements[item] {
                e.setAccessibilityLabel("\(StatusBarView.names[item] ?? ""): \(v)")
                result.append(e)
            }
            if item == .position, let m = message ?? flashText {
                messageElement.setAccessibilityValue(m)
                result.append(messageElement)
            }
        }
        return result
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        DrawnAccessibilityElement.element(at: point, in: accessibilityChildren() as? [DrawnAccessibilityElement] ?? []) ?? self
    }
}
