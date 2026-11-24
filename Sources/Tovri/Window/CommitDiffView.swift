import AppKit

extension NSAttributedString.Key {
    /// The `DiffLineKind` of a line of a diff column, which its layout manager paints as a band.
    static let diffKind = NSAttributedString.Key("TovriDiffKind")
    /// On a hunk row's newline: the `@@ … @@` text the layout manager draws in the band.
    static let diffHunkText = NSAttributedString.Key("TovriDiffHunkText")
}

enum DiffLineKind: Int { case context, added, removed, hunk, note, filler }

/// The fonts and sizes diff columns share: the editor's font and line height, so rows line up arithmetically.
struct DiffMetrics: Equatable {
    static let verticalPadding: CGFloat = 6
    static let noteHeight: CGFloat = 36
    static let moreHeight: CGFloat = 34

    var font: NSFont
    var lineHeight: CGFloat
    var baseline: CGFloat
    var charWidth: CGFloat
    var digitWidth: CGFloat

    static func current() -> DiffMetrics {
        let font = Settings.shared.font
        let ascent = font.ascender
        let descent = -font.descender
        let natural = ceil(ascent + descent + font.leading)
        let height = max(natural, round(natural * CGFloat(Settings.shared.lineHeight)))
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        return DiffMetrics(font: font, lineHeight: height, baseline: round((height - (ascent + descent)) / 2 + ascent),
                           charWidth: (" " as NSString).size(withAttributes: [.font: font]).width,
                           digitWidth: ("0" as NSString).size(withAttributes: [.font: digits]).width)
    }

    func bodyHeight(rows: Int, hidden: Bool) -> CGFloat {
        2 * DiffMetrics.verticalPadding + CGFloat(rows) * lineHeight + (hidden ? DiffMetrics.moreHeight : 0)
    }
}

/// A file's diff turned into text for its columns, ready to show.
struct DiffRender {
    var rows: [DiffRow]
    var hunks: [PatchHunk]
    var split: Bool
    /// One column's text when unified; the old and new sides when split.
    var primary: NSAttributedString
    var secondary: NSAttributedString
    var maxColumns: Int
    var maxNumber: Int
}

enum DiffRenderer {
    /// Builds the syntax-colored text of the first `limit` rows. Each side of a hunk is lexed as its own
    /// sequence, so removed lines read as the old file and added lines as the new one.
    static func render(file: PatchFile, text: NSString, split: Bool, limit: Int, language: Language, theme: Theme,
                       metrics: DiffMetrics) -> DiffRender {
        let rows = file.rows(split: split, limit: limit)
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = metrics.charWidth * 4
        para.tabStops = []
        para.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: theme.foreground, .paragraphStyle: para]

        struct Sides { var old: [Int: NSAttributedString] = [:]; var new: [Int: NSAttributedString] = [:] }
        var cache: [Int: Sides] = [:]
        func sides(_ h: Int) -> Sides {
            if let s = cache[h] { return s }
            var oldIdx: [Int] = [], newIdx: [Int] = []
            var oldText: [String] = [], newText: [String] = []
            for (i, line) in file.hunks[h].lines.enumerated() where line.kind != .note {
                let s = text.substring(with: line.range)
                if line.kind != .added { oldIdx.append(i); oldText.append(s) }
                if line.kind != .removed { newIdx.append(i); newText.append(s) }
            }
            var result = Sides()
            for (k, a) in SnippetHighlighter.highlight(oldText, language: language, theme: theme, font: metrics.font, paragraph: para).enumerated() { result.old[oldIdx[k]] = a }
            for (k, a) in SnippetHighlighter.highlight(newText, language: language, theme: theme, font: metrics.font, paragraph: para).enumerated() { result.new[newIdx[k]] = a }
            cache[h] = result
            return result
        }

