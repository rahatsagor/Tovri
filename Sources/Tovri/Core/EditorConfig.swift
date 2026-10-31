import Foundation

/// Reads `.editorconfig` files (https://editorconfig.org). Nearer files override farther ones,
/// later sections override earlier ones, and a file with `root = true` stops the search.
enum EditorConfig {
    struct Properties: Equatable {
        var values: [String: String] = [:]

        var indentsWithTabs: Bool? {
            switch values["indent_style"] { case "tab": return true; case "space": return false; default: return nil }
        }
        var indentSize: Int? { values["indent_size"].flatMap { Int($0) } }
        var tabWidth: Int? { values["tab_width"].flatMap { Int($0) } ?? (values["indent_size"] == "tab" ? nil : indentSize) }
        var lineEnding: LineEnding? {
            switch values["end_of_line"] { case "lf": return .lf; case "crlf": return .crlf; case "cr": return .cr; default: return nil }
        }
        var encoding: TextEncoding? {
            switch values["charset"] {
            case "utf-8": return .utf8
            case "utf-8-bom": return .utf8BOM
            case "utf-16le": return .utf16LE
            case "utf-16be": return .utf16BE
            case "latin1": return .latin1
            default: return nil
            }
        }
        var trimTrailingWhitespace: Bool? { bool("trim_trailing_whitespace") }
        var insertFinalNewline: Bool? { bool("insert_final_newline") }

        private func bool(_ key: String) -> Bool? {
            switch values[key] { case "true": return true; case "false": return false; default: return nil }
        }
    }

    private struct Section {
        let glob: EditorConfigGlob
        let values: [String: (String, original: String)]
    }

    private struct ConfigFile {
        let directory: String
        let isRoot: Bool
        let sections: [Section]
    }

    private static var cache: [String: (date: Date?, file: ConfigFile?)] = [:]
    private static let lock = NSLock()

    static func properties(for url: URL) -> Properties {
        let path = url.standardizedFileURL.path
        var files: [ConfigFile] = []
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<64 {
            if let f = load(dir.appendingPathComponent(".editorconfig")) {
                files.append(f)
                if f.isRoot { break }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        var result = Properties()
        for f in files.reversed() {
            guard path.hasPrefix(f.directory + "/") else { continue }
            let relative = String(path.dropFirst(f.directory.count + 1))
            for s in f.sections where s.glob.matches(relative) {
                for (k, v) in s.values {
                    if v.0 == "unset" { result.values.removeValue(forKey: k) } else { result.values[k] = v.0 }
                }
            }
        }
        return result
    }

    private static func load(_ url: URL) -> ConfigFile? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        if let hit = cache[url.path], hit.date == date { lock.unlock(); return hit.file }
        lock.unlock()
        let file = date == nil ? nil : (try? String(contentsOf: url, encoding: .utf8)).map {
            parse($0, directory: url.deletingLastPathComponent().standardizedFileURL.path)
        }
        lock.lock()
        cache[url.path] = (date, file)
        lock.unlock()
        return file
    }

    private static func parse(_ text: String, directory: String) -> ConfigFile {
        var isRoot = false
        var sections: [Section] = []
        var glob: String?
        var values: [String: (String, original: String)] = [:]
        func flush() {
            if let g = glob.flatMap(EditorConfigGlob.init) { sections.append(Section(glob: g, values: values)) }
            values = [:]
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                glob = String(line.dropFirst().dropLast())
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if glob == nil {
                if key == "root" { isRoot = value.lowercased() == "true" }
            } else {
                values[key] = (value.lowercased(), original: value)
            }
        }
        flush()
        return ConfigFile(directory: directory, isRoot: isRoot, sections: sections)
    }

    static func globMatches(_ glob: String, directory: String, path: String) -> Bool {
        guard path.hasPrefix(directory + "/"), let g = EditorConfigGlob(glob) else { return false }
        return g.matches(String(path.dropFirst(directory.count + 1)))
    }

}


/// EditorConfig globs, matched without regular expressions: a regex built from several `*`
/// backtracks exponentially, so a hostile `.editorconfig` could freeze the app on every open.
struct EditorConfigGlob {
    private enum Token {
        case literal(Unicode.Scalar)
        case any
        case star
        case globstar
        /// `**/`: zero or more whole folders.
        case folders
        case set([ClosedRange<UInt32>], negated: Bool)
        case number(ClosedRange<Int>)
    }

    private let alternatives: [[Token]]
    private let anchored: Bool

    private static let maxLength = 512
    private static let maxAlternatives = 256

    init?(_ glob: String) {
        guard glob.unicodeScalars.count <= EditorConfigGlob.maxLength else { return nil }
        var g = Array(glob.unicodeScalars)
        anchored = g.contains("/")
        if g.first == "/" { g.removeFirst() }
        var i = 0
        guard let alts = EditorConfigGlob.sequence(g, &i, inBraces: false), i == g.count else { return nil }
        alternatives = alts
    }

