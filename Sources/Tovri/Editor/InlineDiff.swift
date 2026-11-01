import AppKit

/// Syntax-colors standalone lines (removed text, a change card) with a document's language.
enum SnippetHighlighter {
    /// Longer lines are cut: they are shown for context, and drawing them in full would stall.
    static let maxLineLength = 2_000

    static func highlight(_ lines: [String], language: Language, theme: Theme, font: NSFont,
                          paragraph: NSParagraphStyle? = nil, alpha: CGFloat = 1) -> [NSMutableAttributedString] {
        let lexer = language.style == .plain ? nil : language.lexer
        let colors = theme.tokenColors
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.foreground.withAlphaComponent(alpha), .ligature: 0]
        if let paragraph { base[.paragraphStyle] = paragraph }
        var state: UInt32 = 0
        return lines.map { line in
            let shown = line.utf16.count > maxLineLength ? String(line.prefix(maxLineLength)) : line
            let s = NSMutableAttributedString(string: shown, attributes: base)
            guard let lexer else { return s }
            let units = Array(shown.utf16)
            let length = units.count
            state = units.withUnsafeBufferPointer { buf in
                lexer.lex(buf, state: state) { start, count, kind in
                    guard count > 0, start >= 0, start + count <= length, let c = colors[Int(kind.rawValue)] else { return }
                    s.addAttribute(.foregroundColor, value: alpha < 1 ? c.withAlphaComponent(alpha) : c, range: NSRange(location: start, length: count))
                }
            }
            return s
        }
    }
}

/// Compare with Last Commit, shown in the editor itself: lines removed since the last commit are
/// drawn struck through in gaps above the lines that replaced them, and added or changed lines
/// are tinted. Exists only while an editor is comparing.
final class InlineDiff {
    private(set) var gaps = TovriLayoutManager.Gaps()
    /// Added or changed lines of the current text.
    private(set) var changed = IndexSet()
    private(set) var added = 0
    private(set) var deleted = 0
    /// Removed lines by the line they are shown above; `trailingKey` holds those after the last line.
    private var removed: [Int: [String]] = [:]
    private var rendered: [Int: [NSAttributedString]] = [:]

    static let trailingKey = -1

    var isEmpty: Bool { added == 0 && deleted == 0 }

    init(diff: LineDiff, lineCount: Int) {
        for h in diff.hunks {
            added += h.newCount
            deleted += h.oldLines.count
            if h.newCount > 0 { changed.insert(integersIn: h.newStart..<h.newEnd) }
            guard !h.oldLines.isEmpty else { continue }
            if h.newStart >= lineCount {
                gaps.trailing += h.oldLines.count
                removed[InlineDiff.trailingKey, default: []] += h.oldLines
            } else {
                gaps.above[h.newStart, default: 0] += h.oldLines.count
                removed[h.newStart, default: []] += h.oldLines
            }
        }
    }

    /// Keeps removed lines next to the text they belong to while an edit adds or removes lines,
    /// until the diff is recomputed. Returns false when nothing moved.
    func applyEdit(firstLine a: Int, removed r: Int, inserted k: Int) -> Bool {
        let delta = k - r
        guard delta != 0 else { return false }
        var above: [Int: Int] = [:]
        var lines: [Int: [String]] = [:]
        if let t = removed[InlineDiff.trailingKey] { lines[InlineDiff.trailingKey] = t }
        for (line, n) in gaps.above {
            let to = line > a + r ? line + delta : (line > a ? a + 1 : line)
            above[to, default: 0] += n
            lines[to, default: []] += removed[line] ?? []
        }
        gaps.above = above
        removed = lines
        rendered.removeAll()
        changed.shift(startingAt: a + r + 1, by: delta)
        return true
    }

    /// The removed lines shown above `line` (or after the last line for `trailingKey`), colored and struck through.
    func rows(at key: Int, document: Document) -> [NSAttributedString] {
        if let r = rendered[key] { return r }
        let theme = ThemeManager.shared.active
        let strike = (theme.color(.deleted) ?? .systemRed).withAlphaComponent(0.55)
        let rows = SnippetHighlighter.highlight(removed[key] ?? [], language: document.language, theme: theme,
                                                font: document.font, paragraph: document.paragraphStyle, alpha: 0.85)
        for s in rows {
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: strike],
                            range: NSRange(location: 0, length: s.length))
        }
        rendered[key] = rows
        return rows
    }

    /// Drops colored rows after a theme or font change.
    func invalidateRendering() { rendered.removeAll() }
}
