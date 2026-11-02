import AppKit

extension EditorTextView {
    private var len: Int { document.length }
    private var lines: LineIndex { document.lines }

    /// Full lines covered by `range`. A folded block counts as part of the line it is folded into,
    /// so the result also covers the hidden lines and the line the fold ends on.
    func visualLineBlock(_ range: NSRange) -> NSRange {
        let firstLine = lines.line(containing: range.location)
        var endLoc = NSMaxRange(range)
        if range.length > 0 && char(endLoc - 1) == 10 { endLoc -= 1 }
        let lastLine = lines.line(containing: max(endLoc, range.location))
        var start = lines.start(of: firstLine)
        var end = NSMaxRange(lines.fullRange(of: lastLine, textLength: len))
        let tlm = tovriLayoutManager
        guard !tlm.folds.isEmpty else { return NSRange(location: start, length: end - start) }
        while start > 0, let f = tlm.fold(hiding: start) {
            start = lines.start(of: lines.line(containing: f.location))
        }
        while true {
            let lineEnd = end > start && char(end - 1) == 10 ? end - 1 : end
            guard let f = tlm.fold(at: lineEnd), f.location == lineEnd else { break }
            end = NSMaxRange(lines.fullRange(of: lines.line(containing: NSMaxRange(f)), textLength: len))
        }
        return NSRange(location: start, length: end - start)
    }

    /// Folds inside `range`, as offsets from its start.
    private func folds(inside range: NSRange) -> [NSRange] {
        tovriLayoutManager.folds.compactMap { f in
            f.location >= range.location && NSMaxRange(f) <= NSMaxRange(range)
                ? NSRange(location: f.location - range.location, length: f.length) : nil
        }
    }

    /// Full-line ranges covered by all selections, merged into contiguous blocks.
    func selectedLineBlocks() -> [NSRange] {
        var blocks: [NSRange] = []
        for r in allSelections {
            let block = visualLineBlock(r)
            if let last = blocks.last, block.location <= NSMaxRange(last) {
                blocks[blocks.count - 1] = NSUnionRange(last, block)
            } else {
                blocks.append(block)
            }
        }
        return blocks
    }

    private func lineNumbers(in block: NSRange) -> ClosedRange<Int> {
        let a = lines.line(containing: block.location)
        var endLoc = NSMaxRange(block)
        if block.length > 0 && char(endLoc - 1) == 10 { endLoc -= 1 }
        let b = lines.line(containing: max(endLoc, block.location))
        return a...max(a, b)
    }

    private func leadingWhitespaceLength(_ r: NSRange) -> Int {
        var i = r.location
        while i < NSMaxRange(r) && isSpaceU(char(i)) { i += 1 }
        return i - r.location
    }

    // MARK: Indentation

    @objc func indentLines(_ sender: Any?) {
        var edits: [TextEdit] = []
        for block in selectedLineBlocks() {
            for line in lineNumbers(in: block) {
                let r = lines.range(of: line, textLength: len)
                if r.length == 0 && lineNumbers(in: block).count > 1 { continue }
                edits.append(TextEdit(NSRange(location: r.location, length: 0), indentUnit))
            }
        }
        performEdits(edits, selection: .preserve, actionName: "Indent", keepFolds: true)
    }

    @objc func outdentLines(_ sender: Any?) {
        var edits: [TextEdit] = []
        let w = document.indentWidth
        for block in selectedLineBlocks() {
            for line in lineNumbers(in: block) {
                let r = lines.range(of: line, textLength: len)
                if r.length == 0 { continue }
                if char(r.location) == 9 {
                    edits.append(TextEdit(NSRange(location: r.location, length: 1), ""))
                } else {
                    var n = 0
                    while n < w && n < r.length && char(r.location + n) == 32 { n += 1 }
                    if n > 0 { edits.append(TextEdit(NSRange(location: r.location, length: n), "")) }
                }
            }
        }
        performEdits(edits, selection: .preserve, actionName: "Outdent", keepFolds: true)
    }

    // MARK: Comments

