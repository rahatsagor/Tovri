import AppKit

/// Reviewing and reverting changes against HEAD, from the gutter markers or the Goto menu.
extension EditorView {
    func gitHunk(at line: Int) -> DiffHunk? {
        guard Settings.shared.gitGutter else { return nil }
        return document.gitDiff.hunk(at: line, lineCount: document.lines.count)
    }

    var gitHunkAtCaret: DiffHunk? {
        gitHunk(at: document.lines.line(containing: textView.selectedRange().location))
    }

    /// Moves to the change after or before `line` (the caret's line when nil) and shows what it replaced.
    @discardableResult
    func gotoChange(forward: Bool, from line: Int? = nil) -> Bool {
        guard Settings.shared.gitGutter else { return false }
        let line = line ?? document.lines.line(containing: textView.selectedRange().location)
        guard let h = document.gitDiff.nextHunk(from: line, forward: forward, lineCount: document.lines.count) else { return false }
        goTo(line: min(h.newStart, document.lines.count - 1) + 1)
        showGitChange(h)
        return true
    }

    func showGitChange(_ hunk: DiffHunk) {
        GitChangePopover.show(hunk, in: self)
    }

    /// Restores the HEAD version of one hunk as a single undoable edit.
    func revertGitChange(_ h: DiffHunk) {
        // The diff is recomputed shortly after each edit; a hunk from an older version could
        // replace the wrong lines.
        guard document.isGitDiffCurrent, document.gitDiff.hunks.contains(h) else { NSSound.beep(); return }
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

/// Shows the text a change replaced, with Revert and previous/next navigation.
final class GitChangePopover: NSViewController {
    private static weak var current: NSPopover?
    private let hunk: DiffHunk
    private weak var editor: EditorView?

    private static let padding: CGFloat = 12
    private static let maxWidth: CGFloat = 720
    private static let maxCodeHeight: CGFloat = 300
    private static let maxLines = 2000

    static func show(_ hunk: DiffHunk, in editor: EditorView) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: ThemeManager.shared.active.isDark ? .darkAqua : .aqua)
        popover.contentViewController = GitChangePopover(hunk: hunk, editor: editor)
        let tv = editor.textView
        let lines = editor.document.lines
        let first = min(hunk.newStart, lines.count - 1)
        let last = max(first, min(hunk.newEnd, lines.count) - 1)
        let top = tv.caretRect(at: lines.start(of: first))
        let bottom = tv.caretRect(at: lines.start(of: last))
        let visible = tv.visibleRect
        var anchor = NSRect(x: visible.minX + 24, y: top.minY, width: 40, height: max(bottom.maxY - top.minY, top.height))
        if hunk.isDeletion { anchor.size.height = 1 }
        anchor = anchor.intersection(visible)
        if anchor.isNull || anchor.isEmpty { anchor = NSRect(x: visible.minX + 24, y: top.minY, width: 40, height: 1) }
        popover.show(relativeTo: anchor, of: tv, preferredEdge: .maxY)
        current = popover
    }

    init(hunk: DiffHunk, editor: EditorView) {
        self.hunk = hunk
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "1 line changed, 2 added": a hunk replacing 1 line with 3 changed one and added two.
    static func summary(of hunk: DiffHunk) -> String {
        func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }
        let old = hunk.oldLines.count
        let new = hunk.newCount
        if hunk.isDeletion { return "\(lines(old)) deleted" }
        if hunk.isAddition { return "\(lines(new)) added" }
        var parts = ["\(lines(min(old, new))) changed"]
        if new > old { parts.append("\(new - old) added") }
        if old > new { parts.append("\(old - new) deleted") }
        return parts.joined(separator: ", ")
    }

    /// The hunk's place among the document's changes, or nil if the diff has moved on.
    private var position: (index: Int, count: Int)? {
        guard let hunks = editor?.document.gitDiff.hunks, let i = hunks.firstIndex(of: hunk) else { return nil }
        return (i + 1, hunks.count)
    }

