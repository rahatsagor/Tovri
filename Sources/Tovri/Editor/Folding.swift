import AppKit

/// Indentation-based code folding. Folds live in the view's layout manager, so each view of a
/// shared document folds independently.
extension EditorView {
    private var foldLines: LineIndex { document.lines }

    private func indentColumns(_ line: Int) -> Int? {
        let s = document.string
        let r = foldLines.range(of: line, textLength: document.length)
        var cols = 0
        var i = r.location
        let tab = document.indentWidth
        while i < NSMaxRange(r) {
            let c = s.character(at: i)
            if c == 32 { cols += 1 } else if c == 9 { cols += tab - cols % tab } else { return cols }
            i += 1
        }
        return nil
    }

    /// Range that folding `line` would hide, or nil if the line has no indented body.
    func foldableRange(forLine line: Int) -> NSRange? {
        guard line < foldLines.count - 1, let base = indentColumns(line) else { return nil }
        var last = line
        var k = line + 1
        let limit = min(foldLines.count, line + 200_000)
        while k < limit {
            if let ind = indentColumns(k) {
                if ind > base { last = k } else { break }
            }
            k += 1
        }
        guard last > line else { return nil }
        let len = document.length
        let start = NSMaxRange(foldLines.range(of: line, textLength: len))
        var end = NSMaxRange(foldLines.range(of: last, textLength: len))
        if k < foldLines.count, indentColumns(k) == base {
            let closer = foldLines.range(of: k, textLength: len)
            let ws = (indentColumns(k).map { _ in leadingWhitespaceCount(closer) }) ?? 0
            let first = document.string.character(at: closer.location + ws)
            if first == 125 || first == 93 || first == 41 { end = closer.location + ws }
        }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private func leadingWhitespaceCount(_ r: NSRange) -> Int {
        let s = document.string
        var i = r.location
        while i < NSMaxRange(r), isSpaceU(s.character(at: i)) { i += 1 }
        return i - r.location
    }

    var folds: [NSRange] { layoutManager.folds }

    func isFoldable(line: Int) -> Bool {
        guard let base = indentColumns(line) else { return false }
        var k = line + 1
        while k < foldLines.count && k < line + 50 {
            if let ind = indentColumns(k) { return ind > base }
            k += 1
        }
        return false
    }

    func fold(line: Int) {
        guard let r = foldableRange(forLine: line) else { return }
        var fs = folds.filter { NSIntersectionRange($0, r).length == 0 && $0.location != r.location }
        fs.append(r)
        let sel = textView.selectedRange()
        if NSMaxRange(sel) > r.location && sel.location <= NSMaxRange(r) {
            textView.setAllSelections([NSRange(location: r.location, length: 0)], scroll: false)
        }
        applyFolds(fs)
    }

    func unfold(_ r: NSRange) {
        applyFolds(folds.filter { $0 != r })
    }

    func toggleFold(line: Int) {
        let end = NSMaxRange(foldLines.range(of: line, textLength: document.length))
        if let f = folds.first(where: { $0.location == end }) { unfold(f) } else { fold(line: line) }
    }

    func unfoldAll() { applyFolds([]) }

    func foldAll() {
        var fs: [NSRange] = []
        var line = 0
        let count = foldLines.count
        while line < count {
            if indentColumns(line) == 0, let r = foldableRange(forLine: line) {
                fs.append(r)
                line = foldLines.line(containing: NSMaxRange(r)) + 1
            } else {
                line += 1
            }
            if fs.count > 20_000 { break }
        }
        applyFolds(fs)
    }

    /// Fold at the caret: the caret line if it has a body, otherwise the enclosing block.
    func foldAtCaret() {
        var caret = textView.selectedRange().location
        // Right after the "⋯" the caret is on the folded line, not the line the fold ends on.
        if let f = layoutManager.fold(hiding: caret) { caret = f.location }
        var line = foldLines.line(containing: caret)
        if foldableRange(forLine: line) == nil {
            let own = indentColumns(line) ?? Int.max
            var k = line - 1
            while k >= 0 {
                if let ind = indentColumns(k), ind < own { break }
                k -= 1
            }
            guard k >= 0 else { NSSound.beep(); return }
            line = k
        }
        fold(line: line)
    }

    func unfoldAtCaret() {
        let caret = textView.selectedRange().location
        let lr = foldLines.fullRange(of: foldLines.line(containing: caret), textLength: document.length)
        let hits = folds.filter { NSLocationInRange($0.location, lr) || ($0.location <= caret && caret <= NSMaxRange($0)) }
        if hits.isEmpty { NSSound.beep(); return }
        applyFolds(folds.filter { f in !hits.contains(f) })
    }

    func applyFolds(_ fs: [NSRange]) {
        let len = document.length
        layoutManager.setFolds(fs.filter { $0.length > 0 && NSMaxRange($0) <= len })
        textView.sizeToFit()
        textView.needsDisplay = true
        gutter.needsDisplay = true
        colorizeVisible()
    }

    /// Keeps folds aligned with edits: folds after the edit shift, folds touching it open.
    func adjustFolds(editedRange: NSRange, delta: Int) {
        guard !folds.isEmpty else { return }
        let oldEnd = editedRange.location + editedRange.length - delta
        var changed = false
        var out: [NSRange] = []
        for f in folds {
            if NSMaxRange(f) < editedRange.location {
                out.append(f)
            } else if f.location > oldEnd {
                out.append(NSRange(location: f.location + delta, length: f.length))
                changed = true
            } else {
                changed = true
            }
        }
        if changed {
            // Applies whatever folds exist by then, so folds re-added right after the edit
            // (moving or duplicating a folded line) survive.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyFolds(self.folds)
            }
            layoutManager.setFoldsSilently(out)
        }
    }

