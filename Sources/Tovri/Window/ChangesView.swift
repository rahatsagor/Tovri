import AppKit

/// What the sidebar's Changes list asks the window to do with a file.
enum SidebarChangeAction { case open, compare, history }

/// What the Changes list asks the window to do with the selected files.
enum ChangeListAction { case stage, unstage, discard, patch, reveal }

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

/// The sidebar's list of files with uncommitted changes and the lines each adds and removes, in
/// a Staged Changes section and a Changes section for what isn't staged.
final class ChangesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    var onAction: ((GitRepository.ChangedFile, SidebarChangeAction) -> Void)?
    var onListAction: (([GitRepository.ChangedFile], ChangeListAction) -> Void)?
    var onFilterChange: ((ChangeFilter) -> Void)?
    private(set) var allFiles: [GitRepository.ChangedFile] = []
    private(set) var files: [GitRepository.ChangedFile] = []
    private var stagedFiles: [GitRepository.ChangedFile] = []
    private var unstagedFiles: [GitRepository.ChangedFile] = []

    var filter: ChangeFilter = Settings.shared.gitChangesFilter {
        didSet {
            guard oldValue != filter else { return }
            rebuildRows()
            onFilterChange?(filter)
        }
    }

    var sort: ChangeSort = Settings.shared.gitChangesSort {
        didSet {
            guard oldValue != sort else { return }
            rebuildRows()
        }
    }

    var query: String {
        get { filterField.stringValue }
        set {
            guard filterField.stringValue != newValue else { return }
            filterField.stringValue = newValue
            rebuildRows()
        }
    }

    var isFiltered: Bool { filter != .all || !ChangesView.queryTerms(query).isEmpty }

    /// Unique changed paths matching `filter` (ignoring the quick text box).
    var filteredPathCount: Int {
        var seen = Set<String>()
        for f in allFiles where filter.matches(f) { seen.insert(f.path) }
        return seen.count
    }

    let filterField = ThemedTextField(placeholder: "Filter")
    let filterButton = ToolButton(symbol: "line.3.horizontal.decrease.circle")
    let sortButton = ToolButton(symbol: "arrow.up.arrow.down")
    private let scroll = OverlayScrollView(frame: .zero)
    let list = SidebarOutlineView()
    private let empty = NSTextField(labelWithString: "No uncommitted changes")
    private var menuFiles: [GitRepository.ChangedFile] = []
    private var menuSection: [GitRepository.ChangedFile] = []

    /// A section header, when `file` is nil, or one file in the section.
    private final class Row {
        let staged: Bool
        let file: GitRepository.ChangedFile?
        init(staged: Bool, file: GitRepository.ChangedFile?) {
            self.staged = staged
            self.file = file
        }
    }
    private var rows: [Row] = []
    private static let toolbarHeight: CGFloat = 30

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        filterField.fontSize = 12
        filterField.leadingSymbol = "magnifyingglass"
        filterField.field.delegate = self
        filterField.field.setAccessibilityLabel("Filter changes")
        filterField.onClear = { [weak self] in
            guard let self else { return }
            self.query = ""
            self.window?.makeFirstResponder(self.filterField.field)
        }
        filterButton.symbolSize = 12
        filterButton.onClick = { [weak self] in self?.showFilterMenu() }
        sortButton.symbolSize = 11.5
        sortButton.onClick = { [weak self] in self?.showSortMenu() }
        [filterField, filterButton, sortButton].forEach(addSubview)

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
        list.allowsMultipleSelection = true
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.action = #selector(clicked)
        list.onReturn = { [weak self] in
            guard let self, let f = self.selectedFiles.first, self.selectedFiles.count == 1 else { return }
            self.onAction?(f, .open)
        }
        list.onSpace = { [weak self] in self?.toggleStaged() }
        list.onDelete = { [weak self] in self?.discardSelected() }
        list.onSlash = { [weak self] in self?.focusFilter() }
        list.menuProvider = { [weak self] row in self?.menu(row: row) }
        list.setAccessibilityLabel("Changed files")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        addSubview(empty)
        updateToolbarControls()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func key(_ f: GitRepository.ChangedFile) -> String { (f.staged ? "s\0" : "w\0") + f.path }

    static func queryTerms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    }

    static func matchesQuery(_ file: GitRepository.ChangedFile, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            containsCaseInsensitive(file.path, lowercasedTerm: term)
                || (file.originalPath.map { containsCaseInsensitive($0, lowercasedTerm: term) } ?? false)
        }
    }

    /// Fast ASCII byte scan for the common case, falling back to Unicode case/diacritic folding.
    private static func containsCaseInsensitive(_ haystack: String, lowercasedTerm needle: String) -> Bool {
        if needle.isEmpty { return true }
        var hasNonASCII = false
        for b in haystack.utf8 where b >= 128 { hasNonASCII = true; break }
        if !hasNonASCII {
            for b in needle.utf8 where b >= 128 { hasNonASCII = true; break }
        }
        if hasNonASCII { return haystack.localizedStandardContains(needle) }
        return (haystack.utf8.withContiguousStorageIfAvailable { hBuf in
            needle.utf8.withContiguousStorageIfAvailable { nBuf in
                let hCount = hBuf.count, nCount = nBuf.count
                guard nCount <= hCount else { return false }
                let first = nBuf[0]
                let end = hCount - nCount
                var i = 0
                while i <= end {
                    let b0 = hBuf[i]
                    if (b0 >= 65 && b0 <= 90 ? b0 &+ 32 : b0) == first {
                        var j = 1
                        while j < nCount {
                            let bj = hBuf[i &+ j]
                            if (bj >= 65 && bj <= 90 ? bj &+ 32 : bj) != nBuf[j] { break }
                            j &+= 1
                        }
                        if j == nCount { return true }
                    }
                    i &+= 1
                }
                return false
            }
        } ?? nil) ?? haystack.localizedStandardContains(needle)
    }

    func setFiles(_ new: [GitRepository.ChangedFile]) {
        allFiles = new
        rebuildRows()
    }

    private func rebuildRows() {
        let selected = Set(selectedFiles.map(ChangesView.key))
        let terms = ChangesView.queryTerms(query)
        let matched = allFiles.filter { filter.matches($0) && ChangesView.matchesQuery($0, terms: terms) }
        stagedFiles = sort.sorted(matched.filter(\.staged))
        unstagedFiles = sort.sorted(matched.filter { !$0.staged })
        files = stagedFiles + unstagedFiles
        rows = []
        rows.reserveCapacity(files.count + 2)
        for (staged, section) in [(true, stagedFiles), (false, unstagedFiles)] where !section.isEmpty {
            rows.append(Row(staged: staged, file: nil))
            rows += section.map { Row(staged: staged, file: $0) }
        }
        list.reloadData()
        let keep = IndexSet(rows.indices.filter { rows[$0].file.map { selected.contains(ChangesView.key($0)) } ?? false })
        if !keep.isEmpty { list.selectRowIndexes(keep, byExtendingSelection: false) }
        empty.stringValue = !terms.isEmpty ? "No matching changes" : filter.emptyMessage
        empty.isHidden = !rows.isEmpty
        updateToolbarControls()
    }

    private func updateToolbarControls() {
        filterButton.isOn = filter != .all
        filterButton.toolTip = filter == .all ? "Filter Changes" : "Filter Changes (\(filter.title))"
        sortButton.isOn = sort != .path
        sortButton.toolTip = "Sort Changes (by \(sort.title))"
    }

    func syncSettings() {
        let newFilter = Settings.shared.gitChangesFilter
        let newSort = Settings.shared.gitChangesSort
        if sort != newSort { sort = newSort }
        if filter != newFilter { filter = newFilter }
    }

    func applyTheme() {
        filterField.applyTheme()
        filterButton.needsDisplay = true
        sortButton.needsDisplay = true
        empty.textColor = ThemeManager.shared.active.chromeSecondary
        list.reloadData()
    }

    func focus() { window?.makeFirstResponder(list) }
    func focusFilter() { window?.makeFirstResponder(filterField.field) }

    override func layout() {
        super.layout()
        let bar = ChangesView.toolbarHeight
        sortButton.frame = NSRect(x: bounds.width - 32, y: 3, width: 22, height: 24)
        filterButton.frame = NSRect(x: sortButton.frame.minX - 24, y: 3, width: 22, height: 24)
        filterField.frame = NSRect(x: 10, y: 3, width: max(48, filterButton.frame.minX - 16), height: 24)
        scroll.frame = NSRect(x: 0, y: bar + 2, width: bounds.width, height: max(0, bounds.height - bar - 2))
        list.tableColumns.first?.width = scroll.contentSize.width - 4
        empty.frame = NSRect(x: 10, y: bar + 24, width: bounds.width - 20, height: 18)
    }

    // MARK: Filter & sort menus

    func makeFilterMenu() -> NSMenu {
        let m = NSMenu()
        let groups: [[ChangeFilter]] = [[.all], [.tracked, .untracked], [.staged, .unstaged], [.modified, .deleted]]
        for (gi, group) in groups.enumerated() {
            if gi > 0 { m.addItem(.separator()) }
            for f in group {
                let item = m.addItem(withTitle: f.title, action: #selector(chooseFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = f.rawValue
                item.state = filter == f ? .on : .off
            }
        }
        return m
    }

    func makeSortMenu() -> NSMenu {
        let m = NSMenu()
        for s in ChangeSort.allCases {
            let item = m.addItem(withTitle: "Sort by \(s.title)", action: #selector(chooseSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = sort == s ? .on : .off
        }
        return m
    }

    private func showFilterMenu() {
        makeFilterMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.maxY + 2), in: filterButton)
    }

    private func showSortMenu() {
        makeSortMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sortButton.bounds.maxY + 2), in: sortButton)
    }

    @objc private func chooseFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let chosen = ChangeFilter(rawValue: raw) else { return }
        Settings.shared.gitChangesFilter = chosen
        filter = chosen
    }

    @objc private func chooseSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let chosen = ChangeSort(rawValue: raw) else { return }
        Settings.shared.gitChangesSort = chosen
        sort = chosen
    }

    // MARK: Filter text field

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if !query.isEmpty { query = "" } else { focus() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let first = rows.firstIndex(where: { $0.file != nil }) {
                if list.selectedRowIndexes.isEmpty {
                    list.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
                }
                focus()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let f = selectedFiles.first ?? rows.lazy.compactMap(\.file).first {
                onAction?(f, .open)
            }
            return true
        default:
            return false
        }
    }

    private var selectedFiles: [GitRepository.ChangedFile] {
        list.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].file : nil }
    }

    private func section(staged: Bool) -> [GitRepository.ChangedFile] { staged ? stagedFiles : unstagedFiles }

    private func sectionActionTitle(staged: Bool) -> String {
        staged ? (isFiltered ? "Unstage Shown" : "Unstage All") : (isFiltered ? "Stage Shown" : "Stage All")
    }

    @objc private func clicked() {
        let row = list.clickedRow
        guard row >= 0, row < rows.count, let f = rows[row].file else { return }
        // Command- and Shift-clicks change the selection without opening anything.
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        onAction?(f, .open)
    }

    /// Space stages the selected files, or unstages them when they are all staged.
    private func toggleStaged() {
        let sel = selectedFiles
        let unstaged = sel.filter { !$0.staged }
        if !unstaged.isEmpty { onListAction?(unstaged, .stage) } else if !sel.isEmpty { onListAction?(sel, .unstage) }
    }

    private func discardSelected() {
        let targets = selectedFiles.filter { !$0.staged && $0.status != .conflicted }
        if targets.isEmpty { NSSound.beep() } else { onListAction?(targets, .discard) }
    }

    private func menu(row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else {
            let m = NSMenu()
            let filterSub = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
            filterSub.submenu = makeFilterMenu()
            m.addItem(filterSub)
            let sortSub = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
            sortSub.submenu = makeSortMenu()
            m.addItem(sortSub)
            return m
        }
        let r = rows[row]
        menuSection = section(staged: r.staged)
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true, key: String = "") {
            let item = m.addItem(withTitle: title, action: enabled ? sel : nil, keyEquivalent: key)
            item.target = self
        }
        guard r.file != nil else {
            add(sectionActionTitle(staged: r.staged), r.staged ? #selector(menuUnstageAll) : #selector(menuStageAll))
            return m
        }
        // Like Finder: right-clicking outside the selection acts on that row alone.
        if !list.selectedRowIndexes.contains(row) { list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        menuFiles = selectedFiles
        let n = menuFiles.count
        let suffix = n == 1 ? "" : " \(n) Files"
        if n == 1, let f = menuFiles.first {
            let deleted = f.status == .deleted
            add("Open", #selector(menuOpen), enabled: !deleted)
            add("Compare with Last Commit", #selector(menuCompare), enabled: !deleted)
            add("File History…", #selector(menuHistory), enabled: !deleted && f.status != .untracked && !(f.staged && f.status == .added))
        }
        add("Open Changes as Patch", #selector(menuPatch))
        m.addItem(.separator())
        let unstaged = menuFiles.filter { !$0.staged }
        if !unstaged.isEmpty { add("Stage" + (unstaged.count == n ? suffix : ""), #selector(menuStage)) }
        if unstaged.count < n { add("Unstage" + (unstaged.isEmpty ? suffix : ""), #selector(menuUnstage)) }
        if !unstaged.isEmpty {
            add("Discard Changes…", #selector(menuDiscard), enabled: unstaged.contains { $0.status != .conflicted }, key: "\u{8}")
        }
        m.addItem(.separator())
        add(sectionActionTitle(staged: r.staged), r.staged ? #selector(menuUnstageAll) : #selector(menuStageAll))
        m.addItem(.separator())
        add("Reveal in Finder", #selector(menuReveal), enabled: menuFiles.contains { $0.status != .deleted })
        return m
    }

    @objc private func menuOpen() { menuFiles.first.map { onAction?($0, .open) } }
    @objc private func menuCompare() { menuFiles.first.map { onAction?($0, .compare) } }
    @objc private func menuHistory() { menuFiles.first.map { onAction?($0, .history) } }
    @objc private func menuPatch() { onListAction?(menuFiles, .patch) }
    @objc private func menuStage() { onListAction?(menuFiles.filter { !$0.staged }, .stage) }
    @objc private func menuUnstage() { onListAction?(menuFiles.filter(\.staged), .unstage) }
    @objc private func menuDiscard() { onListAction?(menuFiles.filter { !$0.staged && $0.status != .conflicted }, .discard) }
    @objc private func menuStageAll() { onListAction?(menuSection, .stage) }
    @objc private func menuUnstageAll() { onListAction?(menuSection, .unstage) }
    @objc private func menuReveal() { onListAction?(menuFiles.filter { $0.status != .deleted }, .reveal) }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? rows.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { rows[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Row)?.file == nil ? 28 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (item as? Row)?.file == nil ? ThemedRowView() : HoverRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { $0 < rows.count && rows[$0].file != nil }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        guard let file = row.file else {
            let id = NSUserInterfaceItemIdentifier("changeSection")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeSectionCell) ?? ChangeSectionCell()
            cell.identifier = id
            let staged = row.staged
            cell.configure(staged: staged, count: section(staged: staged).count, actionTitle: sectionActionTitle(staged: staged)) { [weak self] in
                guard let self else { return }
                self.onListAction?(self.section(staged: staged), staged ? .unstage : .stage)
            }
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("change")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCell) ?? ChangeCell()
        cell.identifier = id
        cell.configure(file)
        return cell
    }
}

/// "STAGED CHANGES 2" with an Unstage All button, or "CHANGES 5" with Stage All.
private final class ChangeSectionCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let button = ToolButton(symbol: "plus")

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        button.symbolSize = 11
        [title, button].forEach(addSubview)
        title.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(staged: Bool, count: Int, actionTitle: String, action: @escaping () -> Void) {
        let theme = ThemeManager.shared.active
        let name = staged ? "Staged Changes" : "Changes"
        let text = NSMutableAttributedString(string: name.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: theme.chromeSecondary,
        ])
        text.append(NSAttributedString(string: "  \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8),
        ]))
        title.attributedStringValue = text
        button.symbol = staged ? "minus" : "plus"
        button.toolTip = actionTitle
        button.onClick = action
        setAccessibilityLabel("\(name), \(count == 1 ? "1 file" : "\(count) files")")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        button.frame = NSRect(x: bounds.width - 32, y: (h - 22) / 2 + 1, width: 22, height: 22)
        title.frame = NSRect(x: 14, y: (h - 14) / 2 + 1, width: max(0, button.frame.minX - 18), height: 14)
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
        setAccessibilityLabel([file, folder.isEmpty ? nil : "in \(folder)", f.status.label, f.staged ? "staged" : nil, summary]
            .compactMap { $0 }.joined(separator: ", "))
        toolTip = f.originalPath.map { "\($0) → \(f.path)" } ?? f.path
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