    @objc func toggleComment(_ sender: Any?) {
        let blocks = selectedLineBlocks()
        var lineRanges: [NSRange] = []
        for b in blocks { for l in lineNumbers(in: b) { lineRanges.append(lines.range(of: l, textLength: len)) } }
        let edits: [TextEdit]
        if let token = language.primaryLineComment {
            edits = lineCommentEdits(token, lineRanges)
        } else if let (open, close) = language.primaryBlockComment {
            guard let e = blockCommentEdits(open, close, blocks) else { toggleBlockComment(sender); return }
            edits = e
        } else {
            NSSound.beep()
            return
        }
        performEdits(edits, selection: .preserve, actionName: "Toggle Comment", keepFolds: true)
        if allSelections.count == 1 && selectedRange().length == 0 && blocks.count == 1 && lineNumbers(in: blocks[0]).count == 1 && sender is NSMenuItem {
            moveDown(nil)
        }
    }

    private func lineCommentEdits(_ token: String, _ lineRanges: [NSRange]) -> [TextEdit] {
        let nonBlank = lineRanges.filter { leadingWhitespaceLength($0) < $0.length }
        let targets = nonBlank.isEmpty ? lineRanges : nonBlank
        let tokenLen = token.utf16.count
        let allCommented = !nonBlank.isEmpty && nonBlank.allSatisfy { r in
            let ws = leadingWhitespaceLength(r)
            return r.length - ws >= tokenLen && text.substring(with: NSRange(location: r.location + ws, length: tokenLen)) == token
        }
        var edits: [TextEdit] = []
        if allCommented {
            for r in nonBlank {
                let ws = leadingWhitespaceLength(r)
                var remove = tokenLen
                if r.location + ws + tokenLen < NSMaxRange(r) && char(r.location + ws + tokenLen) == 32 { remove += 1 }
                edits.append(TextEdit(NSRange(location: r.location + ws, length: remove), ""))
            }
        } else {
            let minIndent = targets.map { leadingWhitespaceLength($0) }.min() ?? 0
            for r in targets {
                edits.append(TextEdit(NSRange(location: r.location + min(minIndent, r.length), length: 0), token + " "))
            }
        }
        return edits
    }

    /// The text of a line without its leading and trailing whitespace.
    private func lineContent(_ r: NSRange) -> NSRange {
        let a = r.location + leadingWhitespaceLength(r)
        var b = NSMaxRange(r)
        while b > a && isSpaceU(char(b - 1)) { b -= 1 }
        return NSRange(location: a, length: b - a)
    }

    private func hasText(_ s: String, at loc: Int) -> Bool {
        let n = s.utf16.count
        return loc >= 0 && loc + n <= len && text.substring(with: NSRange(location: loc, length: n)) == s
    }

    /// Edits removing `open` at the start of `content` and `close` at its end, each with the space
    /// next to it.
    private func unwrapEdits(_ open: String, _ close: String, first: NSRange, last: NSRange) -> [TextEdit] {
        let o = open.utf16.count, c = close.utf16.count
        let openSpace = char(first.location + o) == 32 && first.location + o < NSMaxRange(last) - c ? 1 : 0
        let closeSpace = char(NSMaxRange(last) - c - 1) == 32 && NSMaxRange(last) - c - 1 >= first.location + o + openSpace ? 1 : 0
        return [TextEdit(NSRange(location: first.location, length: o + openSpace), ""),
                TextEdit(NSRange(location: NSMaxRange(last) - c - closeSpace, length: c + closeSpace), "")]
    }

    /// Toggle Comment for languages that only have block comments (CSS, HTML): every line is
    /// wrapped on its own. Lines commented as one block are uncommented as a block. Nil when all
    /// lines are blank.
    private func blockCommentEdits(_ open: String, _ close: String, _ blocks: [NSRange]) -> [TextEdit]? {
        let o = open.utf16.count, c = close.utf16.count
        let perBlock = blocks.map { b in lineNumbers(in: b).map { lineContent(lines.range(of: $0, textLength: len)) }.filter { $0.length > 0 } }
        let contents = perBlock.flatMap { $0 }
        guard !contents.isEmpty else { return nil }
        func isWrapped(_ r: NSRange) -> Bool { r.length >= o + c && hasText(open, at: r.location) && hasText(close, at: NSMaxRange(r) - c) }
        if contents.allSatisfy(isWrapped) {
            return contents.flatMap { unwrapEdits(open, close, first: $0, last: $0) }
        }
        let blockWrapped = perBlock.allSatisfy { ls in
            guard let first = ls.first, let last = ls.last, ls.count > 1 else { return ls.isEmpty }
            return first.length >= o && hasText(open, at: first.location) && last.length >= c && hasText(close, at: NSMaxRange(last) - c)
        }
        if blockWrapped {
            return perBlock.flatMap { ls -> [TextEdit] in
                guard let first = ls.first, let last = ls.last else { return [] }
                return unwrapEdits(open, close, first: first, last: last)
            }
        }
        return contents.filter { !isWrapped($0) }.flatMap { r in
            [TextEdit(NSRange(location: r.location, length: 0), open + " "), TextEdit(NSRange(location: NSMaxRange(r), length: 0), " " + close)]
        }
    }

