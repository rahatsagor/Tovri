import AppKit

/// Builds a paginating, syntax-colored copy of a document for printing on white paper.
enum PrintableText {
    static func view(for doc: Document, width: CGFloat) -> NSTextView {
        let theme = ThemeManager.shared.theme(named: "Tovri Day")
            ?? ThemeManager.shared.themes.first { !$0.isDark } ?? ThemeManager.shared.active
        let size = min(doc.font.pointSize, 10)
        let font = NSFont(descriptor: doc.font.fontDescriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(doc.indentWidth)
        para.tabStops = []
        para.lineBreakMode = .byCharWrapping
        para.lineHeightMultiple = 1.15
        let text = doc.string
        let attr = NSMutableAttributedString(string: text as String, attributes: [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: para])
        let syntax = doc.syntax
        if !syntax.isPlain && text.length < 8_000_000 {
            let lines = doc.lines
            syntax.ensureStates(through: lines.count - 1, text: text, lines: lines)
            let colors = theme.tokenColors
            var tokens: [Token] = []
            for line in 0..<lines.count {
                let range = lines.range(of: line, textLength: text.length)
                guard range.length > 0 else { continue }
                syntax.tokens(line: line, text: text, lines: lines, into: &tokens)
                for t in tokens {
                    guard let c = colors[Int(t.kind.rawValue)] else { continue }
                    attr.addAttribute(.foregroundColor, value: c, range: NSRange(location: range.location + t.start, length: t.length))
                }
            }
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(attr)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.frame.size.height = ceil(lm.usedRect(for: tc).height) + 2
        }
        return view
    }
}
