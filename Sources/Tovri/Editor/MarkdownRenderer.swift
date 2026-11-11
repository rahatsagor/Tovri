import Foundation

/// GitHub-flavored Markdown to HTML. Top-level blocks carry `data-line` so the preview can follow
/// the editor's scroll position; fenced code is highlighted with Tovri's own lexers.
struct MarkdownRenderer {
    var colors: [TokenKind: String] = [:]

    private var references: [String: (url: String, title: String?)] = [:]
    private var footnotes: [String: (id: String, lines: [String], line: Int)] = [:]
    private var footnoteOrder: [String] = []
    private var orderedFootnotes: [String] = []
    private var footnoteNumbers: [String: Int] = [:]
    private var footnoteIDs: [String: String] = [:]
    private var footnoteRefIDs: [String: [String]] = [:]
    private var idCounts: [String: Int] = [:]
    private var usedIDs: Set<String> = []
    private var headings: [(level: Int, text: String, id: String)] = []
    private var tablesOfContents: [(placeholder: String, attributes: String)] = []

    init(colors: [TokenKind: String]) {
        self.colors = colors
    }

    mutating func render(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        references = [:]
        footnotes = [:]
        footnoteOrder = []
        orderedFootnotes = []
        footnoteNumbers = [:]
        footnoteIDs = [:]
        footnoteRefIDs = [:]
        idCounts = [:]
        usedIDs = []
        headings = []
        tablesOfContents = []
        collectReferences(&lines)
        for key in footnoteOrder {
            guard let fn = footnotes[key] else { continue }
            let label = slug(fn.id)
            footnoteIDs[key] = uniqueID("fn-\(label.isEmpty ? "note" : label)")
        }
        var out = ""
        renderBlocks(lines[...], lineOffset: 0, topLevel: true, into: &out)
        renderFootnotes(into: &out)
        // The block renderer is the only source of headings, including nested and setext ones.
        for toc in tablesOfContents {
            var html = ""
            renderTOC(attr: toc.attributes, into: &html)
            out = out.replacingOccurrences(of: toc.placeholder, with: html)
        }
        return out
    }

    // MARK: Blocks

