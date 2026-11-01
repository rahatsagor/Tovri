import AppKit

/// Layout manager that enforces a uniform line height (so mixed fonts/emoji never make lines
/// jump) and draws invisible characters in a subtle color.
final class TovriLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var lineHeight: CGFloat = 18
    private(set) var baseline: CGFloat = 14
    var showInvisibles = false
    var invisiblesColor: NSColor = .tertiaryLabelColor
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) var foldPlaceholderWidth: CGFloat = 24

    /// Folded character ranges, sorted and non-overlapping. Each starts at the newline ending a
    /// visible line; that newline renders as the "⋯" placeholder and the rest is hidden.
    private(set) var folds: [NSRange] = []

    func setFoldsStorage(_ ranges: [NSRange]) { folds = ranges }

    func setFolds(_ ranges: [NSRange]) {
        let old = folds
        folds = ranges.sorted { $0.location < $1.location }
        var dirty = old + folds
        dirty.sort { $0.location < $1.location }
        guard let storage = textStorage else { return }
        let len = storage.length
        for r in dirty {
            let clamped = NSIntersectionRange(r, NSRange(location: 0, length: len))
            guard clamped.length > 0 else { continue }
            invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
    }

    /// The fold whose hidden part contains `index` (the placeholder position itself is visible).
    func fold(hiding index: Int) -> NSRange? {
        var lo = 0, hi = folds.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = folds[mid]
            if index <= f.location { hi = mid - 1 }
            else if index > NSMaxRange(f) { lo = mid + 1 }
            else { return f }
        }
        return nil
    }

    /// Binary searches: layout asks for every glyph, and Fold All can create thousands of folds.
    func fold(at index: Int) -> NSRange? {
        var lo = 0, hi = folds.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = folds[mid]
            if index < f.location { hi = mid - 1 }
            else if index >= NSMaxRange(f) { lo = mid + 1 }
            else { return f }
        }
        return nil
    }

    private func firstFold(endingAfter index: Int) -> NSRange? {
        var lo = 0, hi = folds.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(folds[mid]) > index { hi = mid } else { lo = mid + 1 }
        }
        return lo < folds.count ? folds[lo] : nil
    }

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
        usesFontLeading = false
        backgroundLayoutEnabled = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(font: NSFont, lineHeightMultiple: CGFloat) {
        self.font = font
        let ascent = font.ascender
        let descent = -font.descender
        let natural = ceil(ascent + descent + font.leading)
        lineHeight = max(natural, round(natural * lineHeightMultiple))
        baseline = round((lineHeight - (ascent + descent)) / 2 + ascent)
        foldPlaceholderWidth = ceil((" " as NSString).size(withAttributes: [.font: font]).width * 3.2)
        invisibleCache.removeAll()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = baseline
        if let gaps, let lines = gapLines, glyphRange.length > 0 {
            let char = characterIndexForGlyph(at: glyphRange.location)
            let line = lines.line(containing: char)
            let above = lines.start(of: line) == char ? gaps.above[line] ?? 0 : 0
            let below = gaps.trailing > 0 && line == lines.count - 1 && NSMaxRange(glyphRange) >= numberOfGlyphs ? gaps.trailing : 0
            if above + below > 0 {
                let a = CGFloat(above) * lineHeight
                lineFragmentRect.pointee.size.height += a + CGFloat(below) * lineHeight
                lineFragmentUsedRect.pointee.origin.y = lineFragmentRect.pointee.origin.y + a
                baselineOffset.pointee = baseline + a
            }
        }
        return true
    }

    // MARK: Gaps for removed lines

    /// Rows of space opened for lines removed since the last commit (Compare with Last Commit).
    struct Gaps: Equatable {
        /// Line → number of removed lines shown above it.
        var above: [Int: Int] = [:]
        /// Removed lines shown below the last line.
        var trailing = 0
        var isEmpty: Bool { above.isEmpty && trailing == 0 }
    }

    /// Nil unless comparing; layout then costs nothing extra.
    private(set) var gaps: Gaps?
    private var gapLines: LineIndex?
    var hasGaps: Bool { gaps != nil }

    /// Sets the gaps and relays out only the lines whose gaps changed.
    func setGaps(_ new: Gaps?, lines: LineIndex) {
        let new = new?.isEmpty == true ? nil : new
        guard new != gaps else { return }
        let old = gaps
        gaps = new
        gapLines = new == nil ? nil : lines
        guard let storage = textStorage else { return }
        let len = storage.length
        var affected = Set(old?.above.keys.map { $0 } ?? []).union(new?.above.keys.map { $0 } ?? [])
        if (old?.trailing ?? 0) != (new?.trailing ?? 0) { affected.insert(lines.count - 1) }
        for line in affected where line >= 0 {
            var r = lines.fullRange(of: min(line, lines.count - 1), textLength: len)
            // The empty line after a final newline has no characters; relaying out the last one updates it.
            if r.length == 0 { r = NSRange(location: max(0, len - 1), length: len > 0 ? 1 : 0) }
            guard r.length > 0 else { continue }
            invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        }
    }

    /// The text row of a line fragment, without the gaps opened above or below it.
    func textBand(forGlyphAt g: Int) -> NSRect {
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        guard gaps != nil else { return frag }
        let used = lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        return NSRect(x: frag.minX, y: used.minY, width: frag.width, height: min(lineHeight, frag.height))
    }

    var extraTextBand: NSRect {
        let frag = extraLineFragmentRect
        guard gaps != nil, frag.height > 0 else { return frag }
        return NSRect(x: frag.minX, y: extraLineFragmentUsedRect.minY, width: frag.width, height: min(lineHeight, frag.height))
    }

    /// Height of removed lines shown below the last line; the used rect doesn't include it.
    var trailingGapHeight: CGFloat { CGFloat(gaps?.trailing ?? 0) * lineHeight }

    /// Shrinks a highlight that lies within one line fragment to that fragment's text row.
    /// Taller highlights span several lines and keep the gaps between them.
    func trimmedToText(_ r: NSRect, origin o: NSPoint) -> NSRect {
        guard gaps != nil, let tc = textContainers.first, numberOfGlyphs > 0 else { return r }
        let g = glyphIndex(for: NSPoint(x: max(0, r.minX - o.x), y: r.midY - o.y), in: tc)
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil).offsetBy(dx: o.x, dy: o.y)
        guard frag.height > lineHeight + 0.5, r.minY >= frag.minY - 0.5, r.maxY <= frag.maxY + 0.5 else { return r }
        let band = textBand(forGlyphAt: g).offsetBy(dx: o.x, dy: o.y)
        return NSRect(x: r.minX, y: band.minY, width: r.width, height: band.height)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard gaps != nil, let tv = firstTextView, rectCount > 0 else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let o = tv.textContainerOrigin
        let rects = (0..<rectCount).map { trimmedToText(rectArray[$0], origin: o) }
        rects.withUnsafeBufferPointer { super.fillBackgroundRectArray($0.baseAddress!, count: rectCount, forCharacterRange: charRange, color: color) }
    }

    // MARK: Folding

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folds.isEmpty, glyphRange.length > 0 else { return 0 }
        let first = charIndexes[0]
        let last = charIndexes[glyphRange.length - 1]
        guard let f = firstFold(endingAfter: first), f.location <= last else { return 0 }
        var newProps = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: props, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let c = charIndexes[i]
            guard let f = fold(at: c) else { continue }
            newProps[i] = c == f.location ? .controlCharacter : .null
        }
        newProps.withUnsafeBufferPointer { p in
            layoutManager.setGlyphs(glyphs, properties: p.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let f = fold(at: charIndex) else { return action }
        return charIndex == f.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: glyphPosition.x, y: 0, width: foldPlaceholderWidth, height: proposedRect.height)
    }

    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        var f = fragmentRect
        var u = usedRect
        f.size.height = lineHeight
        u.size.height = lineHeight
        if let gaps, let lines = gapLines, let storage = textStorage,
           storage.length == 0 || storage.mutableString.character(at: storage.length - 1) == 10 {
            let above = gaps.above[lines.count - 1] ?? 0
            let a = CGFloat(above) * lineHeight
            f.size.height += a + CGFloat(gaps.trailing) * lineHeight
            u.origin.y = f.origin.y + a
        }
        super.setExtraLineFragmentRect(f, usedRect: u, textContainer: container)
    }

    private var invisibleCache: [UInt16: NSAttributedString] = [:]

    private func invisible(_ c: UInt16) -> NSAttributedString {
        if let s = invisibleCache[c] { return s }
        let glyph: String
        switch c {
        case 9: glyph = "→"
        case 10: glyph = "¬"
        default: glyph = "·"
        }
        let s = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: invisiblesColor])
        invisibleCache[c] = s
        return s
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if showInvisibles, let storage = textStorage {
            let chars = storage.mutableString
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let end = NSMaxRange(charRange)
            var i = charRange.location
            while i < end {
                let c = chars.character(at: i)
                if c == 32 || c == 9 || c == 10 {
                    let g = glyphIndexForCharacter(at: i)
                    let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true)
                    let loc = location(forGlyphAt: g)
                    let s = invisible(c)
                    let p = NSPoint(x: origin.x + frag.minX + loc.x, y: origin.y + frag.minY + baseline - font.ascender)
                    s.draw(at: p)
                }
                i += 1
            }
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }
}
