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

    /// Moves to the following or preceding change and shows what it replaced.
    @discardableResult
    func gotoChange(forward: Bool) -> Bool {
        guard Settings.shared.gitGutter else { return false }
        let line = document.lines.line(containing: textView.selectedRange().location)
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

    private var summary: String {
        func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }
        if hunk.isDeletion { return "\(lines(hunk.oldLines.count)) deleted since the last commit" }
        if hunk.isAddition { return "\(lines(hunk.newCount)) added since the last commit" }
        return "\(lines(hunk.newCount)) changed since the last commit"
    }

    override func loadView() {
        let title = NSTextField(labelWithString: summary)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            b.title = ""
            b.imagePosition = .imageOnly
            b.bezelStyle = .accessoryBarAction
            b.isBordered = true
            b.toolTip = label
            b.setAccessibilityLabel(label)
            return b
        }
        let previous = iconButton("chevron.up", "Previous Change (⇧⌥F5)", #selector(previousChange))
        let next = iconButton("chevron.down", "Next Change (⌥F5)", #selector(nextChange))
        let revert = NSButton(title: "Revert", target: self, action: #selector(revertChange))
        revert.bezelStyle = .push
        revert.controlSize = .small
        revert.toolTip = hunk.isAddition ? "Remove the added lines" : "Restore the text from the last commit"

        let header = NSStackView(views: [title, previous, next, revert])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6

        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        var width: CGFloat = 340
        if !hunk.oldLines.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: max(11, Settings.shared.font.pointSize - 1), weight: .regular)
            let shown = hunk.oldLines.prefix(2000).joined(separator: "\n")
            let theme = ThemeManager.shared.active
            let deleted = theme.color(.deleted) ?? .systemRed
            let text = NSTextView()
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = deleted.withAlphaComponent(0.12)
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.font = font
            text.textColor = .labelColor
            text.string = shown
            text.isHorizontallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let longest = hunk.oldLines.prefix(2000).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            width = min(max(width, longest + 40), 720)
            let lineHeight = font.ascender - font.descender + font.leading + 2
            let height = min(CGFloat(min(hunk.oldLines.count, 2000)) * lineHeight + 14, 300)
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = longest + 40 > width
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
            text.frame = NSRect(x: 0, y: 0, width: width - 24, height: height)
            text.minSize = NSSize(width: 0, height: height)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            stack.addArrangedSubview(scroll)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        view = stack
    }

    @objc private func previousChange() {
        GitChangePopover.current?.close()
        editor?.gotoChange(forward: false)
    }

    @objc private func nextChange() {
        GitChangePopover.current?.close()
        editor?.gotoChange(forward: true)
    }

    @objc private func revertChange() {
        GitChangePopover.current?.close()
        editor?.revertGitChange(hunk)
    }
}
