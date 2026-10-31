import Foundation

/// GitHub-flavored Markdown to HTML. Top-level blocks carry `data-line` so the preview can follow
/// the editor's scroll position; fenced code is highlighted with Tovri's own lexers.
struct MarkdownRenderer {
    var colors: [TokenKind: String] = [:]

    private var references: [String: (url: String, title: String?)] = [:]

    init(colors: [TokenKind: String]) {
        self.colors = colors
    }

    mutating func render(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        references = [:]
        collectReferences(&lines)
        var out = ""
        renderBlocks(lines[...], lineOffset: 0, topLevel: true, into: &out)
        return out
    }

    // MARK: Blocks

    private static let fenceRe = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)"#)
    private static let headingRe = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$"#)
    private static let hrRe = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let listRe = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)"#)
    private static let tableDelimRe = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    private static let refRe = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#)
    private static let htmlBlockRe = try! NSRegularExpression(pattern: #"^ {0,3}<(/?(?:address|article|aside|blockquote|details|summary|dialog|div|dl|dt|dd|fieldset|figure|figcaption|footer|form|h[1-6]|header|hr|iframe|li|main|nav|ol|p|picture|pre|section|source|table|tbody|td|tfoot|th|thead|tr|ul|video|audio|img|br|center)\b|!--)"#, options: .caseInsensitive)

    private func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }

    private mutating func collectReferences(_ lines: inout [String]) {
        var inFence = false
        for i in lines.indices {
            if match(MarkdownRenderer.fenceRe, lines[i]) != nil { inFence.toggle() }
            guard !inFence, let m = match(MarkdownRenderer.refRe, lines[i]),
                  let label = group(m, 1, lines[i]), let url = group(m, 2, lines[i]) else { continue }
            references[label.lowercased()] = (url, group(m, 3, lines[i]))
            lines[i] = "\u{1}"
        }
    }

    private func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } || s == "\u{1}" }

    private func indent(of s: String) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break } }
        return n
    }

    private func dedent(_ s: String, _ count: Int) -> String {
        var removed = 0
        var idx = s.startIndex
        while idx < s.endIndex && removed < count {
            if s[idx] == " " { removed += 1 } else if s[idx] == "\t" { removed += 4 - removed % 4 } else { break }
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    private func startsBlock(_ s: String) -> Bool {
        match(MarkdownRenderer.fenceRe, s) != nil || match(MarkdownRenderer.headingRe, s) != nil ||
        match(MarkdownRenderer.hrRe, s) != nil || s.trimmingCharacters(in: .whitespaces).hasPrefix(">") ||
        match(MarkdownRenderer.listRe, s) != nil || match(MarkdownRenderer.htmlBlockRe, s) != nil
    }

    private func attr(_ line: Int, _ top: Bool) -> String { top ? " data-line=\"\(line)\"" : "" }

    private mutating func renderBlocks(_ lines: ArraySlice<String>, lineOffset: Int, topLevel: Bool, into out: inout String) {
        var i = lines.startIndex
        let end = lines.endIndex
        func abs(_ k: Int) -> Int { lineOffset + (k - lines.startIndex) }

        // YAML front matter
        if topLevel && lineOffset == 0, i < end, lines[i] == "---" {
            var k = i + 1
            while k < end && lines[k] != "---" && lines[k] != "..." { k += 1 }
            if k < end {
                out += "<pre class=\"front-matter\" data-line=\"0\"><code>" + esc(lines[(i + 1)..<k].joined(separator: "\n")) + "</code></pre>\n"
                i = k + 1
            }
        }

        while i < end {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            let a = attr(abs(i), topLevel)

            if let m = match(MarkdownRenderer.fenceRe, line), let fence = group(m, 1, line) {
                let lang = (group(m, 2, line) ?? "").lowercased()
                let fenceIndent = indent(of: line)
                var k = i + 1
                var body: [String] = []
                while k < end {
                    let t = lines[k].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(String(fence.first!)) && t.allSatisfy({ $0 == fence.first! }) && t.count >= fence.count { break }
                    body.append(dedent(lines[k], fenceIndent))
                    k += 1
                }
                out += "<pre\(a)><code\(lang.isEmpty ? "" : " class=\"language-\(esc(lang))\"")>" + highlight(body, language: lang) + "</code></pre>\n"
                i = k + 1
                continue
            }

            if let m = match(MarkdownRenderer.headingRe, line), let hashes = group(m, 1, line) {
                let content = group(m, 2, line) ?? ""
                let n = hashes.count
                out += "<h\(n) id=\"\(slug(content))\"\(a)>" + inline(content) + "</h\(n)>\n"
                i += 1
                continue
            }

            if match(MarkdownRenderer.hrRe, line) != nil {
                out += "<hr\(a)>\n"
                i += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var k = i
                var inner: [String] = []
                while k < end {
                    let t = lines[k]
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix(">") {
                        var rest = Substring(trimmed.dropFirst())
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !isBlank(t) && !inner.isEmpty && !isBlank(inner.last!) && !startsBlock(t) {
                        inner.append(t)
                    } else { break }
                    k += 1
                }
                var body = ""
                renderBlocks(inner[...], lineOffset: abs(i), topLevel: false, into: &body)
                let alert = alertKind(inner.first ?? "")
                if let alert {
                    if let r = body.range(of: "[!\(alert)]", options: .caseInsensitive) { body.removeSubrange(r) }
                    out += "<blockquote class=\"alert alert-\(alert)\"\(a)><p class=\"alert-title\">\(alert.capitalized)</p>" + body + "</blockquote>\n"
                } else {
                    out += "<blockquote\(a)>" + body + "</blockquote>\n"
                }
                i = k
                continue
            }

            if let m = match(MarkdownRenderer.listRe, line) {
                i = renderList(lines, from: i, first: m, lineOffset: lineOffset, topLevel: topLevel, into: &out)
                continue
            }

            if i + 1 < end, line.contains("|"), match(MarkdownRenderer.tableDelimRe, lines[i + 1]) != nil, lines[i + 1].contains("-") {
                i = renderTable(lines, from: i, attr: a, into: &out)
                continue
            }

            if match(MarkdownRenderer.htmlBlockRe, line) != nil {
                var k = i
                var html: [String] = []
                while k < end && !isBlank(lines[k]) { html.append(lines[k]); k += 1 }
                out += "<div class=\"html\"\(a)>" + html.joined(separator: "\n") + "</div>\n"
                i = k
                continue
            }

            if indent(of: line) >= 4 {
                var k = i
                var body: [String] = []
                while k < end && (indent(of: lines[k]) >= 4 || isBlank(lines[k])) { body.append(dedent(lines[k], 4)); k += 1 }
                while let last = body.last, isBlank(last) { body.removeLast() }
                out += "<pre\(a)><code>" + esc(body.joined(separator: "\n")) + "</code></pre>\n"
                i = k
                continue
            }

            // Paragraph (with setext heading detection)
            var k = i
            var para: [String] = []
            var setext = 0
            while k < end && !isBlank(lines[k]) {
                let t = lines[k]
                if !para.isEmpty {
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed.allSatisfy({ $0 == "=" }) { setext = 1; k += 1; break }
                    if !trimmed.isEmpty && trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2 { setext = 2; k += 1; break }
                    if startsBlock(t) { break }
                }
                para.append(t.trimmingCharacters(in: .whitespaces) == t ? t : String(t.drop(while: { $0 == " " })))
                k += 1
            }
            let content = para.joined(separator: "\n")
            if setext > 0 {
                out += "<h\(setext) id=\"\(slug(content))\"\(a)>" + inline(content) + "</h\(setext)>\n"
            } else {
                out += "<p\(a)>" + inline(content) + "</p>\n"
            }
            i = k
        }
    }

    private func alertKind(_ first: String) -> String? {
        let t = first.trimmingCharacters(in: .whitespaces).lowercased()
        for k in ["note", "tip", "important", "warning", "caution"] where t.hasPrefix("[!\(k)]") { return k }
        return nil
    }

    private mutating func renderList(_ lines: ArraySlice<String>, from start: Int, first: NSTextCheckingResult, lineOffset: Int,
                                     topLevel: Bool, into out: inout String) -> Int {
        let end = lines.endIndex
        let firstLine = lines[start]
        let marker = group(first, 2, firstLine) ?? "-"
        let ordered = marker.first!.isNumber
        let startNumber = ordered ? Int(marker.dropLast()) ?? 1 : 1
        var items: [(line: Int, body: [String])] = []
        var loose = false
        var i = start
        var blankPending = false
        while i < end {
            let line = lines[i]
            if let m = match(MarkdownRenderer.listRe, line) {
                let mk = group(m, 2, line) ?? ""
                if mk.first!.isNumber != ordered || (!ordered && mk != marker) { break }
                if blankPending { loose = true }
                blankPending = false
                let contentIndent = (m.range.length) + 0
                let content = (line as NSString).substring(from: min(m.range.length, (line as NSString).length))
                items.append((lineOffset + (i - lines.startIndex), [content]))
                var k = i + 1
                while k < end {
                    let t = lines[k]
                    if isBlank(t) {
                        items[items.count - 1].body.append("")
                        k += 1
                        continue
                    }
                    if indent(of: t) >= max(2, contentIndent) {
                        items[items.count - 1].body.append(dedent(t, contentIndent))
                    } else if match(MarkdownRenderer.listRe, t) == nil && !startsBlock(t) && items[items.count - 1].body.last != "" {
                        items[items.count - 1].body.append(t.trimmingCharacters(in: .whitespaces))
                    } else { break }
                    k += 1
                }
                while let last = items[items.count - 1].body.last, last.isEmpty {
                    items[items.count - 1].body.removeLast()
                    blankPending = true
                }
                i = k
                if i < end, isBlank(lines[i]) { blankPending = true; i += 1 }
                while i < end, isBlank(lines[i]) { i += 1 }
            } else { break }
        }
        let tag = ordered ? "ol" : "ul"
        let startAttr = ordered && startNumber != 1 ? " start=\"\(startNumber)\"" : ""
        let hasTasks = items.contains { $0.body.first.map { $0.hasPrefix("[ ] ") || $0.lowercased().hasPrefix("[x] ") } ?? false }
        out += "<\(tag)\(startAttr)\(hasTasks ? " class=\"contains-task-list\"" : "")\(attr(items.first?.line ?? 0, topLevel))>\n"
        for item in items {
            var body = item.body
            var checkbox = ""
            if let f = body.first {
                if f.hasPrefix("[ ] ") { checkbox = "<input type=\"checkbox\" disabled> "; body[0] = String(f.dropFirst(4)) }
                else if f.lowercased().hasPrefix("[x] ") { checkbox = "<input type=\"checkbox\" checked disabled> "; body[0] = String(f.dropFirst(4)) }
            }
            var inner = ""
            renderBlocks(body[...], lineOffset: item.line, topLevel: false, into: &inner)
            if !loose, inner.hasPrefix("<p>") {
                if let close = inner.range(of: "</p>\n") {
                    inner = String(inner[inner.index(inner.startIndex, offsetBy: 3)..<close.lowerBound]) + String(inner[close.upperBound...])
                }
            }
            out += "<li\(checkbox.isEmpty ? "" : " class=\"task-list-item\"")>" + checkbox + inner + "</li>\n"
        }
        out += "</\(tag)>\n"
        return i
    }

    private func splitRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var prev: Character = " "
        var inCode = false
        for c in t {
            if c == "`" { inCode.toggle() }
            if c == "|" && prev != "\\" && !inCode { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(c) }
            prev = c
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private func renderTable(_ lines: ArraySlice<String>, from start: Int, attr a: String, into out: inout String) -> Int {
        let header = splitRow(lines[start])
        let aligns: [String] = splitRow(lines[start + 1]).map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? "center" : (r ? "right" : (l ? "left" : ""))
        }
        func cell(_ tag: String, _ text: String, _ i: Int) -> String {
            let al = i < aligns.count && !aligns[i].isEmpty ? " style=\"text-align:\(aligns[i])\"" : ""
            return "<\(tag)\(al)>" + inline(text) + "</\(tag)>"
        }
        out += "<table\(a)><thead><tr>" + header.enumerated().map { cell("th", $0.element, $0.offset) }.joined() + "</tr></thead><tbody>\n"
        var i = start + 2
        while i < lines.endIndex, !isBlank(lines[i]), lines[i].contains("|") {
            let cells = splitRow(lines[i])
            out += "<tr>" + (0..<header.count).map { cell("td", $0 < cells.count ? cells[$0] : "", $0) }.joined() + "</tr>\n"
            i += 1
        }
        out += "</tbody></table>\n"
        return i
    }

    // MARK: Inline

    private static let codeSpanRe = try! NSRegularExpression(pattern: #"(`+)(.+?)(?<!`)\1(?!`)"#, options: .dotMatchesLineSeparators)
    private static let imageRe = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let linkRe = try! NSRegularExpression(pattern: #"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let refLinkRe = try! NSRegularExpression(pattern: #"(!?)\[((?:[^\[\]]|\[[^\]]*\])+)\](?:\[([^\]]*)\])?"#)
    private static let autoLinkRe = try! NSRegularExpression(pattern: #"<((?:https?|mailto|ftp):[^>\s]+)>"#)
    private static let rawHTMLRe = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][\w:.-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>|<!--.*?-->"#, options: .dotMatchesLineSeparators)
    private static let bareURLRe = try! NSRegularExpression(pattern: #"(?<![\w"'=/])(https?://[^\s<>()]+[^\s<>().,;:!?"'])"#)
    private static let strongRe = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, options: .dotMatchesLineSeparators)
    private static let emRe = try! NSRegularExpression(pattern: #"(?<![\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)|(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#, options: .dotMatchesLineSeparators)
    private static let strikeRe = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#, options: .dotMatchesLineSeparators)
    private static let escapeRe = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|<>~])"#)

    private func inline(_ text: String) -> String {
        var stash: [String] = []
        func hold(_ html: String) -> String {
            stash.append(html)
            return "\u{2}\(stash.count - 1)\u{3}"
        }
        func replace(_ re: NSRegularExpression, in s: String, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += f(m, ns)
                last = NSMaxRange(m.range)
            }
            return out + ns.substring(from: last)
        }
        func g(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        var s = replace(MarkdownRenderer.escapeRe, in: text) { m, ns in hold(esc(ns.substring(with: m.range(at: 1)))) }
        s = replace(MarkdownRenderer.codeSpanRe, in: s) { m, ns in
            var code = ns.substring(with: m.range(at: 2))
            if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
            return hold("<code>" + esc(code) + "</code>")
        }
        s = replace(MarkdownRenderer.imageRe, in: s) { m, ns in
            let alt = g(m, 1, ns) ?? ""
            let src = resolve(g(m, 2, ns) ?? "")
            let title = g(m, 3, ns).map { " title=\"\(esc($0))\"" } ?? ""
            return hold("<img src=\"\(esc(src))\" alt=\"\(esc(alt))\"\(title)>")
        }
        s = replace(MarkdownRenderer.linkRe, in: s) { m, ns in
            let label = g(m, 1, ns) ?? ""
            let href = resolve(g(m, 2, ns) ?? "", isLink: true)
            let title = g(m, 3, ns).map { " title=\"\(esc($0))\"" } ?? ""
            return hold("<a href=\"\(esc(href))\"\(title)>" + inline(label) + "</a>")
        }
        if !references.isEmpty {
            s = replace(MarkdownRenderer.refLinkRe, in: s) { m, ns in
                let whole = ns.substring(with: m.range)
                let label = g(m, 2, ns) ?? ""
                var key = (g(m, 3, ns) ?? "").lowercased()
                if key.isEmpty { key = label.lowercased() }
                guard let ref = references[key] else { return whole }
                let title = ref.title.map { " title=\"\(esc($0))\"" } ?? ""
                if g(m, 1, ns) == "!" { return hold("<img src=\"\(esc(resolve(ref.url)))\" alt=\"\(esc(label))\"\(title)>") }
                return hold("<a href=\"\(esc(resolve(ref.url, isLink: true)))\"\(title)>" + inline(label) + "</a>")
            }
        }
        s = replace(MarkdownRenderer.autoLinkRe, in: s) { m, ns in
            let u = ns.substring(with: m.range(at: 1))
            return hold("<a href=\"\(esc(u))\">\(esc(u))</a>")
        }
        s = replace(MarkdownRenderer.rawHTMLRe, in: s) { m, ns in hold(ns.substring(with: m.range)) }
        s = esc(s)
        s = replace(MarkdownRenderer.bareURLRe, in: s) { m, ns in
            let u = ns.substring(with: m.range(at: 1))
            return "<a href=\"\(u)\">\(u)</a>"
        }
        s = replace(MarkdownRenderer.strongRe, in: s) { m, ns in "<strong>" + ns.substring(with: m.range(at: 2)) + "</strong>" }
        s = replace(MarkdownRenderer.emRe, in: s) { m, ns in "<em>" + (g(m, 1, ns) ?? g(m, 2, ns) ?? "") + "</em>" }
        s = replace(MarkdownRenderer.strikeRe, in: s) { m, ns in "<del>" + ns.substring(with: m.range(at: 1)) + "</del>" }
        s = s.replacingOccurrences(of: "  \n", with: "<br>\n").replacingOccurrences(of: "\\\n", with: "<br>\n")

        // Restore stashed fragments (they may nest, so loop until none remain).
        var guardCount = 0
        while s.contains("\u{2}") && guardCount < 8 {
            guardCount += 1
            var out = ""
            var idx = s.startIndex
            while idx < s.endIndex {
                if s[idx] == "\u{2}", let close = s[idx...].firstIndex(of: "\u{3}"), let n = Int(s[s.index(after: idx)..<close]), n < stash.count {
                    out += stash[n]
                    idx = s.index(after: close)
                } else {
                    out.append(s[idx])
                    idx = s.index(after: idx)
                }
            }
            s = out
        }
        return s
    }

    /// Relative and absolute paths are left alone: they resolve against the preview page's <base>,
    /// which maps to the document's folder. Only file: URLs need translating.
    private func resolve(_ src: String, isLink: Bool = false) -> String {
        if src.lowercased().hasPrefix("file://"), let u = URL(string: src) {
            return MarkdownPreviewView.resourceURL(forPath: u.path)?.absoluteString ?? src
        }
        return src
    }

    private func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for c in lowered {
            if c.isLetter || c.isNumber { out.append(c) } else if c == " " || c == "-" { out.append("-") }
        }
        return out
    }

    private func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Code highlighting

    private func highlight(_ lines: [String], language: String) -> String {
        guard !language.isEmpty, let lang = LanguageRegistry.shared.language(id: language), lang.style != .plain,
              lines.count < 5000 else { return esc(lines.joined(separator: "\n")) }
        let lexer = lang.lexer
        var state: UInt32 = 0
        var out = ""
        for (n, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var tokens: [(Int, Int, TokenKind)] = []
            state = units.withUnsafeBufferPointer { buf in
                lexer.lex(buf, state: state, emit: { s, l, k in tokens.append((s, l, k)) }) & 0xFFFF_FFFF
            }
            var pos = 0
            for (s, l, k) in tokens where s >= pos && s + l <= units.count {
                if s > pos { out += esc(String(utf16CodeUnits: Array(units[pos..<s]), count: s - pos)) }
                let piece = esc(String(utf16CodeUnits: Array(units[s..<(s + l)]), count: l))
                if let color = colors[k] { out += "<span style=\"color:\(color)\">" + piece + "</span>" } else { out += piece }
                pos = s + l
            }
            if pos < units.count { out += esc(String(utf16CodeUnits: Array(units[pos...]), count: units.count - pos)) }
            if n < lines.count - 1 { out += "\n" }
        }
        return out
    }
}
