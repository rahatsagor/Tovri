import AppKit

/// How a commit's file is opened from the History list.
enum CommitFileView { case changes, patch, file }

/// What the History list asks the window to do with a commit or one of its files.
enum HistoryAction {
    case openFile(GitRepository.CommitFile, CommitFileView, pinned: Bool)
    case compareWithCurrent(GitRepository.CommitFile)
    case openCommitPatch(pinned: Bool)
}

/// What the History cells share: the graph's colors and how wide its column is.
final class HistoryStyle {
    static let laneWidth: CGFloat = 10
    static let maxLanes = 8
    static let padding: CGFloat = 8
    var palette: [NSColor] = [.systemBlue]
    /// The widest row loaded so far, in lanes.
    var laneCount = 1
    var showsGraph = false

    var graphWidth: CGFloat { showsGraph ? CGFloat(min(laneCount, HistoryStyle.maxLanes)) * HistoryStyle.laneWidth + HistoryStyle.padding + 4 : 0 }
    /// Where text starts in commit rows and, under them, in the rows of an expanded commit.
    var textLeft: CGFloat { showsGraph ? graphWidth : 12 }
    var childLeft: CGFloat { showsGraph ? graphWidth + 4 : 14 }

    func x(_ lane: Int) -> CGFloat {
        HistoryStyle.padding + (CGFloat(min(lane, HistoryStyle.maxLanes - 1)) + 0.5) * HistoryStyle.laneWidth
    }

    func color(_ lane: Int) -> NSColor { palette[lane % palette.count] }
}

/// One row of the History list: a commit, or a row under an expanded commit.
final class HistoryItem: NSObject {
    enum Kind { case commit, info, summary, file, moreFiles }
    let kind: Kind
    var commit: LogCommit?
    var graph: CommitGraph.Row?
    var text = ""
    var rowHeight: CGFloat = 24
    var detail: GitRepository.CommitDetail?
    var file: GitRepository.CommitFile?
    var children: [HistoryItem] = []
    weak var parent: HistoryItem?
    var cachedHeight: (width: CGFloat, height: CGFloat)?
    lazy var relativeDate: String = commit.map { HistoryView.relativeDate($0.date) } ?? ""

    init(kind: Kind) { self.kind = kind }

    static func info(_ text: String, height: CGFloat = 24) -> HistoryItem {
        let i = HistoryItem(kind: .info)
        i.text = text
        i.rowHeight = height
        return i
    }
}