    @objc func toggleBlockComment(_ sender: Any?) {
        guard let (open, close) = language.primaryBlockComment ?? language.primaryLineComment.map({ ($0, "") }) else { NSSound.beep(); return }
        let o = open.utf16.count, c = close.utf16.count
        let isBlank: (UInt16) -> Bool = { isSpaceU($0) || $0 == 10 }
        var edits: [TextEdit] = []
        for r0 in allSelections {
            let r = r0.length == 0 ? lineRange(at: r0.location) : r0
            var a = r.location, b = NSMaxRange(r)
            while a < b && isBlank(char(a)) { a += 1 }
            while b > a && isBlank(char(b - 1)) { b -= 1 }
            let caret: Int? = r0.length == 0 ? r0.location : nil
            if a == b {
                let s = close.isEmpty ? open + " " : open + "  " + close
                edits.append(TextEdit(NSRange(location: caret ?? r.location, length: 0), s, selection: NSRange(location: o + 1, length: 0)))
                continue
            }
            // A full-line selection ends with its newline; the comment closes before it.
            let content = NSRange(location: a, length: b - a)
            let n = content.length
            if n >= o + c && hasText(open, at: a) && (c == 0 || hasText(close, at: b - c)) {
                var lead = o, trail = c
                if n > o + c && char(a + o) == 32 { lead += 1 }
                if c > 0 && n > lead + c && char(b - c - 1) == 32 { trail += 1 }
                let inner = text.substring(with: NSRange(location: a + lead, length: n - lead - trail))
                let il = inner.utf16.count
                let sel = caret.map { NSRange(location: min(max(0, $0 - a - lead), il), length: 0) } ?? NSRange(location: 0, length: il)
                edits.append(TextEdit(content, inner, selection: sel))
            } else {
                let s = text.substring(with: content)
                let wrapped = close.isEmpty ? open + " " + s : open + " " + s + " " + close
                let sel = caret.map { NSRange(location: min(max(0, $0 - a), n) + o + 1, length: 0) } ?? NSRange(location: 0, length: wrapped.utf16.count)
                edits.append(TextEdit(content, wrapped, selection: sel))
            }
        }
        performEdits(edits, actionName: "Toggle Block Comment")
    }

    // MARK: Line operations

    @objc func duplicateLine(_ sender: Any?) {
        var edits: [TextEdit] = []
        var newSels: [NSRange] = []
        var copiedFolds: [NSRange] = []
        var delta = 0
        for r in allSelections {
            if r.length > 0 {
                let s = text.substring(with: r)
                edits.append(TextEdit(NSRange(location: NSMaxRange(r), length: 0), s))
                newSels.append(NSRange(location: NSMaxRange(r) + delta, length: s.utf16.count))
                delta += s.utf16.count
            } else {
                let full = visualLineBlock(NSRange(location: r.location, length: 0))
                var s = text.substring(with: full)
                let insertAt = NSMaxRange(full)
                if !s.hasSuffix("\n") { s = "\n" + s }
                edits.append(TextEdit(NSRange(location: insertAt, length: 0), s))
                let offset = r.location - full.location
                let newLineStart = s.hasPrefix("\n") && !text.substring(with: full).hasSuffix("\n") ? insertAt + 1 : insertAt
                newSels.append(NSRange(location: newLineStart + offset + delta, length: 0))
                copiedFolds += folds(inside: full).map { NSRange(location: newLineStart + delta + $0.location, length: $0.length) }
                delta += s.utf16.count
            }
        }
        var seen = Set<Int>()
        let unique = edits.filter { seen.insert($0.range.location).inserted }
        // newSels assumes edits land in selection order; a caret whose line ends after a later
        // selection breaks that, and so do shared insertion points.
        let locations = edits.map(\.range.location)
        if unique.count != edits.count || locations != locations.sorted() { return duplicateBlocks() }
        performEdits(edits, selection: .custom(newSels), actionName: "Duplicate", keepFolds: true, addedFolds: copiedFolds)
    }

