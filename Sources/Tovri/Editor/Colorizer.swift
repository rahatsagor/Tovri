import AppKit

/// Applies syntax colors to one layout manager using temporary attributes. Temporary
/// attributes never touch the text storage, so coloring causes no relayout and no undo noise,
/// and each view of a shared document can be colored independently.
final class Colorizer {
    private unowned let document: Document
    private weak var layoutManager: NSLayoutManager?
    private var colored = IndexSet()
    private var tokens: [Token] = []
    private var colors: [NSColor?] = []

    /// Called when the viewport is far beyond the lexed region; the owner catches up in slices.
    var onNeedsCatchUp: ((Int) -> Void)?
    static let blockingGap = 20_000

    init(document: Document, layoutManager: NSLayoutManager) {
        self.document = document
        self.layoutManager = layoutManager
        updateTheme()
    }

    func updateTheme() {
        colors = ThemeManager.shared.active.tokenColors
        invalidateAll()
    }

    func invalidateAll() { colored.removeAll() }

    func clearAll() {
        colored.removeAll()
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: document.length))
    }

    /// Colors every line intersecting `charRange` that isn't already colored.
    func colorize(_ charRange: NSRange) {
        guard let lm = layoutManager else { return }
        let syntax = document.syntax
        if syntax.isPlain { return }
        let text = document.string
        let lines = document.lines
        let length = text.length
        let first = lines.line(containing: charRange.location)
        let last = lines.line(containing: min(NSMaxRange(charRange), length))
        if first > last { return }
        if syntax.pendingLines(before: last) > Colorizer.blockingGap {
            colorProvisionally(first...last, lm: lm)
            onNeedsCatchUp?(last)
            return
        }
        syntax.ensureStates(through: last, text: text, lines: lines)
        var line = first
        while line <= last {
            if colored.contains(line) {
                line += 1
                continue
            }
            let range = lines.range(of: line, textLength: length)
            if range.length > 0 {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                syntax.tokens(line: line, text: text, lines: lines, into: &tokens)
                for t in tokens {
                    guard let c = colors[Int(t.kind.rawValue)] else { continue }
                    lm.addTemporaryAttribute(.foregroundColor, value: c,
                                             forCharacterRange: NSRange(location: range.location + t.start, length: t.length))
                }
            }
            colored.insert(line)
            line += 1
        }
    }

    /// Colors lines assuming a default start state; they stay out of `colored` so they are redone
    /// with exact states once catch-up finishes.
    private func colorProvisionally(_ lineRange: ClosedRange<Int>, lm: NSLayoutManager) {
        let syntax = document.syntax
        let text = document.string
        let lines = document.lines
        let length = text.length
        var state: UInt32 = 0
        for line in lineRange {
            let range = lines.range(of: line, textLength: length)
            state = syntax.tokens(line: line, startState: state, text: text, lines: lines, into: &tokens)
            guard range.length > 0 else { continue }
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for t in tokens {
                guard let col = colors[Int(t.kind.rawValue)] else { continue }
                lm.addTemporaryAttribute(.foregroundColor, value: col, forCharacterRange: NSRange(location: range.location + t.start, length: t.length))
            }
        }
    }
}
