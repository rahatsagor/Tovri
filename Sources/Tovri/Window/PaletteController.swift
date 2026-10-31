import AppKit

struct PaletteItem {
    var title: String
    var detail: String = ""
    var shortcut: String = ""
    var icon: String?
    var image: NSImage?
    /// Title with the detail on a second line (used for files).
    var twoLine = false
    var action: () -> Void
    var preview: (() -> Void)?
    var positions: [Int] = []
    fileprivate var units: [UInt16] = []
    fileprivate var basenameStart = 0
    fileprivate var score = 0

    init(title: String, detail: String = "", shortcut: String = "", icon: String? = nil,
         preview: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.icon = icon
        self.preview = preview
        self.action = action
    }
}

/// Thread-safe counter used to drop superseded background searches.
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return current }
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; current += 1; return current }
}

/// Transparent full-window layer that closes the palette when clicked outside it.
final class PaletteBackdrop: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var isFlipped: Bool { true }
}

/// Sublime-style overlay used for Go to Anything, the command palette, symbols and lists.
final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode { case files, commands, symbols, projectSymbols, line, list }

    unowned let controller: MainWindowController
    private let backdrop = PaletteBackdrop()
    private let panel = FlippedView()
    private let field = ThemedTextField(placeholder: "")
    private let scroll = OverlayScrollView(frame: .zero)
    private let table = NSTableView()
    private var mode: Mode = .files
    private var source: [PaletteItem] = []
    private var results: [PaletteItem] = []
    private var onCancel: (() -> Void)?
    private var restore: (editor: EditorView, selection: NSRange, scroll: CGPoint)?
    private var symbolCache: [EditorView.Symbol] = []
    private var workspaceSymbols: [WorkspaceSymbol]?
    private var loadGeneration = 0
    private let symbolQueue = DispatchQueue(label: "app.tovri.palette-symbols", qos: .userInteractive)
    private let filterGeneration = Generation()
    /// Indices matching an earlier query; a longer query can only match a subset of them.
    private var narrowing: (query: [UInt16], matched: [Int32])?
    private var rowHeight: CGFloat = 32
    private let maxRows = 10
    private let hint = NSTextField(labelWithString: "↑↓ to navigate    ↩ to open    ⎋ to dismiss")

    var isVisible: Bool { backdrop.superview != nil }

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
        backdrop.onClick = { [weak self] in self?.close(cancelled: true) }
        backdrop.addSubview(panel)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 11
        panel.layer?.borderWidth = 1
        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.35
        panel.layer?.shadowRadius = 22
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        field.fontSize = 15
        field.field.delegate = self
        panel.addSubview(field)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        panel.addSubview(scroll)
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        panel.addSubview(hint)
    }

    // MARK: Presentation

    func show(mode: Mode, initial: String = "") {
        self.mode = mode
        source = []
        onCancel = nil
        switch mode {
        case .files: field.field.placeholderString = "Search files by name (append :line or @symbol)"
        case .commands: field.field.placeholderString = "Search commands"; source = controller.paletteCommands()
        case .symbols: field.field.placeholderString = "Go to symbol"
        case .projectSymbols: field.field.placeholderString = "Go to symbol in project"
        case .line: field.field.placeholderString = "Go to line"
        case .list: break
        }
        present(initial: initial)
    }

    func showList(placeholder: String, items: [PaletteItem], selectedIndex: Int = 0, onCancel: (() -> Void)? = nil) {
        mode = .list
        source = items
        self.onCancel = onCancel
        field.field.placeholderString = placeholder
        present(initial: "")
        if selectedIndex < results.count {
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(selectedIndex)
        }
    }

    private func present(initial: String) {
        guard let content = controller.window?.contentView else { return }
        if let e = controller.activeEditor {
            restore = (e, e.textView.selectedRange(), e.scrollPosition)
            symbolCache = (mode == .symbols || initial.hasPrefix("@")) ? e.symbols() : []
        } else {
            restore = nil
            symbolCache = []
        }
        workspaceSymbols = nil
        narrowing = nil
        loadGeneration += 1
        if mode == .projectSymbols {
            let gen = loadGeneration
            controller.loadWorkspaceSymbols { [weak self] syms in
                guard let self, self.isVisible, self.mode == .projectSymbols, gen == self.loadGeneration else { return }
                self.workspaceSymbols = syms
                self.narrowing = nil
                self.update()
                self.layout()
            }
        }
        applyTheme()
        if backdrop.superview == nil {
            backdrop.frame = content.bounds
            backdrop.autoresizingMask = [.width, .height]
            content.addSubview(backdrop)
        }
        field.stringValue = initial
        update()
        layout()
        controller.window?.makeFirstResponder(field.field)
        if let ed = field.field.currentEditor() { ed.selectedRange = NSRange(location: (initial as NSString).length, length: 0) }
    }

    private func applyTheme() {
        let theme = ThemeManager.shared.active
        panel.layer?.backgroundColor = theme.panelBackground.cgColor
        panel.layer?.borderColor = theme.chromeBorder.cgColor
        backdrop.appearance = theme.appearance
        hint.textColor = theme.chromeSecondary.withAlphaComponent(0.8)
        field.applyTheme()
    }

    private func layout() {
        let b = backdrop.bounds
        let width = min(660, b.width - 60)
        let rows = min(results.count, maxRows)
        let listH = CGFloat(rows) * rowHeight + (rows > 0 ? 8 : 0)
        let hintH: CGFloat = 26
        let h = 12 + 36 + 8 + listH + hintH
        panel.frame = NSRect(x: round((b.width - width) / 2), y: 52, width: width, height: h)
        field.frame = NSRect(x: 10, y: 10, width: width - 20, height: 36)
        scroll.frame = NSRect(x: 0, y: 54, width: width, height: listH)
        hint.frame = NSRect(x: 10, y: h - hintH + 4, width: width - 20, height: 16)
        table.tableColumns.first?.width = width
    }

    func close(cancelled: Bool) {
        guard isVisible else { return }
        backdrop.removeFromSuperview()
        if cancelled {
            if let r = restore {
                r.editor.textView.setAllSelections([r.selection], scroll: false)
                r.editor.scrollPosition = r.scroll
            }
            onCancel?()
        }
        onCancel = nil
        restore = nil
        if cancelled { controller.activeEditor?.focus() }
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) {
        update()
        layout()
    }

    private func update() {
        let q = field.stringValue
        switch mode {
        case .files:
            if q.hasPrefix(">") { results = filter(controller.paletteCommands(), String(q.dropFirst())) }
            else if q.hasPrefix(":") { results = lineResults(String(q.dropFirst())) }
            else if q.hasPrefix("@") {
                if symbolCache.isEmpty, let e = controller.activeEditor { symbolCache = e.symbols() }
                results = filter(symbolItems(), String(q.dropFirst()))
            } else { results = fileResults(q) }
        case .commands, .list:
            results = filter(source, q)
        case .symbols:
            results = filter(symbolItems(), q.hasPrefix("@") ? String(q.dropFirst()) : q)
        case .projectSymbols:
            if let all = workspaceSymbols, all.count > 20_000, !Fuzzy.prepare(q).isEmpty {
                filterSymbolsAsync(all, q)
                return
            }
            results = projectSymbolResults(q)
        case .line:
            results = lineResults(q.hasPrefix(":") ? String(q.dropFirst()) : q)
        }
        showResults(query: q)
    }

    private func showResults(query q: String) {
        rowHeight = results.first?.twoLine == true ? 44 : 32
        table.rowHeight = rowHeight
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
            if mode != .files || q.hasPrefix("@") || q.hasPrefix(":") { results[0].preview?() }
        }
    }

    private func filter(_ items: [PaletteItem], _ query: String) -> [PaletteItem] {
        let q = Fuzzy.prepare(query)
        if q.isEmpty { return items }
        var out: [PaletteItem] = []
        for var item in items {
            let units = item.units.isEmpty ? Array(item.title.utf16) : item.units
            guard let m = Fuzzy.match(q, units, basenameStart: item.basenameStart) else { continue }
            item.score = m.score
            item.positions = item.units.isEmpty ? m.positions : []
            out.append(item)
        }
        out.sort { $0.score > $1.score }
        return out
    }

    private func lineResults(_ s: String) -> [PaletteItem] {
        guard let e = controller.activeEditor else { return [] }
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first else {
            return [PaletteItem(title: "Type a line number between 1 and \(e.document.lines.count)", action: {})]
        }
        let col = parts.count > 1 ? max(0, parts[1] &- 1) : 0
        let preview = { e.goTo(line: line, column: col) }
        return [PaletteItem(title: "Go to line \(line)" + (parts.count > 1 ? ", column \(parts[1])" : ""), icon: "arrow.right.to.line",
                            preview: preview, action: { preview(); e.focus() })]
    }

    private func symbolItems() -> [PaletteItem] {
        guard let e = controller.activeEditor else { return [] }
        return symbolCache.map { sym in
            let preview = { e.select(sym.range) }
            return PaletteItem(title: sym.name, detail: "line \(sym.line + 1)", icon: "number", preview: preview, action: { preview(); e.focus() })
        }
    }

    private func projectSymbolResults(_ query: String) -> [PaletteItem] {
        _ = filterGeneration.advance()
        guard let all = workspaceSymbols else {
            return [PaletteItem(title: "Indexing symbols…", icon: "hourglass", action: {})]
        }
        if all.isEmpty { return [PaletteItem(title: "No symbols found", action: {})] }
        let q = Fuzzy.prepare(query)
        if q.isEmpty { return symbolPaletteItems(all, Array(0..<min(all.count, 200)), q) }
        let ranked = PaletteController.rankSymbols(all, q, candidates: nil) { true }
        return symbolPaletteItems(all, ranked?.top ?? [], q)
    }

    private func filterSymbolsAsync(_ all: [WorkspaceSymbol], _ query: String) {
        let q = Fuzzy.prepare(query)
        let generation = filterGeneration
        let gen = generation.advance()
        let base = narrowing.flatMap { q.starts(with: $0.query) ? $0.matched : nil }
        symbolQueue.async { [weak self] in
            guard let ranked = PaletteController.rankSymbols(all, q, candidates: base, isCurrent: { generation.value == gen }) else { return }
            DispatchQueue.main.async {
                guard let self, self.isVisible, self.mode == .projectSymbols, generation.value == gen else { return }
                self.narrowing = (q, ranked.matched)
                self.results = ranked.top.isEmpty ? [PaletteItem(title: "No matching symbols", action: {})]
                                                  : self.symbolPaletteItems(all, ranked.top, q)
                self.showResults(query: query)
                self.layout()
            }
        }
    }

    /// Returns nil when `isCurrent` reports that a newer query superseded this one.
    private static func rankSymbols(_ all: [WorkspaceSymbol], _ q: [UInt16], candidates: [Int32]?,
                                    isCurrent: () -> Bool) -> (top: [Int], matched: [Int32])? {
        var best: [(score: Int, index: Int)] = []
        best.reserveCapacity(512)
        var matched: [Int32] = []
        var minScore = Int.min
        let count = candidates?.count ?? all.count
        for n in 0..<count {
            if n & 8191 == 0 && !isCurrent() { return nil }
            let i = candidates.map { Int($0[n]) } ?? n
            let s = all[i]
            guard let m = Fuzzy.match(q, s.units, wantPositions: false) else { continue }
            matched.append(Int32(i))
            // Prefer exact and shorter names among equally good matches.
            let score = m.score * 4 - s.units.count + (s.units.count == q.count ? 50 : 0)
            if best.count >= 200 && score <= minScore { continue }
            best.append((score, i))
            if best.count > 400 {
                best.sort { $0.score > $1.score }
                best.removeLast(best.count - 200)
                minScore = best.last?.score ?? Int.min
            }
        }
        best.sort { $0.score > $1.score }
        return (best.prefix(100).map(\.index), matched)
    }

    private func symbolPaletteItems(_ all: [WorkspaceSymbol], _ indices: [Int], _ q: [UInt16]) -> [PaletteItem] {
        let controller = self.controller
        return indices.map { i in
            let s = all[i]
            var item = PaletteItem(title: s.name, detail: "\(s.displayPath):\(s.line + 1)", icon: "number") { controller.jump(to: s) }
            if !q.isEmpty { item.positions = Fuzzy.match(q, s.units)?.positions ?? [] }
            return item
        }
    }

    private func fileResults(_ raw: String) -> [PaletteItem] {
        var query = raw
        var line: Int?
        var symbol: String?
        if let at = raw.firstIndex(of: "@") {
            symbol = String(raw[raw.index(after: at)...])
            query = String(raw[..<at])
        } else if let colon = raw.lastIndex(of: ":"), let n = Int(raw[raw.index(after: colon)...]) {
            line = n
            query = String(raw[..<colon])
        }
        let controller = self.controller
        let theme = ThemeManager.shared.active
        let make: (URL, String, String) -> PaletteItem = { url, title, detail in
            let dir = (detail as NSString).deletingLastPathComponent
            var item = PaletteItem(title: title, detail: dir.isEmpty ? "./" : dir, icon: nil) {
                controller.open(url: url, line: line, symbol: symbol)
            }
            item.image = FileIcons.image(forFileName: title, theme: theme, size: 14)
            item.twoLine = true
            return item
        }
        let q = Fuzzy.prepare(query)
        var items: [PaletteItem] = []
        var seen = Set<String>()

        let openDocs = controller.allOpenDocuments().compactMap { $0.url }
        let rootPath = controller.folderURL?.path
        func rel(_ url: URL) -> String {
            if let r = rootPath, url.path.hasPrefix(r + "/") { return String(url.path.dropFirst(r.count + 1)) }
            return (url.path as NSString).abbreviatingWithTildeInPath
        }

        if q.isEmpty {
            for url in openDocs + RecentFiles.shared.items where seen.insert(url.path).inserted {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                items.append(make(url, url.lastPathComponent, rel(url)))
                if items.count > 40 { break }
            }
            return items
        }

        var scored: [(Int, PaletteItem)] = []
        for url in openDocs where seen.insert(url.path).inserted {
            let r = rel(url)
            let units = Array(r.utf16)
            let base = (units.lastIndex(of: 47) ?? -1) + 1
            if let m = Fuzzy.match(q, units, basenameStart: base) {
                var item = make(url, url.lastPathComponent, r)
                item.positions = m.positions.filter { $0 >= base }.map { $0 - base }
                scored.append((m.score + 10, item))
            }
        }
        if let index = controller.projectIndex, let root = controller.folderURL {
            var best: [(Int, Int, [Int])] = []
            best.reserveCapacity(256)
            var minScore = Int.min
            for (i, e) in index.entries.enumerated() {
                guard let m = Fuzzy.match(q, e.units, basenameStart: e.basenameStart, wantPositions: false) else { continue }
                if best.count >= 200 && m.score <= minScore { continue }
                best.append((m.score, i, []))
                if best.count > 400 {
                    best.sort { $0.0 > $1.0 }
                    best.removeLast(best.count - 200)
                    minScore = best.last?.0 ?? Int.min
                }
            }
            best.sort { $0.0 > $1.0 }
            for (score, i, _) in best.prefix(80) {
                let e = index.entries[i]
                let url = root.appendingPathComponent(e.relativePath)
                guard seen.insert(url.path).inserted else { continue }
                var item = make(url, (e.relativePath as NSString).lastPathComponent, e.relativePath)
                if let m = Fuzzy.match(q, e.units, basenameStart: e.basenameStart) {
                    item.positions = m.positions.filter { $0 >= e.basenameStart }.map { $0 - e.basenameStart }
                }
                scored.append((score, item))
            }
        }
        scored.sort { $0.0 > $1.0 }
        items = scored.prefix(80).map { $0.1 }
        return items
    }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(maxRows); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-maxRows); return true
        case #selector(NSResponder.insertNewline(_:)): execute(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(cancelled: true); return true
        case #selector(NSResponder.insertTab(_:)): move(1); return true
        case #selector(NSResponder.insertBacktab(_:)): move(-1); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(0, table.selectedRow + d), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        results[row].preview?()
    }

    private func execute() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { close(cancelled: true); return }
        let action = results[row].action
        restore = nil
        onCancel = nil
        close(cancelled: false)
        controller.activeEditor?.focus()
        action()
    }

    @objc private func rowClicked() {
        if table.clickedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            execute()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("p")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.identifier = id
        if row < results.count { cell.configure(results[row]) }
        return cell
    }
}