    private static let fenceRe = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)(?:[ \t]+(.*?))?[ \t]*$"#)
    private static let headingRe = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$"#)
    private static let hrRe = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let listRe = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)"#)
    private static let anyListRe = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)"#)
    private static let tableDelimRe = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    private static let refRe = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\^\]]+)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#)
    private static let footnoteDefRe = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]]+)\]:[ \t]*(.*)$"#)
    private static let defLineRe = try! NSRegularExpression(pattern: #"^ {0,3}:[ \t]+(.*)$"#)
    private static let alertRe = try! NSRegularExpression(pattern: #"^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:[ \t]+(.*))?$"#, options: .caseInsensitive)
    private static let frontMatterKVRe = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_.-]+)[ \t]*:[ \t]*(.*)$"#)
    private static let htmlBlockRe = try! NSRegularExpression(pattern: #"^ {0,3}<(/?(?:address|article|aside|blockquote|details|summary|dialog|div|dl|dt|dd|fieldset|figure|figcaption|footer|form|h[1-6]|header|hr|iframe|li|main|nav|ol|p|picture|pre|section|source|table|tbody|td|tfoot|th|thead|tr|ul|video|audio|img|br|center)\b|!--)"#, options: .caseInsensitive)
    private static let htmlOpeningTagRe = try! NSRegularExpression(pattern: #"^( {0,3}<[A-Za-z][A-Za-z0-9-]*)(?=\s|>|/>)"#)

    private func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }

    private func isClosingFence(_ line: String, matching openFence: String) -> Bool {
        guard indent(of: line) < 4, let fc = openFence.first else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= openFence.count && t.allSatisfy { $0 == fc }
    }

    private mutating func collectReferences(_ lines: inout [String]) {
        var activeFence: String?
        var i = 0
        // Skip YAML front matter at top of document
        if !lines.isEmpty && lines[0] == "---" {
            var k = 1
            while k < lines.count && lines[k] != "---" && lines[k] != "..." { k += 1 }
            if k < lines.count { i = k + 1 }
        }
        while i < lines.count {
            let line = lines[i]
            if let fence = activeFence {
                if isClosingFence(line, matching: fence) { activeFence = nil }
                i += 1
                continue
            }
            if let m = match(MarkdownRenderer.fenceRe, line), let fence = group(m, 1, line) {
                activeFence = fence
                i += 1
                continue
            }
            if let m = match(MarkdownRenderer.footnoteDefRe, line), let rawId = group(m, 1, line) {
                let key = rawId.lowercased()
                let first = group(m, 2, line) ?? ""
                var body: [String] = first.isEmpty ? [] : [first]
                let defLine = i
                lines[i] = "\u{1}"
                var k = i + 1
                while k < lines.count {
                    let next = lines[k]
                    if isBlank(next) {
                        var look = k + 1
                        while look < lines.count && isBlank(lines[look]) { look += 1 }
                        if look < lines.count && indent(of: lines[look]) >= 2 &&
                            match(MarkdownRenderer.footnoteDefRe, lines[look]) == nil &&
                            match(MarkdownRenderer.refRe, lines[look]) == nil {
                            body.append("")
                            lines[k] = "\u{1}"
                            k += 1
                            continue
                        }
                        break
                    }
                    if indent(of: next) >= 2 &&
                        match(MarkdownRenderer.footnoteDefRe, next) == nil &&
                        match(MarkdownRenderer.refRe, next) == nil {
                        body.append(dedent(next, min(4, indent(of: next))))
                        lines[k] = "\u{1}"
                        k += 1
                    } else {
                        break
                    }
                }
                if footnotes[key] == nil { footnoteOrder.append(key) }
                footnotes[key] = (id: rawId, lines: body, line: defLine)
                i = k
                continue
            }
            if let m = match(MarkdownRenderer.refRe, line),
               let label = group(m, 1, line), let url = group(m, 2, line) {
                references[label.lowercased()] = (url, group(m, 3, line))
                lines[i] = "\u{1}"
                i += 1
                continue
            }
            i += 1
        }
    }

    private func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } || s == "\u{1}" }

    private func indent(of s: String) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break } }
        return n
    }

    private func visualWidth(of s: String) -> Int {
        var n = 0
        for c in s { if c == "\t" { n += 4 - n % 4 } else { n += 1 } }
        return n
    }

    private func dedent(_ s: String, _ count: Int) -> String {
        var removed = 0
        var idx = s.startIndex
        while idx < s.endIndex && removed < count {
            if s[idx] == " " {
                removed += 1
            } else if s[idx] == "\t" {
                let step = 4 - removed % 4
                if removed + step > count {
                    return String(repeating: " ", count: removed + step - count) + String(s[s.index(after: idx)...])
                }
                removed += step
            } else {
                break
            }
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    private func startsBlock(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return match(MarkdownRenderer.fenceRe, s) != nil || match(MarkdownRenderer.headingRe, s) != nil ||
            match(MarkdownRenderer.hrRe, s) != nil || trimmed.hasPrefix(">") ||
            (indent(of: s) < 4 && trimmed.hasPrefix("$$")) ||
            match(MarkdownRenderer.listRe, s) != nil || match(MarkdownRenderer.htmlBlockRe, s) != nil
    }

    private func startsTable(_ lines: ArraySlice<String>, at k: Int) -> Bool {
        k + 1 < lines.endIndex && lines[k].contains("|")
            && match(MarkdownRenderer.tableDelimRe, lines[k + 1]) != nil
            && lines[k + 1].contains("-")
    }

    private func annotateHTMLOpeningTag(_ line: String, attr a: String) -> String {
        guard !a.isEmpty, !line.contains("data-line="),
              let m = match(MarkdownRenderer.htmlOpeningTagRe, line) else { return line }
        let ns = line as NSString
        return ns.substring(to: m.range.length) + a + ns.substring(from: m.range.length)
    }

    private func attr(_ line: Int, _ top: Bool) -> String { top ? " data-line=\"\(line)\"" : "" }

    private mutating func uniqueID(_ proposed: String) -> String {
        let base = proposed.isEmpty ? "section" : proposed
        var count = idCounts[base, default: 0]
        var id = count == 0 ? base : "\(base)-\(count)"
        while !usedIDs.insert(id).inserted {
            count += 1
            id = "\(base)-\(count)"
        }
        idCounts[base] = count + 1
        return id
    }

    private mutating func renderHeading(_ level: Int, text: String, attr a: String, into out: inout String) {
        let id = uniqueID(slug(text))
        headings.append((level, text, id))
        out += "<h\(level) id=\"\(id)\"\(a)>" + inline(text) + "</h\(level)>\n"
    }

    private mutating func renderBlocks(_ lines: ArraySlice<String>, lineOffset: Int, topLevel: Bool, into out: inout String) {
        var i = lines.startIndex
        let end = lines.endIndex
        func abs(_ k: Int) -> Int { lineOffset + (k - lines.startIndex) }

        // YAML front matter
        if topLevel && lineOffset == 0, i < end, lines[i] == "---" {
            var k = i + 1
            while k < end && lines[k] != "---" && lines[k] != "..." { k += 1 }
            if k < end {
                renderFrontMatter(lines[(i + 1)..<k], into: &out)
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
                    if isClosingFence(lines[k], matching: fence) { break }
                    body.append(dedent(lines[k], fenceIndent))
                    k += 1
                }
                let displayLang = lang.isEmpty ? "" : (LanguageRegistry.shared.language(id: lang)?.name ?? lang)
                let langData = displayLang.isEmpty ? "" : " data-lang=\"\(esc(displayLang))\""
                let codeClass = lang.isEmpty ? "" : " class=\"language-\(esc(lang))\""
                out += "<pre\(a)\(langData)><code\(codeClass)>" + highlight(body, language: lang) + "</code></pre>\n"
                i = min(end, k + 1)
                continue
            }

            // Display math block ($$ ... $$)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if indent(of: line) < 4 && trimmedLine.hasPrefix("$$") {
                let afterOpen = trimmedLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if afterOpen.hasSuffix("$$") && afterOpen.count >= 2 {
                    let expr = String(afterOpen.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    out += "<div class=\"math-block\"\(a)><code>" + esc(expr) + "</code></div>\n"
                    i += 1
                    continue
                }
                var k = i + 1
                var body: [String] = afterOpen.isEmpty ? [] : [String(afterOpen)]
                while k < end {
                    let tk = lines[k].trimmingCharacters(in: .whitespaces)
                    if tk == "$$" { k += 1; break }
                    if tk.hasSuffix("$$") && indent(of: lines[k]) < 4 {
                        let beforeClose = String(tk.dropLast(2)).trimmingCharacters(in: .whitespaces)
                        if !beforeClose.isEmpty { body.append(beforeClose) }
                        k += 1
                        break
                    }
                    body.append(lines[k])
                    k += 1
                }
                out += "<div class=\"math-block\"\(a)><code>" + esc(body.joined(separator: "\n")) + "</code></div>\n"
                i = k
                continue
            }

            if let m = match(MarkdownRenderer.headingRe, line), let hashes = group(m, 1, line) {
                let content = group(m, 2, line) ?? ""
                renderHeading(hashes.count, text: content, attr: a, into: &out)
                i += 1
                continue
            }

            if match(MarkdownRenderer.hrRe, line) != nil {
                out += "<hr\(a)>\n"
                i += 1
                continue
            }

            if trimmedLine.hasPrefix(">") {
                var k = i
                var inner: [String] = []
                while k < end {
                    let t = lines[k]
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix(">") {
                        var rest = Substring(trimmed.dropFirst())
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !isBlank(t) && !inner.isEmpty && !isBlank(inner.last!) && !startsBlock(t) && !startsTable(lines, at: k) {
                        inner.append(t)
                    } else { break }
                    k += 1
                }
                if let first = inner.first, let m = match(MarkdownRenderer.alertRe, first), let rawKind = group(m, 1, first) {
                    let kind = rawKind.lowercased()
                    let extra = (group(m, 2, first) ?? "").trimmingCharacters(in: .whitespaces)
                    let titleHTML: String
                    let bodyLines: [String]
                    if inner.count == 1 && !extra.isEmpty {
                        titleHTML = kind.capitalized
                        bodyLines = [extra]
                    } else {
                        titleHTML = extra.isEmpty ? kind.capitalized : inline(extra)
                        bodyLines = Array(inner.dropFirst())
                    }
                    var body = ""
                    renderBlocks(bodyLines[...], lineOffset: abs(i), topLevel: false, into: &body)
                    out += "<blockquote class=\"alert alert-\(kind)\"\(a)><p class=\"alert-title\">\(alertIcon(kind))\(titleHTML)</p>" + body + "</blockquote>\n"
                } else {
                    var body = ""
                    renderBlocks(inner[...], lineOffset: abs(i), topLevel: false, into: &body)
                    out += "<blockquote\(a)>" + body + "</blockquote>\n"
                }
                i = k
                continue
            }

            if let m = match(MarkdownRenderer.listRe, line) {
                i = renderList(lines, from: i, first: m, lineOffset: lineOffset, topLevel: topLevel, into: &out)
                continue
            }

            if startsTable(lines, at: i) {
                i = renderTable(lines, from: i, attr: a, into: &out)
                continue
            }

            if match(MarkdownRenderer.htmlBlockRe, line) != nil {
                var k = i
                var html: [String] = []
                if trimmedLine.hasPrefix("<!--") {
                    while k < end {
                        html.append(lines[k])
                        let closed = lines[k].contains("-->")
                        k += 1
                        if closed { break }
                    }
                } else {
                    while k < end && !isBlank(lines[k]) { html.append(lines[k]); k += 1 }
                }
                if !html.isEmpty { html[0] = annotateHTMLOpeningTag(html[0], attr: a) }
                // Emit raw HTML without wrapping it in a synthetic <div>...</div>, which would
                // force HTML5 to prematurely close multi-paragraph containers like <details>.
                out += html.joined(separator: "\n") + "\n"
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

            // Definition list (Term followed by `: Definition`)
            if i + 1 < end, !startsBlock(line), match(MarkdownRenderer.defLineRe, lines[i + 1]) != nil {
                i = renderDefinitionList(lines, from: i, attr: a, lineOffset: lineOffset, into: &out)
                continue
            }

            // Paragraph (with setext heading and [TOC] detection)
            var k = i
            var para: [String] = []
            var setext = 0
            while k < end && !isBlank(lines[k]) {
                let t = lines[k]
                if !para.isEmpty {
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed.allSatisfy({ $0 == "=" }) { setext = 1; k += 1; break }
                    if !trimmed.isEmpty && trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2 { setext = 2; k += 1; break }
                    if startsBlock(t) || startsTable(lines, at: k) || match(MarkdownRenderer.defLineRe, t) != nil { break }
                }
                para.append(t.trimmingCharacters(in: .whitespaces) == t ? t : String(t.drop(while: { $0 == " " })))
                k += 1
            }
            let content = para.joined(separator: "\n")
            if setext > 0 {
                renderHeading(setext, text: content, attr: a, into: &out)
            } else if para.count == 1 && (content.caseInsensitiveCompare("[toc]") == .orderedSame || content.caseInsensitiveCompare("[[toc]]") == .orderedSame) {
                let placeholder = "<!--tovri-toc-\(UUID().uuidString)-->"
                tablesOfContents.append((placeholder, a))
                out += placeholder
            } else {
                out += "<p\(a)>" + inline(content) + "</p>\n"
            }
            i = k
        }
    }

    private mutating func renderFrontMatter(_ slice: ArraySlice<String>, into out: inout String) {
        var pairs: [(key: String, value: String)] = []
        var structured = true
        for raw in slice {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard indent(of: raw) == 0,
                  let m = match(MarkdownRenderer.frontMatterKVRe, raw),
                  let k = group(m, 1, raw),
                  let v = group(m, 2, raw),
                  !v.isEmpty, v != "|", v != ">" else {
                structured = false
                break
            }
            pairs.append((k, v))
        }
        if structured && !pairs.isEmpty {
            out += "<div class=\"front-matter\" data-line=\"0\"><table><tbody>"
            for (k, rawVal) in pairs {
                var v = rawVal.trimmingCharacters(in: .whitespaces)
                let cellHTML: String
                if v.hasPrefix("[") && v.hasSuffix("]") {
                    let items = v.dropFirst().dropLast().split(separator: ",").map {
                        $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                    }.filter { !$0.isEmpty }
                    cellHTML = items.map { "<span class=\"fm-tag\">\(esc($0))</span>" }.joined(separator: " ")
                } else {
                    if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                        v = String(v.dropFirst().dropLast())
                    }
                    cellHTML = esc(v)
                }
                out += "<tr><th class=\"fm-key\">\(esc(k))</th><td class=\"fm-val\">\(cellHTML)</td></tr>"
            }
            out += "</tbody></table></div>\n"
        } else {
            out += "<pre class=\"front-matter\" data-line=\"0\"><code>" + highlight(Array(slice), language: "yaml") + "</code></pre>\n"
        }
    }

    private mutating func renderTOC(attr a: String, into out: inout String) {
        guard !headings.isEmpty else { return }
        let minLevel = headings.map(\.level).min() ?? 1
        out += "<nav class=\"toc\"\(a)><ul>\n"
        for h in headings {
            let depth = max(0, h.level - minLevel)
            let cls = depth > 0 ? " class=\"toc-level-\(min(depth, 4))\"" : ""
            out += "<li\(cls)><a href=\"#\(esc(h.id))\">" + inline(h.text, forTOC: true) + "</a></li>\n"
        }
        out += "</ul></nav>\n"
    }

    private mutating func renderDefinitionList(_ lines: ArraySlice<String>, from start: Int, attr a: String,
                                               lineOffset: Int, into out: inout String) -> Int {
        let end = lines.endIndex
        var i = start
        out += "<dl\(a)>\n"
        while i < end {
            if isBlank(lines[i]) { i += 1; continue }
            var terms: [String] = []
            var k = i
            while k < end && !isBlank(lines[k]) && !startsBlock(lines[k]) && match(MarkdownRenderer.defLineRe, lines[k]) == nil {
                terms.append(lines[k].trimmingCharacters(in: .whitespaces))
                k += 1
            }
            guard !terms.isEmpty, k < end, match(MarkdownRenderer.defLineRe, lines[k]) != nil else { break }
            for term in terms {
                out += "<dt>" + inline(term) + "</dt>\n"
            }
            while k < end {
                guard let m = match(MarkdownRenderer.defLineRe, lines[k]) else { break }
                let firstDef = group(m, 1, lines[k]) ?? ""
                let defStart = k
                var defBody: [String] = [firstDef]
                k += 1
                while k < end {
                    let next = lines[k]
                    if isBlank(next) {
                        if k + 1 < end && (indent(of: lines[k + 1]) >= 2 || match(MarkdownRenderer.defLineRe, lines[k + 1]) != nil) {
                            if indent(of: lines[k + 1]) >= 2 && match(MarkdownRenderer.defLineRe, lines[k + 1]) == nil {
                                defBody.append("")
                                k += 1
                                continue
                            }
                        }
                        break
                    }
                    if match(MarkdownRenderer.defLineRe, next) != nil { break }
                    if indent(of: next) >= 2 {
                        defBody.append(dedent(next, min(4, indent(of: next))))
                        k += 1
                    } else if !startsBlock(next) {
                        defBody.append(next.trimmingCharacters(in: .whitespaces))
                        k += 1
                    } else {
                        break
                    }
                }
                var rendered = ""
                renderBlocks(defBody[...], lineOffset: lineOffset + (defStart - lines.startIndex), topLevel: false, into: &rendered)
                if rendered.hasPrefix("<p>"), let close = rendered.range(of: "</p>\n"), close.upperBound == rendered.endIndex {
                    rendered = String(rendered[rendered.index(rendered.startIndex, offsetBy: 3)..<close.lowerBound])
                }
                out += "<dd>" + rendered + "</dd>\n"
                while k < end && isBlank(lines[k]) {
                    if k + 1 < end && match(MarkdownRenderer.defLineRe, lines[k + 1]) != nil { k += 1 } else { break }
                }
            }
            i = k
            var nextTerm = i
            while nextTerm < end && isBlank(lines[nextTerm]) { nextTerm += 1 }
            if nextTerm + 1 < end && !startsBlock(lines[nextTerm]) && match(MarkdownRenderer.defLineRe, lines[nextTerm + 1]) != nil {
                i = nextTerm
            } else {
                break
            }
        }
        out += "</dl>\n"
        return i
    }

    private func alertIcon(_ kind: String) -> String {
        switch kind {
        case "note":
            return "<svg class=\"alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"/></svg>"
        case "tip":
            return "<svg class=\"alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z\"/></svg>"
        case "important":
            return "<svg class=\"alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"/></svg>"
        case "warning":
            return "<svg class=\"alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"/></svg>"
        default: // caution
            return "<svg class=\"alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"/></svg>"
        }
    }

    private mutating func renderList(_ lines: ArraySlice<String>, from start: Int, first: NSTextCheckingResult, lineOffset: Int,
                                     topLevel: Bool, into out: inout String) -> Int {
        let end = lines.endIndex
        let firstLine = lines[start]
        let baseIndent = indent(of: firstLine)
        let marker = group(first, 2, firstLine) ?? "-"
        let ordered = marker.first!.isNumber
        let startNumber = ordered ? Int(marker.dropLast()) ?? 1 : 1
        var items: [(line: Int, body: [String])] = []
        var loose = false
        var i = start
        var blankPending = false
        while i < end {
            let line = lines[i]
            if indent(of: line) <= baseIndent + 1, let m = match(MarkdownRenderer.listRe, line) {
                let mk = group(m, 2, line) ?? ""
                if mk.first!.isNumber != ordered || (!ordered && mk != marker) { break }
                if blankPending { loose = true }
                blankPending = false
                let nsLine = line as NSString
                let splitAt = min(m.range.length, nsLine.length)
                let contentIndent = visualWidth(of: nsLine.substring(to: splitAt))
                let content = nsLine.substring(from: splitAt)
                items.append((lineOffset + (i - lines.startIndex), [content]))
                var k = i + 1
                while k < end {
                    let t = lines[k]
                    if isBlank(t) {
                        items[items.count - 1].body.append("")
                        k += 1
                        continue
                    }
                    let tIndent = indent(of: t)
                    if tIndent >= max(2, contentIndent) {
                        items[items.count - 1].body.append(dedent(t, contentIndent))
                    } else if tIndent > baseIndent && match(MarkdownRenderer.anyListRe, t) != nil {
                        items[items.count - 1].body.append(dedent(t, tIndent))
                    } else if match(MarkdownRenderer.listRe, t) == nil && !startsBlock(t) && !startsTable(lines, at: k) && items[items.count - 1].body.last != "" {
                        items[items.count - 1].body.append(t.trimmingCharacters(in: .whitespaces))
                    } else { break }
                    k += 1
                }
                while let last = items[items.count - 1].body.last, last.isEmpty {
                    items[items.count - 1].body.removeLast()
                    blankPending = true
                }
                if items[items.count - 1].body.contains("") { loose = true }
                i = k
                if i < end, isBlank(lines[i]) { blankPending = true; i += 1 }
                while i < end, isBlank(lines[i]) { i += 1 }
            } else { break }
        }
        let tag = ordered ? "ol" : "ul"
        let startAttr = ordered && startNumber != 1 ? " start=\"\(startNumber)\"" : ""
        let hasTasks = items.contains { $0.body.first.map { Self.taskCheckbox(in: $0) != nil } ?? false }
        out += "<\(tag)\(startAttr)\(hasTasks ? " class=\"contains-task-list\"" : "")\(attr(items.first?.line ?? 0, topLevel))>\n"
        for item in items {
            var body = item.body
            var checkbox = ""
            if let f = body.first, let (checked, rest) = Self.taskCheckbox(in: f) {
                checkbox = checked ? "<input type=\"checkbox\" checked disabled> " : "<input type=\"checkbox\" disabled> "
                body[0] = rest
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

    private static func taskCheckbox(in s: String) -> (checked: Bool, rest: String)? {
        let lower = s.lowercased()
        if lower == "[ ]" { return (false, "") }
        if lower == "[x]" { return (true, "") }
        if lower.hasPrefix("[ ] ") || lower.hasPrefix("[ ]\t") { return (false, String(s.dropFirst(4))) }
        if lower.hasPrefix("[x] ") || lower.hasPrefix("[x]\t") { return (true, String(s.dropFirst(4))) }
        return nil
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

    private mutating func renderTable(_ lines: ArraySlice<String>, from start: Int, attr a: String, into out: inout String) -> Int {
        let header = splitRow(lines[start])
        let aligns: [String] = splitRow(lines[start + 1]).map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? "center" : (r ? "right" : (l ? "left" : ""))
        }
        func alignAttr(_ i: Int) -> String {
            i < aligns.count && !aligns[i].isEmpty ? " style=\"text-align:\(aligns[i])\"" : ""
        }
        var headHTML = ""
        for (idx, h) in header.enumerated() {
            headHTML += "<th\(alignAttr(idx))>" + inline(h) + "</th>"
        }
        out += "<table\(a)><thead><tr>" + headHTML + "</tr></thead><tbody>\n"
        var i = start + 2
        while i < lines.endIndex, !isBlank(lines[i]), lines[i].contains("|") {
            let cells = splitRow(lines[i])
            var rowHTML = ""
            for col in 0..<header.count {
                let text = col < cells.count ? cells[col] : ""
                rowHTML += "<td\(alignAttr(col))>" + inline(text) + "</td>"
            }
            out += "<tr>" + rowHTML + "</tr>\n"
            i += 1
        }
        out += "</tbody></table>\n"
        return i
    }

    private mutating func footnoteNumber(for key: String) -> Int {
        if let number = footnoteNumbers[key] { return number }
        orderedFootnotes.append(key)
        let number = orderedFootnotes.count
        footnoteNumbers[key] = number
        return number
    }

    private mutating func renderFootnotes(into out: inout String) {
        guard !footnotes.isEmpty else { return }
        var bodies: [String: String] = [:]
        var nextDefinition = 0
        var nextUnused = 0
        // References discovered inside a definition join the numbered queue. Drain it before
        // adding unused definitions, and render each definition once even for cyclic references.
        while nextDefinition < orderedFootnotes.count || nextUnused < footnoteOrder.count {
            if nextDefinition == orderedFootnotes.count {
                _ = footnoteNumber(for: footnoteOrder[nextUnused])
                nextUnused += 1
                continue
            }
            let key = orderedFootnotes[nextDefinition]
            nextDefinition += 1
            guard let fn = footnotes[key] else { continue }
            var body = ""
            renderBlocks(fn.lines[...], lineOffset: fn.line, topLevel: false, into: &body)
            bodies[key] = body
        }
        out += "<section class=\"footnotes\"><hr><ol class=\"footnote-list\">\n"
        for key in orderedFootnotes {
            guard let id = footnoteIDs[key], var body = bodies[key] else { continue }
            let refs = footnoteRefIDs[key] ?? []
            let backrefs = refs.enumerated().map { index, ref in
                let label = refs.count == 1 ? "Back to content" : "Back to reference \(index + 1)"
                let arrow = refs.count == 1 ? "↩" : "↩\(index + 1)"
                return " <a href=\"#\(ref)\" class=\"footnote-backref\" aria-label=\"\(label)\">\(arrow)</a>"
            }.joined()
            if body.hasSuffix("</p>\n") {
                body = String(body.dropLast(5)) + backrefs + "</p>\n"
            } else {
                body += backrefs
            }
            out += "<li id=\"\(id)\">" + body + "</li>\n"
        }
        out += "</ol></section>\n"
    }

    // MARK: Inline

    private static let codeSpanRe = try! NSRegularExpression(pattern: #"(`+)(.+?)(?<!`)\1(?!`)"#, options: .dotMatchesLineSeparators)
    private static let displayMathInlineRe = try! NSRegularExpression(pattern: #"\$\$(?=\S)(.+?)(?<=\S)\$\$"#, options: .dotMatchesLineSeparators)
    private static let inlineMathRe = try! NSRegularExpression(pattern: #"(?<![\\$\w])\$(?!\s)([^$\n]+?)(?<![\s\\])\$(?![\$\d\w])"#)
    private static let imageRe = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let linkRe = try! NSRegularExpression(pattern: #"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]*)>?(?:\s+"([^"]*)")?\s*\)"#)
    private static let footnoteRefRe = try! NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#)
    private static let refLinkRe = try! NSRegularExpression(pattern: #"(!?)\[((?:[^\[\]]|\[[^\]]*\])+)\](?:\[([^\]]*)\])?"#)
    private static let autoLinkRe = try! NSRegularExpression(pattern: #"<((?:https?|mailto|ftp):[^>\s]+)>"#)
    private static let rawHTMLRe = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][\w:.-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>|<!--.*?-->"#, options: .dotMatchesLineSeparators)
    private static let bareURLRe = try! NSRegularExpression(pattern: #"(?<![\w"'=/])(https?://[^\s<>()]+[^\s<>().,;:!?"'])"#)
    private static let strongRe = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, options: .dotMatchesLineSeparators)
    private static let emRe = try! NSRegularExpression(pattern: #"(?<![\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)|(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#, options: .dotMatchesLineSeparators)
    private static let strikeRe = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#, options: .dotMatchesLineSeparators)
    private static let markRe = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#, options: .dotMatchesLineSeparators)
    private static let supRe = try! NSRegularExpression(pattern: #"\^(?=[^\s\^])([^\^\n]+?)(?<=[^\s\^])\^"#)
    private static let subRe = try! NSRegularExpression(pattern: #"(?<!~)~(?=[^\s~])([^~\n]+?)(?<=[^\s~])~(?!~)"#)
    private static let escapeRe = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|<>~=$^])"#)

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
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

    private mutating func inline(_ text: String, forTOC: Bool = false) -> String {
        var stash: [String] = []
        func hold(_ html: String) -> String {
            stash.append(html)
            return "\u{2}\(stash.count - 1)\u{3}"
        }
        func g(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        var s = Self.replace(Self.escapeRe, in: text) { m, ns in hold(esc(ns.substring(with: m.range(at: 1)))) }
        s = Self.replace(Self.codeSpanRe, in: s) { m, ns in
            var code = ns.substring(with: m.range(at: 2))
            if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
            return hold("<code>" + esc(code) + "</code>")
        }
        s = Self.replace(Self.displayMathInlineRe, in: s) { m, ns in
            let expr = ns.substring(with: m.range(at: 1))
            return hold("<span class=\"math-inline math-display\">" + esc(expr) + "</span>")
        }
        s = Self.replace(Self.inlineMathRe, in: s) { m, ns in
            let expr = ns.substring(with: m.range(at: 1))
            return hold("<span class=\"math-inline\">" + esc(expr) + "</span>")
        }
        s = Self.replace(Self.imageRe, in: s) { m, ns in
            let alt = g(m, 1, ns) ?? ""
            if forTOC { return hold(esc(alt)) }
            let src = resolve(g(m, 2, ns) ?? "")
            let title = g(m, 3, ns).map { " title=\"\(esc($0))\"" } ?? ""
            return hold("<img src=\"\(esc(src))\" alt=\"\(esc(alt))\"\(title)>")
        }
        s = Self.replace(Self.linkRe, in: s) { m, ns in
            let label = g(m, 1, ns) ?? ""
            let content = inline(label, forTOC: forTOC)
            if forTOC { return hold(content) }
            let href = resolve(g(m, 2, ns) ?? "", isLink: true)
            let title = g(m, 3, ns).map { " title=\"\(esc($0))\"" } ?? ""
            return hold("<a href=\"\(esc(href))\"\(title)>" + content + "</a>")
        }
        if !forTOC && !footnotes.isEmpty {
            s = Self.replace(Self.footnoteRefRe, in: s) { m, ns in
                let raw = g(m, 1, ns) ?? ""
                let key = raw.lowercased()
                guard let id = footnoteIDs[key] else { return ns.substring(with: m.range) }
                let idx = footnoteNumber(for: key)
                let refId = uniqueID("fnref-" + id.dropFirst(3))
                footnoteRefIDs[key, default: []].append(refId)
                return hold("<sup class=\"footnote-ref\"><a href=\"#\(id)\" id=\"\(refId)\">[\(idx)]</a></sup>")
            }
        } else if forTOC {
            s = Self.replace(Self.footnoteRefRe, in: s) { m, ns in
                let key = (g(m, 1, ns) ?? "").lowercased()
                return footnotes[key] == nil ? ns.substring(with: m.range) : ""
            }
        }
        if !references.isEmpty {
            s = Self.replace(Self.refLinkRe, in: s) { m, ns in
                let whole = ns.substring(with: m.range)
                let label = g(m, 2, ns) ?? ""
                var key = (g(m, 3, ns) ?? "").lowercased()
                if key.isEmpty { key = label.lowercased() }
                guard let ref = references[key] else { return whole }
                let title = ref.title.map { " title=\"\(esc($0))\"" } ?? ""
                if g(m, 1, ns) == "!" {
                    return hold(forTOC ? esc(label) : "<img src=\"\(esc(resolve(ref.url)))\" alt=\"\(esc(label))\"\(title)>")
                }
                let content = inline(label, forTOC: forTOC)
                return hold(forTOC ? content : "<a href=\"\(esc(resolve(ref.url, isLink: true)))\"\(title)>" + content + "</a>")
            }
        }
        s = Self.replace(Self.autoLinkRe, in: s) { m, ns in
            let u = ns.substring(with: m.range(at: 1))
            return hold(forTOC ? esc(u) : "<a href=\"\(esc(u))\">\(esc(u))</a>")
        }
        s = Self.replace(Self.rawHTMLRe, in: s) { m, ns in forTOC ? "" : hold(ns.substring(with: m.range)) }
        s = esc(s)
        s = Self.replace(Self.bareURLRe, in: s) { m, ns in
            let u = ns.substring(with: m.range(at: 1))
            return forTOC ? u : "<a href=\"\(u)\">\(u)</a>"
        }
        s = Self.replace(Self.strongRe, in: s) { m, ns in "<strong>" + ns.substring(with: m.range(at: 2)) + "</strong>" }
        s = Self.replace(Self.emRe, in: s) { m, ns in "<em>" + (g(m, 1, ns) ?? g(m, 2, ns) ?? "") + "</em>" }
        s = Self.replace(Self.strikeRe, in: s) { m, ns in "<del>" + ns.substring(with: m.range(at: 1)) + "</del>" }
        s = Self.replace(Self.markRe, in: s) { m, ns in "<mark>" + ns.substring(with: m.range(at: 1)) + "</mark>" }
        s = Self.replace(Self.supRe, in: s) { m, ns in "<sup>" + ns.substring(with: m.range(at: 1)) + "</sup>" }
        s = Self.replace(Self.subRe, in: s) { m, ns in "<sub>" + ns.substring(with: m.range(at: 1)) + "</sub>" }
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
