import AppKit

/// What the sidebar's Changes list asks the window to do with a file.
enum SidebarChangeAction { case open, compare, history, reveal }

/// Files / Changes switcher at the top of the sidebar, shown only with Changes and file history on.
final class SidebarTabs: NSView {
    enum Tab: Int { case files, changes }
    var selected: Tab = .files { didSet { needsDisplay = true } }
    var changeCount = 0 { didSet { if oldValue != changeCount { needsDisplay = true } } }
    var onSelect: ((Tab) -> Void)?
    private var hover: Tab?
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Sidebar view")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rect(_ tab: Tab) -> NSRect {
        let inner = bounds.insetBy(dx: 10, dy: 3)
        let w = floor((inner.width - 4) / 2)
        return NSRect(x: inner.minX + (tab == .files ? 0 : w + 4), y: inner.minY, width: w, height: inner.height)
    }

    private func tab(at p: NSPoint) -> Tab? { [.files, .changes].first { rect($0).contains(p) } }

    private var ownTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let t = tab(at: convert(event.locationInWindow, from: nil))
        if t != hover { hover = t; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard let t = tab(at: convert(event.locationInWindow, from: nil)), t != selected else { return }
        selected = t
        onSelect?(t)
    }

    override func accessibilityValue() -> Any? { selected == .files ? "Files" : "Changes" }
    override func accessibilityPerformPress() -> Bool {
        selected = selected == .files ? .changes : .files
        onSelect?(selected)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        for t in [Tab.files, .changes] {
            let r = rect(t)
            if t == selected {
                theme.sidebarSelection.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            } else if t == hover {
                theme.tabHoverBackground.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let color = t == selected ? theme.chromeForeground : theme.chromeSecondary
            let title = (t == .files ? "Files" : "Changes") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let ts = title.size(withAttributes: attrs)
            var badge: (NSString, NSSize, [NSAttributedString.Key: Any])?
            if t == .changes && changeCount > 0 {
                let s = (changeCount > 999 ? "999+" : "\(changeCount)") as NSString
                let a: [NSAttributedString.Key: Any] = [.font: countFont, .foregroundColor: theme.color(.changed) ?? .systemOrange]
                badge = (s, s.size(withAttributes: a), a)
            }
            let total = ts.width + (badge.map { $0.1.width + 6 } ?? 0)
            var x = round(r.midX - total / 2)
            title.draw(at: NSPoint(x: x, y: round(r.midY - ts.height / 2)), withAttributes: attrs)
            x += ts.width + 6
            if let (s, size, a) = badge { s.draw(at: NSPoint(x: x, y: round(r.midY - size.height / 2)), withAttributes: a) }
        }
    }
}

