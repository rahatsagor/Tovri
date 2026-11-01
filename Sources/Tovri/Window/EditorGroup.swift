import AppKit

final class EditorTab {
    let document: Document
    private(set) var editor: EditorView?
    var pendingSelection: NSRange?
    var pendingScroll: CGPoint?

    init(document: Document) { self.document = document }

    func ensureEditor(delegate: EditorViewDelegate) -> EditorView {
        if let e = editor { return e }
        let e = EditorView(document: document)
        e.delegate = delegate
        editor = e
        if let sel = pendingSelection {
            let len = document.length
            let s = NSRange(location: min(sel.location, len), length: min(sel.length, max(0, len - min(sel.location, len))))
            e.textView.setAllSelections([s], scroll: false)
        }
        return e
    }

    func close() {
        editor?.removeFromSuperview()
        editor?.close()
        editor = nil
    }
}

/// A tab strip plus the editor area beneath it. A window holds one or more groups.
final class EditorGroup: NSObject, TabBarDelegate {
    unowned let controller: MainWindowController
    let tabBar = TabBarView()
    let container = FlippedView()
    private let emptyView = EmptyStateView()
    private lazy var previewButton: ToolButton = ToolButton(symbol: "eye", tooltip: "Preview (⇧⌘V)\nRead the rendered document. Click again to edit the source.") { [weak self] in
        guard let self, let e = self.activeEditor else { return }
        e.toggleMarkdownPreview()
        self.refreshAccessories()
    }
    private lazy var splitPreviewButton: ToolButton = ToolButton(symbol: "rectangle.split.2x1", tooltip: "Preview Side by Side (⌥⌘V)\nEdit the source with the rendered document beside it. The preview updates as you type and follows your scroll position.") { [weak self] in
        guard let self, let e = self.activeEditor else { return }
        e.toggleMarkdownPreviewSplit()
        self.refreshAccessories()
    }
    private static let compareTip = "Compare with Last Commit (⇧⌥⌘D)\nShow removed lines and tint changed ones in the editor. Press ⎋ to stop."
    private lazy var compareButton: ToolButton = ToolButton(symbol: "plus.forwardslash.minus", tooltip: EditorGroup.compareTip) { [weak self] in
        guard let self else { return }
        self.controller.activate(group: self)
        self.controller.compareWithLastCommit(nil)
        self.refreshAccessories()
    }
    private(set) var tabs: [EditorTab] = []
    private(set) var selectedIndex = -1

    var activeTab: EditorTab? { selectedIndex >= 0 && selectedIndex < tabs.count ? tabs[selectedIndex] : nil }
    var activeEditor: EditorView? { activeTab?.editor }

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
        tabBar.delegate = self
        container.addSubview(tabBar)
        container.addSubview(emptyView)
        container.addSubview(previewButton)
        container.addSubview(splitPreviewButton)
        container.addSubview(compareButton)
        previewButton.isHidden = true
        splitPreviewButton.isHidden = true
        compareButton.isHidden = true
        emptyView.onOpen = { [weak self] url in self?.controller.open(url: url) }
        container.onLayout = { [weak self] in self?.layout() }
        NotificationCenter.default.addObserver(self, selector: #selector(docStateChanged(_:)), name: .documentStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        refreshTabBar()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func docStateChanged(_ n: Notification) {
        guard let d = n.object as? Document, tabs.contains(where: { $0.document === d }) else { return }
        refreshTabBar()
    }

    @objc private func themeChanged() {
        refreshTabBar()
        emptyView.needsDisplay = true
    }

    func layout() {
        let b = container.bounds
        tabBar.frame = NSRect(x: 0, y: 0, width: b.width, height: TabBarView.height)
        previewButton.frame = NSRect(x: b.width - 34, y: 8, width: 26, height: 24)
        splitPreviewButton.frame = NSRect(x: b.width - 62, y: 8, width: 26, height: 24)
        let markdown = !previewButton.isHidden
        compareButton.frame = NSRect(x: b.width - (markdown ? 90 : 34), y: 8, width: 26, height: 24)
        let content = NSRect(x: 0, y: TabBarView.height, width: b.width, height: max(0, b.height - TabBarView.height))
        emptyView.frame = content
        activeEditor?.frame = content
    }

