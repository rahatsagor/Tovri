import AppKit

/// Inline word/keyword completion popup shown under the caret.
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CompletionController()

    private struct Item {
        let word: String
        let kind: String
        let positions: [Int]
    }

    private var panel: NSPanel?
    private var table: NSTableView!
    private var scroll: NSScrollView!
    private var container: NSView!
    private var items: [Item] = []
    private weak var textView: EditorTextView?
    private var prefixRange = NSRange(location: 0, length: 0)
    private let rowHeight: CGFloat = 22
    private let maxRows = 9

    var isVisible: Bool { panel?.isVisible == true }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = true
        container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1
        container.layer?.masksToBounds = true
        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        table = NSTableView()
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        container.addSubview(scroll)
        p.contentView = container
        panel = p
    }

    func textDidChange(in tv: EditorTextView) {
        // Popups while writing prose get in the way; ⌥⎋ still asks for completions explicitly.
        guard Settings.shared.autoComplete, tv.extraSelections.isEmpty, !tv.document.isProse else { hide(); return }
        show(for: tv, explicit: false)
    }

    func show(for tv: EditorTextView, explicit: Bool) {
        Perf.measure("completion", threshold: 3) { showImpl(for: tv, explicit: explicit) }
    }

    private func showImpl(for tv: EditorTextView, explicit: Bool) {
        let sel = tv.selectedRange()
        guard sel.length == 0 else { hide(); return }
        var a = sel.location
        while a > 0 && tv.isWordChar(tv.char(a - 1)) { a -= 1 }
        let prefixLen = sel.location - a
        if prefixLen < (explicit ? 0 : 2) || (prefixLen > 0 && isDigitU(tv.char(a))) { hide(); return }
        if !explicit && tv.isWordChar(tv.char(sel.location)) { hide(); return }
        let prefix = tv.text.substring(with: NSRange(location: a, length: prefixLen))
        prefixRange = NSRange(location: a, length: prefixLen)
        textView = tv

        let lang = tv.language
        var candidates: [(String, String)] = []
        var seen = Set<String>()
        for w in lang.keywords + lang.storage { if seen.insert(w).inserted { candidates.append((w, "keyword")) } }
        for w in lang.types { if seen.insert(w).inserted { candidates.append((w, "type")) } }
        for w in lang.builtins + lang.constants { if seen.insert(w).inserted { candidates.append((w, "builtin")) } }
        if prefix.utf16.count >= 2 {
            let lowerPrefix = prefix.lowercased()
            var taken = 0
            for w in tv.document.completionWords(prefix: prefix) where taken < 3000 {
                guard w.count > prefix.count, w.lowercased().hasPrefix(lowerPrefix) || prefix.utf16.count <= 2 else { continue }
                if seen.insert(w).inserted { candidates.append((w, "")); taken += 1 }
            }
        }

        let q = Fuzzy.prepare(prefix)
        let first = q.first
        var scored: [(Int, Item)] = []
        for (w, kind) in candidates where w != prefix {
            if let f = first, let w0 = w.utf16.first, Fuzzy.lower(w0) != f { continue }
            let units = Array(w.utf16)
            guard let m = Fuzzy.match(q, units) else { continue }
            var score = m.score
            if w.hasPrefix(prefix) { score += 20 }
            if !kind.isEmpty { score += 2 }
            scored.append((score, Item(word: w, kind: kind, positions: m.positions)))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.word.count < $1.1.word.count }
        ensurePanel()
        items = scored.prefix(60).map { $0.1 }
        table.reloadData()
        guard !items.isEmpty, let window = tv.window, let panel else { hide(); return }
        let theme = ThemeManager.shared.active
        container.layer?.backgroundColor = theme.panelBackground.cgColor
        container.layer?.borderColor = theme.chromeBorder.cgColor
        panel.appearance = theme.appearance
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)

        let font = NSFont.monospacedSystemFont(ofSize: max(11, tv.document.font.pointSize - 1), weight: .regular)
        let longest = items.prefix(30).map { ($0.word as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        let width = min(460, max(220, longest + 90))
        let height = CGFloat(min(items.count, maxRows)) * rowHeight + 8
        let caret = tv.firstRect(forCharacterRange: prefixRange, actualRange: nil)
        var origin = NSPoint(x: caret.minX - 26, y: caret.minY - height - 4)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = caret.maxY + 4 }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        scroll.frame = container.bounds.insetBy(dx: 0, dy: 4)
        table.tableColumns.first?.width = width
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @discardableResult
    func accept() -> Bool {
        guard isVisible, let tv = textView, table.selectedRow >= 0, table.selectedRow < items.count else { return false }
        let word = items[table.selectedRow].word
        hide()
        let current = tv.selectedRange()
        guard prefixRange.location <= current.location else { return false }
        let range = NSRange(location: prefixRange.location, length: current.location - prefixRange.location)
        tv.breakUndoCoalescing()
        tv.insertCompletionText(word, replacing: range)
        return true
    }

    @objc private func clicked() { accept() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let theme = ThemeManager.shared.active
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.identifier = id
        guard row < items.count else { return cell }
        let item = items[row]
        let size = max(11, (textView?.document.font.pointSize ?? 13) - 1)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let s = NSMutableAttributedString(string: item.word, attributes: [.font: font, .foregroundColor: theme.foreground])
        for p in item.positions where p < s.length {
            s.addAttributes([.font: bold, .foregroundColor: theme.accent.mix(theme.foreground, 0.2)], range: NSRange(location: p, length: 1))
        }
        cell.label.attributedStringValue = s
        cell.kind.stringValue = item.kind
        cell.kind.textColor = theme.chromeSecondary
        let icon: String
        switch item.kind {
        case "keyword": icon = "k"
        case "type": icon = "t"
        case "builtin": icon = "f"
        default: icon = "w"
        }
        cell.badge.stringValue = icon
        cell.badge.textColor = theme.color(item.kind == "keyword" ? .keyword : item.kind == "type" ? .type : item.kind == "builtin" ? .builtin : .comment) ?? theme.accent
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let kind = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        kind.font = .systemFont(ofSize: 10.5)
        kind.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        [badge, label, kind].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        badge.frame = NSRect(x: 10, y: (h - 14) / 2, width: 14, height: 14)
        kind.frame = NSRect(x: bounds.width - 70, y: (h - 14) / 2, width: 60, height: 14)
        label.frame = NSRect(x: 30, y: (h - 17) / 2, width: bounds.width - 104, height: 17)
    }
}

extension EditorTextView {
    func insertCompletionText(_ word: String, replacing range: NSRange) {
        if shouldChangeText(in: range, replacementString: word) {
            textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: word, attributes: typingAttributes))
            didChangeText()
            setSelectedRange(NSRange(location: range.location + word.utf16.count, length: 0))
        }
    }
}