    private static func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = s
        return l
    }

    override func loadView() {
        let theme = ThemeManager.shared.active
        let p = GitChangePopover.padding
        let root = FlippedView()

        let title = GitChangePopover.label(GitChangePopover.summary(of: hunk), .systemFont(ofSize: 12.5, weight: .semibold), theme.chromeForeground)
        var detailText = "Since the last commit"
        let position = self.position
        if let position, position.count > 1 { detailText += " · change \(position.index) of \(position.count)" }
        let shownLines = hunk.oldLines.prefix(GitChangePopover.maxLines)
        if hunk.oldLines.count > shownLines.count { detailText += " · first \(shownLines.count) lines shown" }
        let detail = GitChangePopover.label(detailText, .systemFont(ofSize: 11), theme.chromeSecondary)

        var buttons: [ToolButton] = []
        if (position?.count ?? 0) > 1 {
            buttons.append(ToolButton(symbol: "chevron.up", tooltip: "Previous Change\n⇧⌥F5") { [weak self] in self?.go(forward: false) })
            buttons.append(ToolButton(symbol: "chevron.down", tooltip: "Next Change\n⌥F5") { [weak self] in self?.go(forward: true) })
        }
        let revert = ToolButton(title: "Revert", tooltip: hunk.isAddition ? "Revert\nRemove the added lines." : "Revert\nRestore the text from the last commit.") { [weak self] in
            self?.revert()
        }
        revert.wantsLayer = true
        revert.layer?.cornerRadius = 5
        revert.layer?.borderWidth = 1
        revert.layer?.borderColor = theme.chromeBorder.cgColor
        buttons.append(revert)
        let buttonWidths = buttons.map { $0 === revert ? $0.intrinsicWidth : 24 }
        let buttonsWidth = buttonWidths.reduce(0, +) + CGFloat(buttons.count - 1) * 4

        let titleSize = title.fittingSize
        let detailSize = detail.fittingSize
        var width = max(360, ceil(max(titleSize.width, detailSize.width)) + 16 + buttonsWidth + 2 * p)

        var code: NSScrollView?
        var codeHeight: CGFloat = 0
        if !shownLines.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: max(11, Settings.shared.font.pointSize - 1), weight: .regular)
            let inset = NSSize(width: 8, height: 6)
            let longest = shownLines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let textWidth = ceil(longest) + 2 * inset.width + 10
            width = max(width, textWidth + 2 * p)
            width = min(width, GitChangePopover.maxWidth)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let contentHeight = ceil(CGFloat(shownLines.count) * lineHeight + 2 * inset.height)
            codeHeight = min(contentHeight, GitChangePopover.maxCodeHeight)
            let codeWidth = width - 2 * p

            let deleted = theme.color(.deleted) ?? .systemRed
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: max(codeWidth, textWidth), height: max(codeHeight, contentHeight)))
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.textContainerInset = inset
            text.font = font
            text.textColor = theme.foreground
            text.string = shownLines.joined(separator: "\n")
            text.isHorizontallyResizable = true
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.minSize = NSSize(width: codeWidth, height: codeHeight)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityLabel("Text before the change")

            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.drawsBackground = true
            scroll.backgroundColor = deleted.withAlphaComponent(theme.isDark ? 0.16 : 0.10)
            scroll.hasVerticalScroller = contentHeight > codeHeight
            scroll.hasHorizontalScroller = textWidth > codeWidth
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6
            scroll.layer?.masksToBounds = true
            code = scroll
        }
        width = min(width, GitChangePopover.maxWidth)

        let textHeight = ceil(titleSize.height) + 2 + ceil(detailSize.height)
        let headerHeight = max(textHeight, 26)
        let textMaxWidth = width - 2 * p - buttonsWidth - 16
        title.frame = NSRect(x: p, y: p + (headerHeight - textHeight) / 2, width: textMaxWidth, height: ceil(titleSize.height))
        detail.frame = NSRect(x: p, y: title.frame.maxY + 2, width: textMaxWidth, height: ceil(detailSize.height))
        var x = width - p
        for (b, w) in zip(buttons, buttonWidths).reversed() {
            x -= w
            b.frame = NSRect(x: x, y: p + (headerHeight - 24) / 2, width: w, height: 24)
            x -= 4
        }
        [title, detail].forEach(root.addSubview)
        buttons.forEach(root.addSubview)

        var height = p + headerHeight + p
        if let code {
            code.frame = NSRect(x: p, y: height - 2, width: width - 2 * p, height: codeHeight)
            root.addSubview(code)
            height = code.frame.maxY + p
        }
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        preferredContentSize = root.frame.size
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The popover would otherwise focus its first button and draw a focus ring on it.
        view.window?.makeFirstResponder(nil)
    }

    private func go(forward: Bool) {
        guard let editor else { return }
        let line = min(hunk.newStart, editor.document.lines.count - 1)
        GitChangePopover.current?.close()
        editor.gotoChange(forward: forward, from: line)
    }

    private func revert() {
        GitChangePopover.current?.close()
        editor?.revertGitChange(hunk)
    }
}
