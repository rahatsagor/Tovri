import Foundation

enum JSONFormatError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let detail): return detail }
    }
}

/// Re-indents or minifies JSON without parsing it into objects, so key order, number spelling
/// and string escapes stay exactly as written.
enum JSONFormatter {
    /// `indent` nil minifies.
    static func reformat(_ text: String, indent: String?) throws -> String {
        let bytes = Array(text.utf8)
        try validate(bytes)
        let unit = Array((indent ?? "").utf8)
        let pretty = indent != nil
        var out: [UInt8] = []
        out.reserveCapacity(pretty ? bytes.count * 2 : bytes.count)
        var depth = 0
        var inString = false
        var escaped = false
        func newline() {
            out.append(10)
            for _ in 0..<depth { out.append(contentsOf: unit) }
        }
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        var i = 0
        let n = bytes.count
        if n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { i = 3 }
        while i < n {
            let c = bytes[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { inString = false }
                i += 1
                continue
            }
            switch c {
            case 34:
                inString = true
                out.append(c)
            case 123, 91:
                var j = i + 1
                while j < n && isSpace(bytes[j]) { j += 1 }
                if j < n && (bytes[j] == 125 || bytes[j] == 93) {
                    out.append(c)
                    out.append(bytes[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                depth += 1
                if pretty { newline() }
            case 125, 93:
                depth -= 1
                if pretty { newline() }
                out.append(c)
            case 44:
                // JSONSerialization accepts trailing commas, but they aren't JSON.
                var j = i + 1
                while j < n && isSpace(bytes[j]) { j += 1 }
                if j < n && (bytes[j] == 125 || bytes[j] == 93) { throw JSONFormatError.invalid("Trailing comma before “\(bytes[j] == 125 ? "}" : "]")”.") }
                out.append(c)
                if pretty { newline() }
            case 58:
                out.append(c)
                if pretty { out.append(32) }
            case 32, 9, 10, 13:
                break
            default:
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private enum Expect { case value, valueOrClose, valueAfterComma, keyOrClose, key, colon, commaOrClose, end }

    /// Checks the RFC 8259 grammar only. JSONSerialization also checks what Foundation can
    /// represent, so it rejects valid JSON such as `1e400`, a lone `\ud800` or deep nesting.
    /// Iterative, so deeply nested input can't overflow the stack.
    static func validate(_ b: [UInt8]) throws {
        let n = b.count
        var i = n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF ? 3 : 0
        var objects: [Bool] = []
        var expect = Expect.value

        func fail(_ message: String, at k: Int) -> JSONFormatError {
            var line = 1
            var lineStart = 0
            var j = 0
            while j < min(k, n) {
                if b[j] == 10 { line += 1; lineStart = j + 1 }
                j += 1
            }
            let column = String(decoding: b[lineStart..<min(k, n)], as: UTF8.self).count + 1
            return .invalid("\(message) on line \(line), column \(column).")
        }
        func unexpected(_ k: Int) -> JSONFormatError {
            guard k < n else { return fail("The JSON ends too early", at: n) }
            let end = b[k] < 0x80 ? k + 1 : min(n, k + 1 + b[(k + 1)...].prefix { $0 & 0xC0 == 0x80 }.count)
            return fail("Unexpected “\(String(decoding: b[k..<end], as: UTF8.self))”", at: k)
        }
        func isHex(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c | 0x20 >= 97 && c | 0x20 <= 102) }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

        func scanString() throws {
            let start = i
            i += 1
            while i < n {
                let c = b[i]
                if c == 34 { i += 1; return }
                if c < 0x20 { throw fail("A string can’t contain a line break or control character", at: i) }
                if c == 92 {
                    guard i + 1 < n else { break }
                    let e = b[i + 1]
                    switch e {
                    case 34, 92, 47, 98, 102, 110, 114, 116: i += 2
                    case 117:
                        guard i + 5 < n, isHex(b[i + 2]), isHex(b[i + 3]), isHex(b[i + 4]), isHex(b[i + 5]) else {
                            throw fail("“\\u” must be followed by four hex digits", at: i)
                        }
                        i += 6
                    default: throw fail("Unknown escape “\\\(String(decoding: [e], as: UTF8.self))”", at: i)
                    }
                    continue
                }
                i += 1
            }
            throw fail("A string isn’t closed", at: start)
        }

        func scanNumber() throws {
            let start = i
            if b[i] == 45 { i += 1 }
            guard i < n, isDigit(b[i]) else { throw unexpected(i) }
            if b[i] == 48 { i += 1 } else { while i < n && isDigit(b[i]) { i += 1 } }
            if i < n && b[i] == 46 {
                i += 1
                guard i < n, isDigit(b[i]) else { throw fail("A number needs digits after “.”", at: start) }
                while i < n && isDigit(b[i]) { i += 1 }
            }
            if i < n && (b[i] == 101 || b[i] == 69) {
                i += 1
                if i < n && (b[i] == 43 || b[i] == 45) { i += 1 }
                guard i < n, isDigit(b[i]) else { throw fail("A number needs digits after “e”", at: start) }
                while i < n && isDigit(b[i]) { i += 1 }
            }
            if i < n && (isDigit(b[i]) || b[i] == 46 || b[i] == 101 || b[i] == 69 || b[i] == 43 || b[i] == 45) { throw unexpected(i) }
        }

        func scanLiteral(_ word: StaticString) throws {
            let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
            guard i + w.count <= n, b[i..<(i + w.count)].elementsEqual(w) else { throw unexpected(i) }
            i += w.count
        }

        func afterValue() { expect = objects.isEmpty ? .end : .commaOrClose }

        while true {
            while i < n && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13) { i += 1 }
            guard i < n else { break }
            let c = b[i]
            switch expect {
            case .value, .valueOrClose, .valueAfterComma:
                if c == 93 && expect == .valueOrClose { objects.removeLast(); i += 1; afterValue(); continue }
                if c == 93 || c == 125, expect == .valueAfterComma {
                    throw fail("Trailing comma before “\(c == 125 ? "}" : "]")”", at: i)
                }
                switch c {
                case 123: objects.append(true); i += 1; expect = .keyOrClose
                case 91: objects.append(false); i += 1; expect = .valueOrClose
                case 34: try scanString(); afterValue()
                case 45, 48...57: try scanNumber(); afterValue()
                case 116: try scanLiteral("true"); afterValue()
                case 102: try scanLiteral("false"); afterValue()
                case 110: try scanLiteral("null"); afterValue()
                default: throw unexpected(i)
                }
            case .keyOrClose, .key:
                if c == 125 && expect == .keyOrClose { objects.removeLast(); i += 1; afterValue(); continue }
                if c == 125 { throw fail("Trailing comma before “}”", at: i) }
                guard c == 34 else { throw fail("Expected a key in quotes", at: i) }
                try scanString()
                expect = .colon
            case .colon:
                guard c == 58 else { throw fail("Expected “:” after the key", at: i) }
                i += 1
                expect = .value
            case .commaOrClose:
                let inObject = objects[objects.count - 1]
                if c == 44 {
                    i += 1
                    expect = inObject ? .key : .valueAfterComma
                } else if c == (inObject ? 125 : 93) {
                    objects.removeLast()
                    i += 1
                    afterValue()
                } else {
                    throw fail(inObject ? "Expected “,” or “}”" : "Expected “,” or “]”", at: i)
                }
            case .end:
                throw fail("Unexpected text after the JSON value", at: i)
            }
        }
        guard expect == .end else { throw fail("The JSON ends too early", at: n) }
    }
}
