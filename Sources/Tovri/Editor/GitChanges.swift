import AppKit

/// Reviewing and reverting changes against HEAD, from the gutter markers or the Goto menu.
extension EditorView {
    func gitHunk(at line: Int) -> DiffHunk? {
        lineDiff.hunk(at: line, lineCount: document.lines.count)
    }

    var gitHunkAtCaret: DiffHunk? {
        gitHunk(at: document.lines.line(containing: textView.selectedRange().location))
    }

    /// Moves to the change after or before `line` (the caret's line when nil) and shows what it replaced.
    @discardableResult
    func gotoChange(forward: Bool, from line: Int? = nil, showCard: Bool = true) -> Bool {
        let line = line ?? document.lines.line(containing: textView.selectedRange().location)
        guard let h = lineDiff.nextHunk(from: line, forward: forward, lineCount: document.lines.count) else { return false }
        goTo(line: min(h.newStart, document.lines.count - 1) + 1)
        if showCard { showGitChange(h) }
        return true
    }

    /// Restores the HEAD version of one hunk as a single undoable edit.
    func revertGitChange(_ h: DiffHunk) {
        // The diff is recomputed shortly after each edit; a hunk from an older version could
        // replace the wrong lines.
        guard isLineDiffCurrent, lineDiff.hunks.contains(h) else { NSSound.beep(); return }
        closeChangeCard()
        textView.performEdits([EditorView.revertEdit(for: h, lines: document.lines, length: document.length)], actionName: "Revert Change")
    }

    static func revertEdit(for h: DiffHunk, lines: LineIndex, length len: Int) -> TextEdit {
        let old = h.oldLines.joined(separator: "\n")
        let edit: TextEdit
        if h.isDeletion {
            if h.newStart < lines.count {
                edit = TextEdit(NSRange(location: lines.start(of: h.newStart), length: 0), old + "\n")
            } else {
                edit = TextEdit(NSRange(location: len, length: 0), "\n" + old)
            }
        } else {
            let start = lines.start(of: h.newStart)
            if h.newEnd < lines.count {
                edit = TextEdit(NSRange(location: start, length: lines.start(of: h.newEnd) - start), h.isAddition ? "" : old + "\n")
            } else if h.isAddition {
                // Added lines at the end of the file: also remove the newline that preceded them.
                let from = max(0, start - 1)
                edit = TextEdit(NSRange(location: from, length: len - from), "")
            } else {
                edit = TextEdit(NSRange(location: start, length: len - start), old)
            }
        }
        return edit
    }
}

/// Floating card over the editor showing one change: the lines it removed and the lines it
/// added, with previous/next navigation and Revert.
final class GitChangeCard: NSView {
    let hunk: DiffHunk
    private weak var editor: EditorView?

    static let maxWidth: CGFloat = 560
    static let headerHeight: CGFloat = 40
    static let maxVisibleRows = 10
    /// Rows beyond this are summarized; the card is a preview, the editor shows the rest.
    static let maxRows = 400

    private let content = FlippedView()
    private let swatch = NSView()
    private let title = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let scroll = OverlayScrollView(frame: .zero)
    private let rowsView = HunkRowsView()
    private var buttons: [PillButton] = []

