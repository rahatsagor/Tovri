import AppKit

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    /// A symlink to a folder. FileManager won't list a folder through its link, so its
    /// children are read from the folder it points to.
    let isLink: Bool
    /// A link to this folder or one above it; expanding it would never end.
    let isLoop: Bool
    weak var parent: FileNode?
    var children: [FileNode]?

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var isExpandable: Bool { isDirectory && !isLoop }

    init(url: URL, isDirectory: Bool, parent: FileNode?, isLink: Bool = false, isLoop: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.isLoop = isLoop
        self.parent = parent
    }

    func loadChildren() {
        guard !isLoop else { children = []; return }
        let s = Settings.shared
        let hidden = s.hiddenPatterns
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = s.showHiddenFiles ? [] : [.skipsHiddenFiles]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let listed = isLink ? URL(fileURLWithPath: url.realPathURL.path, isDirectory: true) : url
        let urls = (try? fm.contentsOfDirectory(at: listed, includingPropertiesForKeys: keys, options: opts)) ?? []
        var existing: [String: FileNode] = [:]
        for c in children ?? [] { existing[c.url.lastPathComponent] = c }
        var result: [FileNode] = []
        var realPath: String?
        for found in urls {
            let name = found.lastPathComponent
            if hidden.contains(name) { continue }
            // Inside a linked folder, paths stay under the link, where the project shows them.
            let u = isLink ? url.appendingPathComponent(name) : found
            let vals = try? found.resourceValues(forKeys: Set(keys))
            var isDir = (vals?.isDirectory ?? false)
            var isLink = false
            var isLoop = false
            if vals?.isSymbolicLink == true {
                var target: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &target), target.boolValue {
                    isDir = true
                    isLink = true
                    let own = realPath ?? url.realPathURL.path
                    realPath = own
                    let linked = u.realPathURL.path
                    isLoop = own == linked || own.hasPrefix(linked.hasSuffix("/") ? linked : linked + "/")
                }
            }
            if let e = existing[name], e.isDirectory == isDir, e.isLink == isLink, e.isLoop == isLoop {
                result.append(e)
            } else {
                result.append(FileNode(url: u, isDirectory: isDir, parent: self, isLink: isLink, isLoop: isLoop))
            }
        }
        result.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children = result
    }
}

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarView, open url: URL, focusEditor: Bool)
    func sidebar(_ sidebar: SidebarView, quickLook url: URL)
    func sidebar(_ sidebar: SidebarView, openAsText url: URL)
    func sidebarRequestsOpenFolder(_ sidebar: SidebarView)
    func sidebar(_ sidebar: SidebarView, findInFolder url: URL)
    func sidebar(_ sidebar: SidebarView, didMove from: URL, to: URL)
    /// The Changes list was shown and wants current files and line counts.
    func sidebarNeedsChanges(_ sidebar: SidebarView)
    func sidebar(_ sidebar: SidebarView, change: GitRepository.ChangedFile, action: SidebarChangeAction)
}

