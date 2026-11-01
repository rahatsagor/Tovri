import AppKit

struct TextEdit {
    var range: NSRange
    var text: String
    /// Selection after the edit, relative to the start of the inserted text.
    var selection: NSRange

    init(_ range: NSRange, _ text: String, selection: NSRange? = nil) {
        self.range = range
        self.text = text
        self.selection = selection ?? NSRange(location: text.utf16.count, length: 0)
    }
}

enum SelectionUpdate {
    case fromEdits
    case preserve
    case custom([NSRange])
    case none
}

final class EditorTextView: NSTextView {
    unowned let document: Document
    weak var editor: EditorView?

    var extraSelections: [NSRange] = [] {
        didSet { extraSelectionsChanged(oldValue) }
    }
    var isSettingMulti = false
    private(set) var bracketPair: (Int, Int)?
    private(set) var occurrenceRanges: [NSRange] = []
    /// Find-bar matches (sorted). Drawn for the visible region only.
    private(set) var findMatches: [NSRange] = []
    private(set) var currentFindMatch: NSRange?
    private var extraCaretsVisible = true
    private var blinkTimer: Timer?
    var charWidth: CGFloat = 7.8
    var scrollPastEnd = true
    var wholeWordNeedle: String?
    /// Column kept while repeatedly adding carets above/below, so short lines don't pull it left.
    var caretGoalColumn: Int?

    static let fullLinePasteboardType = NSPasteboard.PasteboardType("app.tovri.fullline")

    var tovriLayoutManager: TovriLayoutManager { layoutManager as! TovriLayoutManager }
    var lineHeight: CGFloat { tovriLayoutManager.lineHeight }
    var text: NSString { document.string }
    var language: Language { document.language }
    var indentUnit: String { document.indentUsesTabs ? "\t" : String(repeating: " ", count: document.indentWidth) }

    init(document: Document, frame: NSRect, textContainer: NSTextContainer) {
        self.document = document
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { blinkTimer?.invalidate() }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        usesRuler = false
        displaysLinkToolTips = false
        allowsDocumentBackgroundColorChange = false
        allowsImageEditing = false
        isVerticallyResizable = true
        drawsBackground = true
        textContainerInset = NSSize(width: 4, height: 6)
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        if #available(macOS 15.0, *) { writingToolsBehavior = .none }
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { editor?.textViewDidBecomeFirstResponder() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        CompletionController.shared.hide()
        return super.resignFirstResponder()
    }

    // MARK: Appearance

    func applyTheme(_ theme: Theme) {
        backgroundColor = theme.editorBackground
        drawsBackground = !theme.translucent
        insertionPointColor = theme.caret
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes = document.baseAttributes
        tovriLayoutManager.invisiblesColor = theme.invisibles
        needsDisplay = true
    }

    func applyFontMetrics() {
        let font = document.font
        charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        tovriLayoutManager.configure(font: font, lineHeightMultiple: CGFloat(Settings.shared.lineHeight))
        typingAttributes = document.baseAttributes
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let sv = enclosingScrollView, let tc = textContainer, let lm = layoutManager as? TovriLayoutManager {
            let viewport = sv.contentView.bounds.height
            let insets = textContainerInset.height * 2
            // Noncontiguous layout positions distant lines using estimates that change as
            // more text is laid out. A logical line count cannot describe that coordinate
            // space: it can leave hundreds of empty viewports after the actual last glyph.
            // usedRect includes TextKit's current extent without forcing full-file layout.
            let used = max(lm.usedRect(for: tc).maxY + lm.trailingGapHeight, lm.extraLineFragmentRect.maxY)
            let contentHeight = max(lm.lineHeight, used) + insets
            // Scroll-past-end is useful only once the content fills the viewport.
            let scrollPadding = scrollPastEnd && contentHeight > viewport
                ? max(0, viewport - lm.lineHeight * 3) : 0
            size.height = max(viewport, ceil(contentHeight + scrollPadding))
        }
        super.setFrameSize(size)
    }

    /// NSClipView.scroll(to:) accepts out-of-range points, including old session offsets.
    func constrainedScrollPosition(_ point: NSPoint) -> NSPoint {
        guard let clip = enclosingScrollView?.contentView else { return .zero }
        let x = point.x.isFinite ? point.x : 0
        let y = point.y.isFinite ? point.y : 0
        return NSPoint(x: min(max(0, x), max(0, frame.width - clip.bounds.width)),
                       y: min(max(0, y), max(0, frame.height - clip.bounds.height)))
    }

    func constrainScrollPosition() {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let origin = constrainedScrollPosition(clip.bounds.origin)
        if clip.bounds.origin != origin {
            clip.scroll(to: origin)
            sv.reflectScrolledClipView(clip)
        }
    }

    // MARK: Geometry helpers

    func rects(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let tc = textContainer else { return [] }
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var out: [NSRect] = []
        let origin = textContainerOrigin
        lm.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            out.append(r.offsetBy(dx: origin.x, dy: origin.y))
        }
        if tovriLayoutManager.hasGaps { out = out.map { tovriLayoutManager.trimmedToText($0, origin: origin) } }
        return out
    }

    /// Rect spanning the full width for the logical line containing `loc`.
    func lineRect(forCharacter loc: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let len = document.length
        let lines = document.lines
        let line = lines.line(containing: min(loc, len))
        let full = lines.fullRange(of: line, textLength: len)
        var r: NSRect
        let tlm = tovriLayoutManager
        if full.length == 0 {
            r = tlm.extraTextBand
            if r.height == 0 { r = NSRect(x: 0, y: 0, width: 0, height: lineHeight) }
        } else {
            let gr = lm.glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            guard gr.length > 0 else { return .zero }
            let first = tlm.textBand(forGlyphAt: gr.location)
            if full.length > 5000 || !(textContainer?.widthTracksTextView ?? false) {
                r = first
            } else {
                let last = tlm.textBand(forGlyphAt: NSMaxRange(gr) - 1)
                r = first.union(last)
            }
        }
        _ = tc
        return NSRect(x: 0, y: r.minY + textContainerOrigin.y, width: bounds.width, height: r.height)
    }