    /// Opens any fold hiding the given range so navigation never lands in hidden text. Both ends
    /// of a fold are visible caret positions: before and after the "⋯" placeholder.
    func revealFolds(containing range: NSRange) {
        guard !folds.isEmpty else { return }
        let hits = folds.filter { f in
            (range.location > f.location && range.location < NSMaxRange(f)) ||
            (NSMaxRange(range) > f.location && NSMaxRange(range) < NSMaxRange(f) && range.length > 0)
        }
        if !hits.isEmpty { applyFolds(folds.filter { !hits.contains($0) }) }
    }
}

extension TovriLayoutManager {
    /// Updates fold bookkeeping without invalidating layout (the text storage edit already did).
    func setFoldsSilently(_ ranges: [NSRange]) {
        setFoldsStorage(ranges.sorted { $0.location < $1.location })
    }
}

extension EditorTextView {
    @objc func foldCommand(_ sender: Any?) { editor?.foldAtCaret() }
    @objc func unfoldCommand(_ sender: Any?) { editor?.unfoldAtCaret() }
    @objc func foldAllCommand(_ sender: Any?) { editor?.foldAll() }
    @objc func unfoldAllCommand(_ sender: Any?) { editor?.unfoldAll() }

    func foldPlaceholderRect(_ fold: NSRange) -> NSRect {
        let caret = caretRect(at: fold.location)
        let w = tovriLayoutManager.foldPlaceholderWidth
        return NSRect(x: caret.minX + 2, y: caret.minY + 3, width: w - 4, height: max(8, caret.height - 6))
    }

    func drawFoldPlaceholders(in rect: NSRect) {
        let folds = tovriLayoutManager.folds
        guard !folds.isEmpty else { return }
        let theme = ThemeManager.shared.active
        let vis = visibleCharacterRange
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(9, document.font.pointSize - 2), weight: .bold),
                                                    .foregroundColor: theme.chromeSecondary]
        for f in folds where f.location >= vis.location - 1 && f.location <= NSMaxRange(vis) {
            let r = foldPlaceholderRect(f)
            guard r.intersects(rect) else { continue }
            theme.foreground.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let s = "⋯" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }

    func foldPlaceholder(at point: NSPoint) -> NSRange? {
        tovriLayoutManager.folds.first { foldPlaceholderRect($0).insetBy(dx: -2, dy: -2).contains(point) }
    }
}