    private func duplicateBlocks() {
        var copiedFolds: [NSRange] = []
        var delta = 0
        let edits = selectedLineBlocks().map { b -> TextEdit in
            var s = text.substring(with: b)
            let newLineStart = NSMaxRange(b) + delta + (s.hasSuffix("\n") ? 0 : 1)
            if !s.hasSuffix("\n") { s = "\n" + s }
            copiedFolds += folds(inside: b).map { NSRange(location: newLineStart + $0.location, length: $0.length) }
            delta += s.utf16.count
            return TextEdit(NSRange(location: NSMaxRange(b), length: 0), s)
        }
        performEdits(edits, selection: .preserve, actionName: "Duplicate", keepFolds: true, addedFolds: copiedFolds)
    }

    @objc func deleteLine(_ sender: Any?) {
        var edits: [TextEdit] = []
        for b in selectedLineBlocks() {
            var r = b
            if NSMaxRange(r) == len && r.location > 0 && (r.length == 0 || char(NSMaxRange(r) - 1) != 10) {
                r = NSRange(location: r.location - 1, length: r.length + 1)
            }
            edits.append(TextEdit(r, "", selection: NSRange(location: 0, length: 0)))
        }
        performEdits(edits, actionName: "Delete Line")
        // One caret per deleted block, each at the first character of the line it lands on.
        let carets = allSelections.map { s -> NSRange in
            let r = lineRange(at: s.location)
            return NSRange(location: r.location + leadingWhitespaceLength(r), length: 0)
        }
        setAllSelections(carets, primaryLocation: carets.last?.location)
    }

    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let blocks = selectedLineBlocks()
        guard !blocks.isEmpty else { return }
        if up && blocks[0].location == 0 { return }
        if !up && NSMaxRange(blocks[blocks.count - 1]) >= len { return }
        var edits: [TextEdit] = []
        var shifts: [(NSRange, Int)] = []
        // Swapping keeps the length of the text, so moved folds only move within their edit.
        var movedFolds: [NSRange] = []
        for b in blocks {
            var bText = text.substring(with: b)
            if up {
                let p = visualLineBlock(NSRange(location: b.location - 1, length: 0))
                var pText = text.substring(with: p)
                if !bText.hasSuffix("\n") { bText += "\n"; pText = String(pText.dropLast()) }
                edits.append(TextEdit(NSRange(location: p.location, length: p.length + b.length), bText + pText))
                shifts.append((b, -p.length))
                movedFolds += folds(inside: b).map { NSRange(location: p.location + $0.location, length: $0.length) }
                movedFolds += folds(inside: p).map { NSRange(location: p.location + bText.utf16.count + $0.location, length: $0.length) }
            } else {
                let n = visualLineBlock(NSRange(location: NSMaxRange(b), length: 0))
                var nText = text.substring(with: n)
                if !nText.hasSuffix("\n") { nText += "\n"; bText = String(bText.dropLast()) }
                edits.append(TextEdit(NSRange(location: b.location, length: b.length + n.length), nText + bText))
                shifts.append((b, nText.utf16.count))
                movedFolds += folds(inside: n).map { NSRange(location: b.location + $0.location, length: $0.length) }
                movedFolds += folds(inside: b).map { NSRange(location: b.location + nText.utf16.count + $0.location, length: $0.length) }
            }
        }
        let sels = allSelections.map { r -> NSRange in
            for (b, shift) in shifts where NSLocationInRange(r.location, b) || r.location == NSMaxRange(b) && r.location == len {
                return NSRange(location: r.location + shift, length: r.length)
            }
            return r
        }
        performEdits(edits, selection: .custom(sels), actionName: up ? "Move Line Up" : "Move Line Down", keepFolds: true, addedFolds: movedFolds)
    }

    @objc func joinLines(_ sender: Any?) {
        var edits: [TextEdit] = []
        for r in allSelections {
            let first = lines.line(containing: r.location)
            var last = lines.line(containing: NSMaxRange(r))
            if last == first { last = first + 1 }
            guard last < lines.count else { continue }
            for l in first..<last {
                let cur = lines.range(of: l, textLength: len)
                let next = lines.range(of: l + 1, textLength: len)
                var a = NSMaxRange(cur)
                while a > cur.location && isSpaceU(char(a - 1)) { a -= 1 }
                let b = next.location + leadingWhitespaceLength(next)
                let joiner = (a == cur.location || b == NSMaxRange(next)) ? "" : " "
                edits.append(TextEdit(NSRange(location: a, length: b - a), joiner))
            }
        }
        performEdits(edits, selection: .preserve, actionName: "Join Lines")
    }

    @objc func insertLineAfter(_ sender: Any?) {
        let edits = allSelections.map { r -> TextEdit in
            let lr = lineRange(at: NSMaxRange(r))
            let indent = leadingWhitespace(ofLineAt: lr.location)
            return TextEdit(NSRange(location: NSMaxRange(lr), length: 0), "\n" + indent)
        }
        performEdits(edits, actionName: "Insert Line")
    }

    @objc func insertLineBefore(_ sender: Any?) {
        let edits = allSelections.map { r -> TextEdit in
            let lr = lineRange(at: r.location)
            let indent = leadingWhitespace(ofLineAt: lr.location)
            return TextEdit(NSRange(location: lr.location, length: 0), indent + "\n", selection: NSRange(location: indent.utf16.count, length: 0))
        }
        performEdits(edits, actionName: "Insert Line")
    }

    // MARK: Selection

    @objc func selectLineCommand(_ sender: Any?) {
        let sels = allSelections.map { r -> NSRange in
            let full = fullLineRange(at: r.location)
            let endFull = fullLineRange(at: max(r.location, NSMaxRange(r) - (r.length > 0 ? 1 : 0)))
            var u = NSUnionRange(full, endFull)
            if u == r, NSMaxRange(u) < len { u = NSUnionRange(u, fullLineRange(at: NSMaxRange(u))) }
            return u
        }
        setAllSelections(sels)
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        let sels = allSelections
        let primary = selectedRange()
        if primary.length == 0 {
            let words = sels.map { r in r.length == 0 ? (wordRange(at: r.location) ?? r) : r }
            if let w = wordRange(at: primary.location) { wholeWordNeedle = text.substring(with: w) }
            let keep = wholeWordNeedle
            setAllSelections(words, primaryLocation: wordRange(at: primary.location)?.location)
            wholeWordNeedle = keep
            return
        }
        let needle = text.substring(with: primary)
        let whole = wholeWordNeedle == needle
        let keep = wholeWordNeedle
        guard let found = findOccurrence(of: needle, after: NSMaxRange(sels.last ?? primary), wholeWord: whole, excluding: sels) else {
            NSSound.beep()
            return
        }
        setAllSelections(sels + [found], primaryLocation: found.location)
        wholeWordNeedle = keep
    }

    private func findOccurrence(of needle: String, after start: Int, wholeWord: Bool, excluding: [NSRange]) -> NSRange? {
        var from = min(start, len)
        var wrapped = false
        while true {
            let searchRange = wrapped ? NSRange(location: from, length: max(0, start - from)) : NSRange(location: from, length: len - from)
            if searchRange.length <= 0 {
                if wrapped { return nil }
                wrapped = true
                from = 0
                continue
            }
            let r = text.range(of: needle, options: .literal, range: searchRange)
            if r.location == NSNotFound {
                if wrapped { return nil }
                wrapped = true
                from = 0
                continue
            }
            let okWord = !wholeWord || (!isWordChar(char(r.location - 1)) && !isWordChar(char(NSMaxRange(r))))
            if okWord && !excluding.contains(where: { $0 == r }) { return r }
            from = NSMaxRange(r)
        }
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        var primary = selectedRange()
        var whole = wholeWordNeedle != nil
        if primary.length == 0 {
            guard let w = wordRange(at: primary.location) else { NSSound.beep(); return }
            primary = w
            whole = true
        }
        let needle = text.substring(with: primary)
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: len)
        while search.length > 0 && found.count < 20_000 {
            let r = text.range(of: needle, options: .literal, range: search)
            if r.location == NSNotFound { break }
            if !whole || (!isWordChar(char(r.location - 1)) && !isWordChar(char(NSMaxRange(r)))) { found.append(r) }
            search = NSRange(location: NSMaxRange(r), length: len - NSMaxRange(r))
        }
        if !found.isEmpty { setAllSelections(found, primaryLocation: primary.location) }
    }

    @objc func splitSelectionIntoLines(_ sender: Any?) {
        var out: [NSRange] = []
        for r in allSelections {
            let first = lines.line(containing: r.location)
            let last = lines.line(containing: NSMaxRange(r))
            if first == last { out.append(r); continue }
            for l in first...last {
                let lr = lines.range(of: l, textLength: len)
                let a = max(lr.location, r.location)
                let b = min(NSMaxRange(lr), NSMaxRange(r))
                if b >= a && !(l == last && b == a && a == lr.location && l != first) { out.append(NSRange(location: b, length: 0)) }
            }
        }
        setAllSelections(out)
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(offset: -1) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(offset: 1) }

    private func addCaret(offset: Int) {
        let sels = allSelections
        guard let ref = offset < 0 ? sels.first : sels.last else { return }
        let caret = ref.length == 0 ? ref.location : (offset < 0 ? ref.location : NSMaxRange(ref))
        let line = lines.line(containing: caret)
        let target = line + offset
        guard target >= 0 && target < lines.count else { return }
        let start = lines.start(of: line)
        let col = caretGoalColumn ?? visualColumn(of: caret, lineStart: start)
        let tr = lines.range(of: target, textLength: len)
        var i = tr.location
        var c = 0
        while i < NSMaxRange(tr) && c < col {
            if char(i) == 9 { c += document.indentWidth - c % document.indentWidth } else { c += 1 }
            i += 1
        }
        setAllSelections(sels + [NSRange(location: i, length: 0)], primaryLocation: i)
        caretGoalColumn = col
    }

    @objc func singleSelection(_ sender: Any?) {
        setAllSelections([selectedRange()])
    }

    @objc func jumpToMatchingBracket(_ sender: Any?) {
        let loc = selectedRange().location
        let isBracket: (UInt16) -> Bool = { [40, 41, 91, 93, 123, 125].contains($0) }
        if isBracket(char(loc)), let m = matchingBracket(at: loc) {
            setAllSelections([NSRange(location: char(m) == 41 || char(m) == 93 || char(m) == 125 ? m + 1 : m, length: 0)])
        } else if loc > 0, isBracket(char(loc - 1)), let m = matchingBracket(at: loc - 1) {
            setAllSelections([NSRange(location: m, length: 0)])
        } else if let (open, _) = enclosingBrackets(around: loc) {
            setAllSelections([NSRange(location: open, length: 0)])
        }
    }

    func enclosingBrackets(around loc: Int) -> (Int, Int)? {
        var depth = [0, 0, 0]
        var i = loc - 1
        let limit = max(0, loc - 400_000)
        while i >= limit {
            let c = char(i)
            switch c {
            case 41: depth[0] += 1
            case 93: depth[1] += 1
            case 125: depth[2] += 1
            case 40, 91, 123:
                let k = c == 40 ? 0 : (c == 91 ? 1 : 2)
                if depth[k] == 0 {
                    if let m = matchingBracket(at: i), m >= loc - 1 { return (i, m) }
                } else { depth[k] -= 1 }
            default: break
            }
            i -= 1
        }
        return nil
    }

    @objc func expandSelectionToBrackets(_ sender: Any?) {
        let sel = selectedRange()
        guard let (open, close) = enclosingBrackets(around: sel.location) else { NSSound.beep(); return }
        let inner = NSRange(location: open + 1, length: close - open - 1)
        if sel == inner {
            setAllSelections([NSRange(location: open, length: close - open + 1)])
        } else if inner.location <= sel.location && NSMaxRange(inner) >= NSMaxRange(sel) {
            setAllSelections([inner])
        } else if let outer = enclosingBrackets(around: open) {
            setAllSelections([NSRange(location: outer.0 + 1, length: outer.1 - outer.0 - 1)])
        }
    }

    @objc func selectWordCommand(_ sender: Any?) {
        let sels = allSelections.map { r in r.length == 0 ? (wordRange(at: r.location) ?? r) : r }
        setAllSelections(sels)
    }

    // MARK: Case

    private func transformSelections(_ name: String, _ f: (String) -> String) {
        var edits: [TextEdit] = []
        for r0 in allSelections {
            let r = r0.length == 0 ? (wordRange(at: r0.location) ?? r0) : r0
            guard r.length > 0 else { continue }
            let s = f(text.substring(with: r))
            edits.append(TextEdit(r, s, selection: NSRange(location: 0, length: s.utf16.count)))
        }
        performEdits(edits, actionName: name)
    }

    @objc func upperCase(_ sender: Any?) { transformSelections("Upper Case") { $0.uppercased() } }
    @objc func lowerCase(_ sender: Any?) { transformSelections("Lower Case") { $0.lowercased() } }
    @objc func titleCase(_ sender: Any?) { transformSelections("Title Case", EditorTextView.titleCased) }
    @objc func swapCase(_ sender: Any?) {
        transformSelections("Swap Case") { s in
            // Case mapping can change length ("ß" → "SS"), so map to strings, not characters.
            String(s.flatMap { c in c.isUppercase ? c.lowercased() : c.uppercased() })
        }
    }

    @objc func snakeCase(_ sender: Any?) {
        transformSelections("Snake Case") { s in
            EditorTextView.convertIdentifiers(s) { $0.map { $0.lowercased() }.joined(separator: "_") }
        }
    }

    @objc func camelCase(_ sender: Any?) {
        transformSelections("Camel Case") { s in
            EditorTextView.convertIdentifiers(s) { words in
                guard let first = words.first else { return "" }
                return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
            }
        }
    }

    /// Uppercases the first letter of each word and leaves the rest alone, so "NASA" and
    /// "McDonald" keep their capitals. An apostrophe inside a word ("don't") doesn't start one.
    static func titleCased(_ s: String) -> String {
        var out = ""
        var prev: Character?
        var beforePrev: Character?
        for c in s {
            let startsWord: Bool
            if let p = prev {
                startsWord = p == "'" || p == "’" ? !(beforePrev?.isLetter ?? false) : !p.isLetter && !p.isNumber
            } else {
                startsWord = true
            }
            out += startsWord && c.isLetter ? String(c).capitalized : String(c)
            beforePrev = prev
            prev = c
        }
        return out
    }

    /// Applies `join` to the words of each line, keeping each line's indentation, trailing
    /// spaces and leading or trailing underscores (`_privateName`).
    static func convertIdentifiers(_ s: String, _ join: ([String]) -> String) -> String {
        let edge: (Character) -> Bool = { $0 == "_" || $0 == " " || $0 == "\t" }
        return s.components(separatedBy: "\n").map { line in
            let lead = line.prefix(while: edge)
            let rest = line.dropFirst(lead.count)
            let trail = String(rest.reversed().prefix(while: edge).reversed())
            let words = identifierWords(String(rest.dropLast(trail.count)))
            return words.isEmpty ? line : String(lead) + join(words) + trail
        }.joined(separator: "\n")
    }

    /// Splits at `_`, `-` and spaces and where the case changes, keeping acronyms together:
    /// "parseHTTPResponse" and "parse_http_response" both give parse, HTTP/http, Response/response.
    static func identifierWords(_ s: String) -> [String] {
        var words: [String] = []
        var word = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
                continue
            }
            if c.isUppercase, let prev = word.last {
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(word)
                    word = ""
                }
            }
            word.append(c)
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    // MARK: Line permutations

    private func transformLineBlocks(_ name: String, _ f: ([String]) -> [String]) {
        var blocks = selectedLineBlocks()
        if blocks.count == 1 && allSelections.count == 1 && selectedRange().length == 0 {
            blocks = [NSRange(location: 0, length: len)]
        }
        var edits: [TextEdit] = []
        for b in blocks {
            var s = text.substring(with: b)
            let trailing = s.hasSuffix("\n")
            if trailing { s.removeLast() }
            var out = f(s.components(separatedBy: "\n")).joined(separator: "\n")
            if trailing { out += "\n" }
            edits.append(TextEdit(b, out, selection: NSRange(location: 0, length: out.utf16.count - (trailing ? 1 : 0))))
        }
        performEdits(edits, actionName: name)
    }

    @objc func sortLines(_ sender: Any?) { transformLineBlocks("Sort Lines") { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } } }
    @objc func sortLinesCaseSensitive(_ sender: Any?) { transformLineBlocks("Sort Lines") { $0.sorted() } }
    @objc func reverseLines(_ sender: Any?) { transformLineBlocks("Reverse Lines") { $0.reversed() } }
    @objc func uniqueLines(_ sender: Any?) {
        transformLineBlocks("Unique Lines") { ls in
            var seen = Set<String>()
            return ls.filter { seen.insert($0).inserted }
        }
    }
    @objc func shuffleLines(_ sender: Any?) { transformLineBlocks("Shuffle Lines") { $0.shuffled() } }

    // MARK: Whitespace

    @objc func trimTrailingWhitespace(_ sender: Any?) {
        guard let re = try? NSRegularExpression(pattern: "[ \\t]+$", options: [.anchorsMatchLines]) else { return }
        let s = text as String
        let carets = Set(allSelections.map { $0.location })
        let edits = re.matches(in: s, range: NSRange(location: 0, length: len)).compactMap { m -> TextEdit? in
            if carets.contains(NSMaxRange(m.range)) && sender == nil { return nil }
            return TextEdit(m.range, "")
        }
        if !edits.isEmpty { performEdits(edits, selection: .preserve, actionName: "Trim Trailing Whitespace") }
    }

    func ensureTrailingNewline() {
        guard len > 0, char(len - 1) != 10 else { return }
        let sels = allSelections
        performEdits([TextEdit(NSRange(location: len, length: 0), "\n")], selection: .custom(sels))
    }

    @objc func convertIndentationToSpaces(_ sender: Any?) { convertIndentation(toTabs: false) }
    @objc func convertIndentationToTabs(_ sender: Any?) { convertIndentation(toTabs: true) }

    private func convertIndentation(toTabs: Bool) {
        guard !document.isReadOnly else { NSSound.beep(); return }
        let w = document.indentWidth
        var edits: [TextEdit] = []
        for l in 0..<lines.count {
            let r = lines.range(of: l, textLength: len)
            let ws = leadingWhitespaceLength(r)
            guard ws > 0 else { continue }
            let cols = visualColumn(of: r.location + ws, lineStart: r.location)
            let replacement = toTabs ? String(repeating: "\t", count: cols / w) + String(repeating: " ", count: cols % w)
                                     : String(repeating: " ", count: cols)
            let current = text.substring(with: NSRange(location: r.location, length: ws))
            if current != replacement { edits.append(TextEdit(NSRange(location: r.location, length: ws), replacement)) }
        }
        performEdits(edits, selection: .preserve, actionName: "Convert Indentation")
        document.setIndentation(tabs: toTabs, width: w)
    }


    // MARK: JSON

    @objc func formatJSON(_ sender: Any?) { reformatJSON(pretty: true) }
    @objc func minifyJSON(_ sender: Any?) { reformatJSON(pretty: false) }

    /// Works on the selection, or on the whole document when nothing is selected.
    private func reformatJSON(pretty: Bool) {
        guard !document.isReadOnly else { NSSound.beep(); return }
        let sel = selectedRange()
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: document.length)
        let source = text.substring(with: range)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        do {
            var result = try JSONFormatter.reformat(source, indent: pretty ? indentUnit : nil)
            if pretty && sel.length > 0 {
                // Keep a value formatted inside a larger file aligned with the line it starts on.
                let lineStart = document.lines.start(of: document.lines.line(containing: sel.location))
                let lead = text.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
                let indent = String(lead.prefix { $0 == " " || $0 == "\t" })
                if !indent.isEmpty { result = result.replacingOccurrences(of: "\n", with: "\n" + indent) }
            }
            if source.hasSuffix("\n") { result += "\n" }
            guard result != source else { return }
            let after = sel.length > 0 ? NSRange(location: 0, length: result.utf16.count) : NSRange(location: 0, length: 0)
            performEdits([TextEdit(range, result, selection: after)], actionName: pretty ? "Format JSON" : "Minify JSON")
            if sel.length == 0, document.language === LanguageRegistry.shared.plain,
               let json = LanguageRegistry.shared.language(id: "json") {
                document.setLanguage(json, manual: false)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = sel.length > 0 ? "The selection isn’t valid JSON." : "This document isn’t valid JSON."
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    // MARK: Validation

    static let editingActions: Set<Selector> = [
        #selector(cut(_:)), #selector(paste(_:)), #selector(complete(_:)),
        #selector(indentLines(_:)), #selector(outdentLines(_:)), #selector(duplicateLine(_:)), #selector(deleteLine(_:)),
        #selector(moveLineUp(_:)), #selector(moveLineDown(_:)), #selector(joinLines(_:)),
        #selector(insertLineAfter(_:)), #selector(insertLineBefore(_:)),
        #selector(toggleComment(_:)), #selector(toggleBlockComment(_:)),
        #selector(upperCase(_:)), #selector(lowerCase(_:)), #selector(titleCase(_:)), #selector(swapCase(_:)),
        #selector(snakeCase(_:)), #selector(camelCase(_:)),
        #selector(sortLines(_:)), #selector(sortLinesCaseSensitive(_:)), #selector(reverseLines(_:)),
        #selector(uniqueLines(_:)), #selector(shuffleLines(_:)),
        #selector(trimTrailingWhitespace(_:)), #selector(convertIndentationToSpaces(_:)), #selector(convertIndentationToTabs(_:)),
        #selector(formatJSON(_:)), #selector(minifyJSON(_:)),
    ]

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, document.isReadOnly, EditorTextView.editingActions.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }
}