    func caretRect(at loc: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let len = document.length
        var frag: NSRect
        var x: CGFloat
        let tlm = tovriLayoutManager
        if len == 0 || (loc >= len && text.character(at: len - 1) == 10) {
            frag = tlm.extraTextBand
            if frag.height == 0 { frag = NSRect(x: 0, y: 0, width: 0, height: lineHeight) }
            x = frag.minX + tc.lineFragmentPadding
        } else if loc >= len {
            let g = lm.glyphIndexForCharacter(at: len - 1)
            frag = tlm.textBand(forGlyphAt: g)
            x = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).maxX
        } else {
            let g = lm.glyphIndexForCharacter(at: loc)
            frag = tlm.textBand(forGlyphAt: g)
            x = frag.minX + lm.location(forGlyphAt: g).x
        }
        let o = textContainerOrigin
        return NSRect(x: floor(x + o.x), y: frag.minY + o.y, width: 2, height: frag.height)
    }

    var visibleCharacterRange: NSRange {
        guard let lm = layoutManager, let tc = textContainer else { return NSRange(location: 0, length: 0) }
        var rect = visibleRect
        rect.origin.x -= textContainerOrigin.x
        rect.origin.y -= textContainerOrigin.y
        // A noncontiguous glyph query alone can include estimated, offscreen lines.
        // Resolve just this viewport before using its character range for navigation.
        lm.ensureLayout(forBoundingRect: rect, in: tc)
        let gr = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard layoutManager != nil, textContainer != nil else { return }
        let theme = ThemeManager.shared.active
        let settings = Settings.shared

        if settings.highlightCurrentLine {
            theme.lineHighlight.setFill()
            let sels = allSelections
            if sels.count <= 500 {
                var lastLineY: CGFloat = -1
                for r in sels where r.length == 0 {
                    let lr = lineRect(forCharacter: r.location)
                    if lr.minY != lastLineY && lr.intersects(rect) { lr.fill() }
                    lastLineY = lr.minY
                }
            }
        }

        if let diff = editor?.inlineDiff { drawInlineDiff(diff, in: rect, theme: theme) }

        if settings.rulerColumn > 0, let tc = textContainer {
            let x = floor(textContainerOrigin.x + tc.lineFragmentPadding + CGFloat(settings.rulerColumn) * charWidth)
            theme.guide.setFill()
            NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
        }

        if settings.showIndentGuides { drawIndentGuides(in: rect, theme: theme) }

        if !findMatches.isEmpty { drawFindMatches(in: rect, theme: theme) }

        if !occurrenceRanges.isEmpty {
            theme.wordHighlight.setFill()
            for r in occurrenceRanges {
                for box in rects(for: r) where box.intersects(rect) {
                    NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
                }
            }
        }

        if !extraSelections.isEmpty {
            let color = window?.isKeyWindow == true ? theme.selection : theme.inactiveSelection
            color.setFill()
            for r in extraSelections where r.length > 0 {
                for box in rects(for: r) where box.intersects(rect) { box.fill() }
            }
        }

        drawFoldPlaceholders(in: rect)

        if let (a, b) = bracketPair {
            theme.bracketMatch.setStroke()
            for i in [a, b] {
                guard let box = rects(for: NSRange(location: i, length: 1)).first, box.intersects(rect) else { continue }
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 1.5), xRadius: 2, yRadius: 2)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Tints added and changed lines, and draws removed lines in the gaps opened above them.
    private func drawInlineDiff(_ diff: InlineDiff, in rect: NSRect, theme: Theme) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let tlm = tovriLayoutManager
        let o = textContainerOrigin
        let lines = document.lines
        let len = document.length
        let gr = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -o.x, dy: -o.y), in: tc)
        let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
        let first = lines.line(containing: cr.location)
        // The empty line after a final newline has no glyphs, so it is never in `cr`.
        let last = min(lines.line(containing: NSMaxRange(cr)) + 1, lines.count - 1, first + 2000)
        guard first <= last else { return }
        let deletedTint = (theme.color(.deleted) ?? .systemRed).withAlphaComponent(theme.isDark ? 0.14 : 0.12)
        let insertedTint = (theme.color(.inserted) ?? .systemGreen).withAlphaComponent(theme.isDark ? 0.11 : 0.10)
        let lh = lineHeight
        let textX = o.x + tc.lineFragmentPadding
        let textTop = tlm.baseline - document.font.ascender

        func drawRemoved(_ rows: [NSAttributedString], top: CGFloat) {
            guard !rows.isEmpty else { return }
            let band = NSRect(x: 0, y: top, width: bounds.width, height: CGFloat(rows.count) * lh)
            guard band.intersects(rect) else { return }
            deletedTint.setFill()
            band.intersection(rect).fill()
            let firstRow = max(0, Int((rect.minY - top) / lh))
            let lastRow = min(rows.count - 1, Int((rect.maxY - top) / lh))
            guard firstRow <= lastRow else { return }
            for i in firstRow...lastRow { rows[i].draw(at: NSPoint(x: textX, y: top + CGFloat(i) * lh + textTop)) }
        }

        for line in first...last {
            let start = lines.start(of: line)
            if !tlm.folds.isEmpty, tlm.fold(hiding: start) != nil { continue }
            let frag: NSRect
            let band: NSRect
            if start >= len && (len == 0 || text.character(at: len - 1) == 10) {
                frag = lm.extraLineFragmentRect
                band = tlm.extraTextBand
                if frag.height == 0 { continue }
            } else {
                guard start < len || line == lines.count - 1 else { continue }
                let g = lm.glyphIndexForCharacter(at: min(start, len - 1))
                frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                band = tlm.textBand(forGlyphAt: g)
            }
            let top = frag.minY + o.y
            if top > rect.maxY { break }
            if band.minY > frag.minY + 0.5 { drawRemoved(diff.rows(at: line, document: document), top: top) }
            if line == lines.count - 1, tlm.trailingGapHeight > 0, len > 0 {
                let end = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: len - 1), effectiveRange: nil)
                drawRemoved(diff.rows(at: InlineDiff.trailingKey, document: document), top: end.maxY - tlm.trailingGapHeight + o.y)
            }
            if diff.changed.contains(line) {
                let lr = lineRect(forCharacter: start)
                if lr.intersects(rect) {
                    insertedTint.setFill()
                    lr.intersection(rect).fill()
                }
            }
        }
    }

    private func drawIndentGuides(in rect: NSRect, theme: Theme) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let gr = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
        let lines = document.lines
        let s = text
        let len = s.length
        guard len > 0 else { return }
        let first = lines.line(containing: cr.location)
        let last = min(lines.line(containing: NSMaxRange(cr)), first + 400)
        let tab = max(1, document.indentWidth)
        let step = CGFloat(tab) * charWidth
        let x0 = origin.x + tc.lineFragmentPadding
        theme.guide.setFill()

        func indent(of line: Int) -> Int? {
            let r = lines.range(of: line, textLength: len)
            var cols = 0
            var i = r.location
            let end = NSMaxRange(r)
            while i < end {
                let c = s.character(at: i)
                if c == 32 { cols += 1 } else if c == 9 { cols += tab - cols % tab } else { return cols }
                i += 1
            }
            return nil
        }

        var nextCache: (line: Int, cols: Int)? = nil
        let tlm = tovriLayoutManager
        for line in first...last {
            if !tlm.folds.isEmpty, tlm.fold(hiding: lines.start(of: line)) != nil { continue }
            var cols: Int
            if let c = indent(of: line) {
                cols = c
            } else {
                if let n = nextCache, n.line > line {
                    cols = n.cols
                } else {
                    var k = line + 1
                    cols = 0
                    while k < lines.count && k < line + 200 {
                        if let c = indent(of: k) { cols = c; break }
                        k += 1
                    }
                    nextCache = (k, cols)
                }
            }
            let levels = (cols + tab - 1) / tab
            guard levels > 0 else { continue }
            let lr = lineRect(forCharacter: lines.start(of: line))
            guard lr.intersects(rect) else { continue }
            for k in 0..<levels {
                NSRect(x: floor(x0 + CGFloat(k) * step), y: lr.minY, width: 1, height: lr.height).fill()
            }
        }
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        // Also called while the text view is set up or torn down, without a layout manager.
        if (layoutManager as? TovriLayoutManager)?.hasGaps == true { fitInsertionIndicators() }
    }

    /// The system caret spans its whole line fragment; next to removed lines that fragment also
    /// holds the gap above the text, so the caret is cut back to the text row.
    func fitInsertionIndicators() {
        guard selectedRange().length == 0 else { return }
        let band = caretRect(at: selectedRange().location)
        for case let indicator as NSTextInsertionIndicator in subviews where abs(indicator.frame.height - band.height) > 1 {
            indicator.frame = NSRect(x: indicator.frame.minX, y: band.minY, width: indicator.frame.width, height: band.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !extraSelections.isEmpty, extraCaretsVisible, window?.isKeyWindow == true, window?.firstResponder === self else { return }
        ThemeManager.shared.active.caret.setFill()
        for r in extraSelections {
            let cr = caretRect(at: r.length == 0 ? r.location : NSMaxRange(r))
            if cr.intersects(dirtyRect) { cr.fill() }
        }
    }

    private var lastLineHighlightRects: [NSRect] = []

    /// Redraws only the previously and currently highlighted lines instead of the whole viewport.
    func invalidateCurrentLineHighlights() {
        let sels = allSelections
        var rects: [NSRect] = []
        if sels.count <= 64 {
            for r in sels { rects.append(lineRect(forCharacter: r.location)) }
        } else {
            rects = [visibleRect]
        }
        for r in lastLineHighlightRects + rects { setNeedsDisplay(r) }
        lastLineHighlightRects = rects
    }

    func setFindMatches(_ matches: [NSRange], current: NSRange?) {
        let hadAny = !findMatches.isEmpty
        findMatches = matches
        currentFindMatch = current
        if hadAny || !matches.isEmpty { setNeedsDisplay(visibleRect) }
    }

    private func drawFindMatches(in rect: NSRect, theme: Theme) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let o = textContainerOrigin
        let gr = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -o.x, dy: -o.y), in: tc)
        let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
        let start = cr.location, end = NSMaxRange(cr)
        var lo = 0, hi = findMatches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(findMatches[mid]) < start { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        var drawn = 0
        while i < findMatches.count && findMatches[i].location <= end && drawn < 5000 {
            let m = findMatches[i]
            let isCurrent = m == currentFindMatch
            (isCurrent ? theme.findCurrent : theme.findMatch).setFill()
            let boxes = m.length == 0 ? [caretRect(at: m.location)] : rects(for: m)
            for box in boxes where box.intersects(rect) {
                NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            i += 1
            drawn += 1
        }
    }

    // MARK: Multiple selections

    var allSelections: [NSRange] {
        let primary = selectedRange()
        if extraSelections.isEmpty { return [primary] }
        return EditorTextView.normalize(extraSelections + [primary])
    }

    static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
        var out: [NSRange] = []
        for r in sorted {
            if let last = out.last, r.location < NSMaxRange(last) || r.location == last.location {
                out[out.count - 1] = NSUnionRange(last, r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    func setAllSelections(_ ranges: [NSRange], primaryLocation: Int? = nil, scroll: Bool = true) {
        let len = document.length
        let clamped = ranges.map { r -> NSRange in
            let loc = min(max(0, r.location), len)
            return NSRange(location: loc, length: min(r.length, len - loc))
        }
        let merged = EditorTextView.normalize(clamped)
        guard !merged.isEmpty else { return }
        var pi = merged.count - 1
        if let p = primaryLocation, let idx = merged.firstIndex(where: { NSLocationInRange(p, $0) || $0.location == p || NSMaxRange($0) == p }) {
            pi = idx
        }
        isSettingMulti = true
        setSelectedRange(merged[pi])
        var extras = merged
        extras.remove(at: pi)
        extraSelections = extras
        isSettingMulti = false
        caretGoalColumn = nil
        if scroll { scrollRangeToVisible(merged[pi]) }
        updateBracketMatch()
        updateOccurrences()
        editor?.selectionDidChange()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isSettingMulti && !stillSelecting && ranges.count > 1 {
            let rs = ranges.map { $0.rangeValue }
            isSettingMulti = true
            super.setSelectedRanges([NSValue(range: rs[rs.count - 1])], affinity: affinity, stillSelecting: false)
            extraSelections = Array(rs.dropLast())
            isSettingMulti = false
            return
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isSettingMulti && !stillSelecting {
            if !extraSelections.isEmpty { extraSelections = [] }
            wholeWordNeedle = nil
            caretGoalColumn = nil
        }
    }

    private func extraSelectionsChanged(_ old: [NSRange]) {
        if old.isEmpty && extraSelections.isEmpty { return }
        setNeedsDisplay(visibleRect)
        if extraSelections.isEmpty {
            blinkTimer?.invalidate()
            blinkTimer = nil
        } else if blinkTimer == nil {
            extraCaretsVisible = true
            let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.extraCaretsVisible.toggle()
                for r in self.extraSelections {
                    self.setNeedsDisplay(self.caretRect(at: r.length == 0 ? r.location : NSMaxRange(r)).insetBy(dx: -1, dy: 0))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            blinkTimer = t
        }
        if !isSettingMulti { editor?.selectionDidChange() }
    }

    /// Applies non-overlapping edits as a single undoable change.
    func performEdits(_ edits: [TextEdit], selection: SelectionUpdate = .fromEdits, actionName: String? = nil) {
        guard let storage = textStorage, !document.isReadOnly else { NSSound.beep(); return }
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var filtered: [TextEdit] = []
        var lastEnd = -1
        for e in sorted where e.range.location >= lastEnd {
            filtered.append(e)
            lastEnd = NSMaxRange(e.range)
            if e.range.length == 0 { lastEnd = e.range.location + 0 }
        }
        guard !filtered.isEmpty else { return }
        let oldSelections = allSelections

        breakUndoCoalescing()
        let attrs = typingAttributes
        if filtered.count > 256 {
            // shouldChangeText(inRanges:) is quadratic in the number of ranges (Replace All with
            // 40k matches took 10 s), so many edits become one replacement of the span they cover.
            let start = filtered[0].range.location
            let end = filtered.map { NSMaxRange($0.range) }.max() ?? start
            let span = NSRange(location: start, length: end - start)
            var combined = ""
            var pos = start
            for e in filtered {
                combined += text.substring(with: NSRange(location: pos, length: e.range.location - pos))
                combined += e.text
                pos = NSMaxRange(e.range)
            }
            combined += text.substring(with: NSRange(location: pos, length: end - pos))
            guard shouldChangeText(in: span, replacementString: combined) else { return }
            isSettingMulti = true
            storage.beginEditing()
            storage.replaceCharacters(in: span, with: NSAttributedString(string: combined, attributes: attrs))
            storage.endEditing()
        } else {
            let ranges = filtered.map { NSValue(range: $0.range) }
            let strings = filtered.map { $0.text }
            guard shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return }
            isSettingMulti = true
            storage.beginEditing()
            for e in filtered.reversed() {
                storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.text, attributes: attrs))
            }
            storage.endEditing()
        }
        didChangeText()
        isSettingMulti = false
        if let name = actionName { undoManager?.setActionName(name) }

        switch selection {
        case .fromEdits:
            var delta = 0
            var sels: [NSRange] = []
            for e in filtered {
                let base = e.range.location + delta
                sels.append(NSRange(location: base + e.selection.location, length: e.selection.length))
                delta += e.text.utf16.count - e.range.length
            }
            setAllSelections(sels)
        case .preserve:
            let sels = oldSelections.map { r -> NSRange in
                let a = EditorTextView.map(r.location, through: filtered)
                let b = EditorTextView.map(NSMaxRange(r), through: filtered)
                return NSRange(location: a, length: max(0, b - a))
            }
            setAllSelections(sels, scroll: false)
        case .custom(let sels):
            setAllSelections(sels)
        case .none:
            break
        }
        breakUndoCoalescing()
    }

    static func map(_ p: Int, through edits: [TextEdit]) -> Int {
        var delta = 0
        for e in edits {
            if e.range.location > p { break }
            let end = NSMaxRange(e.range)
            if end <= p {
                delta += e.text.utf16.count - e.range.length
            } else {
                return e.range.location + delta + min(p - e.range.location, e.text.utf16.count)
            }
        }
        return p + delta
    }

    func replace(_ range: NSRange, with string: String, select: NSRange? = nil) {
        performEdits([TextEdit(range, string, selection: select)], selection: .fromEdits)
    }

    // MARK: Edit tracking

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if document.isReadOnly { NSSound.beep(); return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if document.isReadOnly { NSSound.beep(); return false }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    // MARK: Character helpers

    @inline(__always) func char(_ i: Int) -> UInt16 { (i >= 0 && i < document.length) ? text.character(at: i) : 0 }

    func lineRange(at loc: Int) -> NSRange { document.lines.range(of: document.lines.line(containing: loc), textLength: document.length) }
    func fullLineRange(at loc: Int) -> NSRange { document.lines.fullRange(of: document.lines.line(containing: loc), textLength: document.length) }

    func leadingWhitespace(ofLineAt loc: Int, upTo limit: Int? = nil) -> String {
        let r = lineRange(at: loc)
        var i = r.location
        let end = min(NSMaxRange(r), limit ?? Int.max)
        while i < end, isSpaceU(char(i)) { i += 1 }
        return text.substring(with: NSRange(location: r.location, length: i - r.location))
    }

    func isWordChar(_ c: UInt16) -> Bool {
        if isWordU(c) { return true }
        let extra = language.identifierChars.utf16
        return extra.contains(c) && c != 45
    }

    func wordRange(at loc: Int) -> NSRange? {
        var a = loc, b = loc
        while a > 0 && isWordChar(char(a - 1)) { a -= 1 }
        while b < document.length && isWordChar(char(b)) { b += 1 }
        return b > a ? NSRange(location: a, length: b - a) : nil
    }

    // MARK: Typing

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        Perf.measure("insertText", threshold: 12) { insertTextImpl(insertString, replacementRange: replacementRange) }
    }

    private func insertTextImpl(_ insertString: Any, replacementRange: NSRange) {
        if hasMarkedText() || replacementRange.location != NSNotFound {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let str = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if !extraSelections.isEmpty {
            multiInsert(str)
            return
        }
        if str.utf16.count == 1, Settings.shared.autoCloseBrackets, handleAutoPair(str.utf16.first!) {
            CompletionController.shared.textDidChange(in: self)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        if str.utf16.count == 1, Settings.shared.autoIndent, let c = str.utf16.first, language.dedentChars.utf16.contains(c) {
            electricDedent()
        }
        CompletionController.shared.textDidChange(in: self)
    }

    private func multiInsert(_ s: String) {
        if s.utf16.count == 1, Settings.shared.autoCloseBrackets, let c = s.utf16.first, let close = pairCloser(for: c), close != c {
            let open = s
            let closeS = String(utf16CodeUnits: [close], count: 1)
            performEdits(allSelections.map { r in
                r.length > 0
                    ? TextEdit(r, open + text.substring(with: r) + closeS, selection: NSRange(location: 1, length: r.length))
                    : TextEdit(r, open + closeS, selection: NSRange(location: 1, length: 0))
            })
            return
        }
        performEdits(allSelections.map { TextEdit($0, s) })
    }

    private func pairCloser(for c: UInt16) -> UInt16? {
        let pairs = Array(language.autoPairs.utf16)
        var i = 0
        while i + 1 < pairs.count {
            if pairs[i] == c { return pairs[i + 1] }
            i += 2
        }
        return nil
    }

    private func isCloser(_ c: UInt16) -> Bool {
        let pairs = Array(language.autoPairs.utf16)
        var i = 1
        while i < pairs.count {
            if pairs[i] == c { return true }
            i += 2
        }
        return false
    }

    private func handleAutoPair(_ c: UInt16) -> Bool {
        let sel = selectedRange()
        let loc = sel.location
        let next = char(NSMaxRange(sel))
        let closer = pairCloser(for: c)
        let isQuote = closer == c

        if sel.length == 0 && isCloser(c) && next == c {
            if !isQuote || char(loc - 1) != 92 {
                setSelectedRange(NSRange(location: loc + 1, length: 0))
                return true
            }
        }
        guard let close = closer else { return false }
        if sel.length > 0 {
            let inner = text.substring(with: sel)
            if inner.contains("\n") && isQuote { return false }
            let open = String(utf16CodeUnits: [c], count: 1)
            let closeS = String(utf16CodeUnits: [close], count: 1)
            if shouldChangeText(in: sel, replacementString: open + inner + closeS) {
                textStorage?.replaceCharacters(in: sel, with: NSAttributedString(string: open + inner + closeS, attributes: typingAttributes))
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
            }
            return true
        }
        let okNext = next == 0 || next == 10 || isSpaceU(next) || isCloser(next) || next == 44 || next == 59 || next == 58
        guard okNext else { return false }
        if isQuote {
            let prev = char(loc - 1)
            if isWordChar(prev) || prev == c || prev == 92 { return false }
        }
        let pair = String(utf16CodeUnits: [c, close], count: 2)
        super.insertText(pair, replacementRange: sel)
        setSelectedRange(NSRange(location: loc + 1, length: 0))
        return true
    }

    private func electricDedent() {
        let loc = selectedRange().location
        let r = lineRange(at: loc)
        let before = text.substring(with: NSRange(location: r.location, length: loc - r.location))
        guard before.count >= 2, before.dropLast().allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
        guard let match = matchingBracket(at: loc - 1) else { return }
        let target = leadingWhitespace(ofLineAt: match)
        let current = String(before.dropLast())
        guard target != current else { return }
        let wsRange = NSRange(location: r.location, length: current.utf16.count)
        if shouldChangeText(in: wsRange, replacementString: target) {
            textStorage?.replaceCharacters(in: wsRange, with: NSAttributedString(string: target, attributes: typingAttributes))
            didChangeText()
            setSelectedRange(NSRange(location: r.location + target.utf16.count + 1, length: 0))
        }
    }

    override func insertNewline(_ sender: Any?) {
        if CompletionController.shared.isVisible && CompletionController.shared.accept() { return }
        if document.isFindResults { editor?.openFindResult(at: selectedRange().location); return }
        if !extraSelections.isEmpty {
            performEdits(allSelections.map { r in TextEdit(r, "\n" + leadingWhitespace(ofLineAt: r.location, upTo: r.location)) })
            return
        }
        guard Settings.shared.autoIndent else { super.insertNewline(sender); return }
        let sel = selectedRange()
        let loc = sel.location
        let indent = leadingWhitespace(ofLineAt: loc, upTo: loc)
        var k = loc - 1
        let lineStart = lineRange(at: loc).location
        while k >= lineStart && isSpaceU(char(k)) { k -= 1 }
        let prev = k >= lineStart ? char(k) : 0
        let next = char(NSMaxRange(sel))
        let opens = language.indentAfter.utf16
        var extra = ""
        if opens.contains(prev) || (language.indentAfterColon && prev == 58) { extra = indentUnit }
        if !extra.isEmpty, let close = pairCloser(for: prev), close == next, close != prev {
            let insert = "\n" + indent + extra + "\n" + indent
            replace(sel, with: insert, select: NSRange(location: 1 + indent.utf16.count + extra.utf16.count, length: 0))
            return
        }
        let insert = "\n" + indent + extra
        super.insertText(insert, replacementRange: sel)
        trimWhitespaceOnlyLine(before: lineStart, originalIndent: indent)
    }

    private func trimWhitespaceOnlyLine(before lineStart: Int, originalIndent: String) {
        let r = lineRange(at: lineStart)
        guard r.length > 0, r.length == originalIndent.utf16.count else { return }
        let content = text.substring(with: r)
        guard content.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
        let caret = selectedRange().location
        if shouldChangeText(in: r, replacementString: "") {
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: caret - r.length, length: 0))
        }
    }

    override func insertTab(_ sender: Any?) {
        if CompletionController.shared.isVisible && CompletionController.shared.accept() { return }
        let sels = allSelections
        if sels.contains(where: { r in r.length > 0 && text.substring(with: r).contains("\n") }) {
            indentLines(sender)
            return
        }
        let edits = sels.map { r -> TextEdit in
            if document.indentUsesTabs { return TextEdit(r, "\t") }
            let lineStart = lineRange(at: r.location).location
            let col = visualColumn(of: r.location, lineStart: lineStart)
            let n = document.indentWidth - col % document.indentWidth
            return TextEdit(r, String(repeating: " ", count: n))
        }
        if sels.count == 1, let e = edits.first {
            super.insertText(e.text, replacementRange: e.range)
        } else {
            performEdits(edits)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        outdentLines(sender)
    }

    func visualColumn(of loc: Int, lineStart: Int) -> Int {
        var col = 0
        var i = lineStart
        let tab = document.indentWidth
        while i < loc {
            if char(i) == 9 { col += tab - col % tab } else { col += 1 }
            i += 1
        }
        return col
    }

    override func deleteBackward(_ sender: Any?) {
        if !extraSelections.isEmpty {
            let edits = allSelections.compactMap { r -> TextEdit? in
                if r.length > 0 { return TextEdit(r, "") }
                guard r.location > 0 else { return nil }
                return TextEdit(text.rangeOfComposedCharacterSequence(at: r.location - 1), "")
            }
            performEdits(edits)
            return
        }
        let sel = selectedRange()
        if sel.length == 0 && sel.location > 0 {
            let loc = sel.location
            let prev = char(loc - 1)
            if Settings.shared.autoCloseBrackets, let close = pairCloser(for: prev), char(loc) == close {
                let r = NSRange(location: loc - 1, length: 2)
                if shouldChangeText(in: r, replacementString: "") {
                    textStorage?.replaceCharacters(in: r, with: "")
                    didChangeText()
                    setSelectedRange(NSRange(location: loc - 1, length: 0))
                }
                CompletionController.shared.textDidChange(in: self)
                return
            }
            if !document.indentUsesTabs && prev == 32 {
                let lineStart = lineRange(at: loc).location
                var k = loc
                while k > lineStart && char(k - 1) == 32 { k -= 1 }
                if k == lineStart && loc > lineStart {
                    let col = loc - lineStart
                    let w = document.indentWidth
                    let remove = col % w == 0 ? w : col % w
                    let r = NSRange(location: loc - remove, length: remove)
                    if shouldChangeText(in: r, replacementString: "") {
                        textStorage?.replaceCharacters(in: r, with: "")
                        didChangeText()
                        setSelectedRange(NSRange(location: r.location, length: 0))
                    }
                    return
                }
            }
        }
        super.deleteBackward(sender)
        CompletionController.shared.textDidChange(in: self)
    }

    override func deleteForward(_ sender: Any?) {
        if !extraSelections.isEmpty {
            let len = document.length
            let edits = allSelections.compactMap { r -> TextEdit? in
                if r.length > 0 { return TextEdit(r, "") }
                guard r.location < len else { return nil }
                return TextEdit(text.rangeOfComposedCharacterSequence(at: r.location), "")
            }
            performEdits(edits)
            return
        }
        super.deleteForward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if CompletionController.shared.isVisible { CompletionController.shared.hide(); return }
        if !extraSelections.isEmpty {
            setAllSelections([selectedRange()])
            return
        }
        if editor?.closeFindBarIfVisible() == true { return }
        editor?.cancelOperationFallback()
    }

    override func complete(_ sender: Any?) {
        CompletionController.shared.show(for: self, explicit: true)
    }

    // MARK: Document start / end

    // AppKit's implementations lay out far more text than needed on huge documents.
    override func moveToBeginningOfDocument(_ sender: Any?) {
        guard extraSelections.isEmpty else { super.moveToBeginningOfDocument(sender); return }
        setAllSelections([NSRange(location: 0, length: 0)], scroll: false)
        if let clip = enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: 0, y: 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        guard extraSelections.isEmpty else { super.moveToEndOfDocument(sender); return }
        let len = document.length
        setAllSelections([NSRange(location: len, length: 0)], scroll: false)
        editor?.scrollToCenter(NSRange(location: len, length: 0))
    }

    // MARK: Smart home

    override func moveToBeginningOfLine(_ sender: Any?) { smartHome(extend: false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { smartHome(extend: false) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { smartHome(extend: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { smartHome(extend: true) }

    private func smartHome(extend: Bool) {
        let sel = selectedRange()
        let caret = sel.location
        let anchor = NSMaxRange(sel)
        let r = lineRange(at: caret)
        var start = r.location
        if let lm = layoutManager, textContainer?.widthTracksTextView == true, caret < document.length {
            var fragGlyphs = NSRange()
            _ = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: caret), effectiveRange: &fragGlyphs)
            let fragStart = lm.characterIndexForGlyph(at: fragGlyphs.location)
            if fragStart > r.location {
                start = fragStart
            }
        }
        var firstNonWS = start
        if start == r.location {
            while firstNonWS < NSMaxRange(r) && isSpaceU(char(firstNonWS)) { firstNonWS += 1 }
        }
        let target = caret == firstNonWS ? r.location : firstNonWS
        if extend {
            setSelectedRange(NSRange(location: min(target, anchor), length: abs(anchor - target)))
        } else {
            setSelectedRange(NSRange(location: target, length: 0))
        }
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    // MARK: Command dispatch for multiple cursors

    private static let movementSelectors: Set<String> = [
        "moveLeft:", "moveRight:", "moveUp:", "moveDown:", "moveBackward:", "moveForward:",
        "moveWordLeft:", "moveWordRight:", "moveWordBackward:", "moveWordForward:",
        "moveToBeginningOfLine:", "moveToEndOfLine:", "moveToLeftEndOfLine:", "moveToRightEndOfLine:",
        "moveToBeginningOfParagraph:", "moveToEndOfParagraph:", "moveSubWordLeft:", "moveSubWordRight:",
        "moveLeftAndModifySelection:", "moveRightAndModifySelection:", "moveUpAndModifySelection:", "moveDownAndModifySelection:",
        "moveBackwardAndModifySelection:", "moveForwardAndModifySelection:",
        "moveWordLeftAndModifySelection:", "moveWordRightAndModifySelection:",
        "moveWordBackwardAndModifySelection:", "moveWordForwardAndModifySelection:",
        "moveToBeginningOfLineAndModifySelection:", "moveToEndOfLineAndModifySelection:",
        "moveToLeftEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
        "moveToBeginningOfParagraphAndModifySelection:", "moveToEndOfParagraphAndModifySelection:",
        "moveParagraphForwardAndModifySelection:", "moveParagraphBackwardAndModifySelection:",
    ]

    private static let deletionSelectors: [String: String] = [
        "deleteWordBackward:": "moveWordBackwardAndModifySelection:",
        "deleteWordForward:": "moveWordForwardAndModifySelection:",
        "deleteToBeginningOfLine:": "moveToLeftEndOfLineAndModifySelection:",
        "deleteToEndOfLine:": "moveToRightEndOfLineAndModifySelection:",
        "deleteToBeginningOfParagraph:": "moveToBeginningOfParagraphAndModifySelection:",
        "deleteToEndOfParagraph:": "moveToEndOfParagraphAndModifySelection:",
    ]

    override func doCommand(by selector: Selector) {
        Perf.measure("command \(NSStringFromSelector(selector))", threshold: 20) { dispatchCommand(selector) }
    }

    private func dispatchCommand(_ selector: Selector) {
        let name = NSStringFromSelector(selector)
        let completion = CompletionController.shared
        if completion.isVisible {
            switch name {
            case "moveUp:": completion.moveSelection(-1); return
            case "moveDown:": completion.moveSelection(1); return
            case "pageUp:", "scrollPageUp:": completion.moveSelection(-8); return
            case "pageDown:", "scrollPageDown:": completion.moveSelection(8); return
            case "moveLeft:", "moveRight:", "moveToBeginningOfLine:", "moveToEndOfLine:": completion.hide()
            default: break
            }
        }
        if !extraSelections.isEmpty {
            if EditorTextView.movementSelectors.contains(name) {
                var results: [NSRange] = []
                isSettingMulti = true
                for r in allSelections {
                    super.setSelectedRanges([NSValue(range: r)], affinity: .downstream, stillSelecting: false)
                    super.doCommand(by: selector)
                    results.append(selectedRange())
                }
                isSettingMulti = false
                setAllSelections(results, primaryLocation: results.last?.location)
                return
            }
            if let move = EditorTextView.deletionSelectors[name] {
                var ranges: [NSRange] = []
                isSettingMulti = true
                for r in allSelections {
                    if r.length > 0 { ranges.append(r); continue }
                    super.setSelectedRanges([NSValue(range: r)], affinity: .downstream, stillSelecting: false)
                    super.doCommand(by: NSSelectorFromString(move))
                    ranges.append(selectedRange())
                }
                isSettingMulti = false
                // Neighbouring carets can delete overlapping spans; merge them instead of dropping one.
                performEdits(EditorTextView.normalize(ranges).filter { $0.length > 0 }.map { TextEdit($0, "") })
                return
            }
        }
        super.doCommand(by: selector)
    }

    // MARK: Mouse

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Goto Definition", action: #selector(MainWindowController.gotoDefinition(_:)), keyEquivalent: "")
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        CompletionController.shared.hide()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            setAllSelections([NSRange(location: idx, length: 0)], scroll: false)
            NSApp.sendAction(#selector(MainWindowController.gotoDefinition(_:)), to: nil, from: self)
            return
        }
        if flags == .command {
            let point = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: point)
            var sels = allSelections
            if sels.count > 1, let existing = sels.firstIndex(where: { $0.location == idx && $0.length == 0 }) {
                sels.remove(at: existing)
                setAllSelections(sels, scroll: false)
            } else {
                sels.append(NSRange(location: idx, length: 0))
                setAllSelections(sels, primaryLocation: idx, scroll: false)
            }
            return
        }
        if !tovriLayoutManager.folds.isEmpty, let f = foldPlaceholder(at: convert(event.locationInWindow, from: nil)) {
            editor?.unfold(f)
            return
        }
        if event.clickCount == 2 && document.isFindResults {
            let point = convert(event.locationInWindow, from: nil)
            editor?.openFindResult(at: characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
    }

    // MARK: Clipboard

    override func copy(_ sender: Any?) {
        let sels = allSelections
        let pb = NSPasteboard.general
        if sels.count == 1 && sels[0].length == 0 {
            let r = fullLineRange(at: sels[0].location)
            var s = text.substring(with: r)
            if !s.hasSuffix("\n") { s += "\n" }
            pb.declareTypes([.string, EditorTextView.fullLinePasteboardType], owner: nil)
            pb.setString(s, forType: .string)
            pb.setString("1", forType: EditorTextView.fullLinePasteboardType)
            return
        }
        if sels.count > 1 {
            let s = sels.map { text.substring(with: $0) }.joined(separator: "\n")
            pb.declareTypes([.string], owner: nil)
            pb.setString(s, forType: .string)
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        let sels = allSelections
        if sels.count == 1 && sels[0].length == 0 {
            copy(sender)
            let r = fullLineRange(at: sels[0].location)
            performEdits([TextEdit(r, "", selection: NSRange(location: 0, length: 0))], actionName: "Cut")
            return
        }
        if sels.count > 1 {
            copy(sender)
            performEdits(sels.map { TextEdit($0, "") }, actionName: "Cut")
            return
        }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string) else { super.paste(sender); return }
        insertPastedText(s, fullLine: pb.string(forType: EditorTextView.fullLinePasteboardType) != nil)
    }

    func insertPastedText(_ source: String, fullLine: Bool = false) {
        let s = LineEnding.normalize(source, rawData: nil).0
        let sels = allSelections
        if fullLine && sels.allSatisfy({ $0.length == 0 }) {
            let edits = sels.map { r -> TextEdit in
                let start = lineRange(at: r.location).location
                return TextEdit(NSRange(location: start, length: 0), s, selection: NSRange(location: s.utf16.count + r.location - start, length: 0))
            }
            performEdits(edits, actionName: "Paste")
            return
        }
        if sels.count > 1 {
            var parts = s.components(separatedBy: "\n")
            if parts.count == sels.count + 1 && parts.last == "" { parts.removeLast() }
            let edits = sels.enumerated().map { i, r in TextEdit(r, parts.count == sels.count ? parts[i] : s) }
            performEdits(edits, actionName: "Paste")
            return
        }
        breakUndoCoalescing()
        super.insertText(s, replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL || pboard.types?.contains(.fileURL) == true,
           let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            editor?.openDroppedFiles(urls)
            return true
        }
        // Dropped and Services text skips paste, which is where CR line endings are normalized.
        // "\r\n" is one Character, so look for CR among the scalars.
        if type == .string, let s = pboard.string(forType: .string), s.unicodeScalars.contains("\r") {
            insertPastedText(s)
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            editor?.openDroppedFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: Brackets and occurrences

    private static let openBrackets: [UInt16] = [40, 91, 123]
    private static let closeBrackets: [UInt16] = [41, 93, 125]

    func matchingBracket(at index: Int) -> Int? {
        let len = document.length
        guard index >= 0, index < len else { return nil }
        let c = char(index)
        let s = text
        let limit = 400_000
        if let k = EditorTextView.openBrackets.firstIndex(of: c) {
            let close = EditorTextView.closeBrackets[k]
            var depth = 0
            var i = index
            let end = min(len, index + limit)
            let chunk = 4096
            var buf = [UInt16](repeating: 0, count: chunk)
            while i < end {
                let n = min(chunk, end - i)
                buf.withUnsafeMutableBufferPointer { s.getCharacters($0.baseAddress!, range: NSRange(location: i, length: n)) }
                for j in 0..<n {
                    let d = buf[j]
                    if d == c { depth += 1 } else if d == close { depth -= 1; if depth == 0 { return i + j } }
                }
                i += n
            }
        } else if let k = EditorTextView.closeBrackets.firstIndex(of: c) {
            let open = EditorTextView.openBrackets[k]
            var depth = 0
            var i = index + 1
            let start = max(0, index - limit)
            let chunk = 4096
            var buf = [UInt16](repeating: 0, count: chunk)
            while i > start {
                let n = min(chunk, i - start)
                let from = i - n
                buf.withUnsafeMutableBufferPointer { s.getCharacters($0.baseAddress!, range: NSRange(location: from, length: n)) }
                var j = n - 1
                while j >= 0 {
                    let d = buf[j]
                    if d == c { depth += 1 } else if d == open { depth -= 1; if depth == 0 { return from + j } }
                    j -= 1
                }
                i = from
            }
        }
        return nil
    }

    func updateBracketMatch() {
        let old = bracketPair
        bracketPair = nil
        let sel = selectedRange()
        if Settings.shared.highlightBrackets && extraSelections.isEmpty && sel.length == 0 {
            let loc = sel.location
            let isBracket: (UInt16) -> Bool = { EditorTextView.openBrackets.contains($0) || EditorTextView.closeBrackets.contains($0) }
            if loc > 0 && isBracket(char(loc - 1)), let m = matchingBracket(at: loc - 1) {
                bracketPair = (loc - 1, m)
            } else if isBracket(char(loc)), let m = matchingBracket(at: loc) {
                bracketPair = (loc, m)
            }
        }
        for p in [old, bracketPair].compactMap({ $0 }) {
            for i in [p.0, p.1] {
                for r in rects(for: NSRange(location: i, length: 1)) { setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) }
            }
        }
    }

    func updateOccurrences() {
        let old = occurrenceRanges
        occurrenceRanges = []
        let sel = selectedRange()
        if Settings.shared.highlightOccurrences && extraSelections.isEmpty && sel.length > 0 && sel.length <= 120 && document.length < 50_000_000 {
            let needle = text.substring(with: sel)
            let isWord = needle.utf16.allSatisfy { isWordChar($0) }
            if isWord {
                let vis = visibleCharacterRange
                let len = document.length
                let start = max(0, vis.location - 200)
                let end = min(len, NSMaxRange(vis) + 200)
                var search = NSRange(location: start, length: end - start)
                var found: [NSRange] = []
                while search.length > 0 && found.count < 1000 {
                    let r = text.range(of: needle, options: .literal, range: search)
                    if r.location == NSNotFound { break }
                    if !isWordChar(char(r.location - 1)) && !isWordChar(char(NSMaxRange(r))) && r != sel { found.append(r) }
                    let next = NSMaxRange(r)
                    search = NSRange(location: next, length: end - next)
                }
                occurrenceRanges = found
            }
        }
        if !old.isEmpty || !occurrenceRanges.isEmpty { setNeedsDisplay(visibleRect) }
    }
}
