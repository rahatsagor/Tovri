import AppKit

/// Code overview: each line becomes thin colored bars, with the visible region highlighted.
final class MinimapView: NSView {
    weak var textView: EditorTextView?
    private let rowHeight: CGFloat = 3
    private let barHeight: CGFloat = 2
    private let charWidth: CGFloat = 1.15
    private var tokens: [Token] = []
    private var buffer = [UInt16](repeating: 0, count: 256)
    private var dragGrabOffset: CGFloat?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !ThemeManager.shared.active.translucent }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // A visual overview of text VoiceOver already reads from the text view.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }

    struct Geometry {
        var start: Int
        var visibleRows: Int
        var viewportY: CGFloat
        var viewportHeight: CGFloat
        var contentHeight: CGFloat
        var visibleLineCount: Int
    }

    func geometry() -> Geometry? {
        guard let tv = textView, tv.enclosingScrollView != nil else { return nil }
        let total = tv.document.lines.count
        let rows = max(1, Int(bounds.height / rowHeight))
        let visible = tv.visibleCharacterRange
        let first = tv.document.lines.line(containing: min(visible.location, tv.document.length))
        let last = tv.document.lines.line(containing: min(NSMaxRange(visible), tv.document.length))
        let visibleLines = max(1, last - first + 1)
        // Match the source lines on screen, independent of TextKit's estimated pixel
        // positions and the optional scroll-past-end space below the last line.
        let fraction = min(1, CGFloat(first) / CGFloat(max(1, total - visibleLines)))
        let maxStart = max(0, total - rows)
        let start = Int((Double(maxStart) * Double(fraction)).rounded())
        let contentHeight = CGFloat(min(total, rows)) * rowHeight
        let vh = min(contentHeight, CGFloat(visibleLines) * rowHeight)
        let vy = fraction * max(0, contentHeight - vh)
        return Geometry(start: start, visibleRows: rows, viewportY: vy, viewportHeight: vh,
                        contentHeight: contentHeight, visibleLineCount: visibleLines)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        theme.chromeBorder.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        guard let tv = textView, let g = geometry(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        let doc = tv.document
        let lines = doc.lines
        let text = doc.string
        let length = doc.length
        let end = min(lines.count, g.start + g.visibleRows)

        theme.minimapViewport.setFill()
        NSRect(x: 1, y: g.viewportY, width: bounds.width - 1, height: g.viewportHeight).fill()

        guard g.start < end else { return }
        let syntax = doc.syntax
        let exact = syntax.pendingLines(before: end - 1) <= Colorizer.blockingGap
        if exact {
            syntax.ensureStates(through: end - 1, text: text, lines: lines)
        } else {
            tv.editor?.scheduleCatchUp(to: end - 1)
        }

        let maxCols = Int((bounds.width - 8) / charWidth)
        let colors = theme.tokenColors
        let defaultColor = theme.foreground
        var rectsByColor: [Int: [CGRect]] = [:]
        let tab = doc.indentWidth
        let plainKey = -1

        for line in g.start..<end {
            let r = lines.range(of: line, textLength: length)
            if r.length == 0 { continue }
            let n = min(r.length, maxCols * 2, buffer.count)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: r.location, length: n)) }
            if exact { syntax.tokens(line: line, text: text, lines: lines, into: &tokens) } else { tokens.removeAll(keepingCapacity: true) }
            let y = CGFloat(line - g.start) * rowHeight
            if y > dirtyRect.maxY { break }
            var col = 0
            var ti = 0
            var runStart = -1
            var runKey = plainKey
            func flush(_ endCol: Int) {
                if runStart >= 0 && endCol > runStart {
                    let rect = CGRect(x: 6 + CGFloat(runStart) * charWidth, y: y, width: CGFloat(endCol - runStart) * charWidth, height: barHeight)
                    rectsByColor[runKey, default: []].append(rect)
                }
                runStart = -1
            }
            for i in 0..<n {
                if col >= maxCols { break }
                let c = buffer[i]
                while ti < tokens.count && tokens[ti].start + tokens[ti].length <= i { ti += 1 }
                var key = plainKey
                if ti < tokens.count && tokens[ti].start <= i { key = Int(tokens[ti].kind.rawValue) }
                if c == 32 || c == 9 {
                    flush(col)
                    col += c == 9 ? tab - col % tab : 1
                    continue
                }
                if runStart < 0 { runStart = col; runKey = key }
                else if key != runKey { flush(col); runStart = col; runKey = key }
                col += 1
            }
            flush(col)
        }

        for (key, rects) in rectsByColor {
            let color = key == plainKey ? defaultColor : (colors[key] ?? defaultColor)
            ctx.setFillColor(color.withAlphaComponent(0.72).cgColor)
            ctx.fill(rects)
        }

        let marked = doc.bookmarks.lines.filter { $0 >= g.start && $0 < end }
        if !marked.isEmpty {
            ctx.setFillColor(theme.accent.cgColor)
            ctx.fill(marked.map { CGRect(x: 1, y: CGFloat($0 - g.start) * rowHeight, width: 3, height: rowHeight) })
        }
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        guard let g = geometry() else { return }
        let y = convert(event.locationInWindow, from: nil).y
        if y >= g.viewportY && y <= g.viewportY + g.viewportHeight {
            dragGrabOffset = y - g.viewportY
        } else {
            scroll(toMinimapY: y)
            if let updated = geometry() { dragGrabOffset = y - updated.viewportY }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrabOffset else { return }
        let y = convert(event.locationInWindow, from: nil).y
        dragViewport(toMinimapY: y, grabOffset: grab)
    }

    override func mouseUp(with event: NSEvent) { dragGrabOffset = nil }

    func scroll(toMinimapY y: CGFloat) {
        guard let tv = textView, let g = geometry() else { return }
        let line = g.start + Int(floor((y - g.viewportHeight / 2) / rowHeight))
        tv.editor?.scrollLineToTop(min(max(0, line), tv.document.lines.count - 1))
    }

    func dragViewport(toMinimapY y: CGFloat, grabOffset: CGFloat) {
        guard let tv = textView, let g = geometry() else { return }
        let travel = max(1, g.contentHeight - g.viewportHeight)
        let fraction = min(1, max(0, (y - grabOffset) / travel))
        // At the bottom, lay out the actual final line. Extrapolating from the line
        // count visible at the drag's start is inaccurate for distant or wrapped text.
        let line = fraction == 1 ? tv.document.lines.count - 1
            : Int((fraction * CGFloat(max(0, tv.document.lines.count - g.visibleLineCount))).rounded())
        tv.editor?.scrollLineToTop(line)
    }

    override func scrollWheel(with event: NSEvent) {
        textView?.enclosingScrollView?.scrollWheel(with: event)
    }
}