    init(hunk: DiffHunk, editor: EditorView) {
        self.hunk = hunk
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        addSubview(content)

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.stringValue = GitChangeCard.summary(of: hunk)
        title.lineBreakMode = .byTruncatingTail
        position.font = .systemFont(ofSize: 11.5)
        if let p = GitChangeCard.position(of: hunk, in: editor.lineDiff.hunks), p.count > 1 { position.stringValue = "\(p.index) of \(p.count)" }
        divider.wantsLayer = true
        [swatch, title, position, divider].forEach(content.addSubview)

        let several = editor.lineDiff.hunks.count > 1
        if several {
            buttons.append(PillButton(symbol: "arrow.up", tooltip: "Previous Change\n⇧⌥F5") { [weak self] in self?.go(forward: false) })
            buttons.append(PillButton(symbol: "arrow.down", tooltip: "Next Change\n⌥F5") { [weak self] in self?.go(forward: true) })
        }
        let revert = PillButton(symbol: "arrow.uturn.backward", title: "Revert",
                                tooltip: hunk.isAddition ? "Revert\nRemove the added lines."
                                    : "Revert\nRestore the text from \(editor.comparisonLabel ?? "the last commit").") { [weak self] in
            guard let self, let editor = self.editor else { return }
            editor.revertGitChange(self.hunk)
        }
        revert.tintKind = .deleted
        buttons.append(revert)
        buttons.append(PillButton(symbol: "xmark", tooltip: "Close\n⎋") { [weak self] in self?.editor?.closeChangeCard() })
        buttons.forEach(content.addSubview)

        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        content.addSubview(scroll)
        rowsView.removedText = hunk.oldLines.joined(separator: "\n")
        let doc = editor.document
        if hunk.newCount > 0, hunk.newStart < doc.lines.count {
            let start = doc.lines.start(of: hunk.newStart)
            let end = hunk.newEnd < doc.lines.count ? doc.lines.start(of: hunk.newEnd) - 1 : doc.length
            rowsView.addedText = doc.string.substring(with: NSRange(location: start, length: max(0, end - start)))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Change since the last commit: \(title.stringValue)")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    // The editor's I-beam would otherwise show over the card.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override var isFlipped: Bool { true }

    /// "Changed · 1 line → 2 lines": a hunk replacing one line with two.
    static func summary(of hunk: DiffHunk) -> String {
        func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }
        if hunk.isAddition { return "Added · \(lines(hunk.newCount))" }
        if hunk.isDeletion { return "Removed · \(lines(hunk.oldLines.count))" }
        return "Changed · \(lines(hunk.oldLines.count)) → \(lines(hunk.newCount))"
    }

    /// The hunk's place among the changes, or nil if the diff has moved on.
    static func position(of hunk: DiffHunk, in hunks: [DiffHunk]) -> (index: Int, count: Int)? {
        guard let i = hunks.firstIndex(of: hunk) else { return nil }
        return (i + 1, hunks.count)
    }

    static func rows(for hunk: DiffHunk, in doc: Document) -> [HunkRowsView.Row] {
        let theme = ThemeManager.shared.active
        let font = rowFont(for: doc)
        let old = Array(hunk.oldLines.prefix(maxRows))
        let lines = doc.lines
        let newRange = hunk.newStart..<min(hunk.newEnd, lines.count, hunk.newStart + maxRows)
        let new = newRange.map { doc.string.substring(with: lines.range(of: $0, textLength: doc.length)) }
        var rows = SnippetHighlighter.highlight(old, language: doc.language, theme: theme, font: font).map { HunkRowsView.Row(kind: .removed, text: $0) }
        rows += SnippetHighlighter.highlight(new, language: doc.language, theme: theme, font: font).map { HunkRowsView.Row(kind: .added, text: $0) }
        let hidden = (hunk.oldLines.count - old.count) + (hunk.newCount - new.count)
        if hidden > 0 {
            rows.append(HunkRowsView.Row(kind: .note, text: NSAttributedString(string: "\(hidden.formatted()) more lines", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeSecondary])))
        }
        return rows
    }

    static func rowFont(for doc: Document) -> NSFont {
        let base = doc.font
        return NSFont(descriptor: base.fontDescriptor, size: max(11, base.pointSize - 0.5)) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let visible = min(rowsView.rows.count, GitChangeCard.maxVisibleRows)
        return GitChangeCard.headerHeight + CGFloat(visible) * rowsView.rowHeight + 2 * HunkRowsView.inset
    }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        appearance = theme.appearance
        content.layer?.backgroundColor = theme.panelBackground.withAlphaComponent(1).cgColor
        content.layer?.borderColor = theme.chromeBorder.cgColor
        divider.layer?.backgroundColor = theme.chromeBorder.cgColor
        let color: NSColor = hunk.isAddition ? theme.color(.inserted) ?? .systemGreen
            : hunk.isDeletion ? theme.color(.deleted) ?? .systemRed : theme.color(.changed) ?? .systemOrange
        swatch.layer?.backgroundColor = color.cgColor
        title.textColor = theme.foreground
        position.textColor = theme.chromeSecondary
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = theme.isDark ? 0.5 : 0.18
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        if let editor {
            rowsView.font = GitChangeCard.rowFont(for: editor.document)
            rowsView.rows = GitChangeCard.rows(for: hunk, in: editor.document)
        }
        rowsView.needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let h = GitChangeCard.headerHeight
        var x = bounds.width - 8
        for b in buttons.reversed() {
            let w = b.preferredWidth
            x -= w
            b.frame = NSRect(x: x, y: (h - PillButton.height) / 2, width: w, height: PillButton.height)
            x -= 6
        }
        swatch.frame = NSRect(x: 12, y: (h - 8) / 2, width: 8, height: 8)
        let titleW = min(ceil(title.fittingSize.width), max(0, x - 28 - 8))
        title.frame = NSRect(x: 28, y: (h - 16) / 2, width: titleW, height: 16)
        let posX = title.frame.maxX + 8
        position.frame = NSRect(x: posX, y: (h - 15) / 2 + 0.5, width: max(0, x - posX - 4), height: 15)
        divider.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        scroll.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        rowsView.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, rowsView.contentWidth), height: rowsView.contentHeight)
    }

    private func go(forward: Bool) {
        guard let editor else { return }
        editor.gotoChange(forward: forward, from: min(hunk.newStart, editor.document.lines.count - 1))
    }
}

