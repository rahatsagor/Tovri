import Foundation
import QuartzCore

struct Token {
    var start: Int
    var length: Int
    var kind: TokenKind
}

/// Reusable UTF-16 buffer for pulling line contents out of an NSString without allocations.
final class LineBuffer {
    private var pointer: UnsafeMutablePointer<UInt16>
    private var capacity: Int

    init() {
        capacity = 4096
        pointer = .allocate(capacity: capacity)
    }

    deinit { pointer.deallocate() }

    func with<R>(_ text: NSString, _ range: NSRange, _ body: (UnsafeBufferPointer<UInt16>) -> R) -> R {
        if range.length > capacity {
            pointer.deallocate()
            capacity = max(range.length, capacity * 2)
            pointer = .allocate(capacity: capacity)
        }
        if range.length > 0 { text.getCharacters(pointer, range: range) }
        return body(UnsafeBufferPointer(start: pointer, count: range.length))
    }
}

/// Holds lexer states at the start of every line and keeps them up to date lazily.
///
/// `states[0..<validUpTo]` are correct for the current text. `states[validUpTo..<knownUpTo]` are
/// some `unknown` lines (inserted by edits) followed by states that were correct before the most
/// recent edits and still follow one another for the current text, so when re-lexing reaches a
/// line whose new start state equals its known old one, everything up to `knownUpTo` becomes
/// valid again without re-lexing (state convergence).
final class SyntaxEngine {
    static let unknown: UInt32 = .max
    /// Lines longer than this are not colored (state is still tracked) to keep typing responsive.
    static let maxColoredLineLength = 20_000

    private(set) var language: Language
    private var lexer: Lexer
    private(set) var states: [UInt32]
    private(set) var validUpTo = 1
    private var knownUpTo = 1
    private let buffer = LineBuffer()

    var isPlain: Bool { language.style == .plain }

    init(language: Language, lineCount: Int) {
        self.language = language
        self.lexer = language.lexer
        states = [UInt32](repeating: SyntaxEngine.unknown, count: max(1, lineCount))
        states[0] = 0
    }

    func reset(language: Language, lineCount: Int) {
        self.language = language
        self.lexer = language.lexer
        states = [UInt32](repeating: SyntaxEngine.unknown, count: max(1, lineCount))
        states[0] = 0
        validUpTo = 1
        knownUpTo = 1
    }

    func linesChanged(firstLine a: Int, removed r: Int, inserted k: Int) {
        let lo = min(a + 1, states.count)
        let hi = min(a + 1 + r, states.count)
        states.replaceSubrange(lo..<hi, with: repeatElement(SyntaxEngine.unknown, count: k))
        let delta = k - r
        if validUpTo > a + 1 {
            // Only the valid lines below the edit still chain onto each other. An older known
            // region past validUpTo may hold unknown lines or states the valid region never
            // re-checked, so it can't be carried over.
            knownUpTo = validUpTo > a + r + 1 ? validUpTo + delta : a + 1
            validUpTo = a + 1
        } else if knownUpTo > a + 1 {
            knownUpTo = a + 1
        }
        validUpTo = min(max(validUpTo, 1), states.count)
        knownUpTo = min(max(knownUpTo, validUpTo), states.count)
    }

    /// Makes `states[0...line]` valid.
    func ensureStates(through line: Int, text: NSString, lines: LineIndex) {
        guard !isPlain else { return }
        let target = min(line, states.count - 1)
        guard validUpTo <= target else { return }
        let length = text.length
        let from = validUpTo
        defer { if Perf.enabled && target - from > 1000 { FileHandle.standardError.write("[perf] states \(from)->\(validUpTo)\n".data(using: .utf8)!) } }
        while validUpTo <= target {
            let prev = validUpTo - 1
            let range = lines.range(of: prev, textLength: length)
            let start = states[prev]
            let s = buffer.with(text, range) { lexer.lex($0, state: start, emit: { _, _, _ in }) }
            let next = validUpTo
            let old = states[next]
            states[next] = s
            if next < knownUpTo && old == s && old != SyntaxEngine.unknown {
                validUpTo = knownUpTo
            } else {
                validUpTo = next + 1
            }
            if knownUpTo < validUpTo { knownUpTo = validUpTo }
        }
    }

    /// Advances valid states toward `line`, stopping after `budget` seconds. Returns true when done.
    func advance(toward line: Int, text: NSString, lines: LineIndex, budget: CFTimeInterval) -> Bool {
        guard !isPlain else { return true }
        let target = min(line, states.count - 1)
        let deadline = CACurrentMediaTime() + budget
        while validUpTo <= target {
            let chunkEnd = min(target, validUpTo + 512)
            ensureStates(through: chunkEnd, text: text, lines: lines)
            if CACurrentMediaTime() > deadline { return validUpTo > target }
        }
        return true
    }

    /// Lines the engine would have to lex before `line` has a valid start state.
    func pendingLines(before line: Int) -> Int { max(0, min(line, states.count - 1) - validUpTo + 1) }

    /// Tokenizes a line from an explicit start state without touching cached states, returning the
    /// end state. Used to color the viewport provisionally while states catch up in the background.
    func tokens(line: Int, startState: UInt32, text: NSString, lines: LineIndex, into out: inout [Token]) -> UInt32 {
        out.removeAll(keepingCapacity: true)
        guard !isPlain else { return 0 }
        let range = lines.range(of: line, textLength: text.length)
        return buffer.with(text, range) { buf in
            lexer.lex(buf, state: startState, emit: { s, l, k in
                if l > 0 && range.length <= SyntaxEngine.maxColoredLineLength { out.append(Token(start: s, length: l, kind: k)) }
            })
        }
    }

    func state(at line: Int) -> UInt32 { states[min(line, states.count - 1)] }

    /// Tokenizes a line. Callers must have called `ensureStates(through: line)`.
    func tokens(line: Int, text: NSString, lines: LineIndex, into out: inout [Token]) {
        out.removeAll(keepingCapacity: true)
        guard !isPlain else { return }
        let range = lines.range(of: line, textLength: text.length)
        guard range.length > 0, range.length <= SyntaxEngine.maxColoredLineLength else { return }
        let start = states[min(line, states.count - 1)]
        buffer.with(text, range) { buf in
            _ = lexer.lex(buf, state: start == SyntaxEngine.unknown ? 0 : start, emit: { s, l, k in
                if l > 0 { out.append(Token(start: s, length: l, kind: k)) }
            })
        }
    }
}