private final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var hasIcon = false

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingHead
        shortcut.alignment = .right
        [icon, title, detail, shortcut].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var twoLine = false
    override var isFlipped: Bool { true }

    func configure(_ item: PaletteItem) {
        let theme = ThemeManager.shared.active
        twoLine = item.twoLine
        let t = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: theme.foreground])
        for p in item.positions where p < t.length {
            t.addAttributes([.foregroundColor: theme.accent.mix(theme.foreground, 0.15), .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)],
                            range: NSRange(location: p, length: 1))
        }
        title.attributedStringValue = t
        detail.stringValue = item.detail
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = theme.chromeSecondary
        shortcut.stringValue = item.shortcut
        shortcut.font = .systemFont(ofSize: 12, weight: .medium)
        shortcut.textColor = theme.chromeSecondary
        hasIcon = item.icon != nil || item.image != nil
        if let img = item.image {
            icon.image = img
        } else if let name = item.icon {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [theme.chromeSecondary])))
        } else {
            icon.image = nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 20
        icon.isHidden = !hasIcon
        if hasIcon {
            icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 24
        }
        let sw = shortcut.stringValue.isEmpty ? 0 : shortcut.intrinsicContentSize.width + 4
        shortcut.frame = NSRect(x: bounds.width - 20 - sw, y: (h - 16) / 2, width: sw, height: 16)
        if twoLine {
            title.frame = NSRect(x: x, y: 5, width: max(0, bounds.width - x - sw - 28), height: 18)
            detail.frame = NSRect(x: x, y: 23, width: max(0, bounds.width - x - sw - 28), height: 15)
            return
        }
        let tw = min(ceil(title.attributedStringValue.size().width) + 10, bounds.width - x - sw - 40)
        title.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, tw), height: 18)
        let dx = title.frame.maxX + 10
        detail.frame = NSRect(x: dx, y: (h - 15) / 2, width: max(0, bounds.width - dx - sw - 28), height: 15)
    }
}