final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    private(set) var hoverRow = -1

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
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func setHover(_ r: Int) {
        guard r != hoverRow else { return }
        let old = hoverRow
        hoverRow = r
        for i in [old, r] where i >= 0 && i < numberOfRows {
            (rowView(atRow: i, makeIfNecessary: false) as? HoverRowView)?.hovered = i == r
        }
    }
    var onDelete: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 49 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: onSpace?()
        case 51 where event.modifierFlags.contains(.command): onDelete?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(row)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var f = super.frameOfOutlineCell(atRow: row)
        f.origin.x += 4
        return f
    }
}

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarDelegate?
    private let titleLabel = NSTextField(labelWithString: "")
    private let scroll = OverlayScrollView(frame: .zero)
    let outline = SidebarOutlineView()
    private let placeholder = NSTextField(labelWithString: "No Folder Open")
    private lazy var openButton = ToolButton(title: "Open Folder…", tooltip: "Open a project folder to browse and search its files (⌥⌘O)") { [weak self] in
        guard let self else { return }
        self.delegate?.sidebarRequestsOpenFolder(self)
    }
    private lazy var headerButtons: [ToolButton] = [
        ToolButton(symbol: "doc.badge.plus", tooltip: "New file in the selected folder") { [weak self] in self?.newFileInRoot() },
        ToolButton(symbol: "folder.badge.plus", tooltip: "New folder in the selected folder") { [weak self] in self?.newFolderAction() },
        ToolButton(symbol: "arrow.clockwise", tooltip: "Refresh the file tree (it also updates automatically)") { [weak self] in self?.refreshMenu() },
        ToolButton(symbol: "arrow.down.right.and.arrow.up.left", tooltip: "Collapse all folders") { [weak self] in self?.collapseAll() },
    ]
    private(set) var root: FileNode?
    private var nodesByPath: [String: FileNode] = [:]
    static let topInset: CGFloat = TabBarView.height

    // MARK: Changes view

    private let tabs = SidebarTabs()
    /// Created the first time the Changes list is shown, and dropped when the feature is turned off.
    private var changesView: ChangesView?
    var isShowingChanges: Bool { showsTabs && tabs.selected == .changes }
    private var showsTabs: Bool { Settings.shared.gitChangesAndHistory && root != nil }

    func setChangeCount(_ n: Int) { tabs.changeCount = n }

    func setChanges(_ files: [GitRepository.ChangedFile]) {
        tabs.changeCount = files.count
        changesView?.setFiles(files)
    }

    func showChanges(_ on: Bool) {
        guard showsTabs || !on else { return }
        tabs.selected = on ? .changes : .files
        selectTab(tabs.selected)
    }

    private func selectTab(_ tab: SidebarTabs.Tab) {
        if tab == .changes && changesView == nil {
            let v = ChangesView()
            v.onAction = { [weak self] f, action in
                guard let self else { return }
                self.delegate?.sidebar(self, change: f, action: action)
            }
            addSubview(v)
            changesView = v
        }
        updatePlaceholder()
        needsLayout = true
        if tab == .changes { delegate?.sidebarNeedsChanges(self) }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        for b in headerButtons {
            b.symbolSize = 11
            addSubview(b)
        }

        let col = NSTableColumn(identifier: .init("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 13
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.focusRingType = .none
        outline.autoresizesOutlineColumn = false
        outline.onReturn = { [weak self] in self?.openSelected(focus: true) }
        outline.onSpace = { [weak self] in
            guard let self, let node = self.selectedNode else { return }
            self.delegate?.sidebar(self, quickLook: node.url)
        }
        outline.onDelete = { [weak self] in self?.trashSelected() }
        outline.menuProvider = { [weak self] row in self?.contextMenu(row: row) }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.alignment = .center
        addSubview(placeholder)
        addSubview(openButton)
        tabs.onSelect = { [weak self] t in self?.selectTab(t) }
        addSubview(tabs)

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        applyTheme()
        updatePlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func applyTheme() {
        let theme = ThemeManager.shared.active
        appearance = theme.appearance
        outline.backgroundColor = theme.translucent ? .clear : theme.chromeBackground
        titleLabel.textColor = theme.chromeSecondary
        placeholder.textColor = theme.chromeSecondary
        tabs.needsDisplay = true
        changesView?.applyTheme()
        needsDisplay = true
        outline.reloadData()
        openButton.needsDisplay = true
    }

    @objc private func settingsChanged() {
        if !Settings.shared.gitChangesAndHistory, changesView != nil || tabs.selected != .files {
            tabs.selected = .files
            changesView?.removeFromSuperview()
            changesView = nil
        }
        updatePlaceholder()
        needsLayout = true
        guard let root else { return }
        refresh(node: root, recursive: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.chromeBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        theme.chromeBorder.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        let top = SidebarView.topInset
        var bx = bounds.width - 10
        for b in headerButtons.reversed() {
            bx -= 22
            b.frame = NSRect(x: bx, y: top + 2, width: 22, height: 22)
        }
        titleLabel.frame = NSRect(x: 16, y: top + 6, width: max(40, bx - 22), height: 16)
        var contentTop = top + 28
        tabs.isHidden = !showsTabs
        if showsTabs {
            tabs.frame = NSRect(x: 0, y: contentTop, width: bounds.width - 1, height: 30)
            contentTop += 34
        }
        let content = NSRect(x: 0, y: contentTop, width: bounds.width - 1, height: max(0, bounds.height - contentTop))
        scroll.frame = content
        changesView?.frame = content
        outline.tableColumns.first?.width = scroll.contentSize.width - 4
        placeholder.frame = NSRect(x: 10, y: top + 60, width: bounds.width - 20, height: 18)
        let w = openButton.intrinsicWidth + 12
        openButton.frame = NSRect(x: round((bounds.width - w) / 2), y: top + 86, width: w, height: 26)
    }

    private func updatePlaceholder() {
        let none = root == nil
        let changes = isShowingChanges
        for (i, b) in headerButtons.enumerated() {
            // In the Changes list only Refresh applies.
            b.isHidden = none || (changes && i != 2)
        }
        placeholder.isHidden = !none
        openButton.isHidden = !none
        scroll.isHidden = none || changes
        changesView?.isHidden = none || !changes
        needsLayout = true
        titleLabel.stringValue = (root?.name ?? "Explorer").uppercased()
    }

    // MARK: Root

    func setRoot(_ url: URL?) {
        nodesByPath.removeAll()
        if let url {
            let node = FileNode(url: url, isDirectory: true, parent: nil)
            node.loadChildren()
            root = node
            nodesByPath[norm(url.path)] = node
        } else {
            root = nil
        }
        outline.reloadData()
        updatePlaceholder()
    }

    private func norm(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func filesChanged(_ paths: [String]) {
        var targets = Set<ObjectIdentifier>()
        var nodes: [FileNode] = []
        for p in paths {
            var path = norm(p)
            while true {
                if let n = nodesByPath[path] {
                    if targets.insert(ObjectIdentifier(n)).inserted { nodes.append(n) }
                    break
                }
                guard let r = root?.path, path.count > r.count else { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        for n in nodes { refresh(node: n, recursive: false) }
    }

    private func refresh(node: FileNode, recursive: Bool) {
        guard node.children != nil else { return }
        node.loadChildren()
        if recursive { for c in node.children ?? [] where c.isDirectory && c.children != nil { c.loadChildren() } }
        outline.reloadItem(node === root ? nil : node, reloadChildren: true)
    }

    func reveal(_ url: URL, select: Bool = true, expand: Bool = true) {
        guard let root else { return }
        // A file opened through a symlink (/tmp/x) can be in a root kept by its real path (/private/tmp/x).
        var path = url.path
        if !path.hasPrefix(root.path + "/") { path = url.realPathURL.path }
        guard path.hasPrefix(root.path + "/") else { return }
        let rel = path.dropFirst(root.path.count + 1).split(separator: "/")
        var node = root
        for comp in rel {
            if node.children == nil { node.loadChildren(); nodesByPath[norm(node.path)] = node }
            guard let next = node.children?.first(where: { $0.name == String(comp) }) else { return }
            if next.isDirectory && next !== root { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        if node.children == nil {
            node.loadChildren()
            nodesByPath[norm(node.path)] = node
        }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? root!
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { HoverRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell()
        cell.identifier = id
        configure(cell, node)
        return cell
    }

    // MARK: Status decorations

    private var gitStatus: [String: GitFileStatus] = [:]
    private var changedDirectories = Set<String>()
    private var dirtyPaths = Set<String>()
    private var ignoredPaths = Set<String>()

    func setIgnoredPaths(_ paths: Set<String>) {
        guard paths != ignoredPaths else { return }
        ignoredPaths = paths
        refreshVisibleCells()
    }

    private func isIgnored(_ path: String) -> Bool {
        guard !ignoredPaths.isEmpty, let rootPath = root?.url.standardizedFileURL.path else { return false }
        var p = path
        while p.count > rootPath.count {
            if ignoredPaths.contains(p) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
    }

    func setGitStatus(_ status: [String: GitFileStatus]) {
        guard status != gitStatus else { return }
        gitStatus = status
        var dirs = Set<String>()
        for (path, st) in status where st != .ignored {
            var p = (path as NSString).deletingLastPathComponent
            while p.count > 1 && !dirs.contains(p) {
                dirs.insert(p)
                p = (p as NSString).deletingLastPathComponent
            }
        }
        changedDirectories = dirs
        refreshVisibleCells()
    }

    func setDirtyPaths(_ paths: Set<String>) {
        guard paths != dirtyPaths else { return }
        dirtyPaths = paths
        refreshVisibleCells()
    }

    private func configure(_ cell: FileCell, _ node: FileNode) {
        let path = node.url.standardizedFileURL.path
        var status = node.isDirectory ? (changedDirectories.contains(path) ? GitFileStatus.modified : nil) : gitStatus[path]
        if status == nil && isIgnored(path) { status = .ignored }
        cell.configure(node, expanded: outline.isItemExpanded(node), status: status, folderStatus: node.isDirectory,
                       dirty: !node.isDirectory && dirtyPaths.contains(path))
    }

    private func refreshVisibleCells() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let node = self.outline.item(atRow: row) as? FileNode,
                  let cell = rowView.view(atColumn: 0) as? FileCell else { return }
            self.configure(cell, node)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { refreshIcon(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshIcon(notification) }

    private func refreshIcon(_ n: Notification) {
        guard let node = n.userInfo?["NSObject"] as? FileNode else { return }
        let row = outline.row(forItem: node)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell {
            configure(cell, node)
        }
    }

    // MARK: Actions

    var selectedNode: FileNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            delegate?.sidebar(self, open: node.url, focusEditor: false)
        }
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
        delegate?.sidebar(self, open: node.url, focusEditor: true)
    }

    private func openSelected(focus: Bool) {
        guard let node = selectedNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            delegate?.sidebar(self, open: node.url, focusEditor: focus)
        }
    }

    func focusTree() {
        if isShowingChanges, let v = changesView { v.focus() } else { window?.makeFirstResponder(outline) }
    }

    private func contextMenu(row: Int) -> NSMenu? {
        guard let root else { return nil }
        let node = row >= 0 ? (outline.item(atRow: row) as? FileNode ?? root) : root
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
            // Each command acts on the row it was opened for, not on whatever is selected later.
            item.representedObject = node
        }
        add("New File…", #selector(newFile(_:)))
        add("New Folder…", #selector(newFolder(_:)))
        m.addItem(.separator())
        if node !== root {
            add("Rename…", #selector(rename(_:)))
            add("Duplicate", #selector(duplicate(_:)))
            add("Move to Trash", #selector(trashMenu(_:)))
            m.addItem(.separator())
        }
        if node !== root && !node.isDirectory {
            add("Quick Look", #selector(quickLookMenu(_:)))
            if MainWindowController.prefersQuickLook(node.url) { add("Open as Text", #selector(openAsTextMenu(_:))) }
            add("Open in Default App", #selector(openInDefaultApp(_:)))
        }
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Open in Terminal", #selector(openInTerminal(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        add("Copy Relative Path", #selector(copyRelativePath(_:)))
        m.addItem(.separator())
        add("Find in Folder…", #selector(findInFolder(_:)))
        add("Refresh", #selector(refreshMenu))
        return m
    }

    /// The row a context menu command was chosen for, or the selection for other senders.
    private func node(for sender: Any?) -> FileNode? {
        ((sender as? NSMenuItem)?.representedObject as? FileNode) ?? selectedNode
    }

    @objc private func quickLookMenu(_ sender: Any?) {
        guard let node = node(for: sender) else { return }
        delegate?.sidebar(self, quickLook: node.url)
    }

    @objc private func openAsTextMenu(_ sender: Any?) {
        guard let node = node(for: sender) else { return }
        delegate?.sidebar(self, openAsText: node.url)
    }

    @objc private func openInDefaultApp(_ sender: Any?) {
        guard let node = node(for: sender) else { return }
        NSWorkspace.shared.open(node.url)
    }

    private func targetDirectory(for node: FileNode?) -> URL? {
        guard let n = node ?? root else { return nil }
        return n.isDirectory ? n.url : n.url.deletingLastPathComponent()
    }

    private func prompt(_ title: String, _ initial: String, selectBaseName: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            if selectBaseName, let editor = field.currentEditor() {
                let base = (initial as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: base.utf16.count)
            }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func newFileInRoot() { createFile(in: selectedNode ?? root) }

    private func newFolderAction() { createFolder(in: selectedNode ?? root) }

    func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
    }

    @objc private func newFile(_ sender: Any?) { createFile(in: node(for: sender) ?? root) }

    private func createFile(in node: FileNode?) {
        guard let dir = targetDirectory(for: node), let name = prompt("New File", "untitled.txt", selectBaseName: true) else { return }
        let url = dir.appendingPathComponent(name)
        do {
            try SidebarView.createNewFile(at: url)
            reloadDirectory(dir)
            delegate?.sidebar(self, open: url, focusEditor: true)
            reveal(url)
        } catch { showError(error) }
    }

    static func createNewFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An existence check followed by creation would still allow a racing writer to lose data.
        try Data().write(to: url, options: .withoutOverwriting)
    }

    @objc private func newFolder(_ sender: Any?) { createFolder(in: node(for: sender) ?? root) }

    private func createFolder(in node: FileNode?) {
        guard let dir = targetDirectory(for: node), let name = prompt("New Folder", "New Folder") else { return }
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            reloadDirectory(dir)
        } catch { showError(error) }
    }

    @objc private func rename(_ sender: Any?) {
        guard let node = node(for: sender), node !== root,
              let name = prompt("Rename", node.name, selectBaseName: !node.isDirectory), name != node.name else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            reloadDirectory(node.url.deletingLastPathComponent())
            delegate?.sidebar(self, didMove: node.url, to: dest)
        } catch { showError(error) }
    }

    @objc private func duplicate(_ sender: Any?) {
        guard let node = node(for: sender), node !== root else { return }
        let dir = node.url.deletingLastPathComponent()
        let base = node.url.deletingPathExtension().lastPathComponent
        let ext = node.url.pathExtension
        var i = 1
        var dest: URL
        repeat {
            let n = i == 1 ? "\(base) copy" : "\(base) copy \(i)"
            dest = dir.appendingPathComponent(ext.isEmpty ? n : "\(n).\(ext)")
            i += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        do {
            try FileManager.default.copyItem(at: node.url, to: dest)
            reloadDirectory(dir)
        } catch { showError(error) }
    }

    @objc private func trashMenu(_ sender: Any?) { trash(node(for: sender)) }

    /// ⌘⌫ always means the selected row.
    private func trashSelected() { trash(selectedNode) }

    private func trash(_ node: FileNode?) {
        guard let node, node !== root else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            if let error { self?.showError(error) }
            self?.reloadDirectory(node.url.deletingLastPathComponent())
        }
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let n = node(for: sender) ?? root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([n.url])
    }

    @objc private func openInTerminal(_ sender: Any?) {
        guard let dir = targetDirectory(for: node(for: sender)) else { return }
        let config = NSWorkspace.OpenConfiguration()
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: config)
        }
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let n = node(for: sender) ?? root else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.url.path, forType: .string)
    }

    @objc private func copyRelativePath(_ sender: Any?) {
        guard let n = node(for: sender) ?? root, let r = root else { return }
        let rel = n.url.path.hasPrefix(r.path + "/") ? String(n.url.path.dropFirst(r.path.count + 1)) : n.name
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rel, forType: .string)
    }

    @objc private func findInFolder(_ sender: Any?) {
        guard let dir = targetDirectory(for: node(for: sender)) else { return }
        delegate?.sidebar(self, findInFolder: dir)
    }

    @objc private func refreshMenu() {
        if isShowingChanges { delegate?.sidebarNeedsChanges(self); return }
        guard let root else { return }
        refresh(node: root, recursive: true)
    }
    private func reloadDirectory(_ url: URL) {
        if let n = nodesByPath[norm(url.path)] { refresh(node: n, recursive: false) }
    }
}

final class HoverRowView: ThemedRowView {
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        ThemeManager.shared.active.tabHoverBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private final class FileCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        badge.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        badge.alignment = .center
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3.5
        icon.imageScaling = .scaleProportionallyDown
        [icon, label, badge, dirtyDot].forEach(addSubview)
        imageView = icon
        textField = label
        // The cell is read as one element so the name, status letter and unsaved dot are spoken together.
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        [icon, label, badge, dirtyDot].forEach { $0.setAccessibilityElement(false) }
    }

    override func accessibilityChildren() -> [Any]? { nil }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
        var right = bounds.width - 10
        if !badge.isHidden {
            badge.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14)
            right -= 18
        }
        if !dirtyDot.isHidden {
            dirtyDot.frame = NSRect(x: right - 7, y: (h - 7) / 2, width: 7, height: 7)
            right -= 12
        }
        label.frame = NSRect(x: 23, y: (h - 17) / 2, width: max(0, right - 23), height: 17)
    }

    func configure(_ node: FileNode, expanded: Bool, status: GitFileStatus?, folderStatus: Bool, dirty: Bool) {
        let theme = ThemeManager.shared.active
        label.stringValue = node.name
        var textColor = theme.chromeForeground
        if let st = status {
            switch st {
            case .modified, .renamed: textColor = theme.color(.changed) ?? textColor
            case .added, .untracked: textColor = theme.color(.inserted) ?? textColor
            case .conflicted, .deleted: textColor = theme.color(.deleted) ?? textColor
            case .ignored: textColor = theme.chromeSecondary.withAlphaComponent(0.6)
            }
            if folderStatus && status != .ignored { textColor = textColor.mix(theme.chromeForeground, 0.45) }
        }
        label.textColor = textColor
        badge.isHidden = status == nil || folderStatus || status == .ignored
        badge.stringValue = status?.letter ?? ""
        badge.textColor = textColor
        dirtyDot.isHidden = !dirty
        dirtyDot.layer?.backgroundColor = theme.dirty.cgColor
        let (symbol, kind) = FileCell.icon(for: node, expanded: expanded)
        var color: NSColor = node.isDirectory ? theme.accent.mix(theme.chromeSecondary, 0.35) : (theme.color(kind) ?? theme.chromeSecondary)
        if status == .ignored { color = color.withAlphaComponent(0.45) }
        icon.image = FileIcons.image(symbol, color: color, size: 12.5)
        let statusText: String? = status.map { st in folderStatus && st != .ignored ? "Contains changes" : st.label }
        setAccessibilityLabel(([node.name, statusText, dirty ? "Unsaved changes" : nil] as [String?]).compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    static func icon(for node: FileNode, expanded: Bool) -> (String, TokenKind) {
        if node.isDirectory { return (expanded ? "folder" : "folder.fill", .plain) }
        return FileIcons.symbol(forFileName: node.name)
    }
}

/// File-type icons shared by the sidebar, tabs and palette.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String, color: NSColor, size: CGFloat) -> NSImage? {
        let key = "\(symbol)|\(color.description)|\(size)"
        if let i = cache[key] { return i }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color])))
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        return img
    }

    static func image(forFileName name: String, theme: Theme, size: CGFloat = 11) -> NSImage? {
        let (symbol, kind) = symbol(forFileName: name)
        return image(symbol, color: theme.color(kind) ?? theme.chromeSecondary, size: size)
    }

    static func symbol(forFileName name: String) -> (String, TokenKind) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return ("swift", .constant)
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts": return ("curlybraces", .number)
        case "json", "jsonc", "json5": return ("curlybraces.square", .number)
        case "html", "htm", "xml", "svg", "vue", "svelte", "plist", "xib", "storyboard": return ("chevron.left.forwardslash.chevron.right", .tag)
        case "css", "scss", "sass", "less", "styl": return ("paintbrush.pointed", .builtin)
        case "md", "markdown", "mdx", "rst", "txt": return ("doc.plaintext", .heading)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "tiff", "bmp": return ("photo", .string)
        case "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd": return ("terminal", .string)
        case "py", "pyi", "pyw": return ("chevron.left.forwardslash.chevron.right", .type)
        case "rs", "go", "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt", "cs", "rb", "php", "lua", "zig", "dart", "scala":
            return ("chevron.left.forwardslash.chevron.right", .function)
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "env", "properties": return ("gearshape", .property)
        case "lock": return ("lock", .comment)
        case "zip", "gz", "tar", "xz", "7z", "rar", "dmg": return ("archivebox", .comment)
        case "pdf": return ("doc.richtext", .deleted)
        case "sql", "db", "sqlite": return ("cylinder", .keyword)
        case "gitignore", "gitattributes": return ("arrow.triangle.branch", .comment)
        default:
            if name.lowercased() == "dockerfile" { return ("shippingbox", .builtin) }
            if name.lowercased() == "makefile" { return ("hammer", .keyword) }
            return ("doc", .comment)
        }
    }
}
