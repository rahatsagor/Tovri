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
        try validate(text)
        let bytes = Array(text.utf8)
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

    private static func validate(_ text: String) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch let error as NSError {
            let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? (error.userInfo["NSJSONSerializationErrorIndex"].map { "Invalid JSON near character \($0)." })
                ?? error.localizedDescription
            throw JSONFormatError.invalid(detail)
        }
    }
}