        var maxColumns = 0
        func line(_ h: Int, _ index: Int) -> NSMutableAttributedString {
            let pl = file.hunks[h].lines[index]
            let out: NSMutableAttributedString
            let kind: DiffLineKind
            switch pl.kind {
            case .removed:
                out = NSMutableAttributedString(attributedString: sides(h).old[index] ?? NSAttributedString())
                kind = .removed
            case .added:
                out = NSMutableAttributedString(attributedString: sides(h).new[index] ?? NSAttributedString())
                kind = .added
            case .context:
                out = NSMutableAttributedString(attributedString: sides(h).new[index] ?? NSAttributedString())
                kind = .context
            case .note:
                out = NSMutableAttributedString(string: text.substring(with: pl.range), attributes: [
                    .font: NSFont.systemFont(ofSize: metrics.font.pointSize * 0.85), .foregroundColor: theme.chromeSecondary, .paragraphStyle: para])
                kind = .note
            }
            var cols = out.length
            for u in out.string.utf16 where u == 9 { cols += 3 }
            maxColumns = max(maxColumns, cols)
            out.append(NSAttributedString(string: "\n", attributes: base))
            out.addAttribute(.diffKind, value: kind.rawValue, range: NSRange(location: 0, length: out.length))
            return out
        }
        func filler() -> NSAttributedString {
            NSAttributedString(string: "\n", attributes: base.merging([.diffKind: DiffLineKind.filler.rawValue]) { $1 })
        }
        func hunkRow(_ h: Int) -> NSAttributedString {
            NSAttributedString(string: "\n", attributes: base.merging([
                .diffKind: DiffLineKind.hunk.rawValue,
                .diffHunkText: text.substring(with: file.hunks[h].header)]) { $1 })
        }

        let primary = NSMutableAttributedString()
        let secondary = NSMutableAttributedString()
        for row in rows {
            let h = Int(row.hunk)
            if row.kind == .hunk {
                primary.append(hunkRow(h))
                if split { secondary.append(hunkRow(h)) }
            } else if !split {
                primary.append(line(h, Int(row.left)))
            } else {
                primary.append(row.left >= 0 ? line(h, Int(row.left)) : filler())
                secondary.append(row.right >= 0 ? line(h, Int(row.right)) : filler())
            }
        }
        var maxNumber = 0
        for hunk in file.hunks { for l in hunk.lines { maxNumber = max(maxNumber, Int(l.oldNumber), Int(l.newNumber)) } }
        return DiffRender(rows: rows, hunks: file.hunks, split: split, primary: primary, secondary: secondary, maxColumns: maxColumns, maxNumber: maxNumber)
    }
}

/// A small LRU of rendered file diffs, so scrolling back to a file doesn't lex it again.
struct DiffRenderCache {
    struct Key: Hashable { var file: Int; var split: Bool; var limit: Int }
    static let capacity = 40
    private var store: [Key: DiffRender] = [:]
    private var order: [Key] = []

    var count: Int { store.count }

    mutating func render(for key: Key) -> DiffRender? {
        guard let r = store[key] else { return nil }
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        return r
    }

    mutating func insert(_ render: DiffRender, for key: Key) {
        store[key] = render
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        while order.count > DiffRenderCache.capacity { store[order.removeFirst()] = nil }
    }

    mutating func removeAll() {
        store = [:]
        order = []
    }
}

// MARK: - Columns

/// Paints a band across the full width of each added, removed and hunk line, and the hunk header text.
final class DiffLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var lineHeight: CGFloat = 18
    var baseline: CGFloat = 14

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = baseline
        return true
    }

    static func bandColor(_ kind: DiffLineKind, theme: Theme) -> NSColor? {
        switch kind {
        case .added: return (theme.color(.inserted) ?? .systemGreen).withAlphaComponent(0.14)
        case .removed: return (theme.color(.deleted) ?? .systemRed).withAlphaComponent(0.14)
        case .hunk: return theme.foreground.withAlphaComponent(0.06)
        case .filler: return theme.chromeBackground.withAlphaComponent(0.5)
        case .context, .note: return nil
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let view = firstTextView else { return }
        let theme = ThemeManager.shared.active
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let char = self.characterIndexForGlyph(at: glyphRange.location)
            guard char < storage.length,
                  let raw = storage.attribute(.diffKind, at: char, effectiveRange: nil) as? Int, let kind = DiffLineKind(rawValue: raw) else { return }
            let r = NSRect(x: origin.x, y: rect.minY + origin.y, width: max(view.bounds.width, rect.width), height: rect.height)
            if let color = DiffLayoutManager.bandColor(kind, theme: theme) {
                color.setFill()
                r.fill()
            }
            if kind == .hunk, let header = storage.attribute(.diffHunkText, at: char, effectiveRange: nil) as? String {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeSecondary]
                let size = (header as NSString).size(withAttributes: attrs)
                (header as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + round((r.height - size.height) / 2)), withAttributes: attrs)
            }
        }
    }
}

/// Copies only the selected code, to the app's pasteboard.
final class DiffTextView: NSTextView {
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        AppRuntime.pasteboard.clearContents()
        AppRuntime.pasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }
}

