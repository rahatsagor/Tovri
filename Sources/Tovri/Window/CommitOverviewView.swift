import AppKit

/// The page a commit tab shows in Overview mode: a card with the commit's author, message and
/// parents, then each changed file as a section that opens to show its own changes. One virtualized
/// table, so a commit with a thousand files scrolls as smoothly as one with five.
final class CommitOverviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row { case card, filesHeader, file(Int), more, empty(String) }

    let model: CommitOverviewModel
    /// A file or the commit was acted on (open changes, open the file, compare).
    var onAction: ((HistoryAction) -> Void)?
    /// "Show in Patch" for a file: switch to the patch at its section.
    var onShowPatch: ((Int) -> Void)?
    var onOpenParent: ((String) -> Void)?

    private let scroll = OverlayScrollView(frame: .zero)
    let table = OverviewTableView()
    private(set) var rows: [Row] = []
    private var columnWidth: CGFloat = 0
    private var cardHeights: (width: CGFloat, height: CGFloat)?
    private(set) var metrics = DiffMetrics.current()
    /// How many file diffs were built; collapsed files cost nothing.
    private(set) var renderCount = 0
    private var renderCache = DiffRenderCache()
    private var bodyHeights: [Int: CGFloat] = [:]

    static let maxContentWidth: CGFloat = 900
    static let sectionHeaderHeight: CGFloat = 36
    static let sectionGap: CGFloat = 10

    /// The centered column inside a table `width` wide.
    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let pad: CGFloat = width < 560 ? 16 : 28
        let w = max(0, min(maxContentWidth, width - 2 * pad))
        return (floor((width - w) / 2), w)
    }

    override var isFlipped: Bool { true }

    init(model: CommitOverviewModel) {
        self.model = model
        super.init(frame: .zero)
        if model.detail.files.isEmpty && model.detail.hiddenFileCount == 0 {
            rows = [.card, .empty(model.commit.parents.count > 1 ? "No changes compared with the first parent." : "This commit doesn’t change any files.")]
        } else {
            rows = [.card, .filesHeader] + model.detail.files.indices.map { Row.file($0) } + (model.detail.hiddenFileCount > 0 ? [.more] : [])
        }
        let col = NSTableColumn(identifier: .init("overview"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] option in
            guard let self, let i = self.selectedFileIndex else { return }
            if option { self.openChanges(i, pinned: false) } else { self.toggle(i) }
        }
        table.onSpace = { [weak self] in
            guard let self, let i = self.selectedFileIndex else { return }
            self.toggle(i)
        }
        table.menuProvider = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count, case .file(let i) = self.rows[row] else { return nil }
            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return self.makeMenu(for: i, full: true)
        }
        table.setAccessibilityLabel("Changed files")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        addSubview(scroll)
        setAccessibilityElement(false)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, let first = model.detail.files.indices.first { selectFile(first) }
    }

    /// Side by side needs room for two columns; narrower than that, one column shows.
    static let minSplitWidth: CGFloat = 760

    var effectiveSplit: Bool { model.isSplit && CommitOverviewView.column(in: columnWidth).width - 2 >= CommitOverviewView.minSplitWidth }
    private var isNarrowForSplit: Bool { model.isSplit && !effectiveSplit }

    var selectedFileIndex: Int? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .file(let i) = rows[r] else { return nil }
        return i
    }

    func selectFile(_ index: Int) {
        guard let r = row(ofFile: index) else { return }
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private func row(ofFile index: Int) -> Int? {
        rows.firstIndex(where: { if case .file(index) = $0 { return true } else { return false } })
    }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        scroll.backgroundColor = theme.editorBackground
        scroll.drawsBackground = !theme.translucent
        scroll.appearance = theme.appearance
        table.backgroundColor = theme.translucent ? .clear : theme.editorBackground
        cardHeights = nil
        metrics = DiffMetrics.current()
        renderCache.removeAll()
        bodyHeights = [:]
        reload()
    }

    private func reload() {
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < rows.count { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        table.tableColumns.first?.width = width
        if abs(width - columnWidth) > 0.5 {
            let before = effectiveSplit
            columnWidth = width
            cardHeights = nil
            if before != effectiveSplit { bodyHeights = [:] }
            reload()
            if before != effectiveSplit { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
        }
    }

    // MARK: Sections

    func isExpanded(_ index: Int) -> Bool { index < model.expanded.count && model.expanded[index] }

    func toggle(_ index: Int) {
        guard index < model.expanded.count else { return }
        model.expanded[index].toggle()
        refreshSection(index)
    }

    func setAllExpanded(_ on: Bool) {
        model.expanded = model.expanded.map { _ in on }
        reload()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    var allExpanded: Bool { !model.expanded.isEmpty && model.expanded.allSatisfy { $0 } }

    /// Side by side or in one column; the choice is kept for the next commit tab.
    func setSplit(_ split: Bool) {
        guard model.isSplit != split else { return }
        model.isSplit = split
        Settings.shared.gitDiffLayoutIsSplit = split
        bodyHeights = [:]
        reload()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private func showMore(_ index: Int) {
        model.rowLimits[index] = CommitOverviewModel.maxRowLimit
        bodyHeights[index] = nil
        refreshSection(index)
    }

    private func refreshSection(_ index: Int) {
        bodyHeights[index] = nil
        guard let r = row(ofFile: index) else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: r))
        table.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integer: 0))
        updateSelection()
    }

    private func total(_ index: Int) -> Int { model.diff(index)?.rowCount(split: effectiveSplit) ?? 0 }

    private func hasDiffRows(_ index: Int) -> Bool { !(model.diff(index)?.hunks.isEmpty ?? true) }

    /// The height of a section's body when it is open, from row counts alone.
    func bodyHeight(_ index: Int) -> CGFloat {
        if let h = bodyHeights[index] { return h }
        let h: CGFloat
        if hasDiffRows(index) {
            let total = self.total(index)
            let limit = model.rowLimits[index]
            h = metrics.bodyHeight(rows: min(total, limit), hidden: total > limit)
        } else {
            h = DiffMetrics.noteHeight
        }
        bodyHeights[index] = h
        return h
    }

    private func render(_ index: Int) -> (render: DiffRender, hidden: Int)? {
        guard let diff = model.diff(index), !diff.hunks.isEmpty, let text = model.textSource?() else { return nil }
        let limit = model.rowLimits[index]
        let split = effectiveSplit
        let key = DiffRenderCache.Key(file: index, split: split, limit: limit)
        let total = diff.rowCount(split: split)
        if let r = renderCache.render(for: key) { return (r, max(0, total - limit)) }
        let name = ((model.detail.files[index].path) as NSString).lastPathComponent
        let first = diff.hunks.first.flatMap { $0.lines.first }.map { text.substring(with: $0.range) }
        renderCount += 1
        let r = DiffRenderer.render(file: diff, text: text, split: split, limit: limit,
                                    language: LanguageRegistry.shared.language(forFileName: name, firstLine: first),
                                    theme: ThemeManager.shared.active, metrics: metrics)
        renderCache.insert(r, for: key)
        return (r, max(0, total - limit))
    }

    // MARK: Actions

    private func openChanges(_ index: Int, pinned: Bool) {
        guard index < model.detail.files.count else { return }
        onAction?(.openFile(model.detail.files[index], .changes, pinned: pinned))
    }

    private func clickedFileIndex() -> Int? {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case .file(let i) = rows[r] else { return nil }
        return i
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent, event.clickCount != 2, let i = clickedFileIndex() else { return }
        let p = table.convert(event.locationInWindow, from: nil)
        if p.y - table.rect(ofRow: table.clickedRow).minY <= CommitOverviewView.sectionHeaderHeight { toggle(i) }
    }

    @objc private func doubleClicked() {
        guard let i = clickedFileIndex() else { return }
        // The first click of the double-click toggled the section; undo that, and open the changes.
        toggle(i)
        openChanges(i, pinned: false)
    }

    private func updateSelection() {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.subviews.first as? FileSectionCell)?.isSelectedSection = row == selected
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    // MARK: Menu

    func makeMenu(for index: Int, full: Bool) -> NSMenu {
        let file = model.detail.files[index]
        let inWorkTree = FileManager.default.fileExists(atPath: model.repoRoot.appendingPathComponent(file.path).path)
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let item = m.addItem(withTitle: title, action: enabled ? sel : nil, keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        if full {
            add("Open Changes", #selector(menuOpenChanges(_:)))
            add("Open Changes in New Tab", #selector(menuOpenChangesPinned(_:)))
            add("Open File at This Commit", #selector(menuOpenFile(_:)), enabled: file.status != .deleted)
        }
        add("Show in Patch", #selector(menuShowInPatch(_:)))
        add("Open as Patch", #selector(menuOpenPatch(_:)))
        add("Compare with Current File", #selector(menuCompare(_:)), enabled: inWorkTree)
        m.addItem(.separator())
        add("Copy Path", #selector(menuCopyPath(_:)))
        return m
    }

    @objc private func menuOpenChanges(_ sender: NSMenuItem) { openChanges(sender.tag, pinned: false) }
    @objc private func menuOpenChangesPinned(_ sender: NSMenuItem) { openChanges(sender.tag, pinned: true) }
    @objc private func menuOpenFile(_ sender: NSMenuItem) { onAction?(.openFile(model.detail.files[sender.tag], .file, pinned: true)) }
    @objc private func menuShowInPatch(_ sender: NSMenuItem) { onShowPatch?(sender.tag) }
    @objc private func menuOpenPatch(_ sender: NSMenuItem) { onAction?(.openFile(model.detail.files[sender.tag], .patch, pinned: true)) }
    @objc private func menuCompare(_ sender: NSMenuItem) { onAction?(.compareWithCurrent(model.detail.files[sender.tag])) }
    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        AppRuntime.pasteboard.clearContents()
        AppRuntime.pasteboard.setString(model.detail.files[sender.tag].path, forType: .string)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func cardHeight(width: CGFloat) -> CGFloat {
        let col = CommitOverviewView.column(in: width)
        if let c = cardHeights, c.width == col.width { return c.height }
        let h = CommitCardCell.layout(for: model, width: col.width).total
        cardHeights = (col.width, h)
        return h
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .card: return cardHeight(width: columnWidth) + 36
        case .filesHeader: return 44
        case .file(let i):
            return CommitOverviewView.sectionHeaderHeight + (isExpanded(i) ? bodyHeight(i) : 0) + CommitOverviewView.sectionGap
        case .more: return 36
        case .empty: return 60
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("overviewRow")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? OverviewRowView) ?? OverviewRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let col = CommitOverviewView.column(in: columnWidth)
        switch rows[row] {
        case .card:
            let id = NSUserInterfaceItemIdentifier("overviewCard")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitCardCell) ?? CommitCardCell()
            cell.identifier = id
            cell.onOpenParent = { [weak self] sha in self?.onOpenParent?(sha) }
            cell.configure(model, column: col)
            return cell
        case .filesHeader:
            let id = NSUserInterfaceItemIdentifier("overviewHeader")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitFilesHeaderCell) ?? CommitFilesHeaderCell()
            cell.identifier = id
            cell.onLayout = { [weak self] split in self?.setSplit(split) }
            cell.onToggleAll = { [weak self] in
                guard let self else { return }
                self.setAllExpanded(!self.allExpanded)
            }
            cell.configure(model.detail, column: col, isSplit: model.isSplit, narrow: isNarrowForSplit, allExpanded: allExpanded)
            return cell
        case .file(let i):
            let id = NSUserInterfaceItemIdentifier("overviewFile")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileSectionCell) ?? FileSectionCell()
            cell.identifier = id
            cell.onOpenChanges = { [weak self] in self?.openChanges(i, pinned: false) }
            cell.onOpenFile = { [weak self] in
                guard let self else { return }
                self.onAction?(.openFile(self.model.detail.files[i], .file, pinned: true))
            }
            cell.onMenu = { [weak self] button in
                guard let self else { return }
                self.makeMenu(for: i, full: false).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
            }
            cell.onShowMore = { [weak self] in self?.showMore(i) }
            let diff = model.diff(i)
            let shown = isExpanded(i) ? render(i) : nil
            let hiddenRows = shown?.hidden ?? 0
            cell.configure(file: model.detail.files[i], column: col, expanded: isExpanded(i), bodyHeight: bodyHeight(i), metrics: metrics,
                           render: shown?.render, note: diff?.note ?? (hasDiffRows(i) ? nil : "No changes to show."), hiddenRows: hiddenRows,
                           limitReached: model.rowLimits[i] >= CommitOverviewModel.maxRowLimit)
            cell.isSelectedSection = row == table.selectedRow
            return cell
        case .empty(let message):
            let id = NSUserInterfaceItemIdentifier("overviewMore")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryInfoCell) ?? HistoryInfoCell()
            cell.identifier = id
            cell.configure(message, left: col.x + 12)
            return cell
        case .more:
            let id = NSUserInterfaceItemIdentifier("overviewMore")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryInfoCell) ?? HistoryInfoCell()
            cell.identifier = id
            cell.configure("\(model.detail.hiddenFileCount) more files. Switch to Patch to see them all.", left: col.x + 12)
            return cell
        }
    }
}

// MARK: - Table and rows

final class OverviewTableView: NSTableView {
    var onReturn: ((_ option: Bool) -> Void)?
    var onSpace: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event.modifierFlags.contains(.option))
        } else if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onSpace?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(row(at: convert(event.locationInWindow, from: nil))) }

    /// Lets a click place the caret in, or select text from, the card's labels and the diff columns
    /// instead of the table taking it.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isSelectable { return true }
        if let text = responder as? NSTextView, text.isSelectable { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Rows draw nothing of their own: the cells are cards, and a selected one outlines itself.
final class OverviewRowView: ThemedRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// A changed file as a card: a header with its name and counts, and below it, when open, its own changes.
final class FileSectionCell: NSTableCellView {
    var onOpenChanges: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onMenu: ((ToolButton) -> Void)?
    var onShowMore: (() -> Void)?
    var isSelectedSection = false { didSet { if oldValue != isSelectedSection { needsDisplay = true } } }

    private let openChanges = ToolButton(symbol: "plus.forwardslash.minus", tooltip: "Open Changes\nThe file with its changes marked in the editor.")
    private let openFile = ToolButton(symbol: "doc.text", tooltip: "Open File\nThe file as it was at this commit.")
    private let more = ToolButton(symbol: "ellipsis", tooltip: "More\nShow in Patch, Open as Patch, Compare with Current File and Copy Path.")
    let body = DiffBodyView()
    private var file: GitRepository.CommitFile?
    private var column: (x: CGFloat, width: CGFloat) = (0, 0)
    private var expanded = false
    private var bodyHeight: CGFloat = 0
    private var hasBody = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        openChanges.symbolSize = 12
        openFile.symbolSize = 12
        more.symbolSize = 12
        openChanges.onClick = { [weak self] in self?.onOpenChanges?() }
        openFile.onClick = { [weak self] in self?.onOpenFile?() }
        more.onClick = { [weak self] in
            guard let self else { return }
            self.onMenu?(self.more)
        }
        body.onShowMore = { [weak self] in self?.onShowMore?() }
        [openChanges, openFile, more, body].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(file: GitRepository.CommitFile, column: (x: CGFloat, width: CGFloat), expanded: Bool, bodyHeight: CGFloat,
                   metrics: DiffMetrics, render: DiffRender?, note: String?, hiddenRows: Int, limitReached: Bool) {
        self.file = file
        self.column = column
        self.expanded = expanded
        self.bodyHeight = bodyHeight
        openFile.isEnabled = file.status != .deleted
        body.isHidden = !expanded
        if expanded {
            body.configure(render: render, note: render == nil ? note : nil, hiddenRows: hiddenRows, limitReached: limitReached, metrics: metrics)
        }
        let counts = file.added.map { "\($0) added, \(file.removed ?? 0) removed" } ?? "binary"
        setAccessibilityLabel("\(file.path), \(file.status.label), \(counts)")
        setAccessibilityValue(expanded ? "expanded" : "collapsed")
        setAccessibilityHelp(expanded ? "Press to hide this file's changes" : "Press to show this file's changes")
        toolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        needsLayout = true
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let table = enclosingScrollView?.documentView as? OverviewTableView, let owner = table.delegate as? CommitOverviewView,
              let file, let i = owner.model.detail.files.firstIndex(of: file) else { return false }
        owner.toggle(i)
        return true
    }

    private var cardRect: NSRect {
        NSRect(x: column.x, y: 0, width: column.width,
               height: max(0, CommitOverviewView.sectionHeaderHeight + (expanded ? bodyHeight : 0)))
    }

    override func layout() {
        super.layout()
        let card = cardRect
        let y = (CommitOverviewView.sectionHeaderHeight - 24) / 2
        more.frame = NSRect(x: card.maxX - 10 - 26, y: y, width: 26, height: 24)
        openFile.frame = NSRect(x: more.frame.minX - 26, y: y, width: 26, height: 24)
        openChanges.frame = NSRect(x: openFile.frame.minX - 26, y: y, width: 26, height: 24)
        body.frame = NSRect(x: card.minX + 1, y: CommitOverviewView.sectionHeaderHeight, width: max(0, card.width - 2), height: bodyHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let file else { return }
        let theme = ThemeManager.shared.active
        let card = cardRect
        let outline = card.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outline, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        theme.chromeBackground.setFill()
        card.fill()
        if expanded {
            (theme.translucent ? theme.background : theme.editorBackground).setFill()
            NSRect(x: card.minX, y: CommitOverviewView.sectionHeaderHeight, width: card.width, height: card.height - CommitOverviewView.sectionHeaderHeight).fill()
            theme.chromeBorder.setFill()
            NSRect(x: card.minX, y: CommitOverviewView.sectionHeaderHeight - 1, width: card.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        (isSelectedSection ? theme.accent : theme.chromeBorder).setStroke()
        path.lineWidth = isSelectedSection ? 1.5 : 1
        path.stroke()

        let midY = CommitOverviewView.sectionHeaderHeight / 2
        var x = card.minX + 12
        if let chevron = FileIcons.image(expanded ? "chevron.down" : "chevron.right", color: theme.chromeSecondary, size: 10) {
            chevron.draw(in: NSRect(x: x, y: midY - chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 18
        let color: NSColor
        switch file.status {
        case .modified, .renamed: color = theme.color(.changed) ?? theme.chromeForeground
        case .added, .untracked: color = theme.color(.inserted) ?? theme.chromeForeground
        case .deleted, .conflicted: color = theme.color(.deleted) ?? theme.chromeForeground
        case .ignored: color = theme.chromeSecondary
        }
        let letter = file.status.letter as NSString
        let letterAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: color]
        let ls = letter.size(withAttributes: letterAttrs)
        letter.draw(at: NSPoint(x: x, y: midY - ls.height / 2), withAttributes: letterAttrs)
        x += 18
        let name = (file.path as NSString).lastPathComponent
        let folder = file.originalPath.map { "\($0) → \(file.path)" } ?? (file.path as NSString).deletingLastPathComponent
        if let icon = FileIcons.image(forFileName: name, theme: theme, size: 12.5) {
            icon.draw(in: NSRect(x: x, y: midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 22
        var nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color]
        if file.status == .deleted { nameAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let counts = NSMutableAttributedString()
        if file.added == nil {
            counts.append(NSAttributedString(string: "Binary", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.chromeSecondary]))
        } else if let added = file.added, added > 0 || (file.removed ?? 0) > 0 {
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            counts.append(NSAttributedString(string: "+\(added)", attributes: [.font: digits, .foregroundColor: theme.color(.inserted) ?? .systemGreen]))
            counts.append(NSAttributedString(string: " −\(file.removed ?? 0)", attributes: [.font: digits, .foregroundColor: theme.color(.deleted) ?? .systemRed]))
        }
        let countsWidth = ceil(counts.size().width)
        let right = openChanges.frame.minX - 10 - countsWidth
        if counts.length > 0 { counts.draw(at: NSPoint(x: right, y: midY - counts.size().height / 2)) }
        let nameWidth = min(ceil((name as NSString).size(withAttributes: nameAttrs).width) + 2, max(0, right - 12 - x))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var truncating = nameAttrs
        truncating[.paragraphStyle] = para
        (name as NSString).draw(with: NSRect(x: x, y: midY - 9, width: nameWidth, height: 18),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncating)
        x += nameWidth + 8
        if !folder.isEmpty, right - 12 - x > 24 {
            let headPara = NSMutableParagraphStyle()
            headPara.lineBreakMode = .byTruncatingHead
            (folder as NSString).draw(with: NSRect(x: x, y: midY - 8, width: right - 12 - x, height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeSecondary, .paragraphStyle: headPara])
        }
    }
}

/// "CHANGED FILES 5  +8 −0" with the layout switch and Expand All at the right.
final class CommitFilesHeaderCell: NSTableCellView {
    var onLayout: ((Bool) -> Void)?
    var onToggleAll: (() -> Void)?
    private var detail: GitRepository.CommitDetail?
    private var column: (x: CGFloat, width: CGFloat) = (0, 0)
    private let unified = ToolButton(title: "Unified")
    private let split = ToolButton(title: "Split")
    private let all = ToolButton(title: "Expand All")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for b in [unified, split, all] { b.titleFont = .systemFont(ofSize: 11.5, weight: .medium) }
        unified.toolTip = "Unified\nShow each file's changes in one column."
        split.toolTip = "Split\nShow the old and new file side by side."
        unified.onClick = { [weak self] in self?.onLayout?(false) }
        split.onClick = { [weak self] in self?.onLayout?(true) }
        all.onClick = { [weak self] in self?.onToggleAll?() }
        [unified, split, all].forEach(addSubview)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ detail: GitRepository.CommitDetail, column: (x: CGFloat, width: CGFloat), isSplit: Bool, narrow: Bool, allExpanded: Bool) {
        self.detail = detail
        self.column = column
        unified.isOn = !isSplit
        split.isOn = isSplit
        split.toolTip = narrow ? "Split\nSide by side needs a wider window; showing one column until there’s room."
                               : "Split\nShow the old and new file side by side."
        all.title = allExpanded ? "Collapse All" : "Expand All"
        all.toolTip = allExpanded ? "Collapse All\nHide every file's changes." : "Expand All\nShow every file's changes."
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let y = bounds.height - 30
        let right = column.x + column.width
        all.frame = NSRect(x: right - all.intrinsicWidth, y: y, width: all.intrinsicWidth, height: 24)
        split.frame = NSRect(x: all.frame.minX - 14 - split.intrinsicWidth, y: y, width: split.intrinsicWidth, height: 24)
        unified.frame = NSRect(x: split.frame.minX - unified.intrinsicWidth, y: y, width: unified.intrinsicWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let detail else { return }
        let theme = ThemeManager.shared.active
        let total = detail.files.count + detail.hiddenFileCount
        let text = NSMutableAttributedString(string: "CHANGED FILES", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: theme.chromeSecondary])
        text.append(NSAttributedString(string: "  \(total)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8)]))
        let added = detail.files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = detail.files.reduce(0) { $0 + ($1.removed ?? 0) }
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        text.append(NSAttributedString(string: "   +\(added)", attributes: [.font: digits, .foregroundColor: theme.color(.inserted) ?? .systemGreen]))
        text.append(NSAttributedString(string: " −\(removed)", attributes: [.font: digits, .foregroundColor: theme.color(.deleted) ?? .systemRed]))
        text.draw(at: NSPoint(x: column.x + 2, y: bounds.height - 30 + (24 - text.size().height) / 2))
    }
}

// MARK: - The card

final class CommitCardCell: NSTableCellView {
    struct Layout {
        var badgesY: CGFloat?
        var subjectY: CGFloat
        var subjectHeight: CGFloat
        var bodyY: CGFloat?
        var bodyHeight: CGFloat
        var parentsY: CGFloat?
        var committerY: CGFloat?
        var total: CGFloat
    }

    static let padding: CGFloat = 18
    static let subjectFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    var onOpenParent: ((String) -> Void)?
    private var model: CommitOverviewModel?
    private var column: (x: CGFloat, width: CGFloat) = (0, 0)
    private let avatar = AvatarView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let pill = ShaPillView()
    private let copyButton = ToolButton(symbol: "doc.on.doc", tooltip: "Copy commit SHA")
    private let badges = RefBadgesView()
    private let subject = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let parents = ParentsView()
    private let committer = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        meta.font = .systemFont(ofSize: 12)
        meta.lineBreakMode = .byTruncatingTail
        committer.font = .systemFont(ofSize: 12)
        for f in [subject, body] {
            f.isSelectable = true
            f.allowsEditingTextAttributes = false
        }
        subject.font = CommitCardCell.subjectFont
        body.font = CommitCardCell.bodyFont
        copyButton.symbolSize = 11.5
        copyButton.onClick = { [weak self] in
            guard let sha = self?.model?.commit.sha else { return }
            AppRuntime.pasteboard.clearContents()
            AppRuntime.pasteboard.setString(sha, forType: .string)
            (self?.window?.windowController as? MainWindowController)?.statusBar.flash("Copied \(self?.model?.commit.shortSHA ?? "")")
        }
        parents.onOpen = { [weak self] sha in self?.onOpenParent?(sha) }
        [avatar, name, meta, pill, copyButton, badges, subject, body, parents, committer].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What follows the first paragraph of a commit message.
    static func messageBody(_ detail: GitRepository.CommitDetail) -> String {
        guard let r = detail.message.range(of: "\n\n") else { return "" }
        return String(detail.message[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subjectText(_ commit: LogCommit) -> String { commit.subject.isEmpty ? "(no message)" : commit.subject }

    static func hasCommitterLine(_ detail: GitRepository.CommitDetail) -> Bool {
        detail.committerName != detail.authorName || abs(detail.commitDate.timeIntervalSince(detail.authorDate)) > 60
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
    }

    /// Where each part sits in a card `width` wide; the same numbers give the row its height.
    static func layout(for model: CommitOverviewModel, width: CGFloat) -> Layout {
        let pad = padding
        let inner = max(0, width - 2 * pad)
        var y = pad + 40
        var badgesY: CGFloat?
        if !model.commit.refs.isEmpty {
            y += 12
            badgesY = y
            y += 16
        }
        y += 14
        let subjectY = y
        let subjectH = max(22, height(of: subjectText(model.commit), font: subjectFont, width: inner - 4) + 2)
        y += subjectH
        var bodyY: CGFloat?
        var bodyH: CGFloat = 0
        let bodyText = messageBody(model.detail)
        if !bodyText.isEmpty {
            y += 10
            bodyY = y
            bodyH = height(of: bodyText, font: bodyFont, width: inner - 4) + 2
            y += bodyH
        }
        var parentsY: CGFloat?
        if !model.commit.parents.isEmpty {
            y += 16
            parentsY = y
            y += 16
        }
        var committerY: CGFloat?
        if hasCommitterLine(model.detail) {
            y += parentsY == nil ? 16 : 4
            committerY = y
            y += 16
        }
        return Layout(badgesY: badgesY, subjectY: subjectY, subjectHeight: subjectH, bodyY: bodyY, bodyHeight: bodyH,
                      parentsY: parentsY, committerY: committerY, total: y + pad)
    }

    func configure(_ model: CommitOverviewModel, column: (x: CGFloat, width: CGFloat)) {
        self.model = model
        self.column = column
        let theme = ThemeManager.shared.active
        let d = model.detail
        avatar.configure(name: d.authorName, email: d.authorEmail, palette: HistoryStyle.palette(for: theme))
        name.stringValue = d.authorName.isEmpty ? d.authorEmail : d.authorName
        name.textColor = theme.chromeForeground
        let when = "\(HistoryView.absoluteDate(d.authorDate)) · \(HistoryView.relativeDate(d.authorDate))"
        meta.stringValue = d.authorEmail.isEmpty ? when : "\(d.authorEmail) · \(when)"
        meta.textColor = theme.chromeSecondary
        pill.sha = model.commit.shortSHA
        badges.refs = model.commit.refs
        badges.isHidden = model.commit.refs.isEmpty
        subject.stringValue = CommitCardCell.subjectText(model.commit)
        subject.textColor = theme.chromeForeground
        let bodyText = CommitCardCell.messageBody(d)
        body.stringValue = bodyText
        body.isHidden = bodyText.isEmpty
        body.textColor = theme.chromeForeground.withAlphaComponent(0.85)
        parents.configure(parents: model.commit.parents)
        parents.isHidden = model.commit.parents.isEmpty
        let committed = CommitCardCell.hasCommitterLine(d)
        committer.isHidden = !committed
        committer.stringValue = "Committed by \(d.committerName) · \(HistoryView.absoluteDate(d.commitDate))"
        committer.textColor = theme.chromeSecondary
        setAccessibilityLabel("\(CommitCardCell.subjectText(model.commit)), \(d.authorName), \(HistoryView.absoluteDate(d.authorDate)), commit \(model.commit.shortSHA)")
        needsLayout = true
        needsDisplay = true
    }

    private var cardRect: NSRect { NSRect(x: column.x, y: 20, width: column.width, height: max(0, bounds.height - 36)) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let path = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        theme.chromeBackground.setFill()
        path.fill()
        theme.chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        let card = cardRect
        let pad = CommitCardCell.padding
        let l = CommitCardCell.layout(for: model, width: card.width)
        let x = card.minX + pad
        let inner = max(0, card.width - 2 * pad)
        let top = card.minY
        avatar.frame = NSRect(x: x, y: top + pad, width: 40, height: 40)
        copyButton.frame = NSRect(x: card.maxX - pad - 22, y: top + pad - 1, width: 22, height: 22)
        let pillWidth = pill.preferredWidth
        pill.frame = NSRect(x: copyButton.frame.minX - 6 - pillWidth, y: top + pad, width: pillWidth, height: 20)
        let textX = x + 40 + 12
        let textRight = pill.frame.minX - 10
        name.frame = NSRect(x: textX, y: top + pad + 1, width: max(0, textRight - textX), height: 18)
        meta.frame = NSRect(x: textX, y: top + pad + 22, width: max(0, card.maxX - pad - textX), height: 16)
        if let y = l.badgesY { badges.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
        subject.frame = NSRect(x: x - 2, y: top + l.subjectY, width: inner + 4, height: l.subjectHeight)
        if let y = l.bodyY { body.frame = NSRect(x: x - 2, y: top + y, width: inner + 4, height: l.bodyHeight) }
        if let y = l.parentsY { parents.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
        if let y = l.committerY { committer.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
    }
}

/// A circle with the author's initials, colored by a hash of their email so it stays the same.
final class AvatarView: NSView {
    private var initials = ""
    private var color = NSColor.systemBlue

    override var isFlipped: Bool { true }

    static func initials(name: String, email: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first)
        if !letters.isEmpty { return String(letters).uppercased() }
        return email.first.map { String($0).uppercased() } ?? "?"
    }

    /// FNV-1a, because `hashValue` changes from one launch to the next.
    static func stableIndex(_ text: String, count: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(max(1, count)))
    }

    func configure(name: String, email: String, palette: [NSColor]) {
        initials = AvatarView.initials(name: name, email: email)
        color = palette[AvatarView.stableIndex(email.isEmpty ? name : email, count: palette.count)]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let s = initials as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: round((bounds.width - size.width) / 2), y: round((bounds.height - size.height) / 2)), withAttributes: attrs)
    }
}

final class ShaPillView: NSView {
    var sha = "" { didSet { needsDisplay = true } }
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat { ceil((sha as NSString).size(withAttributes: [.font: ShaPillView.font]).width) + 18 }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        theme.chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: ShaPillView.font, .foregroundColor: theme.chromeSecondary]
        let size = (sha as NSString).size(withAttributes: attrs)
        (sha as NSString).draw(at: NSPoint(x: 9, y: round((bounds.height - size.height) / 2)), withAttributes: attrs)
    }
}

final class RefBadgesView: NSView {
    var refs: [RefLabel] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        _ = RefBadges.drawRow(refs, at: 0, y: 0, right: bounds.width, theme: ThemeManager.shared.active)
    }
}

/// "Parent ab23a35", or "Parents ab23a35, 80ca6ab · merge, changes compared with the first parent", with
/// each SHA a link that opens that commit.
final class ParentsView: NSView {
    var onOpen: ((String) -> Void)?
    private var shas: [String] = []
    private var links: [(rect: NSRect, sha: String)] = []
    private static let font = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }

    func configure(parents: [String]) {
        shas = parents
        links = []
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(parents.count > 1 ? "Parents" : "Parent")
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let plain: [NSAttributedString.Key: Any] = [.font: ParentsView.font, .foregroundColor: theme.chromeSecondary]
        let link: [NSAttributedString.Key: Any] = [.font: ParentsView.font, .foregroundColor: theme.accent]
        var x: CGFloat = 0
        var found: [(NSRect, String)] = []
        func put(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> NSRect {
            let size = (s as NSString).size(withAttributes: attrs)
            let r = NSRect(x: x, y: round((bounds.height - size.height) / 2), width: ceil(size.width), height: ceil(size.height))
            (s as NSString).draw(at: r.origin, withAttributes: attrs)
            x = r.maxX
            return r
        }
        _ = put(shas.count > 1 ? "Parents " : "Parent ", plain)
        for (i, sha) in shas.enumerated() {
            if i > 0 { _ = put(", ", plain) }
            found.append((put(String(sha.prefix(7)), link).insetBy(dx: -1, dy: -1), sha))
        }
        if shas.count > 1 { _ = put(" · merge, changes compared with the first parent", plain) }
        links = found
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for l in links { addCursorRect(l.rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = links.first(where: { $0.rect.contains(p) }) { onOpen?(hit.sha) }
    }

    override func accessibilityChildren() -> [Any]? {
        links.map { l in
            let e = DrawnAccessibilityElement(in: self, role: .button) { l.rect }
            e.setAccessibilityLabel("Open commit \(l.sha.prefix(7))")
            e.onPress = { [weak self] in self?.onOpen?(l.sha) }
            return e
        }
    }
}