    // MARK: Tabs

    @discardableResult
    func add(_ document: Document, select: Bool = true, at index: Int? = nil) -> EditorTab {
        let tab = EditorTab(document: document)
        let i = min(index ?? (selectedIndex >= 0 ? selectedIndex + 1 : tabs.count), tabs.count)
        tabs.insert(tab, at: i)
        if select { self.select(i) } else {
            if selectedIndex >= i { selectedIndex += 1 }
            refreshTabBar()
        }
        return tab
    }

    func select(_ index: Int, focus: Bool = true) {
        guard index >= 0, index < tabs.count else { return }
        let previous = activeEditor
        selectedIndex = index
        let tab = tabs[index]
        let editor = tab.ensureEditor(delegate: controller)
        if previous !== editor { previous?.removeFromSuperview() }
        if editor.superview !== container {
            container.addSubview(editor, positioned: .below, relativeTo: tabBar)
        }
        layout()
        editor.layoutSubtreeIfNeeded()
        if let scroll = tab.pendingScroll {
            editor.scrollPosition = scroll
            tab.pendingScroll = nil
        }
        emptyView.isHidden = true
        if focus { editor.focus() }
        editor.colorizeVisible()
        refreshTabBar()
        controller.groupDidChangeSelection(self)
    }

    func index(of document: Document) -> Int? { tabs.firstIndex { $0.document === document } }

    func removeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs.remove(at: index)
        SessionStore.shared.setNeedsSave()
        let wasSelected = index == selectedIndex
        tab.close()
        if tabs.isEmpty {
            selectedIndex = -1
            emptyView.isHidden = false
            refreshTabBar()
            controller.groupDidChangeSelection(self)
            return
        }
        if wasSelected {
            selectedIndex = -1
            select(min(index, tabs.count - 1))
        } else {
            if index < selectedIndex { selectedIndex -= 1 }
            refreshTabBar()
        }
    }

    /// Removes a tab without closing its editor's document attachment; used when moving between groups.
    func detachTab(at index: Int) -> EditorTab? {
        guard index >= 0, index < tabs.count else { return nil }
        let tab = tabs[index]
        tab.pendingSelection = tab.editor?.textView.selectedRange()
        tab.pendingScroll = tab.editor?.scrollPosition
        removeTab(at: index)
        return tab
    }

    func moveTab(from: Int, to: Int) {
        guard from != to, from >= 0, from < tabs.count, to >= 0, to < tabs.count else { return }
        SessionStore.shared.setNeedsSave()
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        if selectedIndex == from { selectedIndex = to }
        else if from < selectedIndex && to >= selectedIndex { selectedIndex -= 1 }
        else if from > selectedIndex && to <= selectedIndex { selectedIndex += 1 }
        refreshTabBar()
    }

    func refreshTabBar() {
        var counts: [String: Int] = [:]
        let theme = ThemeManager.shared.active
        for t in tabs { counts[t.document.displayName, default: 0] += 1 }
        tabBar.items = tabs.map { t in
            let d = t.document
            var detail: String?
            if counts[d.displayName, default: 0] > 1, let url = d.url { detail = url.deletingLastPathComponent().lastPathComponent }
            let icon: NSImage? = d.isFindResults ? FileIcons.image("magnifyingglass", color: theme.chromeSecondary, size: 10.5)
                : FileIcons.image(forFileName: d.url?.lastPathComponent ?? (d.language === LanguageRegistry.shared.plain ? "file.txt" : "file." + (d.language.extensions.first ?? "txt")), theme: theme, size: 10.5)
            return TabItem(title: d.displayName, icon: icon, detail: detail, dirty: d.isDirty, missing: d.checkDiskStatusCached,
                           tooltip: d.url?.path ?? d.displayName)
        }
        tabBar.selectedIndex = selectedIndex
        emptyView.isHidden = !tabs.isEmpty
        refreshAccessories()
    }

    func refreshAccessories() {
        let markdown = activeEditor?.isMarkdown == true
        previewButton.isHidden = !markdown
        splitPreviewButton.isHidden = !markdown
        previewButton.isOn = activeEditor?.previewMode == .full
        splitPreviewButton.isOn = activeEditor?.previewMode == .split
        // Offered only for files with changes, so it never shows for people who don't use Git.
        let e = activeEditor
        let compare = e?.isComparing == true || (Settings.shared.gitGutter && e?.document.gitDiff.hunks.isEmpty == false)
        compareButton.isHidden = !compare
        compareButton.isOn = e?.isComparing == true
        compareButton.toolTip = e?.comparisonLabel.map { "Comparing with \($0)\nClick or press ⎋ to stop." } ?? EditorGroup.compareTip
        tabBar.trailingInset = (markdown ? 68 : 8) + (compare ? 28 : 0)
        layout()
    }

    // MARK: TabBarDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        select(index)
        controller.activate(group: self)
    }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        controller.closeTab(in: self, at: index)
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        moveTab(from: from, to: to)
    }

    func tabBarDidDoubleClickEmpty(_ bar: TabBarView) {
        controller.activate(group: self)
        controller.newTab(nil)
    }

    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        controller.tabMenu(group: self, index: index)
    }
}