/// The removed and added lines of a change, one tinted row each, with "−" and "+" markers.
final class HunkRowsView: NSView {
    enum Kind { case removed, added, note }
    struct Row {
        var kind: Kind
        var text: NSAttributedString
    }

    static let inset: CGFloat = 8
    private static let markerX: CGFloat = 12
    private static let textX: CGFloat = 30

    var rows: [Row] = [] { didSet { measure() } }
    /// The code font; set before `rows`. Rows can be blank lines, so it isn't read from them.
    var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    /// Full text for copying; rows may be shortened.
    var removedText = ""
    var addedText = ""
    private(set) var rowHeight: CGFloat = 20
    private(set) var contentWidth: CGFloat = 0
    var contentHeight: CGFloat { CGFloat(rows.count) * rowHeight + 2 * HunkRowsView.inset }

    override var isFlipped: Bool { true }

    private func measure() {
        rowHeight = max(18, ceil(font.ascender - font.descender + font.leading) + 5)
        // Measuring every row of a huge change would cost more than it's worth; long lines scroll.
        let widest = rows.prefix(200).map { $0.text.size().width }.max() ?? 0
        contentWidth = ceil(widest) + HunkRowsView.textX + 16
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let removed = theme.color(.deleted) ?? .systemRed
        let added = theme.color(.inserted) ?? .systemGreen
        guard !rows.isEmpty else { return }
        let inset = HunkRowsView.inset
        let first = max(0, Int((dirtyRect.minY - inset) / rowHeight))
        let last = min(rows.count - 1, Int((dirtyRect.maxY - inset) / rowHeight))
        guard first <= last else { return }
        let markerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        for i in first...last {
            let row = rows[i]
            let y = inset + CGFloat(i) * rowHeight
            let h = row.text.size().height
            let textY = y + floor((rowHeight - h) / 2)
            switch row.kind {
            case .removed, .added:
                let color = row.kind == .removed ? removed : added
                color.withAlphaComponent(row.kind == .removed ? (theme.isDark ? 0.14 : 0.12) : (theme.isDark ? 0.11 : 0.10)).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
                let marker = (row.kind == .removed ? "−" : "+") as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: color]
                let ms = marker.size(withAttributes: attrs)
                marker.draw(at: NSPoint(x: HunkRowsView.markerX, y: y + floor((rowHeight - ms.height) / 2)), withAttributes: attrs)
                row.text.draw(at: NSPoint(x: HunkRowsView.textX, y: textY))
            case .note:
                row.text.draw(at: NSPoint(x: HunkRowsView.textX, y: textY))
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if rows.contains(where: { $0.kind == .removed }) {
            m.addItem(withTitle: "Copy Original Lines", action: #selector(copyRemoved), keyEquivalent: "").target = self
        }
        if rows.contains(where: { $0.kind == .added }) {
            m.addItem(withTitle: "Copy New Lines", action: #selector(copyAdded), keyEquivalent: "").target = self
        }
        return m.items.isEmpty ? nil : m
    }

    @objc private func copyRemoved() { copy(removedText) }
    @objc private func copyAdded() { copy(addedText) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