/// The sidebar's History tab: the repository's commits with a branch graph, search, and each
/// commit's files. Pages of commits are read as the list scrolls, and a commit's details only when
/// it is expanded.
final class HistoryView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    static let pageSize = 200
    static let maxCommits = 5_000
    static let prefetchRows = 30
    static let detailCacheLimit = 32
    static let searchDelay: TimeInterval = 0.25
    static let limitMessage = "Showing the latest 5,000 commits. Search to find older ones."

    var onAction: ((LogCommit, GitRepository.CommitDetail?, HistoryAction) -> Void)?
    private(set) var repository: GitRepository?
    let searchField = ThemedTextField(placeholder: "Search commits")
    private let scroll = OverlayScrollView(frame: .zero)
    let list = SidebarOutlineView()
    private let empty = NSTextField(labelWithString: "")
    let style = HistoryStyle()

    private var commitItems: [HistoryItem] = []
    private var trailing: HistoryItem?
    private var graphState = CommitGraph.State()
    private(set) var query = HistoryQuery()
    private var tip = "HEAD"
    private var topoOrder = false
    private var generation = 0
    private var inFlight: GitCancellation?
    private var isLoadingPage = false
    private var reachedEnd = false
    private var pageFailed = false
    private var loadedToken: String?
    private var needsReload = true
    private var searchDebounce: DispatchWorkItem?
    private var lastWidth: CGFloat = 0

    private var detailCache: [String: GitRepository.CommitDetail] = [:]
    private var detailOrder: [String] = []

    private static let toolbarHeight: CGFloat = 30

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func relativeDate(_ date: Date) -> String { relativeFormatter.localizedString(for: date, relativeTo: Date()) }
    static func absoluteDate(_ date: Date) -> String { absoluteFormatter.string(from: date) }

    var commits: [LogCommit] { commitItems.compactMap(\.commit) }
    var cachedDetailCount: Int { detailCache.count }
    var isLoading: Bool { isLoadingPage }
    var emptyMessage: String? { empty.isHidden ? nil : empty.stringValue }
    var hasLoaded: Bool { !needsReload }
    var usesTopoOrder: Bool { topoOrder }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        searchField.fontSize = 12
        searchField.leadingSymbol = "magnifyingglass"
        searchField.field.delegate = self
        searchField.field.setAccessibilityLabel("Search commits")
        searchField.toolTip = "Words match commit messages. Add author:name or path:folder to narrow the list; quote values with spaces."
        searchField.onClear = { [weak self] in
            guard let self else { return }
            self.searchField.stringValue = ""
            self.applyQueryNow()
            self.window?.makeFirstResponder(self.searchField.field)
        }
        addSubview(searchField)

        let col = NSTableColumn(identifier: .init("commit"))
        col.resizingMask = .autoresizingMask
        list.addTableColumn(col)
        list.outlineTableColumn = col
        list.hidesDisclosure = true
        list.headerView = nil
        list.rowHeight = 40
        list.indentationPerLevel = 0
        list.intercellSpacing = .zero
        list.style = .plain
        list.focusRingType = .none
        list.backgroundColor = .clear
        list.allowsMultipleSelection = false
        list.autoresizesOutlineColumn = false
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.action = #selector(clicked)
        list.doubleAction = #selector(doubleClicked)
        list.onReturn = { [weak self] in self?.returnPressed() }
        list.onSlash = { [weak self] in self?.focusSearch() }
        list.menuProvider = { [weak self] row in self?.menu(row: row) }
        list.setAccessibilityLabel("Commits")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        empty.isHidden = true
        addSubview(empty)

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        inFlight?.cancel()
        searchDebounce?.cancel()
    }

    // MARK: Lifecycle

    func setRepository(_ new: GitRepository?) {
        guard new !== repository else { return }
        repository = new
        detailCache = [:]
        detailOrder = []
        loadedToken = nil
        needsReload = true
        dropRows()
    }

    /// Stops any running git command and releases everything loaded.
    func teardown() {
        searchDebounce?.cancel()
        searchDebounce = nil
        dropRows()
        detailCache = [:]
        detailOrder = []
        onAction = nil
    }

    /// The tab came into view: the first time, or after HEAD moved while it was hidden, loads page one.
    func show() {
        if needsReload || (loadedToken != nil && repository?.headToken != loadedToken) { reload() }
    }

    /// The window saw git change. Reloads at once while showing, otherwise on the next `show()`.
    func headMayHaveChanged(visible: Bool) {
        guard !needsReload, let repository, repository.headToken != loadedToken else { return }
        if visible { reload() } else { needsReload = true }
    }

    private func dropRows() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        isLoadingPage = false
        reachedEnd = false
        pageFailed = false
        commitItems = []
        trailing = nil
        graphState = CommitGraph.State()
        style.laneCount = 1
        list.reloadData()
        empty.isHidden = true
    }

    /// Reads the first page again, with the commits collapsed.
    func reload() {
        dropRows()
        searchDebounce?.cancel()
        needsReload = false
        query = HistoryQuery(searchField.stringValue)
        style.showsGraph = query.isEmpty
        guard let repo = repository else { setEmpty("Couldn’t read the history"); return }
        loadedToken = repo.headToken
        if repo.isUnborn { setEmpty("No commits yet"); return }
        tip = repo.headCommitSHA ?? "HEAD"
        topoOrder = query.isEmpty && repo.hasCommitGraph
        setEmpty("Loading…")
        loadPage()
    }

    private func setEmpty(_ text: String?) {
        empty.stringValue = text ?? ""
        empty.isHidden = text == nil
    }

    // MARK: Paging

    private func loadPage() {
        guard let repo = repository, !isLoadingPage, !reachedEnd, !pageFailed else { return }
        isLoadingPage = true
        let generation = generation
        let cancellation = GitCancellation()
        inFlight = cancellation
        if !commitItems.isEmpty { setTrailing(.info("Loading more…")) }
        repo.log(from: tip, query: query, skip: commitItems.count, limit: HistoryView.pageSize, topoOrder: topoOrder,
                 cancellation: cancellation) { [weak self] page in
            guard let self, generation == self.generation, !cancellation.isCancelled else { return }
            self.isLoadingPage = false
            self.inFlight = nil
            guard let page else { self.pageDidFail(); return }
            self.append(page)
        }
    }

    private func pageDidFail() {
        pageFailed = true
        if commitItems.isEmpty {
            setEmpty("Couldn’t read the history")
        } else {
            setTrailing(.info("Couldn’t load more commits"))
        }
    }

    private func append(_ page: [LogCommit]) {
        let rows = style.showsGraph ? CommitGraph.layout(page, state: &graphState) : []
        let items = page.enumerated().map { i, commit -> HistoryItem in
            let item = HistoryItem(kind: .commit)
            item.commit = commit
            item.rowHeight = 40
            if i < rows.count { item.graph = rows[i] }
            return item
        }
        let before = commitItems.count
        let widest = rows.map(\.laneCount).max() ?? 1
        let widthChanged = style.showsGraph && min(widest, HistoryStyle.maxLanes) > min(style.laneCount, HistoryStyle.maxLanes)
        if widest > style.laneCount { style.laneCount = widest }
        setTrailing(nil)
        commitItems += items
        if before == 0 {
            list.reloadData()
        } else if !items.isEmpty {
            list.insertItems(at: IndexSet(before..<commitItems.count), inParent: nil, withAnimation: [])
        }
        reachedEnd = page.count < HistoryView.pageSize || commitItems.count >= HistoryView.maxCommits
        if commitItems.isEmpty {
            setEmpty(query.isEmpty ? "No commits yet" : "No matching commits")
        } else {
            setEmpty(nil)
            if page.count == HistoryView.pageSize && commitItems.count >= HistoryView.maxCommits {
                setTrailing(.info(HistoryView.limitMessage, height: 40))
            }
        }
        if widthChanged { refreshVisibleCells() }
        maybeLoadMore()
    }

    private func setTrailing(_ item: HistoryItem?) {
        if trailing != nil {
            trailing = nil
            list.removeItems(at: IndexSet(integer: commitItems.count), inParent: nil, withAnimation: [])
        }
        if let item {
            trailing = item
            list.insertItems(at: IndexSet(integer: commitItems.count), inParent: nil, withAnimation: [])
        }
    }

    @objc private func scrolled() { maybeLoadMore() }

    func scrollToEnd() {
        guard list.numberOfRows > 0 else { return }
        list.scrollRowToVisible(list.numberOfRows - 1)
    }

    /// Reads the next page once the list is scrolled within a few rows of its end.
    func maybeLoadMore() {
        guard !isLoadingPage, !reachedEnd, !pageFailed, !commitItems.isEmpty else { return }
        let visible = list.rows(in: list.visibleRect)
        if NSMaxRange(visible) >= list.numberOfRows - HistoryView.prefetchRows { loadPage() }
    }

    private func refreshVisibleCells() {
        list.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            for case let cell as HistoryCommitCell in rowView.subviews { cell.needsDisplay = true }
            for case let cell as HistorySummaryCell in rowView.subviews { cell.needsDisplay = true }
            for case let cell as HistoryInfoCell in rowView.subviews { cell.needsDisplay = true }
            for case let cell as ChangeCell in rowView.subviews { cell.leadingInset = self.style.childLeft - 12; cell.needsLayout = true }
        }
        invalidateSummaryHeights()
    }

    // MARK: Search

    func focusSearch() { window?.makeFirstResponder(searchField.field) }
    func focus() { window?.makeFirstResponder(list) }

    /// Searches for `text` at once, as pressing Return does.
    func search(_ text: String) {
        searchField.stringValue = text
        applyQueryNow()
    }

    private func applyQueryNow() {
        searchDebounce?.cancel()
        guard HistoryQuery(searchField.stringValue) != query else { return }
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyQueryNow() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HistoryView.searchDelay, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyQueryNow()
            } else {
                focus()
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let first = commitItems.first, list.selectedRowIndexes.isEmpty {
                list.selectRowIndexes(IndexSet(integer: list.row(forItem: first)), byExtendingSelection: false)
            }
            if !commitItems.isEmpty { focus() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            applyQueryNow()
            return true
        default:
            return false
        }
    }

    // MARK: Theme and layout

    func applyTheme() {
        let theme = ThemeManager.shared.active
        let colors = [theme.accent, theme.color(.changed), theme.color(.inserted), theme.color(.function),
                      theme.color(.keyword), theme.color(.type), theme.color(.string), theme.color(.number)]
        style.palette = colors.compactMap { $0 }
        searchField.applyTheme()
        empty.textColor = theme.chromeSecondary
        list.reloadData()
    }

    override func layout() {
        super.layout()
        let bar = HistoryView.toolbarHeight
        searchField.frame = NSRect(x: 10, y: 3, width: max(48, bounds.width - 20), height: 24)
        scroll.frame = NSRect(x: 0, y: bar + 2, width: bounds.width, height: max(0, bounds.height - bar - 2))
        list.tableColumns.first?.width = scroll.contentSize.width - 4
        empty.frame = NSRect(x: 10, y: bar + 24, width: bounds.width - 20, height: 18)
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateSummaryHeights()
        }
    }

    /// Summary rows wrap their text to the row's width, so a change of width changes their height.
    private func invalidateSummaryHeights() {
        var changed = IndexSet()
        for item in commitItems where list.isItemExpanded(item) {
            for child in item.children where child.kind == .summary {
                child.cachedHeight = nil
                let row = list.row(forItem: child)
                if row >= 0 { changed.insert(row) }
            }
        }
        if !changed.isEmpty { list.noteHeightOfRows(withIndexesChanged: changed) }
    }

    // MARK: Details

    private func cachedDetail(_ sha: String) -> GitRepository.CommitDetail? {
        guard let d = detailCache[sha] else { return nil }
        if let i = detailOrder.firstIndex(of: sha) { detailOrder.remove(at: i) }
        detailOrder.append(sha)
        return d
    }

    private func store(_ detail: GitRepository.CommitDetail) {
        detailCache[detail.sha] = detail
        if let i = detailOrder.firstIndex(of: detail.sha) { detailOrder.remove(at: i) }
        detailOrder.append(detail.sha)
        while detailOrder.count > HistoryView.detailCacheLimit { detailCache[detailOrder.removeFirst()] = nil }
    }

    private func setChildren(of item: HistoryItem, from detail: GitRepository.CommitDetail) {
        let summary = HistoryItem(kind: .summary)
        summary.detail = detail
        var children = [summary]
        for file in detail.files {
            let child = HistoryItem(kind: .file)
            child.file = file
            children.append(child)
        }
        if detail.hiddenFileCount > 0 {
            let more = HistoryItem(kind: .moreFiles)
            more.text = "\(detail.hiddenFileCount) more files. Open the commit as a patch to see all."
            children.append(more)
        }
        for c in children { c.parent = item }
        item.children = children
    }

    private func loadDetail(for item: HistoryItem) {
        guard let repo = repository, let commit = item.commit else { return }
        if let d = cachedDetail(commit.sha) {
            setChildren(of: item, from: d)
            return
        }
        let loading = HistoryItem.info("Loading…")
        loading.parent = item
        item.children = [loading]
        let generation = generation
        repo.commitDetail(sha: commit.sha, parents: commit.parents) { [weak self, weak item] detail in
            guard let self, let item, generation == self.generation else { return }
            if let detail {
                self.store(detail)
                self.setChildren(of: item, from: detail)
            } else {
                let failed = HistoryItem.info("Couldn’t read this commit")
                failed.parent = item
                item.children = [failed]
            }
            if self.list.isItemExpanded(item) { self.list.reloadItem(item, reloadChildren: true) }
        }
    }

    // MARK: Actions

    private func toggle(_ item: HistoryItem) {
        if list.isItemExpanded(item) { list.collapseItem(item) } else { list.expandItem(item) }
    }

    private func commit(of item: HistoryItem) -> LogCommit? { item.commit ?? item.parent?.commit }

    private func send(_ item: HistoryItem, _ action: HistoryAction) {
        guard let commit = commit(of: item) else { return }
        onAction?(commit, detailCache[commit.sha], action)
    }

    /// What a click or Return does to `item`: commits expand, files open.
    func activate(_ item: HistoryItem, pinned: Bool) {
        switch item.kind {
        case .commit:
            if pinned { send(item, .openCommitPatch(pinned: true)) } else { toggle(item) }
        case .file:
            if let file = item.file { send(item, .openFile(file, .changes, pinned: pinned)) }
        default:
            break
        }
    }

    private func clickedItem() -> HistoryItem? {
        let row = list.clickedRow
        return row >= 0 ? list.item(atRow: row) as? HistoryItem : nil
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.clickCount != 2, let item = clickedItem() else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        activate(item, pinned: false)
    }

    @objc private func doubleClicked() {
        guard let item = clickedItem() else { return }
        activate(item, pinned: true)
    }

    private func returnPressed() {
        let row = list.selectedRow
        guard row >= 0, let item = list.item(atRow: row) as? HistoryItem else { return }
        if item.kind == .commit { toggle(item) } else { activate(item, pinned: true) }
    }

    // MARK: Menus

    private func menu(row: Int) -> NSMenu? {
        guard row >= 0, let item = list.item(atRow: row) as? HistoryItem else { return nil }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let mi = m.addItem(withTitle: title, action: enabled ? sel : nil, keyEquivalent: "")
            mi.target = self
            mi.representedObject = item
        }
        switch item.kind {
        case .commit:
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            add("Open Commit as Patch", #selector(menuCommitPatch(_:)))
            add("Copy Commit SHA", #selector(menuCopySHA(_:)))
            add("Copy Message", #selector(menuCopyMessage(_:)))
            m.addItem(.separator())
            add(list.isItemExpanded(item) ? "Collapse" : "Expand", #selector(menuToggle(_:)))
        case .file:
            guard let file = item.file else { return nil }
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let inWorkTree = repository.map { FileManager.default.fileExists(atPath: $0.root.appendingPathComponent(file.path).path) } ?? false
            add("Open Changes", #selector(menuOpenChanges(_:)))
            add("Open Changes in New Tab", #selector(menuOpenChangesPinned(_:)))
            add("Open as Patch", #selector(menuOpenPatch(_:)))
            add("Open File at This Commit", #selector(menuOpenFile(_:)), enabled: file.status != .deleted)
            add("Compare with Current File", #selector(menuCompareCurrent(_:)), enabled: inWorkTree)
            m.addItem(.separator())
            add("Copy Path", #selector(menuCopyPath(_:)))
        default:
            return nil
        }
        return m
    }

    private func menuItem(_ sender: Any?) -> HistoryItem? { (sender as? NSMenuItem)?.representedObject as? HistoryItem }

    private func copy(_ text: String) {
        AppRuntime.pasteboard.clearContents()
        AppRuntime.pasteboard.setString(text, forType: .string)
    }

    @objc private func menuCommitPatch(_ sender: Any?) { menuItem(sender).map { send($0, .openCommitPatch(pinned: true)) } }
    @objc private func menuCopySHA(_ sender: Any?) { menuItem(sender)?.commit.map { copy($0.sha) } }
    @objc private func menuToggle(_ sender: Any?) { menuItem(sender).map(toggle) }

    @objc private func menuCopyMessage(_ sender: Any?) {
        guard let commit = menuItem(sender)?.commit else { return }
        if let d = cachedDetail(commit.sha) { copy(d.message); return }
        repository?.commitDetail(sha: commit.sha, parents: commit.parents) { [weak self] detail in
            guard let self, let detail else { return }
            self.store(detail)
            self.copy(detail.message)
        }
    }

    private func openFile(_ sender: Any?, _ view: CommitFileView, pinned: Bool) {
        guard let item = menuItem(sender), let file = item.file else { return }
        send(item, .openFile(file, view, pinned: pinned))
    }

    @objc private func menuOpenChanges(_ sender: Any?) { openFile(sender, .changes, pinned: false) }
    @objc private func menuOpenChangesPinned(_ sender: Any?) { openFile(sender, .changes, pinned: true) }
    @objc private func menuOpenPatch(_ sender: Any?) { openFile(sender, .patch, pinned: true) }
    @objc private func menuOpenFile(_ sender: Any?) { openFile(sender, .file, pinned: true) }
    @objc private func menuCompareCurrent(_ sender: Any?) {
        guard let item = menuItem(sender), let file = item.file else { return }
        send(item, .compareWithCurrent(file))
    }
    @objc private func menuCopyPath(_ sender: Any?) { menuItem(sender)?.file.map { copy($0.path) } }

    // MARK: Outline

    private var rootCount: Int { commitItems.count + (trailing == nil ? 0 : 1) }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? HistoryItem else { return rootCount }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? HistoryItem else { return index < commitItems.count ? commitItems[index] : trailing as Any }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? HistoryItem)?.kind == .commit }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let item = item as? HistoryItem, item.kind == .commit else { return false }
        loadDetail(for: item)
        return true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? HistoryItem)?.children = []
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? HistoryItem else { return 24 }
        switch item.kind {
        case .file: return 24
        case .summary: return summaryHeight(item)
        default: return item.rowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { row in
            guard let item = list.item(atRow: row) as? HistoryItem else { return false }
            return item.kind == .commit || item.kind == .file
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("historyRow")
        let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? HistoryRowView) ?? HistoryRowView()
        view.identifier = id
        view.style = style
        view.lanes = []
        if let item = item as? HistoryItem, item.kind != .commit, style.showsGraph, let graph = item.parent?.graph {
            view.lanes = graph.continuing
        }
        return view
    }

    private func textWidth() -> CGFloat {
        max(40, (list.tableColumns.first?.width ?? bounds.width) - style.childLeft - 10)
    }

    private func summaryHeight(_ item: HistoryItem) -> CGFloat {
        let width = textWidth()
        if let c = item.cachedHeight, c.width == width { return c.height }
        var height: CGFloat = 8 + 16
        let body = item.detail.map(HistorySummaryCell.body) ?? ""
        if !body.isEmpty {
            let font = HistorySummaryCell.bodyFont
            let measured = ceil((body as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
            height += 4 + min(measured, HistorySummaryCell.lineHeight * CGFloat(HistorySummaryCell.maxBodyLines))
        }
        item.cachedHeight = (width, height)
        return height
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? HistoryItem else { return nil }
        switch item.kind {
        case .commit:
            let id = NSUserInterfaceItemIdentifier("historyCommit")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? HistoryCommitCell) ?? HistoryCommitCell()
            cell.identifier = id
            cell.configure(item, style: style)
            return cell
        case .file:
            guard let file = item.file else { return nil }
            let id = NSUserInterfaceItemIdentifier("historyFile")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ChangeCell) ?? ChangeCell()
            cell.identifier = id
            cell.leadingInset = style.childLeft - 12
            cell.configure(file.changedFile)
            return cell
        case .summary:
            let id = NSUserInterfaceItemIdentifier("historySummary")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? HistorySummaryCell) ?? HistorySummaryCell()
            cell.identifier = id
            if let detail = item.detail { cell.configure(detail, style: style) }
            return cell
        case .info, .moreFiles:
            let id = NSUserInterfaceItemIdentifier("historyInfo")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? HistoryInfoCell) ?? HistoryInfoCell()
            cell.identifier = id
            cell.configure(item.text, style: style, isChild: item.parent != nil)
            return cell
        }
    }
}

/// Draws the lanes that carry on past an expanded commit, behind the rows under it.
final class HistoryRowView: HoverRowView {
    weak var style: HistoryStyle?
    var lanes: [Int] = []

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        lanes = []
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let style, !lanes.isEmpty else { return }
        for lane in lanes {
            let x = style.x(lane)
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
            style.color(lane).withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }
}

/// One commit, drawn in a single pass: the graph, subject, short SHA, ref badges, author and date.
final class HistoryCommitCell: NSTableCellView {
    private var style = HistoryStyle()
    private var commit: LogCommit?
    private var graph: CommitGraph.Row?
    private var meta = ""

    private static let subjectFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let shaFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let metaFont = NSFont.systemFont(ofSize: 11)
    private static let maxBadges = 3

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? { nil }

    func configure(_ item: HistoryItem, style: HistoryStyle) {
        guard let c = item.commit else { return }
        self.style = style
        commit = c
        graph = style.showsGraph ? item.graph : nil
        meta = "\(c.author) · \(item.relativeDate)"
        toolTip = HistoryView.absoluteDate(c.date)
        let refs = c.refs.map(\.name)
        setAccessibilityLabel([c.subject.isEmpty ? "No message" : c.subject, c.author, item.relativeDate, "commit \(c.shortSHA)"]
            .joined(separator: ", ") + (refs.isEmpty ? "" : ", " + refs.joined(separator: ", ")))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let theme = ThemeManager.shared.active
        if let graph { drawGraph(graph, theme: theme) }
        let left = style.textLeft
        let right = bounds.width - 10
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        let shaAttrs: [NSAttributedString.Key: Any] = [.font: HistoryCommitCell.shaFont, .foregroundColor: theme.chromeSecondary]
        let sha = commit.shortSHA as NSString
        let shaWidth = ceil(sha.size(withAttributes: shaAttrs).width)
        sha.draw(at: NSPoint(x: right - shaWidth, y: 7), withAttributes: shaAttrs)
        let subject = (commit.subject.isEmpty ? "(no message)" : commit.subject) as NSString
        subject.draw(with: NSRect(x: left, y: 5, width: max(0, right - shaWidth - 8 - left), height: 16),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                     attributes: [.font: HistoryCommitCell.subjectFont, .foregroundColor: theme.chromeForeground, .paragraphStyle: para])

        var x = left
        let shown = commit.refs.prefix(HistoryCommitCell.maxBadges)
        for ref in shown where x < right - 40 {
            x += drawBadge(ref, at: x, right: right, theme: theme) + 4
        }
        if commit.refs.count > shown.count {
            let more = "+\(commit.refs.count - shown.count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: HistoryCommitCell.badgeFont, .foregroundColor: theme.chromeSecondary]
            more.draw(at: NSPoint(x: x, y: 23), withAttributes: attrs)
            x += ceil(more.size(withAttributes: attrs).width) + 4
        }
        if !shown.isEmpty { x += 2 }
        (meta as NSString).draw(with: NSRect(x: x, y: 22, width: max(0, right - x), height: 15),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: HistoryCommitCell.metaFont, .foregroundColor: theme.chromeSecondary, .paragraphStyle: para])
    }

    private func drawBadge(_ ref: RefLabel, at x: CGFloat, right: CGFloat, theme: Theme) -> CGFloat {
        let emphasized = ref.isCheckedOut
        let tint: NSColor
        let fill: NSColor
        switch ref.kind {
        case .branch, .detachedHead:
            tint = emphasized ? theme.accent.mix(theme.foreground, 0.25) : theme.chromeForeground.withAlphaComponent(0.85)
            fill = emphasized ? theme.accent.withAlphaComponent(0.24) : theme.chromeForeground.withAlphaComponent(0.1)
        case .remoteBranch:
            tint = theme.chromeSecondary
            fill = theme.chromeForeground.withAlphaComponent(0.06)
        case .tag:
            let c = theme.color(.changed) ?? .systemOrange
            tint = c
            fill = c.withAlphaComponent(0.14)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: HistoryCommitCell.badgeFont, .foregroundColor: tint]
        let name = ref.name as NSString
        let glyph = ref.kind == .tag ? FileIcons.image("tag.fill", color: tint, size: 8.5) : nil
        let glyphWidth = glyph.map { $0.size.width + 3 } ?? 0
        let textWidth = min(ceil(name.size(withAttributes: attrs).width), 90, max(20, right - x - 14 - glyphWidth))
        let width = textWidth + 10 + glyphWidth
        let r = NSRect(x: x, y: 22, width: width, height: 15)
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        var tx = r.minX + 5
        if let glyph {
            glyph.draw(in: NSRect(x: tx, y: r.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            tx += glyphWidth
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var truncating = attrs
        truncating[.paragraphStyle] = para
        name.draw(with: NSRect(x: tx, y: r.minY + 1, width: textWidth, height: 13),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncating)
        return width
    }

    private func drawGraph(_ row: CommitGraph.Row, theme: Theme) {
        let mid = bounds.midY
        for edge in row.edges {
            let (startY, endY) = edge.half == .top ? (bounds.minY, mid) : (mid, bounds.maxY)
            let start = NSPoint(x: style.x(edge.from), y: startY)
            let end = NSPoint(x: style.x(edge.to), y: endY)
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: start)
            if start.x == end.x {
                path.line(to: end)
            } else {
                let bend = (endY - startY) * 0.6
                path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: startY + bend), controlPoint2: NSPoint(x: end.x, y: endY - bend))
            }
            style.color(edge.half == .top ? edge.from : edge.to).withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
        let radius: CGFloat = 3.5
        let dot = NSBezierPath(ovalIn: NSRect(x: style.x(row.lane) - radius, y: mid - radius, width: radius * 2, height: radius * 2))
        let color = style.color(row.lane)
        if row.isMerge {
            theme.chromeBackground.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            color.setStroke()
            dot.stroke()
        } else {
            color.setFill()
            dot.fill()
        }
    }
}

/// "3 files changed  +12 −4", then the commit message's body under it.
final class HistorySummaryCell: NSTableCellView {
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let lineHeight: CGFloat = 15
    static let maxBodyLines = 12
    private var summary = NSAttributedString()
    private var body = ""
    private var style = HistoryStyle()
    private var left: CGFloat { style.childLeft }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? { nil }

    /// What follows the subject in a commit message.
    static func body(_ detail: GitRepository.CommitDetail) -> String {
        guard let newline = detail.message.firstIndex(of: "\n") else { return "" }
        return detail.message[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(_ detail: GitRepository.CommitDetail, theme: Theme) -> NSAttributedString {
        let total = detail.files.count + detail.hiddenFileCount
        let added = detail.files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = detail.files.reduce(0) { $0 + ($1.removed ?? 0) }
        let font = NSFont.systemFont(ofSize: 11.5)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let out = NSMutableAttributedString(string: "\(total) \(total == 1 ? "file" : "files") changed  ",
                                            attributes: [.font: font, .foregroundColor: theme.chromeSecondary])
        out.append(NSAttributedString(string: "+\(added)", attributes: [.font: digits, .foregroundColor: theme.color(.inserted) ?? .systemGreen]))
        out.append(NSAttributedString(string: " −\(removed)", attributes: [.font: digits, .foregroundColor: theme.color(.deleted) ?? .systemRed]))
        if detail.parents.count > 1 {
            out.append(NSAttributedString(string: " · merge, compared with the first parent",
                                          attributes: [.font: font, .foregroundColor: theme.chromeSecondary]))
        }
        return out
    }

    func configure(_ detail: GitRepository.CommitDetail, style: HistoryStyle) {
        self.style = style
        summary = HistorySummaryCell.summary(detail, theme: ThemeManager.shared.active)
        body = HistorySummaryCell.body(detail)
        toolTip = detail.message
        setAccessibilityLabel(summary.string + (body.isEmpty ? "" : ". " + body))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = max(0, bounds.width - left - 10)
        summary.draw(with: NSRect(x: left, y: 4, width: width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard !body.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let capped = HistorySummaryCell.lineHeight * CGFloat(HistorySummaryCell.maxBodyLines)
        (body as NSString).draw(with: NSRect(x: left, y: 24, width: width, height: min(capped, max(0, bounds.height - 28))),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: HistorySummaryCell.bodyFont, .foregroundColor: ThemeManager.shared.active.chromeSecondary,
                                             .paragraphStyle: para])
    }
}

/// A row with only a message: "Loading…", "Showing the latest 5,000 commits…".
final class HistoryInfoCell: NSTableCellView {
    private var text = ""
    private var style = HistoryStyle()
    private var isChild = false
    private var left: CGFloat { isChild ? style.childLeft : 12 }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, style: HistoryStyle, isChild: Bool) {
        self.text = text
        self.style = style
        self.isChild = isChild
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: 11.5)
        let width = max(0, bounds.width - left - 10)
        let height = ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
        (text as NSString).draw(with: NSRect(x: left, y: max(2, (bounds.height - height) / 2), width: width, height: height),
                                options: [.usesLineFragmentOrigin],
                                attributes: [.font: font, .foregroundColor: ThemeManager.shared.active.chromeSecondary, .paragraphStyle: para])
    }
}