/// The sidebar's list of files with uncommitted changes and the lines each adds and removes.
final class ChangesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onAction: ((GitRepository.ChangedFile, SidebarChangeAction) -> Void)?
    private(set) var files: [GitRepository.ChangedFile] = []
    private let scroll = OverlayScrollView(frame: .zero)
    private let list = SidebarOutlineView()
    private let empty = NSTextField(labelWithString: "No uncommitted changes")
    private var menuFile: GitRepository.ChangedFile?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: .init("change"))
        col.resizingMask = .autoresizingMask
        list.addTableColumn(col)
        list.outlineTableColumn = col
        list.headerView = nil
        list.rowHeight = 24
        list.indentationPerLevel = 0
        list.intercellSpacing = .zero
        list.style = .plain
        list.focusRingType = .none
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.action = #selector(clicked)
        list.onReturn = { [weak self] in self?.perform(.open, row: self?.list.selectedRow ?? -1) }
        list.menuProvider = { [weak self] row in self?.menu(row: row) }
        list.setAccessibilityLabel("Changed files")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        addSubview(empty)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFiles(_ new: [GitRepository.ChangedFile]) {
        let selected = list.selectedRow >= 0 && list.selectedRow < files.count ? files[list.selectedRow].path : nil
        files = new
        list.reloadData()
        if let selected, let i = files.firstIndex(where: { $0.path == selected }) {
            list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        empty.isHidden = !files.isEmpty
    }

    func applyTheme() {
        empty.textColor = ThemeManager.shared.active.chromeSecondary
        list.reloadData()
    }

    func focus() { window?.makeFirstResponder(list) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        list.tableColumns.first?.width = scroll.contentSize.width - 4
        empty.frame = NSRect(x: 10, y: 24, width: bounds.width - 20, height: 18)
    }

    @objc private func clicked() { perform(.open, row: list.clickedRow) }

    private func perform(_ action: SidebarChangeAction, row: Int) {
        guard row >= 0, row < files.count else { return }
        onAction?(files[row], action)
    }

    private func menu(row: Int) -> NSMenu? {
        guard row >= 0, row < files.count else { return nil }
        menuFile = files[row]
        let m = NSMenu()
        let deleted = files[row].status == .deleted
        for (title, sel, enabled) in [("Open", #selector(menuOpen), !deleted), ("Compare with Last Commit", #selector(menuCompare), !deleted),
                                      ("File History…", #selector(menuHistory), !deleted && files[row].status != .untracked),
                                      ("Reveal in Finder", #selector(menuReveal), !deleted)] {
            let item = m.addItem(withTitle: title, action: enabled ? sel : nil, keyEquivalent: "")
            item.target = self
        }
        return m
    }

    @objc private func menuOpen() { menuFile.map { onAction?($0, .open) } }
    @objc private func menuCompare() { menuFile.map { onAction?($0, .compare) } }
    @objc private func menuHistory() { menuFile.map { onAction?($0, .history) } }
    @objc private func menuReveal() { menuFile.map { onAction?($0, .reveal) } }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? files.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { index as NSNumber }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { HoverRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let i = (item as? NSNumber)?.intValue, i < files.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("change")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCell) ?? ChangeCell()
        cell.identifier = id
        cell.configure(files[i])
        return cell
    }
}

private final class ChangeCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let dir = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        dir.font = .systemFont(ofSize: 11)
        dir.lineBreakMode = .byTruncatingHead
        counts.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        [icon, name, dir, counts].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        [icon, name, dir, counts].forEach { $0.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? { nil }

    func configure(_ f: GitRepository.ChangedFile) {
        let theme = ThemeManager.shared.active
        let file = (f.path as NSString).lastPathComponent
        let folder = (f.path as NSString).deletingLastPathComponent
        icon.image = FileIcons.image(forFileName: file, theme: theme, size: 12.5)
        var color = theme.chromeForeground
        switch f.status {
        case .modified, .renamed: color = theme.color(.changed) ?? color
        case .added, .untracked: color = theme.color(.inserted) ?? color
        case .deleted, .conflicted: color = theme.color(.deleted) ?? color
        case .ignored: break
        }
        var nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        if f.status == .deleted { nameAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        name.attributedStringValue = NSAttributedString(string: file, attributes: nameAttrs)
        dir.stringValue = folder
        dir.textColor = theme.chromeSecondary
        counts.attributedStringValue = MainWindowController.changeSummary(f.added.map { ($0, f.removed ?? 0) }, status: f.status, theme: theme)
        let summary = f.added.map { "\($0) added, \(f.removed ?? 0) removed" }
        setAccessibilityLabel([file, folder.isEmpty ? nil : "in \(folder)", f.status.label, summary].compactMap { $0 }.joined(separator: ", "))
        toolTip = f.path
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        // Labels inset their text slightly, so a frame of exactly the text's width cuts off the end.
        let cw = ceil(counts.attributedStringValue.size().width) + 8
        counts.frame = NSRect(x: bounds.width - 10 - cw, y: (h - 15) / 2, width: cw, height: 15)
        let right = counts.frame.minX - 8
        let nw = min(ceil(name.attributedStringValue.size().width) + 4, max(0, right - 33))
        name.frame = NSRect(x: 33, y: (h - 17) / 2, width: nw, height: 17)
        let dx = name.frame.maxX + 6
        dir.frame = NSRect(x: dx, y: (h - 14) / 2 + 0.5, width: max(0, right - dx), height: 14)
    }
}
