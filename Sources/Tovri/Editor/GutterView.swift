import AppKit

/// Line-number gutter drawn alongside the text view's scroll view.
final class GutterView: NSView {
    weak var textView: EditorTextView?
    private var numberAttrs: [NSAttributedString.Key: Any] = [:]
    private var activeAttrs: [NSAttributedString.Key: Any] = [:]
    private var digitWidth: CGFloat = 7
    var showsNumbers = true
    private var hovering = false
    private static let foldColumn: CGFloat = 16

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !ThemeManager.shared.active.translucent }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Line numbers, fold arrows and change markers are drawn, and the text view already reports lines to VoiceOver.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }

    func updateStyle() {
        guard let tv = textView else { return }
        let theme = ThemeManager.shared.active
        let base = tv.document.font
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, base.pointSize - 1), weight: .regular)
        numberAttrs = [.font: font, .foregroundColor: theme.gutterForeground]
        activeAttrs = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(9, base.pointSize - 1), weight: .medium),
                       .foregroundColor: theme.gutterActiveForeground]
        digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        needsDisplay = true
    }

    var requiredWidth: CGFloat {
        guard showsNumbers, let tv = textView else { return 18 }
        let digits = max(3, String(tv.document.lines.count).count)
        return ceil(CGFloat(digits) * digitWidth + 22 + GutterView.foldColumn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        // Without line numbers the narrow gutter still shows bookmarks.
        guard let tv = textView, showsNumbers || !tv.document.bookmarks.isEmpty, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = tv.enclosingScrollView?.contentView else { return }
        let numbers = showsNumbers
        let bookmarks = tv.document.bookmarks
        let marking = !bookmarks.isEmpty
        let bookmarkColor = theme.accent

        let doc = tv.document
        let lines = doc.lines
        let length = doc.length
        let visible = clip.bounds
        let yOffset = tv.textContainerOrigin.y - visible.minY + (tv.frame.minY)
        var rect = visible
        rect.origin.y -= tv.textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var activeLines = Set<Int>()
        let sels = tv.allSelections
        if sels.count < 2000 {
            for r in sels {
                let a = lines.line(containing: r.location)
                let b = lines.line(containing: NSMaxRange(r))
                for l in a...min(b, a + 2000) { activeLines.insert(l) }
            }
        }

        let theme2 = theme
        let tlm = tv.tovriLayoutManager
        let right = bounds.width - GutterView.foldColumn - 4
        let folds = tlm.folds
        let chevronColor = theme.gutterForeground
        let editor = tv.editor
        let diff = editor?.lineDiff ?? LineDiff()
        let addedColor = theme.color(.inserted) ?? .systemGreen
        let modifiedColor = theme.color(.changed) ?? .systemOrange
        let deletedColor = theme.color(.deleted) ?? .systemRed
        let baselineShift = tlm.baseline
        let inline = editor?.inlineDiff
        let gaps = tlm.hasGaps
        let deletedTint = deletedColor.withAlphaComponent(theme.isDark ? 0.14 : 0.12)
        let insertedTint = addedColor.withAlphaComponent(theme.isDark ? 0.11 : 0.10)
        let lh = tlm.lineHeight
        let minusAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: max(9, tv.document.font.pointSize - 1), weight: .bold),
                                                         .foregroundColor: deletedColor]
        let minus = "−" as NSString
        let minusSize = minus.size(withAttributes: minusAttrs)
        func drawRemoved(top: CGFloat, height: CGFloat) {
            guard height > 0.5 else { return }
            deletedTint.setFill()
            NSRect(x: 0, y: top, width: bounds.width, height: height).fill()
            var row = top
            while row < top + height - 0.5 {
                minus.draw(at: NSPoint(x: 8 - minusSize.width / 2 + 1, y: row + (lh - minusSize.height) / 2), withAttributes: minusAttrs)
                row += lh
            }
        }

        var line = lines.line(containing: chars.location)
        let endChar = NSMaxRange(chars)
        while line < lines.count {
            let start = lines.start(of: line)
            if start > endChar && line > 0 { break }
            if !folds.isEmpty, let f = tlm.fold(hiding: start) {
                let next = lines.line(containing: NSMaxRange(f)) + 1
                line = max(line + 1, next)
                continue
            }
            var frag: NSRect
            var full: NSRect
            if start >= length {
                full = lm.extraLineFragmentRect
                if full.height == 0 { break }
                frag = gaps ? tlm.extraTextBand : full
            } else {
                let g = lm.glyphIndexForCharacter(at: start)
                full = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                frag = gaps ? tlm.textBand(forGlyphAt: g) : full
            }
            let y = frag.minY + yOffset
            if full.minY + yOffset > bounds.maxY { break }
            if gaps && numbers {
                drawRemoved(top: full.minY + yOffset, height: frag.minY - full.minY)
                if line == lines.count - 1 { drawRemoved(top: full.maxY + yOffset - tlm.trailingGapHeight, height: tlm.trailingGapHeight) }
            }
            if numbers, inline?.changed.contains(line) == true {
                insertedTint.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: frag.height).fill()
            }
            if y + frag.height >= dirtyRect.minY {
                if !numbers {
                    if bookmarks.contains(line) { drawBookmark(x: 5, y: y, height: frag.height, color: bookmarkColor) }
                    line += 1
                    continue
                }
                let isActive = activeLines.contains(line)
                if isActive && Settings.shared.highlightCurrentLine && sels.allSatisfy({ $0.length == 0 }) {
                    theme2.lineHighlight.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: frag.height).fill()
                }
                if !diff.isEmpty {
                    if let mark = diff.marks[line] {
                        (mark == .added ? addedColor : modifiedColor).setFill()
                        NSBezierPath(roundedRect: NSRect(x: 2, y: y + 1, width: 3, height: frag.height - 2), xRadius: 1.5, yRadius: 1.5).fill()
                    }
                    // Lines removed after the last line are marked below it. While comparing,
                    // the removed lines themselves are shown instead.
                    for top in inline != nil ? [] : [diff.deletions.contains(line) ? y : nil,
                                line == lines.count - 1 && diff.deletions.contains(lines.count) ? y + frag.height : nil].compactMap({ $0 }) {
                        deletedColor.setFill()
                        let tri = NSBezierPath()
                        tri.move(to: NSPoint(x: 1, y: top - 4))
                        tri.line(to: NSPoint(x: 7, y: top))
                        tri.line(to: NSPoint(x: 1, y: top + 4))
                        tri.close()
                        tri.fill()
                    }
                }
                if marking && bookmarks.contains(line) { drawBookmark(x: 7, y: y, height: frag.height, color: bookmarkColor) }
                let s = String(line + 1) as NSString
                let attrs = isActive ? activeAttrs : numberAttrs
                let font = attrs[.font] as! NSFont
                let w = s.size(withAttributes: attrs).width
                s.draw(at: NSPoint(x: right - w, y: y + baselineShift - font.ascender), withAttributes: attrs)
                let lineEnd = NSMaxRange(lines.range(of: line, textLength: length))
                let folded = !folds.isEmpty && folds.contains { $0.location == lineEnd }
                if folded || (hovering && editor?.isFoldable(line: line) == true) {
                    drawChevron(folded: folded, y: y, height: frag.height, color: folded ? theme2.accent : chevronColor)
                }
            }
            line += 1
        }
    }

    /// Top of a line's fragment in text container coordinates, or infinity past the end. The empty
    /// line after a final newline has no glyphs and lives in the extra line fragment.
    static func top(ofLine line: Int, in tv: EditorTextView) -> CGFloat {
        guard let lm = tv.layoutManager else { return .greatestFiniteMagnitude }
        let doc = tv.document
        guard line < doc.lines.count else { return .greatestFiniteMagnitude }
        let start = doc.lines.start(of: line)
        if start >= doc.length {
            if doc.length > 0 { lm.ensureLayout(forCharacterRange: NSRange(location: doc.length - 1, length: 1)) }
            let extra = lm.extraLineFragmentRect
            return extra.height > 0 ? extra.minY : .greatestFiniteMagnitude
        }
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil).minY
    }

    /// A ribbon with a notched end, left of the line number.
    private func drawBookmark(x: CGFloat, y: CGFloat, height: CGFloat, color: NSColor) {
        let h = min(12, max(6, height - 6))
        let w: CGFloat = 7
        let top = y + (height - h) / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: top))
        p.line(to: NSPoint(x: x + w, y: top))
        p.line(to: NSPoint(x: x + w, y: top + h))
        p.line(to: NSPoint(x: x + w / 2, y: top + h - 3))
        p.line(to: NSPoint(x: x, y: top + h))
        p.close()
        color.setFill()
        p.fill()
    }

    private func drawChevron(folded: Bool, y: CGFloat, height: CGFloat, color: NSColor) {
        let name = folded ? "chevron.right" : "chevron.down"
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: folded ? "Unfold" : "Fold")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [color]))) else { return }
        let s = img.size
        let x = bounds.width - GutterView.foldColumn + (GutterView.foldColumn - s.width) / 2 - 2
        img.draw(in: NSRect(x: x, y: y + (height - s.height) / 2, width: s.width, height: s.height))
    }

    private var ownTrackingArea: NSTrackingArea?


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only replace our own area: removing every tracking area also kills AppKit's tooltip tracking.
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let p = tv.convert(event.locationInWindow, from: nil)
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: p.y - tv.textContainerOrigin.y), in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        let doc = tv.document
        let startLine = doc.lines.line(containing: charIndex)
        let x = convert(event.locationInWindow, from: nil).x
        if x < 14, let editor = tv.editor {
            // A deletion marker straddles the boundary, so a click just above a line also counts.
            let nextTop = GutterView.top(ofLine: startLine + 1, in: tv)
            let below = editor.gitHunk(at: startLine + 1)
            if let hunk = (below?.isDeletion == true && nextTop - (p.y - tv.textContainerOrigin.y) < 5 ? below : nil) ?? editor.gitHunk(at: startLine) {
                editor.showGitChange(hunk, toggle: true)
                return
            }
        }
        if x >= bounds.width - GutterView.foldColumn - 2 {
            tv.editor?.toggleFold(line: startLine)
            return
        }
        let anchorRange = doc.lines.fullRange(of: startLine, textLength: doc.length)
        if event.modifierFlags.contains(.shift) {
            tv.setAllSelections([NSUnionRange(tv.selectedRange(), anchorRange)])
        } else {
            tv.setAllSelections([anchorRange], scroll: false)
        }
        tv.window?.makeFirstResponder(tv)
        while let next = tv.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            tv.autoscroll(with: next)
            let q = tv.convert(next.locationInWindow, from: nil)
            let g = lm.glyphIndex(for: NSPoint(x: 0, y: q.y - tv.textContainerOrigin.y), in: tc)
            let c = lm.characterIndexForGlyph(at: g)
            let l = doc.lines.fullRange(of: doc.lines.line(containing: c), textLength: doc.length)
            tv.setAllSelections([NSUnionRange(anchorRange, l)], scroll: false)
        }
    }
}