    /// `path` is relative to the folder holding the `.editorconfig`.
    func matches(_ path: String) -> Bool {
        let s = Array(path.unicodeScalars)
        return alternatives.contains { EditorConfigGlob.match(anchored ? $0 : [.folders] + $0, s) }
    }

    private static func sequence(_ g: [Unicode.Scalar], _ i: inout Int, inBraces: Bool) -> [[Token]]? {
        var results: [[Token]] = [[]]
        func append(_ t: Token) { for k in results.indices { results[k].append(t) } }
        while i < g.count {
            let c = g[i]
            if inBraces && (c == "," || c == "}") { break }
            switch c {
            case "*":
                if i + 1 < g.count && g[i + 1] == "*" {
                    i += 2
                    while i < g.count && g[i] == "*" { i += 1 }
                    if i < g.count && g[i] == "/" { append(.folders); i += 1 } else { append(.globstar) }
                    continue
                }
                append(.star)
            case "?":
                append(.any)
            case "[":
                if let (token, end) = charClass(g, from: i) { append(token); i = end } else { append(.literal("[")) }
            case "{":
                guard let close = matchingBrace(g, from: i) else { append(.literal("{")); break }
                let body = String(String.UnicodeScalarView(g[(i + 1)..<close]))
                let ends = body.components(separatedBy: "..")
                if ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]) {
                    append(.number(min(a, b)...max(a, b)))
                    i = close + 1
                    continue
                }
                guard g[(i + 1)..<close].contains(",") else {
                    for s in g[i...close] { append(.literal(s)) }
                    i = close + 1
                    continue
                }
                i += 1
                var options: [[Token]] = []
                while true {
                    guard let part = sequence(g, &i, inBraces: true) else { return nil }
                    options += part
                    guard i < g.count else { return nil }
                    if g[i] == "," { i += 1; continue }
                    i += 1
                    break
                }
                var product: [[Token]] = []
                for r in results { for o in options { product.append(r + o) } }
                guard product.count <= maxAlternatives else { return nil }
                results = product
                continue
            case "\\" where i + 1 < g.count:
                i += 1
                append(.literal(g[i]))
            default:
                append(.literal(c))
            }
            i += 1
        }
        return results
    }

    private static func matchingBrace(_ g: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < g.count {
            switch g[i] {
            case "\\": i += 1
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    private static func charClass(_ g: [Unicode.Scalar], from start: Int) -> (Token, Int)? {
        var i = start + 1
        var negated = false
        if i < g.count && (g[i] == "!" || g[i] == "^") { negated = true; i += 1 }
        var ranges: [ClosedRange<UInt32>] = []
        var first = true
        while i < g.count {
            var c = g[i]
            if c == "]" && !first { return (.set(ranges, negated: negated), i) }
            if c == "/" { return nil }
            if c == "\\" && i + 1 < g.count { i += 1; c = g[i] }
            if i + 2 < g.count && g[i + 1] == "-" && g[i + 2] != "]" {
                let hi = g[i + 2]
                ranges.append(min(c.value, hi.value)...max(c.value, hi.value))
                i += 3
            } else {
                ranges.append(c.value...c.value)
                i += 1
            }
            first = false
        }
        return nil
    }

    /// Memoized over (token, position), so matching is O(tokens × path length) at worst.
    private static func match(_ t: [Token], _ s: [Unicode.Scalar]) -> Bool {
        let width = s.count + 1
        var memo = [UInt8](repeating: 0, count: (t.count + 1) * width)
        func m(_ ti: Int, _ si: Int) -> Bool {
            if ti == t.count { return si == s.count }
            let key = ti * width + si
            if memo[key] != 0 { return memo[key] == 2 }
            var r = false
            switch t[ti] {
            case .literal(let c):
                r = si < s.count && s[si] == c && m(ti + 1, si + 1)
            case .any:
                r = si < s.count && s[si] != "/" && m(ti + 1, si + 1)
            case .star:
                var j = si
                while true {
                    if m(ti + 1, j) { r = true; break }
                    if j >= s.count || s[j] == "/" { break }
                    j += 1
                }
            case .globstar:
                var j = si
                while j <= s.count {
                    if m(ti + 1, j) { r = true; break }
                    j += 1
                }
            case .folders:
                if m(ti + 1, si) { r = true; break }
                var j = si
                while j < s.count {
                    if s[j] == "/" && m(ti + 1, j + 1) { r = true; break }
                    j += 1
                }
            case .set(let ranges, let negated):
                if si < s.count && s[si] != "/" {
                    let v = s[si].value
                    r = ranges.contains { $0.contains(v) } != negated && m(ti + 1, si + 1)
                }
            case .number(let range):
                var j = si
                if j < s.count && s[j] == "-" { j += 1 }
                var k = j
                while k < s.count && k - j < 18 && ("0"..."9").contains(s[k]) {
                    k += 1
                    if let n = Int(String(String.UnicodeScalarView(s[si..<k]))), range.contains(n), m(ti + 1, k) { r = true; break }
                }
            }
            memo[key] = r ? 2 : 1
            return r
        }
        return m(0, 0)
    }
}