extension Document {
    var checkDiskStatusCached: Bool { url != nil && fileMissing }
}

final class FlippedView: NSView {
    var onLayout: (() -> Void)?
    var background: NSColor? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func draw(_ dirtyRect: NSRect) {
        if let b = background { b.setFill(); dirtyRect.intersection(bounds).fill() }
    }
}

/// Shown in a group with no tabs: shortcuts plus clickable recent files.
final class EmptyStateView: NSView {
    override var isFlipped: Bool { true }
    var onOpen: ((URL) -> Void)?
    private var recentRects: [(NSRect, URL)] = []
    private var hoverIndex: Int?

    private let shortcuts: [(String, String)] = [
        ("Go to File", "⌘P"), ("Command Palette", "⇧⌘P"), ("New File", "⌘N"),
        ("Open File or Folder", "⌘O"), ("Find in Files", "⇧⌘F"),
    ]

    private static let titleFont = NSFont.systemFont(ofSize: 34, weight: .bold)
    private static let columnWidth: CGFloat = 300

    private struct ContentLayout {
        var titleY: CGFloat
        var x0: CGFloat
        var shortcutYs: [CGFloat]
        var recentsHeaderY: CGFloat
        var recentYs: [CGFloat]
    }

    private func recents() -> [URL] {
        let fm = FileManager.default
        return Array(RecentFiles.shared.items.filter { fm.fileExists(atPath: $0.path) }.prefix(6))
    }

    /// Nil when the view is too short to show anything.
    private func contentLayout(recentCount: Int) -> ContentLayout? {
        let titleH = ("Tovri" as NSString).size(withAttributes: [.font: EmptyStateView.titleFont]).height
        let recentH: CGFloat = recentCount == 0 ? 0 : 40 + CGFloat(recentCount) * 26
        let blockH = titleH + 24 + CGFloat(shortcuts.count) * 26 + recentH
        var y = round((bounds.height - blockH) / 2)
        guard y > 10 else { return nil }
        let titleY = y
        y += titleH + 24
        let shortcutYs = shortcuts.indices.map { y + CGFloat($0) * 26 }
        y += CGFloat(shortcuts.count) * 26 + 16
        let headerY = y
        y += 24
        return ContentLayout(titleY: titleY, x0: round((bounds.width - EmptyStateView.columnWidth) / 2), shortcutYs: shortcutYs,
                             recentsHeaderY: headerY, recentYs: (0..<recentCount).map { y + CGFloat($0) * 26 })
    }

