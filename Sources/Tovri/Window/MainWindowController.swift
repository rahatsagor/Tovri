import AppKit
import QuartzCore

enum LayoutMode: String {
    case single, columns2, columns3, rows2

    var groupCount: Int {
        switch self {
        case .single: return 1
        case .columns2, .rows2: return 2
        case .columns3: return 3
        }
    }
    var vertical: Bool { self == .rows2 }
}

final class TovriWindow: NSWindow {
    func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let mini = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        let h = TabBarView.height
        var f = container.frame
        if f.height != h || f.minY != frame.height - h {
            f.size.height = h
            f.origin.y = frame.height - h
            container.frame = f
        }
        let y = round((h - close.frame.height) / 2)
        var x: CGFloat = 16
        for b in [close, mini, zoom] {
            let o = NSPoint(x: x, y: y)
            if b.frame.origin != o { b.setFrameOrigin(o) }
            x += 20
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }
}

final class RootView: NSView {
    weak var controller: MainWindowController?
    /// Behind-window blur plus a tint, shown for translucent themes. Kept below all content.
    private let blur = NSVisualEffectView()
    private let tint = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        tint.autoresizingMask = [.width, .height]
        addSubview(blur)
        addSubview(tint)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drops that no subview handles (empty editor, tab bar, status bar) open the files.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard let controller, !urls.isEmpty else { return false }
        for url in urls { controller.open(url: url) }
        return true
    }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        blur.frame = bounds
        tint.frame = bounds
        controller?.layoutContent()
    }

    func applyTheme(_ theme: Theme) {
        blur.isHidden = !theme.translucent
        tint.isHidden = !theme.translucent
        tint.background = theme.windowTint
        blur.appearance = theme.appearance
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        guard !theme.translucent else { return }
        theme.chromeBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

final class DividerView: NSView {
    var vertical = true
    var onDrag: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var drawsLine = true
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsLine else { return }
        ThemeManager.shared.active.chromeBorder.setFill()
        if vertical { NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill() }
        else { NSRect(x: 0, y: floor(bounds.midY), width: bounds.width, height: 1).fill() }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, EditorViewDelegate, SidebarDelegate, StatusBarDelegate, NSMenuItemValidation {
    let rootView = RootView()
    let sidebar = SidebarView()
    private let sidebarDivider = DividerView()
    let statusBar = StatusBarView()
    private(set) var groups: [EditorGroup] = []
    private var groupDividers: [DividerView] = []
    private var groupRatios: [CGFloat] = [1]
    private(set) var activeGroupIndex = 0
    var quickLookItems: [URL] = []
    private(set) var layoutMode: LayoutMode = .single
    private(set) var folderURL: URL?
    private(set) var projectIndex: ProjectIndex?
    private var symbolIndex: ProjectSymbolIndex?
    private var watcher: FileWatcher?
    private lazy var palette = PaletteController(controller: self)
    private lazy var findInFilesPanel = FindInFilesPanel(controller: self)
    private var closedTabs: [URL] = []
    private var sidebarVisible: Bool
    private var sidebarForcedOpen = false
    private var sidebarWidth: CGFloat
    /// The sidebar only appears automatically when a folder is open.
    private var isSidebarShown: Bool { folderURL != nil ? sidebarVisible : sidebarForcedOpen }
    private var searcher: FileSearcher?
    /// Weak, so a closed document isn't kept alive: reopening it after "Don't Save" must read
    /// the file from disk, not bring back the discarded edits.
    private struct HistoryPoint {
        weak var doc: Document?
        let url: URL?
        let location: Int
        init(_ doc: Document, _ location: Int) { self.doc = doc; url = doc.url; self.location = location }
    }
    private var history: [HistoryPoint] = []
    private var historyIndex = -1
    private var isClosing = false

    var activeGroup: EditorGroup { groups[min(activeGroupIndex, groups.count - 1)] }
    var activeTab: EditorTab? { activeGroup.activeTab }
    var activeEditor: EditorView? { activeGroup.activeEditor }
    var activeDocument: Document? { activeTab?.document }

    init() {
        let window = TovriWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = rootView
        sidebarVisible = Settings.shared.sidebarVisible
        sidebarWidth = CGFloat(Settings.shared.sidebarWidth)
        super.init(window: window)
        window.delegate = self
        rootView.controller = self

        sidebar.delegate = self
        statusBar.delegate = self
        rootView.addSubview(sidebar)
        sidebarDivider.drawsLine = false
        sidebarDivider.onDrag = { [weak self] p in
            guard let self else { return }
            self.sidebarWidth = min(max(160, p.x), min(640, self.rootView.bounds.width - 300))
            Settings.shared.sidebarWidth = Double(self.sidebarWidth)
            self.rootView.needsLayout = true
        }
        rootView.addSubview(sidebarDivider)
        rootView.addSubview(statusBar)
        setLayout(.single)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(documentStateChanged(_:)), name: .documentStateDidChange, object: nil)
        applyTheme()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let changesObserver { NotificationCenter.default.removeObserver(changesObserver) }
    }

    // MARK: Layout

    func layoutContent() {
        let b = rootView.bounds
        let statusH = Settings.shared.showStatusBar ? StatusBarView.height : 0
        let mainH = b.height - statusH
        var x: CGFloat = 0
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let showSidebar = isSidebarShown
        sidebar.isHidden = !showSidebar
        sidebarDivider.isHidden = !showSidebar
        if showSidebar {
            let w = min(sidebarWidth, b.width - 200)
            sidebar.frame = NSRect(x: 0, y: 0, width: w, height: mainH)
            sidebarDivider.frame = NSRect(x: w - 3, y: 0, width: 6, height: mainH)
            x = w
        }
        statusBar.isHidden = statusH == 0
        statusBar.frame = NSRect(x: 0, y: mainH, width: b.width, height: statusH)

        let area = NSRect(x: x, y: 0, width: b.width - x, height: mainH)
        let n = groups.count
        let vertical = layoutMode.vertical
        let total = vertical ? area.height : area.width
        var offset: CGFloat = 0
        let sum = groupRatios.prefix(n).reduce(0, +)
        for (i, g) in groups.enumerated() {
            let size = i == n - 1 ? total - offset : round(total * groupRatios[i] / max(sum, 0.001))
            let f = vertical ? NSRect(x: area.minX, y: area.minY + offset, width: area.width, height: size)
                             : NSRect(x: area.minX + offset, y: area.minY, width: size, height: area.height)
            g.container.frame = f
            let touchesTopLeft = i == 0 && !showSidebar
            g.tabBar.leadingInset = touchesTopLeft && !fullScreen ? 84 : 6
            if i < groupDividers.count {
                let d = groupDividers[i]
                d.frame = vertical ? NSRect(x: area.minX, y: f.maxY - 3, width: area.width, height: 6)
                                   : NSRect(x: f.maxX - 3, y: area.minY, width: 6, height: area.height)
            }
            offset += size
        }
        (window as? TovriWindow)?.positionTrafficLights()
    }

    func setLayout(_ mode: LayoutMode) {
        let oldGroups = groups
        layoutMode = mode
        let n = mode.groupCount
        while groups.count < n {
            let g = EditorGroup(controller: self)
            groups.append(g)
            rootView.addSubview(g.container, positioned: .below, relativeTo: statusBar)
        }
        if groups.count > n {
            let target = groups[n - 1]
            for g in groups[n...] {
                while !g.tabs.isEmpty {
                    let doc = g.tabs[0].document
                    let sel = g.tabs[0].editor?.textView.selectedRange()
                    g.removeTab(at: 0)
                    if target.index(of: doc) == nil {
                        let t = target.add(doc, select: false)
                        t.pendingSelection = sel
                    }
                }
                g.container.removeFromSuperview()
            }
            groups.removeLast(groups.count - n)
        }
        groupDividers.forEach { $0.removeFromSuperview() }
        groupDividers = []
        for i in 0..<(n - 1) {
            let d = DividerView()
            d.vertical = !mode.vertical
            d.onDrag = { [weak self] p in self?.dragGroupDivider(i, to: p) }
            d.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.groupRatios = Array(repeating: 1, count: n)
                self.rootView.needsLayout = true
            }
            rootView.addSubview(d)
            groupDividers.append(d)
        }
        groupRatios = Array(repeating: 1, count: n)
        activeGroupIndex = min(activeGroupIndex, n - 1)
        rootView.needsLayout = true
        if oldGroups.count != groups.count { updateGroupFocus() }
        if activeGroup.tabs.isEmpty && groups.allSatisfy({ $0.tabs.isEmpty }) { updateStatusBar() }
    }

    private func dragGroupDivider(_ i: Int, to p: NSPoint) {
        let vertical = layoutMode.vertical
        let n = groups.count
        let x0 = isSidebarShown ? sidebar.frame.maxX : 0
        let total = vertical ? rootView.bounds.height - statusBar.frame.height : rootView.bounds.width - x0
        let pos = vertical ? p.y : p.x - x0
        let sum = groupRatios.reduce(0, +)
        var sizes = groupRatios.map { $0 / sum * total }
        let start = sizes.prefix(i).reduce(0, +)
        let pairTotal = sizes[i] + sizes[i + 1]
        let newSize = min(max(120, pos - start), pairTotal - 120)
        sizes[i] = newSize
        sizes[i + 1] = pairTotal - newSize
        groupRatios = sizes.map { $0 / total * CGFloat(n) }
        rootView.needsLayout = true
    }

    // MARK: Theme and settings

    @objc private func themeChanged() { applyTheme() }

    private func applyTheme() {
        let theme = ThemeManager.shared.active
        window?.appearance = theme.appearance
        window?.isOpaque = !theme.translucent
        window?.backgroundColor = theme.translucent ? .clear : theme.chromeBackground
        rootView.applyTheme(theme)
        rootView.needsDisplay = true
        statusBar.needsDisplay = true
        sidebarDivider.needsDisplay = true
        groupDividers.forEach { $0.needsDisplay = true }
        DispatchQueue.main.async { (self.window as? TovriWindow)?.positionTrafficLights() }
    }

    @objc private func settingsChanged() {
        rootView.needsLayout = true
        updateStatusBar()
    }

    @objc private func documentStateChanged(_ n: Notification) {
        guard let d = n.object as? Document else { return }
        if d.url != nil { updateSidebarDirtyMarks() }
        guard d === activeDocument else { return }
        updateTitle()
        updateStatusBar()
    }

    // MARK: Groups

    func activate(group: EditorGroup) {
        guard let i = groups.firstIndex(where: { $0 === group }) else { return }
        if i != activeGroupIndex {
            activeGroupIndex = i
            updateGroupFocus()
        }
    }

    private func updateGroupFocus() {
        for (i, g) in groups.enumerated() { g.tabBar.isActiveGroup = i == activeGroupIndex || groups.count == 1 }
        updateTitle()
        updateStatusBar()
    }

    func groupDidChangeSelection(_ group: EditorGroup) {
        SessionStore.shared.setNeedsSave()
        if Settings.shared.revealActiveFile, isSidebarShown, group === activeGroup, let url = group.activeTab?.document.url {
            sidebar.reveal(url, select: true, expand: true)
        }
        if group === activeGroup {
            updateTitle()
            updateStatusBar()
        }
    }

    private func group(containing editor: EditorView) -> EditorGroup? {
        groups.first { g in g.tabs.contains { $0.editor === editor } }
    }

    func allOpenDocuments() -> [Document] {
        var seen = Set<ObjectIdentifier>()
        var out: [Document] = []
        for g in groups { for t in g.tabs where seen.insert(ObjectIdentifier(t.document)).inserted { out.append(t.document) } }
        return out
    }

    var hasDirtyDocuments: Bool { allOpenDocuments().contains { $0.isDirty } }
    var isEmptyWindow: Bool {
        folderURL == nil && groups.allSatisfy { g in g.tabs.allSatisfy { $0.document.url == nil && !$0.document.isDirty && $0.document.length == 0 } }
    }

    // MARK: Title and status

    private func updateTitle() {
        guard let window else { return }
        let doc = activeDocument
        var title = doc?.displayName ?? "Tovri"
        if let f = folderURL { title += " — " + f.lastPathComponent }
        window.title = title
        window.representedURL = doc?.url
        window.isDocumentEdited = doc?.isDirty ?? false
    }

    func updateStatusBar() {
        guard let e = activeEditor else {
            statusBar.values = [:]
            return
        }
        let doc = e.document
        let tv = e.textView
        let sels = tv.allSelections
        let primary = tv.selectedRange()
        let line = doc.lines.line(containing: primary.location)
        let lineStart = doc.lines.start(of: line)
        let col = tv.visualColumn(of: primary.location, lineStart: lineStart) + 1
        var pos = "Ln \(line + 1), Col \(col)"
        if sels.count > 1 {
            pos += "  ·  \(sels.count) selections"
        } else if primary.length > 0 {
            let lines = doc.lines.line(containing: NSMaxRange(primary)) - line + 1
            pos += "  ·  \(primary.length) selected" + (lines > 1 ? " (\(lines) lines)" : "")
            if doc.isProse && primary.length < 2_000_000 {
                let words = Document.countWords(doc.string, in: primary)
                pos += words == 1 ? ", 1 word" : ", \(words) words"
            }
        } else if doc.isProse, let words = doc.wordCount(updated: { [weak self] in self?.updateStatusBar() }) {
            pos += words == 1 ? "  ·  1 word" : "  ·  \(words.formatted()) words"
        }
        let repo = GitRepository.find(for: doc.url ?? folderURL ?? URL(fileURLWithPath: "/"))
        statusBar.values = [
            .branch: (doc.url != nil || folderURL != nil) ? (repo?.branch ?? "") : "",
            .position: pos,
            .indentation: doc.indentUsesTabs ? "Tab Size: \(doc.indentWidth)" : "Spaces: \(doc.indentWidth)",
            .encoding: doc.encoding.rawValue,
            .lineEnding: doc.lineEnding.rawValue,
            .language: doc.language.name,
        ]
    }

    // MARK: EditorViewDelegate

    func editorDidFocus(_ editor: EditorView) {
        if let g = group(containing: editor) { activate(group: g) }
    }

    func editorSelectionDidChange(_ editor: EditorView) {
        if editor === activeEditor { updateStatusBar() }
        group(containing: editor)?.refreshAccessories()
    }

    func editor(_ editor: EditorView, openFindResultPath path: String, line: Int) {
        let target = groups.count > 1 ? groups.first(where: { $0 !== group(containing: editor) }) : nil
        open(url: URL(fileURLWithPath: path), line: line, group: target)
        if let e = activeEditor, let re = FindState.shared.makeRegex() {
            let r = e.document.lines.range(of: line - 1, textLength: e.document.length)
            if let m = re.firstMatch(in: e.document.string as String, range: r) { e.select(m.range) }
        }
    }

    func editor(_ editor: EditorView, openFiles urls: [URL]) {
        for u in urls { open(url: u) }
    }

    // MARK: Opening

    @discardableResult
    func open(url: URL, line: Int? = nil, column: Int? = nil, symbol: String? = nil, focus: Bool = true,
              group target: EditorGroup? = nil, asText: Bool = false) -> Document? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            NSSound.beep()
            return nil
        }
        // Documents saved as packages (Keynote, Pages) are folders on disk but files to people.
        if isDir.boolValue && NSWorkspace.shared.isFilePackage(atPath: url.path) && MainWindowController.prefersQuickLook(url) {
            quickLook(url)
            return nil
        }
        if isDir.boolValue {
            openFolder(url)
            return nil
        }
        recordHistory()
        let std = url.standardizedFileURL.resolvingSymlinksInPath()
        for g in (target.map { [$0] } ?? groups) {
            if let i = g.tabs.firstIndex(where: { $0.document.url?.standardizedFileURL.resolvingSymlinksInPath() == std }) {
                activate(group: g)
                g.select(i, focus: focus)
                navigate(line: line, column: column, symbol: symbol)
                return g.tabs[i].document
            }
        }
        if !asText, DocumentRegistry.shared.existing(for: url) == nil, MainWindowController.prefersQuickLook(url) {
            quickLook(url)
            return nil
        }
        let doc: Document
        do {
            if DocumentRegistry.shared.existing(for: url) == nil, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > 8_000, isLikelyBinary(url) {
                let alert = NSAlert()
                alert.messageText = "“\(url.lastPathComponent)” looks like a binary file."
                alert.informativeText = "Opening it as text may show unreadable characters."
                alert.addButton(withTitle: "Open Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            }
            doc = try Perf.measure("load \(url.lastPathComponent)", threshold: 0) { try DocumentRegistry.shared.open(url) }
        } catch {
            showError(error)
            return nil
        }
        let g = target ?? activeGroup
        activate(group: g)
        let t0 = CACurrentMediaTime()
        defer {
            if Perf.enabled {
                DispatchQueue.main.async { FileHandle.standardError.write("[perf] open+first layout \(url.lastPathComponent) \(Int((CACurrentMediaTime() - t0) * 1000)) ms\n".data(using: .utf8)!) }
            }
        }
        if g.tabs.count == 1, let t = g.tabs.first, t.document.url == nil, !t.document.isDirty, t.document.length == 0 {
            g.add(doc)
            g.removeTab(at: g.index(of: t.document) ?? 0)
        } else {
            g.add(doc)
        }
        if !focus { sidebar.window?.makeFirstResponder(sidebar.window?.firstResponder) }
        if focus { activeEditor?.focus() }
        RecentFiles.shared.add(url)
        navigate(line: line, column: column, symbol: symbol)
        updateTitle()
        updateStatusBar()
        if Settings.shared.markdownPreviewOnOpen && doc.language.id == "markdown" { activeEditor?.setMarkdownPreview(true) }
        return doc
    }

    /// Opens a path that doesn't exist yet as a new unsaved file.
    func openNewFile(at url: URL) -> Document {
        if let d = DocumentRegistry.shared.existing(for: url), let (g, i) = locate(d) {
            activate(group: g)
            g.select(i)
            return d
        }
        let doc = Document(newFileAt: url)
        DocumentRegistry.shared.register(doc)
        replaceEmptyUntitled(with: doc, in: activeGroup)
        activeEditor?.focus()
        return doc
    }

    /// Opens text (e.g. piped from the CLI) in a new untitled tab.
    func openText(_ text: String) -> Document {
        let doc = Document()
        let (text, ending) = LineEnding.normalize(text, rawData: nil)
        doc.lineEnding = ending
        doc.restoreBuffer(text)
        if let first = text.split(separator: "\n", maxSplits: 1).first, let lang = LanguageRegistry.shared.language(forFirstLine: String(first)) {
            doc.setLanguage(lang, manual: false)
        } else if text.hasPrefix("diff --git") || text.hasPrefix("--- ") {
            if let diff = LanguageRegistry.shared.language(id: "diff") { doc.setLanguage(diff, manual: false) }
        }
        replaceEmptyUntitled(with: doc, in: activeGroup)
        activeEditor?.focus()
        return doc
    }

    private func replaceEmptyUntitled(with doc: Document, in g: EditorGroup) {
        activate(group: g)
        if g.tabs.count == 1, let t = g.tabs.first, t.document.url == nil, !t.document.isDirty, t.document.length == 0 {
            g.add(doc)
            g.removeTab(at: g.index(of: t.document) ?? 0)
        } else {
            g.add(doc)
        }
    }

    private func isLikelyBinary(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 8000)) ?? Data()
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return false }
        return d.contains(0)
    }

    private func navigate(line: Int?, column: Int? = nil, symbol: String?) {
        guard let e = activeEditor else { return }
        if let line { e.goTo(line: line, column: max(0, (column ?? 1) &- 1)) }
        if let sym = symbol, !sym.isEmpty {
            let q = Fuzzy.prepare(sym)
            let best = e.symbols().compactMap { s -> (Int, EditorView.Symbol)? in
                Fuzzy.match(q, Array(s.name.utf16)).map { ($0.score, s) }
            }.max { $0.0 < $1.0 }
            if let s = best?.1 { e.select(s.range) }
        }
    }

    func openFolder(_ url: URL) {
        if folderURL != nil && folderURL != url, let app = NSApp.delegate as? AppDelegate {
            app.newWindow(folder: url)
            return
        }
        setFolder(url)
    }

    func setFolder(_ url: URL?) {
        watcher?.stop()
        watcher = nil
        folderURL = url
        sidebar.setRoot(url)
        if let url {
            projectIndex = ProjectIndex(root: url)
            var pending = false
            watcher = FileWatcher(path: url.path) { [weak self] paths in
                guard let self else { return }
                self.sidebar.filesChanged(paths)
                if !pending {
                    pending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        pending = false
                        self.projectIndex?.rebuild()
                        self.refreshGitStatus()
                    }
                }
            }
            RecentFiles.shared.add(url)
            if !sidebarVisible {
                sidebarVisible = true
                Settings.shared.sidebarVisible = true
            }
        } else {
            projectIndex = nil
        }
        symbolIndex = nil
        rootView.needsLayout = true
        updateTitle()
        refreshGitStatus()
        SessionStore.shared.setNeedsSave()
    }

    // MARK: Git

    private var gitStatusPending = false

    func refreshGitStatus() {
        guard let folder = folderURL, let repo = GitRepository.find(for: folder) else {
            sidebar.setGitStatus([:])
            sidebar.setIgnoredPaths([])
            return
        }
        guard !gitStatusPending else { return }
        gitStatusPending = true
        repo.status { [weak self] status in
            guard let self else { return }
            self.gitStatusPending = false
            var abs: [String: GitFileStatus] = [:]
            for (rel, st) in status { abs[repo.root.appendingPathComponent(rel).standardizedFileURL.path] = st }
            self.sidebar.setGitStatus(abs)
            self.updateStatusBar()
        }
        repo.ignored { [weak self] list in
            self?.sidebar.setIgnoredPaths(Set(list.map { repo.root.appendingPathComponent($0).standardizedFileURL.path }))
        }
    }

    private func updateSidebarDirtyMarks() {
        let paths = Set(allOpenDocuments().filter { $0.isDirty }.compactMap { $0.url?.standardizedFileURL.path })
        sidebar.setDirtyPaths(paths)
    }

    @objc func newTab(_ sender: Any?) {
        let doc = Document()
        activeGroup.add(doc)
        activeEditor?.focus()
    }

    // MARK: Closing

    func closeTab(in group: EditorGroup, at index: Int, completion: ((Bool) -> Void)? = nil) {
        guard index >= 0, index < group.tabs.count else { completion?(false); return }
        let tab = group.tabs[index]
        let doc = tab.document
        let otherViews = allGroupsTabs().filter { $0 !== tab && $0.document === doc }.count + (doc.editorCount - (tab.editor == nil ? 0 : 1)) > 0
        let finish = { [weak self] in
            guard let self else { return }
            if let url = doc.url { self.closedTabs.append(url) }
            if let i = group.index(of: doc) { group.removeTab(at: i) }
            let stillOpen = (NSApp.delegate as? AppDelegate)?.controllers.contains { $0.allOpenDocuments().contains { $0 === doc } } ?? false
            WaitRegistry.shared.documentMayHaveClosed(doc, stillOpen: stillOpen)
            if Settings.shared.quitWhenLastWindowCloses && self.groups.allSatisfy({ $0.tabs.isEmpty }) {
                completion?(true)
                // Deferred: when a save sheet just ended it is still attached and blocks the close.
                DispatchQueue.main.async { self.window?.performClose(nil) }
                return
            }
            if self.activeGroup.tabs.isEmpty, let other = self.groups.firstIndex(where: { !$0.tabs.isEmpty }) {
                self.activeGroupIndex = other
                self.updateGroupFocus()
            }
            self.activeEditor?.focus()
            self.updateTitle()
            self.updateStatusBar()
            completion?(true)
        }
        if doc.isDirty && !otherViews {
            confirmSave(doc) { ok in ok ? finish() : completion?(false) }
        } else {
            finish()
        }
    }

    private func allGroupsTabs() -> [EditorTab] { groups.flatMap { $0.tabs } }

    private func confirmSave(_ doc: Document, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(doc.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.buttons[2].keyEquivalent = "d"
        alert.buttons[2].keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] resp in
            switch resp {
            case .alertFirstButtonReturn: self?.save(doc, completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    /// Asks about each dirty document in turn.
    func confirmCloseAll(_ completion: @escaping (Bool) -> Void) {
        let dirty = allOpenDocuments().filter { $0.isDirty && ($0.editorCount <= editorsCount(for: $0)) }
        confirmClose(dirty, completion: completion)
    }

    /// The app supplies globally deduplicated documents when every window is quitting.
    func confirmClose(_ dirty: [Document], completion: @escaping (Bool) -> Void) {
        func next(_ i: Int) {
            guard i < dirty.count else { completion(true); return }
            guard dirty[i].isDirty else { next(i + 1); return }
            if let (g, idx) = locate(dirty[i]) {
                activate(group: g)
                g.select(idx)
            }
            confirmSave(dirty[i]) { ok in ok ? next(i + 1) : completion(false) }
        }
        next(0)
    }

    private func editorsCount(for doc: Document) -> Int {
        allGroupsTabs().filter { $0.document === doc && $0.editor != nil }.count
    }

    private func locate(_ doc: Document) -> (EditorGroup, Int)? {
        for g in groups { if let i = g.index(of: doc) { return (g, i) } }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        if (NSApp.delegate as? AppDelegate)?.isTerminating == true { return true }
        if let app = NSApp.delegate as? AppDelegate, app.closingKeepsUnsavedChanges(self) {
            return app.saveSessionBeforeClosingWindow(self)
        }
        guard hasDirtyDocuments else { return true }
        confirmCloseAll { [weak self] ok in
            guard ok, let self else { return }
            self.isClosing = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if (NSApp.delegate as? AppDelegate)?.isTerminating != true { teardown() }
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    func teardown() {
        watcher?.stop()
        searcher?.cancel()
        let docs = allOpenDocuments()
        for g in groups { for t in g.tabs { t.close() } }
        let others = (NSApp.delegate as? AppDelegate)?.controllers.filter { $0 !== self } ?? []
        for d in docs {
            WaitRegistry.shared.documentMayHaveClosed(d, stillOpen: others.contains { $0.allOpenDocuments().contains { $0 === d } })
        }
    }

    @objc func closeTabCommand(_ sender: Any?) {
        if palette.isVisible { palette.close(cancelled: true); return }
        if findInFilesPanel.isVisible { findInFilesPanel.close(); return }
        let g = activeGroup
        if g.selectedIndex >= 0 {
            closeTab(in: g, at: g.selectedIndex)
        } else if groups.count > 1 {
            setLayout(.single)
        } else {
            window?.performClose(sender)
        }
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        let g = activeGroup
        guard let keep = g.activeTab?.document else { return }
        closeTabs(in: g, where: { $0 !== keep })
    }

    @objc func closeTabsToRight(_ sender: Any?) {
        let g = activeGroup
        let idx = g.selectedIndex
        let docs = Set(g.tabs.enumerated().filter { $0.offset > idx }.map { ObjectIdentifier($0.element.document) })
        closeTabs(in: g, where: { docs.contains(ObjectIdentifier($0)) })
    }

    @objc func closeAllTabs(_ sender: Any?) {
        for g in groups { closeTabs(in: g, where: { _ in true }) }
    }

    @objc func closeSavedTabs(_ sender: Any?) {
        for g in groups { closeTabs(in: g, where: { !$0.isDirty }) }
    }

    private func closeTabs(in g: EditorGroup, where pred: @escaping (Document) -> Bool) {
        guard let i = g.tabs.firstIndex(where: { pred($0.document) }) else { return }
        closeTab(in: g, at: i) { [weak self] ok in
            if ok { self?.closeTabs(in: g, where: pred) }
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        while let url = closedTabs.popLast() {
            if FileManager.default.fileExists(atPath: url.path) { open(url: url); return }
        }
        NSSound.beep()
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        save(doc)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        saveAs(doc)
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        let docs = allOpenDocuments().filter { $0.isDirty }
        func next(_ i: Int) {
            guard i < docs.count else { return }
            save(docs[i]) { _ in next(i + 1) }
        }
        next(0)
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard let doc = activeDocument, doc.url != nil, let window else { return }
        // Reloading clears the undo history, so the unsaved edits can't be brought back.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert “\(doc.displayName)” to the saved version?"
        alert.informativeText = "Your unsaved changes will be lost. This can’t be undone."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            do { try doc.reload() } catch { self?.showError(error) }
        }
    }

    /// With `interactive` false (automatic saves), a save that would need a question is skipped
    /// and the document stays unsaved, rather than showing a dialog while Tovri is in the background.
    func save(_ doc: Document, replacingExternalChanges: Bool = false, interactive: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !doc.isTransient else { completion?(true); return }
        guard doc.url != nil else {
            if interactive { saveAs(doc, completion: completion) } else { completion?(false) }
            return
        }
        write(doc, to: nil, replacingExternalChanges: replacingExternalChanges, interactive: interactive, completion: completion)
    }

    /// Writes `doc` to `target`, or to its own file when nil, after the save-time cleanups.
    func write(_ doc: Document, to target: URL?, replacingExternalChanges: Bool = false, interactive: Bool = true,
               completion: ((Bool) -> Void)? = nil) {
        let editor = allGroupsTabs().first { $0.document === doc && $0.editor != nil }?.editor
        if let tv = editor?.textView {
            let cleanups = doc.saveCleanups(to: target)
            if cleanups.trimTrailingWhitespace { tv.trimTrailingWhitespace(nil) }
            if cleanups.insertFinalNewline { tv.ensureTrailingNewline() }
        }
        do {
            try doc.save(to: target, replacingExternalChanges: replacingExternalChanges)
            statusBar.flash("Saved “\(doc.displayName)”")
            if target != nil { updateTitle() }
            refreshGitStatus()
            completion?(true)
        } catch let error where !interactive {
            statusBar.flash("“\(doc.displayName)” wasn’t saved automatically: \(MainWindowController.autosaveProblem(error))")
            completion?(false)
        } catch DocumentError.modifiedOnDisk {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = doc.isNewFile
                ? "Another application created “\(doc.displayName)”."
                : "“\(doc.displayName)” was changed by another application."
            alert.informativeText = "Saving will replace the file on disk with your version."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                write(doc, to: target, replacingExternalChanges: true, completion: completion)
            } else { completion?(false) }
        } catch DocumentError.encodingFailed(let enc) {
            let alert = NSAlert()
            alert.messageText = "This document can’t be saved as \(enc.rawValue)."
            alert.informativeText = "Save it using UTF-8 instead?"
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                doc.encoding = .utf8
                write(doc, to: target, replacingExternalChanges: replacingExternalChanges, completion: completion)
            } else { completion?(false) }
        } catch {
            showError(error)
            completion?(false)
        }
        updateStatusBar()
    }

    private static func autosaveProblem(_ error: Error) -> String {
        switch error {
        case DocumentError.modifiedOnDisk: return "it changed on disk."
        case DocumentError.encodingFailed: return "its encoding can’t hold the text."
        default: return error.localizedDescription
        }
    }

    func saveAs(_ doc: Document, completion: ((Bool) -> Void)? = nil) {
        guard let window else { completion?(false); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.url?.lastPathComponent ?? (doc.displayName.hasPrefix("Untitled") ? "untitled.txt" : doc.displayName)
        panel.directoryURL = doc.url?.deletingLastPathComponent() ?? folderURL
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { completion?(false); return }
            self.write(doc, to: url, completion: completion)
        }
    }

    // MARK: External changes

    func windowDidBecomeKey(_ notification: Notification) {
        (window as? TovriWindow)?.positionTrafficLights()
        checkExternalChanges()
        refreshGitStatus()
        allOpenDocuments().forEach { $0.refreshGitBaseline() }
    }

    func windowDidResize(_ notification: Notification) { (window as? TovriWindow)?.positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) {
        rootView.needsLayout = true
        (window as? TovriWindow)?.positionTrafficLights()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { rootView.needsLayout = true }

    private var diskPrompts = Set<ObjectIdentifier>()

    func checkExternalChanges() {
        for doc in allOpenDocuments() { handleDiskChange(doc) }
    }

    /// Clean documents reload silently; documents with unsaved edits ask first (as a sheet).
    func handleDiskChange(_ doc: Document) {
        switch doc.checkDiskStatus() {
        case .modified:
            if !doc.isDirty {
                reloadPreservingViews(doc)
                statusBar.flash("Reloaded “\(doc.displayName)” (changed on disk)")
            } else {
                promptForDiskChange(doc)
            }
        case .deleted:
            doc.markDeletedOnDisk()
        case .unchanged:
            break
        }
        groups.forEach { $0.refreshTabBar() }
    }

    /// A caret parked at the end of a growing file (a log, an agent's output) follows new lines.
    private func reloadPreservingViews(_ doc: Document) {
        let oldLength = doc.length
        let saved = editors(for: doc).map { e -> (EditorView, NSRange, CGPoint, Bool) in
            let endVisible = e.textView.visibleRect.intersects(e.textView.caretRect(at: oldLength))
            return (e, e.textView.selectedRange(), e.scrollPosition, endVisible)
        }
        do { try doc.reload() } catch { return }
        for (e, s, p, endVisible) in saved {
            let len = doc.length
            let follow = s.length == 0 && s.location >= oldLength && len > oldLength
            e.textView.setAllSelections([NSRange(location: follow ? len : min(s.location, len), length: 0)], scroll: false)
            e.scrollPosition = p
            if follow && endVisible {
                e.layoutManager.ensureLayout(forCharacterRange: NSRange(location: len - 1, length: 1))
                e.textView.scrollRangeToVisible(NSRange(location: len, length: 0))
            }
        }
    }

    // MARK: Printing

    @objc func printActiveDocument(_ sender: Any?) {
        guard let e = activeEditor, let window else { NSSound.beep(); return }
        if e.previewMode == .off && e.document.lines.count > 20_000 {
            let alert = NSAlert()
            alert.messageText = "Print \(e.document.lines.count.formatted()) lines?"
            alert.informativeText = "This document is long. Preparing it can take a while and it may print hundreds of pages."
            alert.addButton(withTitle: "Print")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for side in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: side] = 40 }
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        let op: NSPrintOperation
        if e.previewMode != .off, let preview = e.preview {
            op = preview.printOperation(with: info)
        } else {
            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            op = NSPrintOperation(view: PrintableText.view(for: e.document, width: width), printInfo: info)
        }
        op.jobTitle = e.document.displayName
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func promptForDiskChange(_ doc: Document) {
        let key = ObjectIdentifier(doc)
        guard !diskPrompts.contains(key), let window else { return }
        if window.attachedSheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak doc] in
                if let doc { self?.promptForDiskChange(doc) }
            }
            return
        }
        diskPrompts.insert(key)
        if let (g, i) = locate(doc) { activate(group: g); g.select(i, focus: false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(doc.displayName)” was changed by another application."
        alert.informativeText = "You have unsaved changes in Tovri. Keep your version, or discard it and load the file from disk?"
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: window) { [weak self] resp in
            self?.diskPrompts.remove(key)
            if resp == .alertSecondButtonReturn { self?.reloadPreservingViews(doc) } else { doc.acknowledgeDiskVersion() }
            self?.groups.forEach { $0.refreshTabBar() }
        }
    }

    private func editors(for doc: Document) -> [EditorView] {
        allGroupsTabs().compactMap { $0.document === doc ? $0.editor : nil }
    }

    // MARK: Tabs navigation

    // NSWindow's own selectNextTab(_:) and selectPreviousTab(_:), for native window tabs, would
    // take these first and grey them out, so the names differ.
    @objc func selectNextTabCommand(_ sender: Any?) {
        let g = activeGroup
        guard !g.tabs.isEmpty else { return }
        g.select((g.selectedIndex + 1) % g.tabs.count)
    }

    @objc func selectPreviousTabCommand(_ sender: Any?) {
        let g = activeGroup
        guard !g.tabs.isEmpty else { return }
        g.select((g.selectedIndex - 1 + g.tabs.count) % g.tabs.count)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let g = activeGroup
        guard !g.tabs.isEmpty else { return }
        g.select(item.tag >= 9 ? g.tabs.count - 1 : min(item.tag - 1, g.tabs.count - 1))
    }

    @objc func moveTabLeft(_ sender: Any?) {
        let g = activeGroup
        guard g.selectedIndex > 0 else { return }
        g.moveTab(from: g.selectedIndex, to: g.selectedIndex - 1)
    }

    @objc func moveTabRight(_ sender: Any?) {
        let g = activeGroup
        guard g.selectedIndex >= 0, g.selectedIndex < g.tabs.count - 1 else { return }
        g.moveTab(from: g.selectedIndex, to: g.selectedIndex + 1)
    }

    func tabMenu(group: EditorGroup, index: Int) -> NSMenu? {
        group.select(index)
        activate(group: group)
        let m = NSMenu()
        m.addItem(withTitle: "Close", action: #selector(closeTabCommand(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Close Tabs to the Right", action: #selector(closeTabsToRight(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Close Saved Tabs", action: #selector(closeSavedTabs(_:)), keyEquivalent: "")
        m.addItem(.separator())
        if groups.count > 1 { m.addItem(withTitle: "Move to Next Group", action: #selector(moveTabToNextGroup(_:)), keyEquivalent: "") }
        m.addItem(withTitle: "Split to New Column", action: #selector(splitTabRight(_:)), keyEquivalent: "")
        if group.tabs[index].document.url != nil {
            m.addItem(.separator())
            m.addItem(withTitle: "Copy Path", action: #selector(copyFilePath(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Copy Relative Path", action: #selector(copyRelativePath(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Reveal in Sidebar", action: #selector(revealInSidebar(_:)), keyEquivalent: "")
        }
        m.items.forEach { $0.target = self }
        return m
    }

    // MARK: Layout commands

    @objc func layoutSingle(_ sender: Any?) { setLayout(.single) }
    @objc func layoutColumns2(_ sender: Any?) { setLayout(.columns2) }
    @objc func layoutColumns3(_ sender: Any?) { setLayout(.columns3) }
    @objc func layoutRows2(_ sender: Any?) { setLayout(.rows2) }

    @objc func focusGroupByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let i = item.tag - 1
        guard i >= 0 && i < groups.count else { return }
        activeGroupIndex = i
        updateGroupFocus()
        activeEditor?.focus()
    }

    @objc func moveTabToNextGroup(_ sender: Any?) {
        if groups.count == 1 { setLayout(.columns2) }
        let from = activeGroup
        let to = groups[(activeGroupIndex + 1) % groups.count]
        moveActiveTab(from: from, to: to)
    }

    @objc func splitTabRight(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        if groups.count == 1 { setLayout(.columns2) }
        let to = groups[(activeGroupIndex + 1) % groups.count]
        let sel = activeEditor?.textView.selectedRange()
        if let i = to.index(of: doc) { to.select(i) } else {
            let t = to.add(doc, select: false)
            t.pendingSelection = sel
            to.select(to.index(of: doc) ?? 0)
        }
        activate(group: to)
    }

    private func moveActiveTab(from: EditorGroup, to: EditorGroup) {
        guard from !== to, from.selectedIndex >= 0 else { return }
        let doc = from.tabs[from.selectedIndex].document
        guard let tab = from.detachTab(at: from.selectedIndex) else { return }
        if let i = to.index(of: doc) { to.select(i) } else {
            let t = to.add(doc, select: false)
            t.pendingSelection = tab.pendingSelection
            t.pendingScroll = tab.pendingScroll
            to.select(to.index(of: doc) ?? 0)
        }
        activate(group: to)
    }

    // MARK: Sidebar

    /// Not named `toggleSidebar(_:)`: NSWindow implements that for split view sidebars, and as the
    /// window comes before its controller in the responder chain, it would grey out View → Sidebar.
    @objc func toggleSidebarCommand(_ sender: Any?) {
        if folderURL == nil {
            sidebarForcedOpen.toggle()
        } else {
            sidebarVisible.toggle()
            Settings.shared.sidebarVisible = sidebarVisible
        }
        rootView.needsLayout = true
    }

    @objc func focusSidebar(_ sender: Any?) {
        if !isSidebarShown { toggleSidebarCommand(nil) }
        sidebar.focusTree()
    }

    @objc func revealInSidebar(_ sender: Any?) {
        guard let url = activeDocument?.url else { return }
        if !isSidebarShown { toggleSidebarCommand(nil) }
        sidebar.reveal(url)
    }

    @objc func closeFolder(_ sender: Any?) { setFolder(nil) }

    func sidebar(_ sidebar: SidebarView, open url: URL, focusEditor: Bool) {
        open(url: url, focus: focusEditor)
        if !focusEditor { sidebar.focusTree() }
    }

    func sidebar(_ sidebar: SidebarView, quickLook url: URL) {
        quickLook(url)
    }

    func sidebar(_ sidebar: SidebarView, openAsText url: URL) {
        open(url: url, asText: true)
    }

    func sidebarRequestsOpenFolder(_ sidebar: SidebarView) {
        (NSApp.delegate as? AppDelegate)?.openFolderPanel(for: self)
    }

    func sidebar(_ sidebar: SidebarView, findInFolder url: URL) {
        findInFilesPanel.show(folder: url)
    }

    func sidebar(_ sidebar: SidebarView, didMove from: URL, to: URL) {
        let fromPath = from.standardizedFileURL.path
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? [self]
        // A renamed folder moves every open file inside it, including files shown in other windows.
        var seen = Set<ObjectIdentifier>()
        for doc in controllers.flatMap({ $0.allOpenDocuments() }) where seen.insert(ObjectIdentifier(doc)).inserted {
            guard let path = doc.url?.standardizedFileURL.path else { continue }
            if path == fromPath {
                doc.fileDidMove(to: to)
            } else if path.hasPrefix(fromPath + "/") {
                doc.fileDidMove(to: to.appendingPathComponent(String(path.dropFirst(fromPath.count + 1))))
            }
        }
        controllers.forEach { c in c.groups.forEach { $0.refreshTabBar() } }
    }

    // MARK: File info commands

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = activeDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let url = activeDocument?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func copyRelativePath(_ sender: Any?) {
        guard let url = activeDocument?.url else { return }
        var s = url.lastPathComponent
        if let r = folderURL?.path, url.path.hasPrefix(r + "/") { s = String(url.path.dropFirst(r.count + 1)) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) { activeEditor?.showFindBar(replace: false) }
    @objc func showReplace(_ sender: Any?) { activeEditor?.showFindBar(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { activeEditor?.findNext(forward: true) }
    @objc func findPreviousMatch(_ sender: Any?) { activeEditor?.findNext(forward: false) }
    @objc func useSelectionForFindCommand(_ sender: Any?) { activeEditor?.useSelectionForFind() }
    @objc func showFindInFiles(_ sender: Any?) { findInFilesPanel.show(folder: nil) }

    func runFindInFiles(_ options: FileSearcher.Options) {
        searcher?.cancel()
        let s = FileSearcher()
        searcher = s
        statusBar.message = "Searching for “\(options.query)”…"
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = s.run(options)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searcher === s else { return }
                self.searcher = nil
                self.statusBar.message = nil
                guard let result else {
                    if !s.isCancelled { NSSound.beep() }
                    return
                }
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                var text = "Searching \(result.scanned) files for “\(options.query)” in \(options.root.path)\n\n"
                text += result.text
                text += "\(result.matches) match\(result.matches == 1 ? "" : "es") across \(result.files) file\(result.files == 1 ? "" : "s") (\(elapsed)s)\n"
                let st = FindState()
                st.regex = options.regex
                st.caseSensitive = options.caseSensitive
                st.wholeWord = options.wholeWord
                self.showFindResults(text, highlight: st.makeRegex(query: options.query))
            }
        }
    }

    private func showFindResults(_ text: String, highlight re: NSRegularExpression?) {
        var shown = false
        for g in groups {
            if let i = g.tabs.firstIndex(where: { $0.document.isFindResults }) {
                g.tabs[i].document.replaceAllContent(text)
                activate(group: g)
                g.select(i)
                shown = true
                break
            }
        }
        if !shown {
            let doc = Document(text: text, name: "Find Results", language: LanguageRegistry.shared.findResults)
            doc.isReadOnly = true
            doc.isTransient = true
            activeGroup.add(doc)
        }
        activeEditor?.goTo(line: 1)
        if let re { activeEditor?.highlightFindResults(re) }
    }

    // MARK: Palette

    @objc func gotoAnything(_ sender: Any?) { palette.show(mode: .files) }
    @objc func commandPalette(_ sender: Any?) { palette.show(mode: .commands) }
    @objc func gotoSymbol(_ sender: Any?) { palette.show(mode: .files, initial: "@") }
    @objc func gotoLine(_ sender: Any?) { palette.show(mode: .files, initial: ":") }

    @objc func showSyntaxPicker(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        let all = LanguageRegistry.shared.all
        let items = all.map { lang in
            PaletteItem(title: lang.name, detail: lang.extensions.prefix(4).map { "." + $0 }.joined(separator: " "),
                        icon: lang === doc.language ? "checkmark" : nil) { doc.setLanguage(lang) }
        }
        palette.showList(placeholder: "Set syntax", items: items, selectedIndex: all.firstIndex { $0 === doc.language } ?? 0)
    }

    @objc func showThemePicker(_ sender: Any?) {
        let tm = ThemeManager.shared
        let current = tm.current
        let items = tm.themes.map { t in
            PaletteItem(title: t.name, detail: t.isDark ? "dark" : "light", icon: t === current ? "checkmark" : nil,
                        preview: { tm.preview(t) }) {
                tm.preview(nil)
                Settings.shared.followSystemAppearance = false
                Settings.shared.theme = t.name
            }
        }
        palette.showList(placeholder: "Select theme", items: items, selectedIndex: tm.themes.firstIndex { $0 === current } ?? 0) {
            tm.preview(nil)
        }
    }

    func paletteCommands() -> [PaletteItem] {
        guard let main = NSApp.mainMenu else { return [] }
        var out: [PaletteItem] = []
        func walk(_ menu: NSMenu, prefix: String) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    // Syntax and Theme get their own "Set Syntax:" and "Theme:" entries below.
                    if ["Open Recent", "Services", "Window", "Syntax", "Theme"].contains(item.title) { continue }
                    walk(sub, prefix: menu === main ? item.title : prefix)
                    continue
                }
                guard let action = item.action, !item.title.isEmpty else { continue }
                if menu.title == "Window" && item.target is NSWindow { continue }
                guard paletteCanRun(item) else { continue }
                let target = item.target
                let title = prefix.isEmpty ? item.title : "\(prefix): \(item.title)"
                out.append(PaletteItem(title: title, shortcut: MainWindowController.shortcutString(item)) { [weak self] in
                    self?.activeEditor?.focus()
                    NSApp.sendAction(action, to: target, from: item)
                })
            }
        }
        for top in main.items {
            guard let sub = top.submenu, top.title != "Window" || true else { continue }
            if top === main.items.first { walk(sub, prefix: "Tovri"); continue }
            walk(sub, prefix: top.title)
        }
        for lang in LanguageRegistry.shared.all {
            out.append(PaletteItem(title: "Set Syntax: \(lang.name)") { [weak self] in self?.activeDocument?.setLanguage(lang) })
        }
        for t in ThemeManager.shared.themes {
            out.append(PaletteItem(title: "Theme: \(t.name)") {
                Settings.shared.followSystemAppearance = false
                Settings.shared.theme = t.name
            })
        }
        return out
    }

    /// Whether the menu would enable `item` with the editor focused, so the palette only lists
    /// commands that do something. The chain starts at the editor, not the palette's own field,
    /// because the palette focuses the editor again before it runs a command.
    func paletteCanRun(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        var target: AnyObject?
        if let t = item.target {
            target = t.responds(to: action) ? t : nil
        } else {
            var r: NSResponder? = activeEditor?.textView ?? window
            while let x = r, target == nil {
                if x.responds(to: action) { target = x }
                r = x.nextResponder
            }
            if target == nil, responds(to: action) { target = self }
            if target == nil, let d = NSApp.delegate, d.responds(to: action) { target = d }
        }
        guard let target else { return false }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        return true
    }

    static func shortcutString(_ item: NSMenuItem) -> String {
        KeyShortcut(item: item)?.display ?? ""
    }

    // MARK: Symbols across the project

    /// Symbols from the project folder plus open documents; unsaved documents override their
    /// file on disk. `completion` runs on the main thread once the index matches the disk.
    func loadWorkspaceSymbols(_ completion: @escaping ([WorkspaceSymbol]) -> Void) {
        if let index = projectIndex, index.isBuilding, index.entries.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.loadWorkspaceSymbols(completion) }
            return
        }
        let assemble = { [weak self] () -> [WorkspaceSymbol] in
            guard let self else { return [] }
            let root = self.folderURL?.standardizedFileURL
            let rootPrefix = root.map { $0.path + "/" }
            var out: [WorkspaceSymbol] = []
            var overridden = Set<String>()
            for d in self.allOpenDocuments() {
                let path = d.url?.standardizedFileURL.path
                let rel = path.flatMap { p in rootPrefix.flatMap { p.hasPrefix($0) ? String(p.dropFirst($0.count)) : nil } }
                if rel != nil && !d.isDirty { continue }
                if let rel { overridden.insert(rel) }
                let shown = rel ?? path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? d.displayName
                for s in d.symbols() {
                    out.append(WorkspaceSymbol(name: s.name, units: Array(s.name.utf16), target: .document(d, s.range),
                                               line: s.line, column: s.range.location - d.lines.start(of: s.line), displayPath: shown))
                }
            }
            if let root, let index = self.symbolIndex, index.root == root {
                out.reserveCapacity(out.count + index.symbols.count)
                for s in index.symbols where !overridden.contains(s.path) {
                    out.append(WorkspaceSymbol(name: s.name, units: s.units, target: .file(root: root, relativePath: s.path),
                                               line: s.line, column: s.column, displayPath: s.path))
                }
            }
            return out
        }
        guard let root = folderURL?.standardizedFileURL, let index = projectIndex else { completion(assemble()); return }
        if symbolIndex?.root != root { symbolIndex = ProjectSymbolIndex(root: root) }
        symbolIndex?.refresh(files: index.entries.map(\.relativePath)) {
            completion(Perf.measure("assemble symbols", threshold: 8) { assemble() })
        }
    }

    @objc func gotoSymbolInProject(_ sender: Any?) { palette.show(mode: .projectSymbols) }

    // MARK: Changes since the last commit

    private func flashNoChanges(_ doc: Document?) {
        guard let doc, doc.url != nil else { statusBar.flash("Save the file to compare it with Git"); return }
        statusBar.flash(doc.hasGitBaseline ? "No changes since the last commit" : "“\(doc.displayName)” isn’t tracked by Git")
    }

    @objc func nextChange(_ sender: Any?) {
        if activeEditor?.gotoChange(forward: true) != true { flashNoChanges(activeDocument) }
    }

    @objc func previousChange(_ sender: Any?) {
        if activeEditor?.gotoChange(forward: false) != true { flashNoChanges(activeDocument) }
    }

    @objc func revertChange(_ sender: Any?) {
        guard let e = activeEditor else { return }
        guard let h = e.gitHunkAtCaret else { NSSound.beep(); return }
        e.revertGitChange(h)
    }

    /// Opens a read-only diff of the active file, including unsaved edits, against HEAD.
    @objc func compareWithLastCommit(_ sender: Any?) {
        guard let doc = activeDocument, !doc.isTransient else { NSSound.beep(); return }
        guard let diff = doc.unifiedDiffAgainstHead(), !diff.isEmpty else { flashNoChanges(doc); return }
        let name = "\(doc.displayName) — Changes"
        observeChangesSources()
        for g in groups {
            if let i = g.tabs.firstIndex(where: { $0.document.changesSource === doc }) {
                g.tabs[i].document.replaceAllContent(diff)
                activate(group: g)
                g.select(i)
                return
            }
        }
        let lang = LanguageRegistry.shared.language(id: "diff") ?? LanguageRegistry.shared.plain
        let changes = Document(text: diff, name: name, language: lang)
        changes.isReadOnly = true
        changes.isTransient = true
        changes.changesSource = doc
        activeGroup.add(changes)
    }

    private var changesObserver: NSObjectProtocol?
    private var observingChangesSources: Bool { changesObserver != nil }

    /// Keeps open Changes tabs current as their files are edited, saved or reloaded.
    private func observeChangesSources() {
        guard !observingChangesSources else { return }
        changesObserver = NotificationCenter.default.addObserver(forName: .documentStateDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let source = note.object as? Document else { return }
            for tab in self.allGroupsTabs() where tab.document.changesSource === source {
                guard let diff = source.unifiedDiffAgainstHead() else { continue }
                let text = diff.isEmpty ? "No changes since the last commit.\n" : diff
                if tab.document.string as String != text { tab.document.replaceAllContent(text) }
            }
        }
    }

    /// Lists files with uncommitted changes, e.g. everything an AI agent just touched.
    @objc func showChangedFiles(_ sender: Any?) {
        guard let base = folderURL ?? activeDocument?.url, let repo = GitRepository.find(for: base) else {
            statusBar.flash("Not in a Git repository")
            return
        }
        repo.status { [weak self] status in
            guard let self else { return }
            let theme = ThemeManager.shared.active
            let entries = status.filter { $0.value != .ignored && $0.value != .deleted }.sorted { $0.key < $1.key }
            guard !entries.isEmpty else { self.statusBar.flash("No changed files"); return }
            let items = entries.map { rel, st -> PaletteItem in
                let url = repo.root.appendingPathComponent(rel)
                let dir = (rel as NSString).deletingLastPathComponent
                var item = PaletteItem(title: url.lastPathComponent, detail: st.label + (dir.isEmpty ? "" : " · " + dir)) { [weak self] in
                    self?.open(url: url)
                }
                item.image = FileIcons.image(forFileName: url.lastPathComponent, theme: theme, size: 12)
                item.twoLine = true
                return item
            }
            self.palette.showList(placeholder: "Changed files (\(entries.count))", items: items)
        }
    }

    @objc func gotoDefinition(_ sender: Any?) {
        guard let e = activeEditor else { return }
        let sel = e.textView.selectedRange()
        guard let r = sel.length > 0 ? sel : e.textView.wordRange(at: sel.location) else { NSSound.beep(); return }
        let word = e.document.string.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.utf16.count <= 200, !word.contains("\n") else { NSSound.beep(); return }
        let doc = e.document
        loadWorkspaceSymbols { [weak self] all in
            guard let self, self.activeEditor === e else { return }
            let matches = all.filter { $0.name == word || $0.name.hasSuffix("." + word) }
            let others = matches.filter { !$0.isDefinition(in: doc, at: r) }
            // Definitions in the current file first, then the rest in project order.
            let ordered = others.filter { $0.belongs(to: doc) } + others.filter { !$0.belongs(to: doc) }
            if ordered.isEmpty {
                if matches.isEmpty { self.palette.show(mode: .projectSymbols, initial: word) } else { NSSound.beep() }
                return
            }
            if ordered.count == 1 { self.jump(to: ordered[0]); return }
            let items = ordered.map { s in
                PaletteItem(title: s.name, detail: "\(s.displayPath):\(s.line + 1)", icon: "arrow.turn.down.right") { [weak self] in self?.jump(to: s) }
            }
            self.palette.showList(placeholder: "Definitions of \(word)", items: items)
        }
    }

    func jump(to symbol: WorkspaceSymbol) {
        switch symbol.target {
        case .document(let d, let range):
            recordHistory()
            if let (g, i) = locate(d) {
                activate(group: g)
                g.select(i)
            } else {
                activeGroup.add(d)
            }
            guard NSMaxRange(range) <= d.length else { return }
            activeEditor?.select(range)
        case .file(let root, let rel):
            guard open(url: root.appendingPathComponent(rel), line: symbol.line + 1, column: symbol.column + 1) != nil,
                  let ed = activeEditor else { return }
            let loc = ed.textView.selectedRange().location
            let len = symbol.units.count
            if loc + len <= ed.document.length, ed.document.string.substring(with: NSRange(location: loc, length: len)) == symbol.name {
                ed.select(NSRange(location: loc, length: len))
            }
        }
        activeEditor?.focus()
    }

    // MARK: History

    private func recordHistory() {
        guard let e = activeEditor else { return }
        let point = HistoryPoint(e.document, e.textView.selectedRange().location)
        if historyIndex < history.count - 1 { history.removeLast(history.count - 1 - historyIndex) }
        if let last = history.last, last.doc === point.doc, abs(last.location - point.location) < 2 { return }
        history.append(point)
        if history.count > 100 { history.removeFirst() }
        historyIndex = history.count - 1
    }

    @objc func jumpBack(_ sender: Any?) {
        guard historyIndex >= 0, historyIndex < history.count else { NSSound.beep(); return }
        if historyIndex == history.count - 1, let e = activeEditor {
            history.append(HistoryPoint(e.document, e.textView.selectedRange().location))
        }
        go(to: history[historyIndex])
        historyIndex -= 1
    }

    @objc func jumpForward(_ sender: Any?) {
        guard historyIndex + 2 < history.count else { NSSound.beep(); return }
        historyIndex += 1
        go(to: history[historyIndex + 1])
    }

    private func go(to point: HistoryPoint) {
        if let doc = point.doc {
            if let (g, i) = locate(doc) {
                activate(group: g)
                g.select(i)
            } else {
                activeGroup.add(doc)
            }
        } else if let url = point.url {
            guard open(url: url) != nil else { return }
        } else {
            NSSound.beep()
            return
        }
        guard let e = activeEditor else { return }
        e.select(NSRange(location: min(point.location, e.document.length), length: 0))
    }

    // MARK: View toggles

    @objc func toggleWordWrap(_ sender: Any?) { activeEditor?.toggleWordWrap() }
    @objc func toggleMarkdownPreview(_ sender: Any?) { activeEditor?.toggleMarkdownPreview() }
    @objc func toggleMarkdownPreviewSplit(_ sender: Any?) { activeEditor?.toggleMarkdownPreviewSplit() }
    @objc func toggleMinimap(_ sender: Any?) { Settings.shared.showMinimap.toggle() }
    @objc func toggleLineNumbers(_ sender: Any?) { Settings.shared.showLineNumbers.toggle() }
    @objc func toggleIndentGuides(_ sender: Any?) { Settings.shared.showIndentGuides.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { Settings.shared.showInvisibles.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { Settings.shared.showStatusBar.toggle() }
    @objc func increaseFontSize(_ sender: Any?) { Settings.shared.fontSize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { Settings.shared.fontSize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { Settings.shared.fontSize = 13 }

    @objc func setSyntaxFromMenu(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String, let lang = LanguageRegistry.shared.language(id: id) else { return }
        activeDocument?.setLanguage(lang)
    }

    @objc func setThemeFromMenu(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        Settings.shared.followSystemAppearance = false
        Settings.shared.theme = name
    }

    @objc func toggleFollowSystemAppearance(_ sender: Any?) {
        Settings.shared.followSystemAppearance.toggle()
    }

    // MARK: Status bar

    func statusBar(_ bar: StatusBarView, clicked item: StatusBarView.Item, at rect: NSRect) {
        guard let doc = activeDocument else { return }
        let menu = NSMenu()
        switch item {
        case .branch:
            return
        case .position:
            gotoLine(nil)
            return
        case .language:
            showSyntaxPicker(nil)
            return
        case .indentation:
            let spaces = NSMenuItem(title: "Indent Using Spaces", action: #selector(setIndentSpaces(_:)), keyEquivalent: "")
            spaces.state = doc.indentUsesTabs ? .off : .on
            let tabs = NSMenuItem(title: "Indent Using Tabs", action: #selector(setIndentTabs(_:)), keyEquivalent: "")
            tabs.state = doc.indentUsesTabs ? .on : .off
            menu.addItem(spaces)
            menu.addItem(tabs)
            menu.addItem(.separator())
            for w in [2, 3, 4, 8] {
                let i = NSMenuItem(title: "Width: \(w)", action: #selector(setIndentWidth(_:)), keyEquivalent: "")
                i.tag = w
                i.state = doc.indentWidth == w ? .on : .off
                menu.addItem(i)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Convert Indentation to Spaces", action: #selector(EditorTextView.convertIndentationToSpaces(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Convert Indentation to Tabs", action: #selector(EditorTextView.convertIndentationToTabs(_:)), keyEquivalent: "")
        case .encoding:
            let header = NSMenuItem(title: "Save with Encoding", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for e in TextEncoding.allCases {
                let i = NSMenuItem(title: e.rawValue, action: #selector(setEncoding(_:)), keyEquivalent: "")
                i.representedObject = e.rawValue
                i.state = doc.encoding == e ? .on : .off
                menu.addItem(i)
            }
            if doc.url != nil {
                menu.addItem(.separator())
                let reopen = NSMenuItem(title: "Reopen with Encoding", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for e in TextEncoding.allCases {
                    let i = NSMenuItem(title: e.rawValue, action: #selector(reopenWithEncoding(_:)), keyEquivalent: "")
                    i.representedObject = e.rawValue
                    i.target = self
                    sub.addItem(i)
                }
                reopen.submenu = sub
                menu.addItem(reopen)
            }
        case .lineEnding:
            for le in LineEnding.allCases {
                let i = NSMenuItem(title: le.displayName, action: #selector(setLineEnding(_:)), keyEquivalent: "")
                i.representedObject = le.rawValue
                i.state = doc.lineEnding == le ? .on : .off
                menu.addItem(i)
            }
        }
        for i in menu.items where i.target == nil && i.action != nil && !NSStringFromSelector(i.action!).hasPrefix("convert") { i.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - 4), in: bar)
    }

    @objc private func setIndentSpaces(_ sender: Any?) { activeDocument.map { $0.setIndentation(tabs: false, width: $0.indentWidth) }; updateStatusBar() }
    @objc private func setIndentTabs(_ sender: Any?) { activeDocument.map { $0.setIndentation(tabs: true, width: $0.indentWidth) }; updateStatusBar() }
    @objc private func setIndentWidth(_ sender: NSMenuItem) {
        activeDocument.map { $0.setIndentation(tabs: $0.indentUsesTabs, width: sender.tag) }
        activeEditor?.applySettings()
        updateStatusBar()
    }

    @objc private func setEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw), let doc = activeDocument else { return }
        doc.encoding = e
        if doc.url != nil { save(doc) }
        updateStatusBar()
    }

    @objc private func reopenWithEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw), let doc = activeDocument else { return }
        do { try doc.reload(encoding: e) } catch { showError(error) }
        updateStatusBar()
    }

    @objc private func setLineEnding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw), let doc = activeDocument else { return }
        doc.lineEnding = le
        if doc.url != nil { save(doc) }
        updateStatusBar()
    }

    // MARK: Help

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        guard let main = NSApp.mainMenu else { return }
        var text = "Tovri Keyboard Shortcuts\n========================\n\n"
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                if let sub = item.submenu {
                    if ["Open Recent", "Services", "Window", "Syntax", "Theme"].contains(item.title) { continue }
                    let header = item.title
                    if depth == 0 { text += "## \(header)\n\n" } else { text += "### \(header)\n" }
                    walk(sub, depth: depth + 1)
                    text += "\n"
                    continue
                }
                let sc = MainWindowController.shortcutString(item)
                guard !sc.isEmpty else { continue }
                text += "- " + item.title.padding(toLength: 44, withPad: " ", startingAt: 0) + sc + "\n"
            }
        }
        walk(main, depth: 0)
        text += """
        ## Editor

        - Add caret                                   ⌘-Click
        - Column selection                            ⌥-Drag
        - Select line(s)                              Click/drag in gutter
        - Accept completion                           ↩ or ⇥
        - Collapse multiple selections                ⎋
        - Find: next / previous / select all          ↩ / ⇧↩ / ⌥↩

        """
        let doc = Document(text: text, name: "Keyboard Shortcuts", language: LanguageRegistry.shared.language(id: "markdown") ?? LanguageRegistry.shared.plain)
        doc.isTransient = true
        doc.isReadOnly = true
        activeGroup.add(doc)
    }

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let s = Settings.shared
        switch menuItem.action {
        case #selector(toggleSidebarCommand(_:)): menuItem.state = isSidebarShown ? .on : .off
        case #selector(toggleMinimap(_:)): menuItem.state = s.showMinimap ? .on : .off
        case #selector(toggleLineNumbers(_:)): menuItem.state = s.showLineNumbers ? .on : .off
        case #selector(toggleIndentGuides(_:)): menuItem.state = s.showIndentGuides ? .on : .off
        case #selector(toggleInvisibles(_:)): menuItem.state = s.showInvisibles ? .on : .off
        case #selector(toggleStatusBar(_:)): menuItem.state = s.showStatusBar ? .on : .off
        case #selector(toggleWordWrap(_:)):
            menuItem.state = activeEditor?.wordWrap == true ? .on : .off
            return activeEditor != nil
        case #selector(toggleFollowSystemAppearance(_:)): menuItem.state = s.followSystemAppearance ? .on : .off
        case #selector(setSyntaxFromMenu(_:)):
            menuItem.state = (menuItem.representedObject as? String) == activeDocument?.language.id ? .on : .off
            return activeDocument != nil
        case #selector(setThemeFromMenu(_:)):
            menuItem.state = (menuItem.representedObject as? String) == ThemeManager.shared.current.name ? .on : .off
        case #selector(layoutSingle(_:)): menuItem.state = layoutMode == .single ? .on : .off
        case #selector(layoutColumns2(_:)): menuItem.state = layoutMode == .columns2 ? .on : .off
        case #selector(layoutColumns3(_:)): menuItem.state = layoutMode == .columns3 ? .on : .off
        case #selector(layoutRows2(_:)): menuItem.state = layoutMode == .rows2 ? .on : .off
        case #selector(focusGroupByNumber(_:)): return menuItem.tag <= groups.count
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return activeDocument != nil && activeDocument?.isTransient == false
        case #selector(revertDocumentToSaved(_:)): return activeDocument?.url != nil && activeDocument?.isDirty == true
        case #selector(revealInFinder(_:)), #selector(copyFilePath(_:)), #selector(copyRelativePath(_:)), #selector(revealInSidebar(_:)):
            return activeDocument?.url != nil
        case #selector(closeFolder(_:)): return folderURL != nil
        case #selector(closeOtherTabs(_:)): return activeGroup.tabs.count > 1
        case #selector(moveTabLeft(_:)): return activeGroup.selectedIndex > 0
        case #selector(moveTabRight(_:)): return activeGroup.selectedIndex >= 0 && activeGroup.selectedIndex < activeGroup.tabs.count - 1
        case #selector(moveTabToNextGroup(_:)), #selector(splitTabRight(_:)): return activeTab != nil
        case #selector(saveAllDocuments(_:)): return hasDirtyDocuments
        case #selector(revertChange(_:)): return activeEditor?.gitHunkAtCaret != nil
        case #selector(reopenClosedTab(_:)): return !closedTabs.isEmpty
        case #selector(toggleMarkdownPreview(_:)):
            menuItem.state = activeEditor?.previewMode == .full ? .on : .off
            return activeEditor?.isMarkdown == true
        case #selector(toggleMarkdownPreviewSplit(_:)):
            menuItem.state = activeEditor?.previewMode == .split ? .on : .off
            return activeEditor?.isMarkdown == true
        case #selector(showFind(_:)), #selector(showReplace(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)),
             #selector(useSelectionForFindCommand(_:)), #selector(gotoSymbol(_:)), #selector(gotoLine(_:)), #selector(showSyntaxPicker(_:)),
             #selector(gotoDefinition(_:)):
            return activeEditor != nil
        default: break
        }
        return true
    }

    // MARK: Session

    func sessionState() -> WindowSession {
        var gs: [GroupSession] = []
        for g in groups {
            var tabs: [TabSession] = []
            var selected = 0
            for t in g.tabs where !t.document.isTransient {
                let d = t.document
                var ts = TabSession(path: d.url?.path, untitledName: d.url == nil ? d.displayName : nil, buffer: nil,
                                    selection: t.editor?.textView.selectedRange().location ?? t.pendingSelection?.location ?? 0,
                                    selectionLength: t.editor?.textView.selectedRange().length ?? t.pendingSelection?.length ?? 0,
                                    scrollX: Double(t.editor?.scrollPosition.x ?? t.pendingScroll?.x ?? 0),
                                    scrollY: Double(t.editor?.scrollPosition.y ?? t.pendingScroll?.y ?? 0),
                                    language: d.languageWasSetManually ? d.language.id : nil,
                                    encoding: d.encoding.rawValue, lineEnding: d.lineEnding.rawValue)
                ts.isNewFile = d.isNewFile ? true : nil
                if Settings.shared.hotExit && (d.isDirty || (d.url == nil && d.length > 0)) {
                    ts.buffer = SessionStore.shared.bufferName(for: d)
                } else if d.url == nil && d.length == 0 {
                    continue
                }
                if t === g.activeTab { selected = tabs.count }
                tabs.append(ts)
            }
            gs.append(GroupSession(tabs: tabs, selected: selected))
        }
        return WindowSession(frame: window.map { NSStringFromRect($0.frame) } ?? "", folder: folderURL?.path,
                             sidebarVisible: sidebarVisible, sidebarWidth: Double(sidebarWidth), layout: layoutMode.rawValue,
                             groups: gs, activeGroup: activeGroupIndex, fullScreen: window?.styleMask.contains(.fullScreen) ?? false)
    }

    func restore(_ s: WindowSession) {
        let bufferDirectory = SessionStore.shared.bufferDirectory
        if !s.frame.isEmpty { window?.setFrame(NSRectFromString(s.frame), display: false) }
        sidebarVisible = s.sidebarVisible
        sidebarWidth = CGFloat(s.sidebarWidth)
        if let f = s.folder, FileManager.default.fileExists(atPath: f) { setFolder(URL(fileURLWithPath: f)) }
        sidebarVisible = s.sidebarVisible
        setLayout(LayoutMode(rawValue: s.layout) ?? .single)
        for (gi, gsess) in s.groups.enumerated() where gi < groups.count {
            let g = groups[gi]
            for t in gsess.tabs {
                var doc: Document?
                let encoding = t.encoding.flatMap(TextEncoding.init(rawValue:))
                if let p = t.path {
                    let url = URL(fileURLWithPath: p)
                    if FileManager.default.fileExists(atPath: p) {
                        doc = try? DocumentRegistry.shared.open(url, encoding: encoding)
                    } else if t.isNewFile == true || t.buffer != nil {
                        doc = Document(newFileAt: url)
                    }
                    if doc == nil && t.buffer == nil { continue }
                    if doc == nil { doc = Document() }
                } else {
                    doc = Document()
                    if let n = t.untitledName { doc?.restoreUntitledName(n) }
                }
                guard let d = doc else { continue }
                if let lid = t.language, let lang = LanguageRegistry.shared.language(id: lid) { d.setLanguage(lang) }
                // A file read from disk keeps the format it was decoded with, which may have changed
                // since the session was saved; the stored values are for documents without a file.
                if d.url == nil || d.isNewFile {
                    if let encoding { d.encoding = encoding }
                    if let le = t.lineEnding.flatMap(LineEnding.init(rawValue:)) { d.lineEnding = le }
                }
                if let b = t.buffer, let text = try? String(contentsOf: bufferDirectory.appendingPathComponent(b), encoding: .utf8) {
                    d.restoreBuffer(text)
                    if t.path != nil && !FileManager.default.fileExists(atPath: t.path!) { d.markDirtyForRestoredBuffer() }
                }
                if g.index(of: d) != nil { continue }
                let tab = g.add(d, select: false)
                tab.pendingSelection = NSRange(location: t.selection, length: t.selectionLength)
                tab.pendingScroll = CGPoint(x: t.scrollX, y: t.scrollY)
            }
            if !g.tabs.isEmpty { g.select(min(max(0, gsess.selected), g.tabs.count - 1), focus: false) }
        }
        activeGroupIndex = min(max(0, s.activeGroup), groups.count - 1)
        updateGroupFocus()
        rootView.needsLayout = true
        if s.fullScreen { DispatchQueue.main.async { self.window?.toggleFullScreen(nil) } }
    }

    // MARK: Errors

    func showError(_ error: Error) {
        guard let window else { NSAlert(error: error).runModal(); return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