/// Hands mostly vertical scrolling to the page behind, so a trackpad never gets stuck in a diff.
final class DiffCodeScrollView: OverlayScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// One selectable, non-editable column of code, scrolling sideways on its own.
final class DiffCodeColumn: NSView {
    let scroll = DiffCodeScrollView(frame: .zero)
    let textView: DiffTextView
    let layoutManager = DiffLayoutManager()
    private let storage = NSTextStorage()
    private var rows = 0
    private var columns = 0
    private var metrics = DiffMetrics.current()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)
        textView = DiffTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 0, height: DiffMetrics.verticalPadding)
        textView.setAccessibilityLabel("Changes")
        scroll.documentView = textView
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ text: NSAttributedString, rows: Int, columns: Int, metrics: DiffMetrics) {
        self.rows = rows
        self.columns = columns
        self.metrics = metrics
        layoutManager.lineHeight = metrics.lineHeight
        layoutManager.baseline = metrics.baseline
        storage.setAttributedString(text)
        textView.selectedTextAttributes = [.backgroundColor: ThemeManager.shared.active.selection]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = max(scroll.contentSize.width, CGFloat(columns) * metrics.charWidth + 24)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: metrics.bodyHeight(rows: rows, hidden: false))
        textView.minSize = NSSize(width: scroll.contentSize.width, height: 0)
    }
}

// MARK: - Gutter

/// Line numbers and +/− markers, drawn arithmetically for just the rows that are showing.
final class DiffGutterView: NSView {
    enum Side { case unified, old, new }
    var side: Side = .unified
    var render: DiffRender?
    var metrics = DiffMetrics.current()

    override var isFlipped: Bool { true }

    static func width(side: Side, maxNumber: Int, metrics: DiffMetrics) -> CGFloat {
        let digits = max(2, String(maxNumber).count)
        let number = CGFloat(digits) * metrics.digitWidth + 12
        return side == .unified ? 2 * number + 18 : number + 18
    }

    private func lineKind(_ row: DiffRow, _ render: DiffRender) -> (DiffLineKind, PatchLine?) {
        if row.kind == .hunk { return (.hunk, nil) }
        let index = side == .new ? row.right : row.left
        guard index >= 0 else { return (.filler, nil) }
        let line = render.hunks[Int(row.hunk)].lines[Int(index)]
        switch line.kind {
        case .added: return (.added, line)
        case .removed: return (.removed, line)
        case .context: return (.context, line)
        case .note: return (.note, line)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let render, !render.rows.isEmpty else { return }
        let theme = ThemeManager.shared.active
        let pad = DiffMetrics.verticalPadding
        let lh = metrics.lineHeight
        let first = max(0, Int(floor((dirtyRect.minY - pad) / lh)))
        let last = min(render.rows.count - 1, Int(ceil((dirtyRect.maxY - pad) / lh)))
        guard first <= last else { return }
        let digits = max(2, String(render.maxNumber).count)
        let numberWidth = CGFloat(digits) * metrics.digitWidth + 12
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: metrics.font.pointSize * 0.85, weight: .regular)
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.7)]
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        var right = numberAttrs
        right[.paragraphStyle] = para
        for i in first...last {
            let row = render.rows[i]
            let (kind, line) = lineKind(row, render)
            let y = pad + CGFloat(i) * lh
            if let band = DiffLayoutManager.bandColor(kind, theme: theme) {
                band.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: lh).fill()
            }
            guard let line, kind != .note else { continue }
            let textY = y + round((lh - numberFont.pointSize * 1.2) / 2)
            func number(_ n: Int32, column: Int) {
                guard n > 0 else { return }
                ("\(n)" as NSString).draw(in: NSRect(x: CGFloat(column) * numberWidth, y: textY, width: numberWidth - 6, height: lh), withAttributes: right)
            }
            switch side {
            case .unified:
                number(line.oldNumber, column: 0)
                number(line.newNumber, column: 1)
            case .old: number(line.oldNumber, column: 0)
            case .new: number(line.newNumber, column: 0)
            }
            if kind == .added || kind == .removed {
                let color = kind == .added ? (theme.color(.inserted) ?? .systemGreen) : (theme.color(.deleted) ?? .systemRed)
                let marker = (kind == .added ? "+" : "−") as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: metrics.font.pointSize, weight: .semibold), .foregroundColor: color]
                let columns: CGFloat = side == .unified ? 2 : 1
                marker.draw(at: NSPoint(x: columns * numberWidth + 2, y: y + round((lh - metrics.font.pointSize * 1.2) / 2)), withAttributes: attrs)
            }
        }
    }
}