    private static func recentRow(x0: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: x0 - 8, y: y - 3, width: columnWidth + 16, height: 24)
    }

    private var ownTrackingArea: NSTrackingArea?


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only replace our own area: removing every tracking area also kills AppKit's tooltip tracking.
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = recentRects.firstIndex { $0.0.contains(p) }
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
        if i != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = recentRects.first(where: { $0.0.contains(p) }) { onOpen?(hit.1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.editorBackground.setFill()
        bounds.fill()
        recentRects = []
        let fm = FileManager.default
        let recents = recents()
        guard let layout = contentLayout(recentCount: recents.count) else { return }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: EmptyStateView.titleFont,
                                                         .foregroundColor: theme.foreground.withAlphaComponent(0.13)]
        let title = "Tovri" as NSString
        let ts = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: round((bounds.width - ts.width) / 2), y: layout.titleY), withAttributes: titleAttrs)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.chromeSecondary]
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: theme.chromeForeground.withAlphaComponent(0.7)]
        let colW = EmptyStateView.columnWidth
        let x0 = layout.x0
        for ((label, key), y) in zip(shortcuts, layout.shortcutYs) {
            (label as NSString).draw(at: NSPoint(x: x0, y: y), withAttributes: labelAttrs)
            let ks = (key as NSString).size(withAttributes: keyAttrs)
            (key as NSString).draw(at: NSPoint(x: x0 + colW - ks.width, y: y), withAttributes: keyAttrs)
        }
        guard !recents.isEmpty else { return }
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8)]
        ("RECENT" as NSString).draw(at: NSPoint(x: x0, y: layout.recentsHeaderY), withAttributes: headAttrs)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        for (i, (url, y)) in zip(recents, layout.recentYs).enumerated() {
            let row = EmptyStateView.recentRow(x0: x0, y: y)
            if hoverIndex == i {
                theme.tabHoverBackground.setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let img = isDir.boolValue ? FileIcons.image("folder.fill", color: theme.accent.mix(theme.chromeSecondary, 0.35), size: 11)
                                      : FileIcons.image(forFileName: url.lastPathComponent, theme: theme, size: 11)
            if let img { img.draw(in: NSRect(x: x0, y: y + 1, width: img.size.width, height: img.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            let name = NSMutableAttributedString(string: url.lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.accent.mix(theme.foreground, 0.35)])
            name.append(NSAttributedString(string: "   " + (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                                           attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8)]))
            name.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: name.length))
            name.draw(with: NSRect(x: x0 + 20, y: y, width: colW - 20, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            recentRects.append((row, url))
        }
    }

    // MARK: Accessibility

    private lazy var shortcutElements: [DrawnAccessibilityElement] = shortcuts.enumerated().map { i, shortcut in
        let e = DrawnAccessibilityElement(in: self, role: .staticText) { [weak self] in
            guard let self, let layout = self.contentLayout(recentCount: self.recents().count) else { return nil }
            return NSRect(x: layout.x0, y: layout.shortcutYs[i], width: EmptyStateView.columnWidth, height: 18)
        }
        e.setAccessibilityValue("\(shortcut.0): \(EmptyStateView.spokenShortcut(shortcut.1))")
        return e
    }

    private lazy var recentsHeaderElement: DrawnAccessibilityElement = {
        let e = DrawnAccessibilityElement(in: self, role: .staticText) { [weak self] in
            guard let self, let layout = self.contentLayout(recentCount: self.recents().count) else { return nil }
            return NSRect(x: layout.x0, y: layout.recentsHeaderY, width: EmptyStateView.columnWidth, height: 16)
        }
        e.setAccessibilityValue("Recent")
        return e
    }()

    private var recentElements: [(URL, DrawnAccessibilityElement)] = []

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "No Open Files" }

    override func accessibilityChildren() -> [Any]? {
        let recents = recents()
        if recentElements.map(\.0) != recents {
            recentElements = recents.enumerated().map { i, url in
                let e = DrawnAccessibilityElement(in: self, role: .button) { [weak self] in
                    guard let self, let layout = self.contentLayout(recentCount: self.recents().count), i < layout.recentYs.count else { return nil }
                    return EmptyStateView.recentRow(x0: layout.x0, y: layout.recentYs[i])
                }
                e.setAccessibilityLabel(url.lastPathComponent)
                e.setAccessibilityHelp("Open " + (url.path as NSString).abbreviatingWithTildeInPath)
                e.onPress = { [weak self] in self?.onOpen?(url) }
                return (url, e)
            }
        }
        guard contentLayout(recentCount: recents.count) != nil else { return [] }
        return shortcutElements + (recents.isEmpty ? [] : [recentsHeaderElement]) + recentElements.map(\.1)
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        DrawnAccessibilityElement.element(at: point, in: accessibilityChildren() as? [DrawnAccessibilityElement] ?? []) ?? self
    }

    static func spokenShortcut(_ keys: String) -> String {
        let names: [Character: String] = ["⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control"]
        return keys.map { names[$0] ?? String($0) }.joined(separator: " ")
    }
}
