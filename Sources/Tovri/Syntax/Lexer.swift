import Foundation

typealias TokenEmit = (_ start: Int, _ length: Int, _ kind: TokenKind) -> Void

/// A line-oriented lexer. `state` carries multi-line context (block comments, strings,
/// embedded languages) from the end of one line to the start of the next.
/// States must fit in 16 bits for lexers that can be embedded in markup/markdown.
protocol Lexer: AnyObject {
    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32
}

// MARK: - Character helpers

@inline(__always) func isDigitU(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isAlphaU(_ c: UInt16) -> Bool { let l = c | 0x20; return l >= 97 && l <= 122 }
@inline(__always) func isAlnumU(_ c: UInt16) -> Bool { isDigitU(c) || isAlphaU(c) || c == 95 }
@inline(__always) func isHexU(_ c: UInt16) -> Bool { isDigitU(c) || ((c | 0x20) >= 97 && (c | 0x20) <= 102) }
@inline(__always) func isSpaceU(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 || c == 12 }
@inline(__always) func isWordU(_ c: UInt16) -> Bool { isAlnumU(c) || c >= 128 }

@inline(__always) func matchAt(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, _ p: [UInt16]) -> Bool {
    let m = p.count
    if m == 0 || i + m > s.count { return false }
    var k = 0
    while k < m {
        if s[i + k] != p[k] { return false }
        k += 1
    }
    return true
}

@inline(__always) func matchAtCI(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, _ p: [UInt16]) -> Bool {
    let m = p.count
    if i + m > s.count { return false }
    var k = 0
    while k < m {
        var c = s[i + k]
        if c >= 65 && c <= 90 { c += 32 }
        if c != p[k] { return false }
        k += 1
    }
    return true
}

@inline(__always) func find(_ s: UnsafeBufferPointer<UInt16>, _ p: [UInt16], from: Int) -> Int? {
    guard let first = p.first else { return nil }
    var i = from
    let n = s.count
    while i < n {
        if s[i] == first && matchAt(s, i, p) { return i }
        i += 1
    }
    return nil
}

@inline(__always) func nextNonSpace(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Int {
    var j = i
    while j < s.count && isSpaceU(s[j]) { j += 1 }
    return j
}

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

// MARK: - Plain

final class PlainLexer: Lexer {
    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32 { 0 }
}

// MARK: - Code lexer

/// Configurable lexer driven by a `Language` definition. Handles the vast majority of
/// programming and configuration languages.
final class CodeLexer: Lexer {
    private enum Last { case none, op, keyword, value, ident }

    private static let fIdentStart: UInt8 = 1
    private static let fIdentPart: UInt8 = 2
    private static let fOp: UInt8 = 4
    private static let fVar: UInt8 = 8
    private static let fAnnot: UInt8 = 16
    private static let fStrPrefix: UInt8 = 32
    private static let fHint: UInt8 = 64

    private let lang: Language
    private let words: [UInt64: TokenKind]
    private let fnDefs: Set<UInt64>
    private let typeDefs: Set<UInt64>
    private let lineComments: [[UInt16]]
    private let blockComments: [([UInt16], [UInt16])]
    private let rules: [(index: Int, rule: StringRule)]
    private let allRules: [StringRule]
    private let prefixRules: [([UInt16], TokenKind)]
    private let ci: Bool
    private let keyMode: Bool
    private let hasStringPrefixes: Bool
    private let hasPrefixFlags: Bool
    private let rawPrefixes: [UInt16]
    private let interpolationPrefixes: [UInt16]
    private let heredocOpen: [UInt16]
    private let commentsNeedSpace: Bool
    private let quoteDigitSeparators: Bool
    private let rawBackslashQuotes: Bool
    /// Keywords that only count as the first word of a line; they are not in `words`.
    private let lineStartWords: Set<UInt64>
    // Plain Bool copies of per-line checks, so the hot path never touches collection storage.
    private let hasLineStartWords: Bool
    private let interpolationNeedsPrefix: Bool
    private let hasHeredoc: Bool
    private let blockScalars: Bool
    private let hasLineStartConstructs: Bool
    /// Character class bits for ASCII. A raw buffer rather than an Array: in a function as large as
    /// `lex` the compiler stops inlining Array's bounds checks, which turns each lookup into a call.
    private let flags: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        p.initialize(repeating: 0, count: 128)
        return p
    }()

    private static let heredocFlag: UInt32 = 0x80
    private static let blockScalarState: UInt32 = 3
    private static let rawFlag: UInt32 = 1 << 12
    private static let interpolationFlag: UInt32 = 1 << 13

    init(language: Language) {
        lang = language
        if language.keywordsAtLineStart {
            words = language.wordTable.filter { $0.value != .keyword }
            lineStartWords = Set(language.wordTable.filter { $0.value == .keyword }.keys)
        } else {
            words = language.wordTable
            lineStartWords = []
        }
        fnDefs = language.functionDefHashes
        typeDefs = language.typeDefHashes
        lineComments = language.lineCommentUnits
        blockComments = language.blockCommentUnits
        rules = language.sortedStringRules
        allRules = language.strings
        prefixRules = language.linePrefixUnits
        ci = language.caseInsensitive
        keyMode = language.propertyKeys == .jsonKeys || language.propertyKeys == .colon
        hasStringPrefixes = !language.stringPrefixes.isEmpty
        rawPrefixes = Array(language.rawStringPrefixes.utf16)
        interpolationPrefixes = Array(language.interpolationPrefixes.utf16)
        hasPrefixFlags = !rawPrefixes.isEmpty || !interpolationPrefixes.isEmpty
        heredocOpen = Array(language.heredoc.utf16)
        commentsNeedSpace = language.commentsNeedSpace
        hasLineStartWords = !lineStartWords.isEmpty
        interpolationNeedsPrefix = !interpolationPrefixes.isEmpty
        hasHeredoc = !heredocOpen.isEmpty
        blockScalars = language.blockScalars
        hasLineStartConstructs = language.sectionHeaders || language.preprocessor || hasLineStartWords || blockScalars
        quoteDigitSeparators = language.quoteDigitSeparators
        rawBackslashQuotes = language.rawStringBackslashQuotes

        for c in 0..<128 {
            let u = UInt16(c)
            if isAlphaU(u) || u == 95 { flags[c] |= CodeLexer.fIdentStart | CodeLexer.fIdentPart }
            if isDigitU(u) { flags[c] |= CodeLexer.fIdentPart }
        }
        for u in language.identifierChars.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fIdentStart | CodeLexer.fIdentPart }
        for u in language.identifierPartChars.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fIdentPart }
        for u in language.operatorChars.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fOp }
        for u in language.variablePrefixes.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fVar }
        for u in language.annotationPrefix.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fAnnot }
        for u in language.stringPrefixes.utf16 where u < 128 { flags[Int(u)] |= CodeLexer.fStrPrefix }
        for p in lineComments { if let f = p.first, f < 128 { flags[Int(f)] |= CodeLexer.fHint } }
        for p in blockComments { if let f = p.0.first, f < 128 { flags[Int(f)] |= CodeLexer.fHint } }
        for r in allRules { if let f = r.open.first, f < 128 { flags[Int(f)] |= CodeLexer.fHint } }
    }

    deinit { flags.deallocate() }

    @inline(__always) private func flag(_ c: UInt16) -> UInt8 {
        c < 128 ? flags[Int(c)] : (CodeLexer.fIdentStart | CodeLexer.fIdentPart)
    }

    @inline(__always) private func isPart(_ c: UInt16) -> Bool { flag(c) & CodeLexer.fIdentPart != 0 }
    @inline(__always) private func isStart(_ c: UInt16) -> Bool { flag(c) & CodeLexer.fIdentStart != 0 }

    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32 {
        let n = s.count
        var i = 0
        var endState: UInt32 = 0

        if state != 0 {
            let type = state & 0xFF
            let idx = Int((state >> 8) & 0xF)
            let depth = Int((state >> 12) & 0xF)
            var next: UInt32 = 0
            if type == 1, idx < blockComments.count {
                (i, next) = scanBlock(s, from: 0, tokenStart: 0, index: idx, depth: max(depth, 1), emit: emit)
            } else if type == 2, idx < allRules.count {
                (i, next) = scanString(s, from: 0, tokenStart: 0, rule: allRules[idx], index: idx,
                                       raw: state & CodeLexer.rawFlag != 0,
                                       interpolates: state & CodeLexer.interpolationFlag != 0, emit: emit)
            } else if (type & CodeLexer.heredocFlag != 0 && hasHeredoc) || (type == CodeLexer.blockScalarState && blockScalars) {
                guard let e = resumeBlockLine(s, state: state, emit: emit) else { return state }
                i = e
            }
            if next != 0 { return next }
        } else {
            for (p, kind) in prefixRules where matchAt(s, 0, p) {
                if n > 0 { emit(0, n, kind) }
                return 0
            }
        }

        if i == 0 && hasLineStartConstructs {
            if blockScalars, let parent = blockScalarParent(s) {
                endState = CodeLexer.blockScalarState | UInt32(min(parent, 255)) << 8
            }
            let j = nextNonSpace(s, 0)
            if j < n {
                if lang.sectionHeaders && s[j] == 91 {
                    var k = j + 1
                    while k < n && s[k] != 93 { k += 1 }
                    if k < n {
                        while k + 1 < n && s[k + 1] == 93 { k += 1 }
                        emit(j, k - j + 1, .heading)
                        i = k + 1
                    }
                } else if hasLineStartWords && isStart(s[j]) {
                    i = lineStartKeyword(s, j, emit: emit)
                } else if lang.preprocessor && s[j] == 35 {
                    var k = nextNonSpace(s, j + 1)
                    while k < n && isAlnumU(s[k]) { k += 1 }
                    emit(j, k - j, .preprocessor)
                    i = k
                    let m = nextNonSpace(s, k)
                    if m < n && s[m] == 60 {
                        var e = m + 1
                        while e < n && s[e] != 62 { e += 1 }
                        if e < n { emit(m, e - m + 1, .string); i = e + 1 }
                    }
                }
            }
        }

        var last = Last.none
        var pending: TokenKind? = nil
        var firstToken = true

        outer: while i < n {
            let c = s[i]
            if isSpaceU(c) { i += 1; continue }
            let f = flag(c)

            if f & CodeLexer.fHint != 0 {
                for lc in lineComments where matchAt(s, i, lc) {
                    if commentsNeedSpace && i > 0 && !isCommentBoundary(s[i - 1]) { break }
                    emit(i, n - i, .comment)
                    return endState
                }
                for (bi, bc) in blockComments.enumerated() where matchAt(s, i, bc.0) {
                    let (ni, st) = scanBlock(s, from: i + bc.0.count, tokenStart: i, index: bi, depth: 1, emit: emit)
                    if st != 0 { return st }
                    i = ni
                    continue outer
                }
                for entry in rules where matchAt(s, i, entry.rule.open) {
                    let r = entry.rule
                    if r.isChar && !isCharLiteral(s, i, r) {
                        var e = i + r.open.count
                        if e < n && isStart(s[e]) {
                            while e < n && isPart(s[e]) { e += 1 }
                            emit(i, e - i, .annotation)
                            i = e
                        } else {
                            i += r.open.count
                        }
                        last = .op
                        continue outer
                    }
                    let (ni, st) = openString(s, at: i, rule: r, index: entry.index, emit: emit)
                    if st != 0 { return st }
                    i = ni
                    last = .value
                    firstToken = false
                    continue outer
                }
            }

            if f & CodeLexer.fVar != 0 && i + 1 < n {
                let e = scanVariable(s, i)
                if e > i + 1 {
                    emit(i, e - i, .variable)
                    i = e
                    last = .value
                    firstToken = false
                    continue
                }
            }

            if isDigitU(c) || (c == 46 && i + 1 < n && isDigitU(s[i + 1]) && last != .ident && last != .value) {
                let e = scanNumber(s, i)
                emit(i, e - i, .number)
                i = e
                last = .value
                firstToken = false
                continue
            }

            if f & CodeLexer.fIdentStart != 0 {
                let start = i
                var h: UInt64 = 0xcbf29ce484222325
                var allPrefix = true
                while i < n {
                    let d = s[i]
                    let df = flag(d)
                    if df & CodeLexer.fIdentPart == 0 { break }
                    var dd = d
                    if ci && dd >= 65 && dd <= 90 { dd += 32 }
                    h = (h ^ UInt64(dd)) &* 0x100000001b3
                    if df & CodeLexer.fStrPrefix == 0 { allPrefix = false }
                    i += 1
                }
                let len = i - start

                if hasStringPrefixes && allPrefix && len <= 3 && i < n {
                    for entry in rules where matchAt(s, i, entry.rule.open) {
                        let r = entry.rule
                        if r.isChar && !isCharLiteral(s, i, r) { continue }
                        let (ni, st) = openString(s, at: i, prefixStart: start, rule: r, index: entry.index, emit: emit)
                        if st != 0 { return st }
                        i = ni
                        last = .value
                        continue outer
                    }
                }

                var kind: TokenKind = .plain
                let keyAhead = nextNonSpace(s, i)
                if lang.propertyKeys == .colon, !lang.cssMode, keyAhead < n, s[keyAhead] == 58,
                   keyAhead + 1 == n || isSpaceU(s[keyAhead + 1]) {
                    kind = .property
                    last = .ident
                } else if let k = words[h] {
                    kind = k
                    last = .keyword
                } else {
                    if let p = pending {
                        kind = p
                    } else {
                        let nx = nextNonSpace(s, i)
                        if lang.propertyKeys == .colon, lang.cssMode, nx < n, s[nx] == 58, !(nx + 1 < n && s[nx + 1] == 58) {
                            if !lineContains(s, from: nx, 123) { kind = .property }
                        } else if lang.propertyKeys == .equals, nx < n, s[nx] == 61, firstToken || followsSeparator(s, start) {
                            kind = .property
                        }
                        if kind == .plain {
                            if lang.functionCalls && nx < n && s[nx] == 40 {
                                kind = .function
                            } else if lang.capitalizedTypes && s[start] >= 65 && s[start] <= 90 {
                                kind = isAllCaps(s, start, i) ? .constant : .type
                            }
                        }
                    }
                    last = .ident
                }
                if fnDefs.contains(h) { pending = .function }
                else if typeDefs.contains(h) { pending = .type }
                else if words[h] == nil { pending = nil }
                if kind != .plain { emit(start, len, kind) }
                firstToken = false
                continue
            }

            if c == 35 && lang.hashAttributes && i + 1 < n && (s[i + 1] == 91 || (s[i + 1] == 33 && i + 2 < n && s[i + 2] == 91)) {
                var e = i + 1
                var depth = 0
                while e < n {
                    if s[e] == 91 { depth += 1 } else if s[e] == 93 { depth -= 1; if depth == 0 { e += 1; break } }
                    e += 1
                }
                emit(i, e - i, .annotation)
                i = e
                continue
            }

            if f & CodeLexer.fAnnot != 0 && i + 1 < n
                && (isStart(s[i + 1]) || (s[i + 1] == c && i + 2 < n && isStart(s[i + 2]))) {
                var e = s[i + 1] == c ? i + 2 : i + 1
                while e < n && (isPart(s[e]) || (s[e] == 46 && e + 1 < n && isStart(s[e + 1]))) { e += 1 }
                emit(i, e - i, .annotation)
                i = e
                last = .value
                continue
            }

            if lang.cssMode {
                if c == 35 {
                    var e = i + 1
                    var allHex = true
                    while e < n && isPart(s[e]) {
                        if !isHexU(s[e]) { allHex = false }
                        e += 1
                    }
                    let len = e - i - 1
                    if len > 0 {
                        emit(i, e - i, allHex && (len == 3 || len == 4 || len == 6 || len == 8) ? .number : .attribute)
                        i = e
                        continue
                    }
                }
                if c == 46 && i + 1 < n && isStart(s[i + 1]) {
                    var e = i + 1
                    while e < n && isPart(s[e]) { e += 1 }
                    emit(i, e - i, .attribute)
                    i = e
                    continue
                }
                if (c == 64 || c == 33) && i + 1 < n && isStart(s[i + 1]) {
                    var e = i + 1
                    while e < n && isPart(s[e]) { e += 1 }
                    emit(i, e - i, .keyword)
                    i = e
                    continue
                }
            }

            if c == 60 && hasHeredoc, let (e, st) = scanHeredoc(s, i, emit: emit) {
                endState = st
                i = e
                last = .value
                pending = nil
                firstToken = false
                continue
            }

            if c == 47 && lang.regexLiterals && (last == .none || last == .op || last == .keyword) {
                if let e = scanRegex(s, i) {
                    emit(i, e - i, .regex)
                    i = e
                    last = .value
                    continue
                }
            }

            if f & CodeLexer.fOp != 0 {
                var e = i + 1
                while e < n {
                    let d = s[e]
                    guard d < 128 else { break }
                    let df = flags[Int(d)]
                    if df & CodeLexer.fOp == 0 || df & CodeLexer.fHint != 0 { break }
                    e += 1
                }
                emit(i, e - i, .operatorSymbol)
                i = e
                last = .op
                pending = nil
                firstToken = false
                continue
            }

            switch c {
            case 41, 93: last = .value
            default: last = .op
            }
            if c != 42 && c != 38 { pending = nil }
            firstToken = false
            i += 1
        }
        return endState
    }

    /// Whether the token at `i` follows "{" or ",", as keys in TOML inline tables do.
    @inline(never)
    private func followsSeparator(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Bool {
        var p = i - 1
        while p >= 0 && isSpaceU(s[p]) { p -= 1 }
        return p >= 0 && (s[p] == 123 || s[p] == 44)
    }

    /// Emits the first word of the line at `j` when it is a line-start keyword; returns where lexing continues.
    @inline(never)
    private func lineStartKeyword(_ s: UnsafeBufferPointer<UInt16>, _ j: Int, emit: TokenEmit) -> Int {
        let n = s.count
        var k = j
        var h: UInt64 = 0xcbf29ce484222325
        while k < n && isPart(s[k]) {
            var d = s[k]
            if ci && d >= 65 && d <= 90 { d += 32 }
            h = (h ^ UInt64(d)) &* 0x100000001b3
            k += 1
        }
        guard lineStartWords.contains(h) else { return 0 }
        emit(j, k - j, .keyword)
        return k
    }

    /// Lexes a line inside a heredoc body or YAML block scalar. Returns nil when the line belongs
    /// to it (and `state` carries on), otherwise where ordinary lexing of the line resumes.
    @inline(never)
    private func resumeBlockLine(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> Int? {
        let n = s.count
        if state & CodeLexer.heredocFlag != 0 {
            if let e = heredocEnd(s, state: state, emit: emit) { return e }
            if n > 0 { emit(0, n, .string) }
            return nil
        }
        let j = nextNonSpace(s, 0)
        if j == n { return nil }
        if j > Int(state >> 8) {
            emit(j, n - j, .string)
            return nil
        }
        return 0
    }

    @inline(__always) private func isCommentBoundary(_ c: UInt16) -> Bool {
        isSpaceU(c) || c == 59 || c == 38 || c == 124 || c == 40 || c == 41
    }

    /// End of a sigil variable starting at `i`; `i + 1` when there is none.
    @inline(never)
    private func scanVariable(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Int {
        let n = s.count
        let c = s[i]
        var e = i + 1
        guard e < n else { return e }
        let d = s[e]
        if d == 123 {
            while e < n && s[e] != 125 { e += 1 }
            e = min(e + 1, n)
        } else if d == c && i + 2 < n && isStart(s[i + 2]) {
            e = i + 2
            while e < n && isPart(s[e]) { e += 1 }
        } else if isStart(d) {
            while e < n && isPart(s[e]) { e += 1 }
        } else if d == 40 && lang.parenVariables {
            var k = i + 2
            while k < n && isPart(s[k]) { k += 1 }
            if k > i + 2 && k < n && s[k] == 41 { e = k + 1 }
        } else if isDigitU(d) || d == 64 || d == 63 || d == 35 || d == 42 || d == 33 || d == 36 || d == 45 || d == 60 || d == 94 {
            e = i + 2
        }
        return e
    }

    /// Scans the string whose opener is at `i`, preceded by prefix characters from `prefixStart`.
    /// Out of line so the prefix handling adds no register pressure to `lex`.
    @inline(never)
    private func openString(_ s: UnsafeBufferPointer<UInt16>, at i: Int, prefixStart: Int? = nil, rule r: StringRule, index: Int,
                            emit: TokenEmit) -> (Int, UInt32) {
        var start = prefixStart ?? i
        var raw = false
        var interpolates = r.interpolation != .none && !interpolationNeedsPrefix
        if hasPrefixFlags {
            if prefixStart == nil {
                // Non-letter prefixes such as C#'s $ and @ are not part of an identifier.
                while start > 0 && i - start < 3
                    && flag(s[start - 1]) & (CodeLexer.fStrPrefix | CodeLexer.fIdentStart) == CodeLexer.fStrPrefix {
                    start -= 1
                }
            }
            (raw, interpolates) = stringFlags(s, start, i, r)
        }
        return scanString(s, from: i + r.open.count, tokenStart: start, rule: r, index: index,
                          raw: raw, interpolates: interpolates, emit: emit)
    }

    @inline(__always) private func stringFlags(_ s: UnsafeBufferPointer<UInt16>, _ a: Int, _ b: Int, _ r: StringRule) -> (Bool, Bool) {
        var raw = false
        var prefixed = false
        var k = a
        while k < b {
            if rawPrefixes.contains(s[k]) { raw = true }
            if interpolationPrefixes.contains(s[k]) { prefixed = true }
            k += 1
        }
        return (raw, r.interpolation != .none && (!interpolationNeedsPrefix || prefixed))
    }

    @inline(__always) private func matchesInterpolation(_ s: UnsafeBufferPointer<UInt16>, _ e: Int, start: UInt16, next: UInt16) -> Bool {
        s[e] == start && (next == 0 || (e + 1 < s.count && s[e + 1] == next))
    }

    private func heredocState(_ s: UnsafeBufferPointer<UInt16>, _ a: Int, _ b: Int) -> UInt32 {
        var h: UInt32 = 2166136261
        var k = a
        while k < b { h = (h ^ UInt32(s[k])) &* 16777619; k += 1 }
        h ^= h >> 15
        // 15 bits of the delimiter's hash; the low byte stays >= 0x80 to mark a heredoc.
        return CodeLexer.heredocFlag | (h & 0x7F) | ((h >> 7) & 0xFF) << 8
    }

    /// Parses `<<EOF`, `<<-'EOF'`, `<<~EOS`, `<<<"EOT"`, returning its end and the state for the body lines.
    @inline(never)
    private func scanHeredoc(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, emit: TokenEmit) -> (Int, UInt32)? {
        guard matchAt(s, i, heredocOpen) else { return nil }
        let n = s.count
        var k = i + heredocOpen.count
        if k < n && s[k] == 60 { return nil }
        if k < n && (s[k] == 45 || s[k] == 126) { k += 1 }
        var d = k
        if lang.heredocAllowsSpace { while d < n && isSpaceU(s[d]) { d += 1 } }
        let quote: UInt16 = d < n && (s[d] == 39 || s[d] == 34) ? s[d] : 0
        let a = quote == 0 ? d : d + 1
        guard a < n, isAlphaU(s[a]) || s[a] == 95 else { return nil }
        var b = a
        while b < n && isAlnumU(s[b]) { b += 1 }
        var e = b
        if quote != 0 {
            guard e < n && s[e] == quote else { return nil }
            e += 1
        }
        emit(i, k - i, .operatorSymbol)
        emit(d, e - d, .string)
        return (e, heredocState(s, a, b))
    }

    /// End of the delimiter when this line closes the heredoc described by `state`.
    private func heredocEnd(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> Int? {
        let n = s.count
        let a = nextNonSpace(s, 0)
        var b = a
        while b < n && isAlnumU(s[b]) { b += 1 }
        guard b > a else { return nil }
        if b < n {
            let c = s[b]
            guard isSpaceU(c) || c == 59 || c == 44 || c == 41 else { return nil }
        }
        guard heredocState(s, a, b) == state else { return nil }
        emit(a, b - a, .string)
        return b
    }

    /// Indentation the content of a YAML block scalar opened on this line must exceed.
    @inline(never)
    private func blockScalarParent(_ s: UnsafeBufferPointer<UInt16>) -> Int? {
        let n = s.count
        let j = nextNonSpace(s, 0)
        var k = j
        while k + 1 < n && s[k] == 45 && isSpaceU(s[k + 1]) { k = nextNonSpace(s, k + 1) }
        var end = k
        while end < n && !(s[end] == 35 && end > 0 && isSpaceU(s[end - 1])) { end += 1 }
        while end > k && isSpaceU(s[end - 1]) { end -= 1 }
        var p = end
        while p > k && (s[p - 1] == 45 || s[p - 1] == 43 || isDigitU(s[p - 1])) { p -= 1 }
        guard p > k, s[p - 1] == 124 || s[p - 1] == 62 else { return nil }
        let indicator = p - 1
        if indicator == k { return j }
        guard isSpaceU(s[indicator - 1]) else { return nil }
        var q = indicator - 1
        while q > k && isSpaceU(s[q]) { q -= 1 }
        return s[q] == 58 ? k : nil
    }

    /// End of the interpolation whose content starts at `from` (index of its closing character).
    @inline(never)
    private func interpolationEnd(_ s: UnsafeBufferPointer<UInt16>, from: Int, rule: StringRule) -> Int? {
        let n = s.count
        let close = rule.interpolation.close
        let open = rule.interpolation.bracket
        var depth = 0
        var e = from
        while e < n {
            let d = s[e]
            if d == close {
                if depth == 0 { return e }
                depth -= 1
            } else if d == open {
                depth += 1
            } else if d == 34 || d == 39 || d == 96 {
                e = skipString(s, e)
                continue
            }
            e += 1
        }
        return nil
    }

    /// Index just past the string literal starting at `i` (nested inside an interpolation).
    private func skipString(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Int {
        let n = s.count
        for entry in rules where matchAt(s, i, entry.rule.open) {
            let r = entry.rule
            if r.isChar && !isCharLiteral(s, i, r) { return i + r.open.count }
            let nestedInterpolation = r.interpolation != .none && !interpolationNeedsPrefix
            let start = r.interpolation.start, next = r.interpolation.next
            var e = i + r.open.count
            while e < n {
                if nestedInterpolation && matchesInterpolation(s, e, start: start, next: next),
                   let c = interpolationEnd(s, from: e + r.interpolation.length, rule: r) {
                    e = c + 1
                    continue
                }
                if r.escape && s[e] == 92 { e += 2; continue }
                if matchAt(s, e, r.close) { return e + r.close.count }
                e += 1
            }
            return n
        }
        return i + 1
    }

    @inline(__always) private func lineContains(_ s: UnsafeBufferPointer<UInt16>, from: Int, _ c: UInt16) -> Bool {
        var i = from
        while i < s.count { if s[i] == c { return true }; i += 1 }
        return false
    }

    @inline(__always) private func isAllCaps(_ s: UnsafeBufferPointer<UInt16>, _ a: Int, _ b: Int) -> Bool {
        if b - a < 2 { return false }
        var i = a
        while i < b {
            let c = s[i]
            if c >= 97 && c <= 122 { return false }
            i += 1
        }
        return true
    }

    private func isCharLiteral(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, _ r: StringRule) -> Bool {
        let n = s.count
        var k = i + r.open.count
        guard k < n else { return false }
        if s[k] == 92 {
            k += 2
            let limit = min(n, i + 14)
            while k < limit {
                if matchAt(s, k, r.close) { return true }
                k += 1
            }
            return false
        }
        if matchAt(s, k + 1, r.close) { return true }
        if matchAt(s, k + 2, r.close) && s[k] >= 0xD800 && s[k] <= 0xDBFF { return true }
        return false
    }

    private func scanNumber(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Int {
        let n = s.count
        var e = i
        let quotes = quoteDigitSeparators
        if s[e] == 48 && e + 1 < n && ((s[e + 1] | 0x20) == 120 || (s[e + 1] | 0x20) == 98 || (s[e + 1] | 0x20) == 111) {
            e += 2
            while e < n && (isHexU(s[e]) || s[e] == 95 || (quotes && s[e] == 39 && e + 1 < n && isHexU(s[e + 1]))) { e += 1 }
        } else {
            if s[e] == 46 { e += 1 }
            while e < n && (isDigitU(s[e]) || s[e] == 95 || (quotes && s[e] == 39 && e + 1 < n && isDigitU(s[e + 1]))) { e += 1 }
            if e + 1 < n && s[e] == 46 && isDigitU(s[e + 1]) {
                e += 1
                while e < n && (isDigitU(s[e]) || s[e] == 95) { e += 1 }
            }
            if e < n && (s[e] | 0x20) == 101 {
                let save = e
                e += 1
                if e < n && (s[e] == 43 || s[e] == 45) { e += 1 }
                if e < n && isDigitU(s[e]) {
                    while e < n && isDigitU(s[e]) { e += 1 }
                } else {
                    e = save
                }
            }
        }
        while e < n && isPart(s[e]) && s[e] != 36 { e += 1 }
        return e
    }

    private func scanRegex(_ s: UnsafeBufferPointer<UInt16>, _ i: Int) -> Int? {
        let n = s.count
        var e = i + 1
        if e < n && (s[e] == 47 || s[e] == 42 || s[e] == 32) { return nil }
        var inClass = false
        while e < n {
            let d = s[e]
            if d == 92 { e += 2; continue }
            if d == 91 { inClass = true }
            else if d == 93 { inClass = false }
            else if d == 47 && !inClass {
                e += 1
                while e < n && isAlphaU(s[e]) { e += 1 }
                return e
            }
            e += 1
        }
        return nil
    }

    private func scanBlock(_ s: UnsafeBufferPointer<UInt16>, from: Int, tokenStart: Int, index: Int, depth: Int, emit: TokenEmit) -> (Int, UInt32) {
        let n = s.count
        let (open, close) = blockComments[index]
        var d = depth
        var i = from
        while i < n {
            if matchAt(s, i, close) {
                i += close.count
                d -= 1
                if d == 0 {
                    emit(tokenStart, i - tokenStart, .comment)
                    return (i, 0)
                }
                continue
            }
            if lang.nestedComments && matchAt(s, i, open) {
                d = min(d + 1, 15)
                i += open.count
                continue
            }
            i += 1
        }
        if n > tokenStart { emit(tokenStart, n - tokenStart, .comment) }
        return (n, 1 | UInt32(index) << 8 | UInt32(d) << 12)
    }

    private func scanString(_ s: UnsafeBufferPointer<UInt16>, from: Int, tokenStart: Int, rule: StringRule, index: Int,
                            raw: Bool, interpolates: Bool, emit: TokenEmit) -> (Int, UInt32) {
        let n = s.count
        if keyMode && rule.kind == .string {
            var e = from
            var closed = false
            while e < n {
                if rule.escape && s[e] == 92 { e += 2; continue }
                if matchAt(s, e, rule.close) { e += rule.close.count; closed = true; break }
                e += 1
            }
            if closed {
                let nx = nextNonSpace(s, e)
                if nx < n && s[nx] == 58 {
                    emit(tokenStart, e - tokenStart, .property)
                    return (e, 0)
                }
            }
        }
        if interpolates || (rule.variables && !raw) {
            return scanTemplate(s, from: from, tokenStart: tokenStart, rule: rule, index: index, raw: raw,
                                interpolates: interpolates, emit: emit)
        }
        let escapes = rule.kind == .string && !raw
        let backslashes = rule.escape && (!raw || rawBackslashQuotes)
        var seg = tokenStart
        var e = from
        while e < n {
            let d = s[e]
            if backslashes && d == 92 {
                if e + 1 >= n { e = n; break }
                let len = escapeLength(s, e)
                if escapes {
                    if e > seg { emit(seg, e - seg, rule.kind) }
                    emit(e, len, .escape)
                    seg = e + len
                }
                e += len
                continue
            }
            if matchAt(s, e, rule.close) {
                e += rule.close.count
                if e > seg { emit(seg, e - seg, rule.kind) }
                return (e, 0)
            }
            e += 1
        }
        let end = min(e, n)
        if end > seg { emit(seg, end - seg, rule.kind) }
        guard rule.multiline else { return (n, 0) }
        return (n, 2 | UInt32(index) << 8 | (raw ? CodeLexer.rawFlag : 0))
    }

    /// Length of the escape sequence starting with the backslash at `e` (which is not the last unit).
    @inline(__always) private func escapeLength(_ s: UnsafeBufferPointer<UInt16>, _ e: Int) -> Int {
        let n = s.count
        let x = s[e + 1]
        guard x == 117 || x == 120 || x == 85 else { return 2 }
        var k = e + 2
        if k < n && s[k] == 123 {
            while k < n && s[k] != 125 { k += 1 }
            k = min(k + 1, n)
        } else {
            while k < n && k < e + 10 && isHexU(s[k]) { k += 1 }
        }
        return k - e
    }

    /// `scanString` for strings with interpolation or sigil variables, kept out of line so plain
    /// strings keep a tight loop.
    @inline(never)
    private func scanTemplate(_ s: UnsafeBufferPointer<UInt16>, from: Int, tokenStart: Int, rule: StringRule, index: Int,
                              raw: Bool, interpolates: Bool, emit: TokenEmit) -> (Int, UInt32) {
        let n = s.count
        let escapes = rule.kind == .string && !raw
        let backslashes = rule.escape && (!raw || rawBackslashQuotes)
        let variables = rule.variables && !raw
        let interpolationStart = rule.interpolation.start, interpolationNext = rule.interpolation.next
        var seg = tokenStart
        var e = from
        while e < n {
            let d = s[e]
            if interpolates && matchesInterpolation(s, e, start: interpolationStart, next: interpolationNext) {
                let open = e + rule.interpolation.length
                if interpolationNext == 0 && open < n && s[open] == d {
                    e += 2
                    continue
                }
                if let close = interpolationEnd(s, from: open, rule: rule) {
                    if e > seg { emit(seg, e - seg, rule.kind) }
                    emit(e, open - e, .punctuation)
                    if close > open, let base = s.baseAddress {
                        let sub = UnsafeBufferPointer(start: base + open, count: close - open)
                        _ = lex(sub, state: 0, emit: { emit($0 + open, $1, $2) })
                    }
                    emit(close, 1, .punctuation)
                    e = close + 1
                    seg = e
                    continue
                }
            }
            if variables && d < 128 && flags[Int(d)] & CodeLexer.fVar != 0 {
                let v = scanVariable(s, e)
                if v > e + 1 {
                    if e > seg { emit(seg, e - seg, rule.kind) }
                    emit(e, v - e, .variable)
                    e = v
                    seg = e
                    continue
                }
            }
            if backslashes && d == 92 {
                if e + 1 >= n { e = n; break }
                let len = escapeLength(s, e)
                if escapes {
                    if e > seg { emit(seg, e - seg, rule.kind) }
                    emit(e, len, .escape)
                    seg = e + len
                }
                e += len
                continue
            }
            if matchAt(s, e, rule.close) {
                e += rule.close.count
                if e > seg { emit(seg, e - seg, rule.kind) }
                return (e, 0)
            }
            e += 1
        }
        let end = min(e, n)
        if end > seg { emit(seg, end - seg, rule.kind) }
        guard rule.multiline else { return (n, 0) }
        return (n, 2 | UInt32(index) << 8 | (raw ? CodeLexer.rawFlag : 0) | (interpolates ? CodeLexer.interpolationFlag : 0))
    }
}

// MARK: - Markup (HTML / XML / templates)

final class MarkupLexer: Lexer {
    private static let mText: UInt32 = 0, mComment: UInt32 = 1, mTag: UInt32 = 2, mDQ: UInt32 = 3, mSQ: UInt32 = 4
    private static let mCData: UInt32 = 5, mScript: UInt32 = 6, mStyle: UInt32 = 7, mDecl: UInt32 = 8

    private let lang: Language
    private lazy var scriptLexer: Lexer? = lang.embeddedScript.flatMap { LanguageRegistry.shared.language(id: $0) }?.lexer
    private lazy var styleLexer: Lexer? = lang.embeddedStyle.flatMap { LanguageRegistry.shared.language(id: $0) }?.lexer

    private let commentOpen = u("<!--"), commentClose = u("-->")
    private let cdataOpen = u("<![CDATA["), cdataClose = u("]]>")
    private let scriptClose = u("</script"), styleClose = u("</style")
    private let scriptName = u("script"), styleName = u("style")
    private let mustacheClose = u("}}"), blockClose = u("%}"), erbClose = u("%>"), templCommentClose = u("#}")

    init(language: Language) { lang = language }

    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32 {
        let n = s.count
        var mode = state & 0xF
        var tagKind = (state >> 4) & 0x3
        var inner = state >> 16
        var i = 0

        while i < n {
            switch mode {
            case MarkupLexer.mComment:
                if let e = find(s, commentClose, from: i) {
                    emit(i, e + 3 - i, .comment); i = e + 3; mode = MarkupLexer.mText
                } else { emit(i, n - i, .comment); return mode }
            case MarkupLexer.mCData:
                if let e = find(s, cdataClose, from: i) {
                    emit(i, e + 3 - i, .string); i = e + 3; mode = MarkupLexer.mText
                } else { emit(i, n - i, .string); return mode }
            case MarkupLexer.mDecl:
                var e = i
                while e < n && s[e] != 62 { e += 1 }
                if e < n { emit(i, e + 1 - i, .preprocessor); i = e + 1; mode = MarkupLexer.mText }
                else { emit(i, n - i, .preprocessor); return mode }
            case MarkupLexer.mDQ, MarkupLexer.mSQ:
                let q: UInt16 = mode == MarkupLexer.mDQ ? 34 : 39
                var e = i
                while e < n && s[e] != q { e += 1 }
                if e < n { emit(i, e + 1 - i, .string); i = e + 1; mode = MarkupLexer.mTag }
                else { emit(i, n - i, .string); return mode | tagKind << 4 }
            case MarkupLexer.mScript, MarkupLexer.mStyle:
                let isScript = mode == MarkupLexer.mScript
                let end = findCI(s, isScript ? scriptClose : styleClose, from: i) ?? n
                if end > i, let lx = isScript ? scriptLexer : styleLexer, let base = s.baseAddress {
                    let sub = UnsafeBufferPointer(start: base + i, count: end - i)
                    let off = i
                    inner = lx.lex(sub, state: inner, emit: { emit($0 + off, $1, $2) }) & 0xFFFF
                }
                if end < n { mode = MarkupLexer.mText; inner = 0; i = end }
                else { return mode | inner << 16 }
            case MarkupLexer.mTag:
                let c = s[i]
                if isSpaceU(c) { i += 1; continue }
                if c == 62 {
                    emit(i, 1, .punctuation)
                    i += 1
                    mode = tagKind == 1 ? MarkupLexer.mScript : (tagKind == 2 ? MarkupLexer.mStyle : MarkupLexer.mText)
                    tagKind = 0
                } else if c == 47 && i + 1 < n && s[i + 1] == 62 {
                    emit(i, 2, .punctuation); i += 2; mode = MarkupLexer.mText; tagKind = 0
                } else if c == 34 || c == 39 {
                    var e = i + 1
                    while e < n && s[e] != c { e += 1 }
                    if e < n { emit(i, e + 1 - i, .string); i = e + 1 }
                    else { emit(i, n - i, .string); return (c == 34 ? MarkupLexer.mDQ : MarkupLexer.mSQ) | tagKind << 4 }
                } else if c == 61 {
                    emit(i, 1, .operatorSymbol); i += 1
                } else if c == 123 {
                    var e = i + 1
                    while e < n && s[e] != 125 { e += 1 }
                    e = min(e + 1, n)
                    emit(i, e - i, .variable); i = e
                } else if c == 60 && i + 1 < n && s[i + 1] == 37 {
                    i = templateSpan(s, i, erbClose, .preprocessor, emit)
                } else {
                    var e = i
                    while e < n {
                        let d = s[e]
                        if isSpaceU(d) || d == 61 || d == 62 || d == 34 || d == 39 || (d == 47 && e + 1 < n && s[e + 1] == 62) { break }
                        e += 1
                    }
                    if e == i { e += 1 }
                    emit(i, e - i, .attribute); i = e
                }
            default:
                let c = s[i]
                if c == 60 {
                    if matchAt(s, i, commentOpen) {
                        if let e = find(s, commentClose, from: i + 4) { emit(i, e + 3 - i, .comment); i = e + 3 }
                        else { emit(i, n - i, .comment); return MarkupLexer.mComment }
                    } else if matchAt(s, i, cdataOpen) {
                        if let e = find(s, cdataClose, from: i + 9) { emit(i, e + 3 - i, .string); i = e + 3 }
                        else { emit(i, n - i, .string); return MarkupLexer.mCData }
                    } else if i + 1 < n && s[i + 1] == 37 {
                        i = templateSpan(s, i, erbClose, .preprocessor, emit)
                    } else if i + 1 < n && (s[i + 1] == 33 || s[i + 1] == 63) {
                        var e = i
                        while e < n && s[e] != 62 { e += 1 }
                        if e < n { emit(i, e + 1 - i, .preprocessor); i = e + 1 }
                        else { emit(i, n - i, .preprocessor); return MarkupLexer.mDecl }
                    } else if i + 1 < n && (isAlphaU(s[i + 1]) || (s[i + 1] == 47 && i + 2 < n && isAlphaU(s[i + 2]))) {
                        let closing = s[i + 1] == 47
                        let nameStart = closing ? i + 2 : i + 1
                        emit(i, nameStart - i, .punctuation)
                        var e = nameStart
                        while e < n && (isAlnumU(s[e]) || s[e] == 45 || s[e] == 58 || s[e] == 46) { e += 1 }
                        emit(nameStart, e - nameStart, .tag)
                        tagKind = 0
                        if !closing {
                            if e - nameStart == 6 && matchAtCI(s, nameStart, scriptName) { tagKind = 1 }
                            else if e - nameStart == 5 && matchAtCI(s, nameStart, styleName) { tagKind = 2 }
                        }
                        mode = MarkupLexer.mTag
                        i = e
                    } else {
                        i += 1
                    }
                } else if c == 38 {
                    var e = i + 1
                    while e < n && e < i + 12 && (isAlnumU(s[e]) || s[e] == 35) { e += 1 }
                    if e < n && s[e] == 59 && e > i + 1 { emit(i, e + 1 - i, .constant); i = e + 1 } else { i += 1 }
                } else if c == 123 && i + 1 < n && s[i + 1] == 123 {
                    i = templateSpan(s, i, mustacheClose, .variable, emit)
                } else if c == 123 && i + 1 < n && s[i + 1] == 37 {
                    i = templateSpan(s, i, blockClose, .keyword, emit)
                } else if c == 123 && i + 1 < n && s[i + 1] == 35 {
                    i = templateSpan(s, i, templCommentClose, .comment, emit)
                } else {
                    i += 1
                }
            }
        }
        return mode | tagKind << 4 | inner << 16
    }

    private func templateSpan(_ s: UnsafeBufferPointer<UInt16>, _ i: Int, _ close: [UInt16], _ kind: TokenKind, _ emit: TokenEmit) -> Int {
        let e = find(s, close, from: i + 2).map { $0 + close.count } ?? s.count
        emit(i, e - i, kind)
        return e
    }

    private func findCI(_ s: UnsafeBufferPointer<UInt16>, _ p: [UInt16], from: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == 60 && matchAtCI(s, i, p) { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Markdown

final class MarkdownLexer: Lexer {
    private let lang: Language
    private lazy var registry = LanguageRegistry.shared
    private lazy var indexById: [ObjectIdentifier: Int] = {
        var d: [ObjectIdentifier: Int] = [:]
        for (i, l) in registry.all.enumerated() { d[ObjectIdentifier(l)] = i }
        return d
    }()
    private let commentOpen = u("<!--"), commentClose = u("-->")

    init(language: Language) { lang = language }

    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32 {
        let n = s.count
        let mode = state & 0xF

        if mode == 1 || mode == 2 {
            var j = 0
            while j < n && j < 4 && s[j] == 32 { j += 1 }
            let fc: UInt16 = mode == 1 ? 96 : 126
            var k = j
            while k < n && s[k] == fc { k += 1 }
            // A closing fence must be at least as long as the opening one.
            if k - j >= max(3, Int((state >> 12) & 0xF)) && nextNonSpace(s, k) == n {
                emit(0, n, .punctuation)
                return 0
            }
            let li = Int((state >> 4) & 0xFF)
            if li > 0, li - 1 < registry.all.count {
                let l = registry.all[li - 1]
                if l.style != .markdown && l.style != .plain {
                    let inner = l.lexer.lex(s, state: state >> 16, emit: emit) & 0xFFFF
                    return (state & 0xFFFF) | inner << 16
                }
            }
            if n > 0 { emit(0, n, .code) }
            return state
        }

        var i = 0
        if mode == 3 {
            if let e = find(s, commentClose, from: 0) {
                emit(0, e + 3, .comment)
                i = e + 3
            } else {
                if n > 0 { emit(0, n, .comment) }
                return 3
            }
            return inline(s, from: i, emit: emit)
        }

        var j = 0
        while j < n && s[j] == 32 { j += 1 }
        if j >= n { return 0 }
        let c = s[j]

        if (c == 96 || c == 126) && j < 4 {
            var k = j
            while k < n && s[k] == c { k += 1 }
            if k - j >= 3 {
                emit(j, k - j, .punctuation)
                let infoStart = nextNonSpace(s, k)
                var infoEnd = infoStart
                while infoEnd < n && !isSpaceU(s[infoEnd]) && s[infoEnd] != 123 && s[infoEnd] != 44 { infoEnd += 1 }
                var langIndex = 0
                if infoEnd > infoStart, let base = s.baseAddress {
                    let name = String(utf16CodeUnits: base + infoStart, count: infoEnd - infoStart).lowercased()
                    emit(infoStart, infoEnd - infoStart, .keyword)
                    if let l = registry.language(id: name), let idx = indexById[ObjectIdentifier(l)], idx < 0xFF { langIndex = idx + 1 }
                }
                return (c == 96 ? 1 : 2) | UInt32(langIndex) << 4 | UInt32(min(k - j, 15)) << 12
            }
        }

        if c == 35 {
            var k = j
            while k < n && s[k] == 35 { k += 1 }
            if k - j <= 6 && (k == n || s[k] == 32 || s[k] == 9) {
                emit(j, n - j, .heading)
                return 0
            }
        }

        if c == 45 || c == 42 || c == 95 || c == 61 {
            var k = j
            var count = 0
            var only = true
            while k < n {
                if s[k] == c { count += 1 } else if !isSpaceU(s[k]) { only = false; break }
                k += 1
            }
            if only && count >= 3 {
                emit(j, n - j, c == 61 ? .heading : .punctuation)
                return 0
            }
        }

        i = j
        if c == 62 {
            var k = j
            while k < n && (s[k] == 62 || s[k] == 32) { k += 1 }
            emit(j, k - j, .comment)
            i = k
        }
        if i < n && (s[i] == 45 || s[i] == 42 || s[i] == 43) && i + 1 < n && s[i + 1] == 32 {
            emit(i, 1, .keyword)
            i += 2
        } else if i < n && isDigitU(s[i]) {
            var k = i
            while k < n && isDigitU(s[k]) { k += 1 }
            if k < n && (s[k] == 46 || s[k] == 41) && k + 1 < n && s[k + 1] == 32 {
                emit(i, k + 1 - i, .keyword)
                i = k + 2
            }
        }
        if i + 3 < n && s[i] == 91 && (s[i + 1] == 32 || (s[i + 1] | 0x20) == 120) && s[i + 2] == 93 && s[i + 3] == 32 {
            emit(i, 3, .constant)
            i += 4
        }
        return inline(s, from: i, emit: emit)
    }

    private func inline(_ s: UnsafeBufferPointer<UInt16>, from: Int, emit: TokenEmit) -> UInt32 {
        let n = s.count
        var i = from
        while i < n {
            let c = s[i]
            switch c {
            case 92:
                if i + 1 < n && !isAlnumU(s[i + 1]) && !isSpaceU(s[i + 1]) { emit(i, 2, .escape); i += 2 } else { i += 1 }
            case 96:
                var k = i
                while k < n && s[k] == 96 { k += 1 }
                let run = k - i
                var e = k
                var found = -1
                while e < n {
                    if s[e] == 96 {
                        var r = e
                        while r < n && s[r] == 96 { r += 1 }
                        if r - e == run { found = r; break }
                        e = r
                    } else { e += 1 }
                }
                if found > 0 { emit(i, found - i, .code); i = found } else { i = k }
            case 42, 95, 126:
                var k = i
                while k < n && s[k] == c && k - i < 3 { k += 1 }
                let run = k - i
                if c == 95 && i > 0 && isWordU(s[i - 1]) { i = k; continue }
                if c == 126 && run < 2 { i = k; continue }
                if k >= n || isSpaceU(s[k]) { i = k; continue }
                var e = k
                var found = -1
                while e + run <= n {
                    if s[e] == c && !isSpaceU(s[e - 1]) {
                        var r = e
                        while r < n && s[r] == c { r += 1 }
                        if r - e >= run && !(c == 95 && r < n && isWordU(s[r])) { found = e + run; break }
                        e = r
                    } else { e += 1 }
                }
                if found > 0 {
                    let kind: TokenKind = c == 126 ? .deleted : (run >= 2 ? .strong : .emphasis)
                    emit(i, found - i, kind)
                    i = found
                } else { i = k }
            case 33, 91:
                let open = c == 33 ? i + 1 : i
                guard open < n, s[open] == 91 else { i += 1; continue }
                var e = open + 1
                var depth = 1
                while e < n {
                    if s[e] == 91 { depth += 1 } else if s[e] == 93 { depth -= 1; if depth == 0 { break } }
                    e += 1
                }
                guard e < n else { i += 1; continue }
                emit(i, e + 1 - i, .link)
                i = e + 1
                if i < n && (s[i] == 40 || s[i] == 91) {
                    let close: UInt16 = s[i] == 40 ? 41 : 93
                    var k = i + 1
                    while k < n && s[k] != close { k += 1 }
                    if k < n { emit(i, k + 1 - i, .string); i = k + 1 }
                } else if i < n && s[i] == 58 {
                    emit(i, n - i, .string)
                    i = n
                }
            case 60:
                if matchAt(s, i, commentOpen) {
                    if let e = find(s, commentClose, from: i + 4) { emit(i, e + 3 - i, .comment); i = e + 3 }
                    else { emit(i, n - i, .comment); return 3 }
                } else if i + 1 < n && (isAlphaU(s[i + 1]) || s[i + 1] == 47) {
                    var e = i + 1
                    while e < n && s[e] != 62 { e += 1 }
                    if e < n {
                        let isLink = (s[i + 1] | 0x20) == 104 && e - i > 8
                        emit(i, e + 1 - i, isLink ? .link : .tag)
                        i = e + 1
                    } else { i += 1 }
                } else { i += 1 }
            case 104:
                if i + 7 < n && s[i + 1] == 116 && s[i + 2] == 116 && s[i + 3] == 112 && (i == 0 || !isWordU(s[i - 1])) {
                    var e = i
                    while e < n && !isSpaceU(s[e]) && s[e] != 41 && s[e] != 62 { e += 1 }
                    if e - i > 8 { emit(i, e - i, .link) }
                    i = e
                } else { i += 1 }
            case 124:
                emit(i, 1, .punctuation)
                i += 1
            default:
                i += 1
            }
        }
        return 0
    }
}

// MARK: - Find results

final class FindResultsLexer: Lexer {
    func lex(_ s: UnsafeBufferPointer<UInt16>, state: UInt32, emit: TokenEmit) -> UInt32 {
        let n = s.count
        guard n > 0 else { return 0 }
        if s[0] != 32 {
            emit(0, n, s[n - 1] == 58 ? .heading : .comment)
            return 0
        }
        var i = nextNonSpace(s, 0)
        let start = i
        while i < n && isDigitU(s[i]) { i += 1 }
        if i > start {
            emit(start, i - start, .number)
            if i < n && s[i] == 58 { emit(i, 1, .punctuation) }
        }
        return 0
    }
}
