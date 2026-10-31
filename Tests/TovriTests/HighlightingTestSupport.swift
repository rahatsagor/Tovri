import AppKit
import XCTest
@testable import Tovri

/// Lexes a whole document through `SyntaxEngine`, the same path `Colorizer` uses, and records the
/// token kind of every UTF-16 unit so tests can assert on substrings.
struct Highlighted {
    let text: NSString
    let kinds: [TokenKind]
    /// Lexer state at the start of each line.
    let lineStates: [UInt32]

    init(_ languageId: String, _ source: String) {
        guard let language = LanguageRegistry.shared.language(id: languageId) else {
            fatalError("Unknown language \(languageId)")
        }
        let text = source as NSString
        let lines = LineIndex()
        lines.rebuild(from: text)
        self.init(engine: SyntaxEngine(language: language, lineCount: lines.count), text: text, lines: lines)
    }

    init(document: Document) {
        self.init(engine: document.syntax, text: document.string, lines: document.lines)
    }

    init(engine: SyntaxEngine, text: NSString, lines: LineIndex) {
        engine.ensureStates(through: lines.count - 1, text: text, lines: lines)
        var kinds = [TokenKind](repeating: .plain, count: text.length)
        var tokens: [Token] = []
        var states: [UInt32] = []
        for line in 0..<lines.count {
            states.append(engine.state(at: line))
            let range = lines.range(of: line, textLength: text.length)
            engine.tokens(line: line, text: text, lines: lines, into: &tokens)
            for t in tokens {
                for k in 0..<t.length { kinds[range.location + t.start + k] = t.kind }
            }
        }
        self.text = text
        self.kinds = kinds
        self.lineStates = states
    }

    /// Range of the `occurrence`-th (0-based) match of `needle`.
    func range(of needle: String, occurrence: Int = 0) -> NSRange? {
        var from = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            if found.location == NSNotFound { return nil }
            from = found.location + max(found.length, 1)
        }
        return found
    }

    /// `kind«text»` for each run of non-plain units, plain text as is.
    func dump(_ range: NSRange? = nil) -> String {
        let r = range ?? NSRange(location: 0, length: text.length)
        var out = ""
        var i = r.location
        let end = NSMaxRange(r)
        while i < end {
            if text.character(at: i) == 10 { out += "\n"; i += 1; continue }
            let k = kinds[i]
            var e = i + 1
            while e < end && kinds[e] == k && text.character(at: e) != 10 { e += 1 }
            let s = text.substring(with: NSRange(location: i, length: e - i))
            out += k == .plain ? s : "\(k)«\(s)»"
            i = e
        }
        return out
    }
}

/// Asserts the `dump` of the first line containing `needle`.
func XCTAssertLine(_ h: Highlighted, _ needle: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let r = h.range(of: needle) else {
        XCTFail("\"\(needle)\" not found", file: file, line: line)
        return
    }
    var lineRange = h.text.lineRange(for: r)
    if NSMaxRange(lineRange) > 0 && NSMaxRange(lineRange) <= h.text.length && h.text.character(at: NSMaxRange(lineRange) - 1) == 10 {
        lineRange.length -= 1
    }
    XCTAssertEqual(h.dump(lineRange), expected, file: file, line: line)
}

/// Asserts that every unit of the `occurrence`-th match of `needle` has `kind`.
func XCTAssertKind(_ h: Highlighted, _ needle: String, _ kind: TokenKind, occurrence: Int = 0,
                   file: StaticString = #filePath, line: UInt = #line) {
    guard let r = h.range(of: needle, occurrence: occurrence) else {
        XCTFail("\"\(needle)\" occurrence \(occurrence) not found", file: file, line: line)
        return
    }
    let actual = h.kinds[r.location..<NSMaxRange(r)]
    if let bad = actual.firstIndex(where: { $0 != kind }) {
        let lineRange = h.text.lineRange(for: r)
        XCTFail("\"\(needle)\" should be \(kind) but unit \(bad - r.location) is \(actual[bad]) in: \(h.dump(lineRange))",
                file: file, line: line)
    }
}