// MARK: - Body

/// What a file section shows below its header: its diff, or a one-line note.
final class DiffBodyView: NSView {
    /// "Show N more lines" was clicked.
    var onShowMore: (() -> Void)?
    private let gutterA = DiffGutterView()
    private let gutterB = DiffGutterView()
    private let columnA = DiffCodeColumn()
    private let columnB = DiffCodeColumn()
    private let moreButton = ToolButton(title: "Show more lines")
    private var render: DiffRender?
    private var note: String?
    private var hiddenRows = 0
    private var limitReached = false
    private var metrics = DiffMetrics.current()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        gutterA.side = .unified
        gutterB.side = .new
        moreButton.onClick = { [weak self] in self?.onShowMore?() }
        [gutterA, columnA, gutterB, columnB, moreButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var codeViews: [NSTextView] { render == nil ? [] : (render!.split ? [columnA.textView, columnB.textView] : [columnA.textView]) }

    func configure(render: DiffRender?, note: String?, hiddenRows: Int, limitReached: Bool, metrics: DiffMetrics) {
        self.render = render
        self.note = render == nil ? note : nil
        self.hiddenRows = hiddenRows
        self.limitReached = limitReached
        self.metrics = metrics
        let showsCode = render != nil
        let split = render?.split ?? false
        columnA.isHidden = !showsCode
        gutterA.isHidden = !showsCode
        columnB.isHidden = !split
        gutterB.isHidden = !split
        moreButton.isHidden = hiddenRows == 0 || limitReached
        if let render {
            gutterA.side = split ? .old : .unified
            gutterA.render = render
            gutterB.render = render
            gutterA.metrics = metrics
            gutterB.metrics = metrics
            columnA.apply(render.primary, rows: render.rows.count, columns: render.maxColumns, metrics: metrics)
            if split { columnB.apply(render.secondary, rows: render.rows.count, columns: render.maxColumns, metrics: metrics) }
            moreButton.title = "Show \(hiddenRows.formatted()) more lines"
        }
        needsLayout = true
        needsDisplay = true
        gutterA.needsDisplay = true
        gutterB.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let render else { return }
        let rowsHeight = metrics.bodyHeight(rows: render.rows.count, hidden: false)
        let gutterWidth = DiffGutterView.width(side: render.split ? .old : .unified, maxNumber: render.maxNumber, metrics: metrics)
        if render.split {
            let half = floor(bounds.width / 2)
            gutterA.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: rowsHeight)
            columnA.frame = NSRect(x: gutterWidth, y: 0, width: max(0, half - gutterWidth), height: rowsHeight)
            let rightGutter = DiffGutterView.width(side: .new, maxNumber: render.maxNumber, metrics: metrics)
            gutterB.frame = NSRect(x: half + 1, y: 0, width: rightGutter, height: rowsHeight)
            columnB.frame = NSRect(x: half + 1 + rightGutter, y: 0, width: max(0, bounds.width - half - 1 - rightGutter), height: rowsHeight)
        } else {
            gutterA.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: rowsHeight)
            columnA.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: rowsHeight)
        }
        let w = ceil(moreButton.intrinsicWidth)
        moreButton.frame = NSRect(x: gutterWidth + 8, y: rowsHeight + 5, width: w, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        if let note {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.chromeSecondary]
            let size = (note as NSString).size(withAttributes: attrs)
            (note as NSString).draw(at: NSPoint(x: 14, y: round((bounds.height - size.height) / 2)), withAttributes: attrs)
            return
        }
        guard let render else { return }
        if render.split {
            theme.chromeBorder.setFill()
            NSRect(x: floor(bounds.width / 2), y: 0, width: 1, height: metrics.bodyHeight(rows: render.rows.count, hidden: false)).fill()
        }
        if limitReached && hiddenRows > 0 {
            let text = "Showing the first \(DiffRenderLimit.maxRows.formatted()) lines. Open Changes shows the whole file." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.chromeSecondary]
            let size = text.size(withAttributes: attrs)
            let y = metrics.bodyHeight(rows: render.rows.count, hidden: false)
            text.draw(at: NSPoint(x: 14, y: y + round((DiffMetrics.moreHeight - size.height) / 2)), withAttributes: attrs)
        }
    }
}

enum DiffRenderLimit {
    static let maxRows = CommitOverviewModel.maxRowLimit
}
