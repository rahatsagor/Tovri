import AppKit

/// Multi-threaded project search. Files are scanned concurrently across all cores.
final class FileSearcher {
    struct Options {
        var query: String
        var regex: Bool
        var caseSensitive: Bool
        var wholeWord: Bool
        var root: URL
        var include: [String]
        var exclude: [String]
        /// Current text of open documents with unsaved edits, by path relative to `root`;
        /// searched instead of the file on disk.
        var unsaved: [String: String] = [:]
        /// The languages of documents in `unsaved`, whose word characters Whole Word uses.
        var languages: [String: Language] = [:]
    }

    struct Result {
        var text: String
        var matches: Int
        var files: Int
        var scanned: Int
        /// The search stopped at `maxMatches`, `maxFiles` or `maxMatchesPerFile`; `text` has the first ones.
        var limited = false
    }

    static let maxMatches = 10_000
    static let maxFiles = 2_000
    static let maxMatchesPerFile = 5_000

    private struct Found {
        var text: String
        var matches: Int
        var truncated: Bool
    }

    private let lock = NSLock()
    private var _cancelled = false
    private var found = (matches: 0, files: 0)
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    private var hasEnough: Bool {
        lock.lock(); defer { lock.unlock() }
        return found.matches >= FileSearcher.maxMatches || found.files >= FileSearcher.maxFiles
    }

    private func record(_ matches: Int) {
        lock.lock()
        found.matches += matches
        found.files += 1
        lock.unlock()
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    static func patterns(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }.filter { !$0.isEmpty }
    }

    private static func matches(_ name: String, _ rel: String, _ patterns: [String]) -> Bool {
        for p in patterns {
            let target = p.contains("/") ? rel : name
            if fnmatch(p, target, 0) == 0 { return true }
        }
        return false
    }

    /// The search's pattern. Whole Word is left to `wordTest`, which uses the editor's rule.
    static func regex(for o: Options) -> NSRegularExpression? {
        let st = FindState()
        st.regex = o.regex
        st.caseSensitive = o.caseSensitive
        st.wholeWord = o.wholeWord
        return st.makeRegex(query: o.query, wordBoundaries: false)
    }

    /// Whole Word's word characters for the file at `rel`, the same as in its editor.
    static func wordTest(_ o: Options, path rel: String) -> ((UInt16) -> Bool)? {
        guard o.wholeWord else { return nil }
        let language = o.languages[rel] ?? LanguageRegistry.shared.language(forFileName: (rel as NSString).lastPathComponent)
        return FindState.wordCharTest(language)
    }

    func run(_ o: Options) -> Result? {
        guard let re = FileSearcher.regex(for: o) else { return nil }
        let excludes = Settings.shared.searchExcludes.union(Settings.shared.hiddenPatterns)
        var files = FileSearcher.files(in: o.root, excludes: excludes, limit: 500_000)
        if !o.include.isEmpty || !o.exclude.isEmpty {
            files = files.filter { rel in
                let name = (rel as NSString).lastPathComponent
                if !o.include.isEmpty && !FileSearcher.matches(name, rel, o.include) { return false }
                if !o.exclude.isEmpty && FileSearcher.matches(name, rel, o.exclude) { return false }
                return true
            }
        }
        var results = [Found?](repeating: nil, count: files.count)
        let root = o.root
        let unsaved = o.unsaved
        let chunk = 64
        let chunks = (files.count + chunk - 1) / chunk
        var finished = [Bool](repeating: false, count: chunks)
        results.withUnsafeMutableBufferPointer { resultBuf in
            finished.withUnsafeMutableBufferPointer { doneBuf in
                let resultPtr = resultBuf.baseAddress!
                let donePtr = doneBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    // Chunks start in order, so once enough is found the ones not yet started
                    // all come after every finished one and the results stay a complete prefix.
                    if self.hasEnough { return }
                    let start = c * chunk
                    let end = min(files.count, start + chunk)
                    for i in start..<end {
                        if self.isCancelled { return }
                        let url = root.appendingPathComponent(files[i])
                        let isWordChar = FileSearcher.wordTest(o, path: files[i])
                        let hit = unsaved[files[i]].map { FileSearcher.search(text: $0, path: url.path, re, isWordChar: isWordChar) }
                            ?? FileSearcher.search(url, path: url.path, re, isWordChar: isWordChar)
                        if let hit {
                            resultPtr[i] = hit
                            self.record(hit.matches)
                        }
                    }
                    donePtr[c] = true
                }
            }
        }
        if isCancelled { return nil }
        var text = ""
        var total = 0
        var fileCount = 0
        var limited = false
        for (i, found) in results.enumerated() {
            guard finished[i / chunk] else { limited = true; break }
            guard let found else { continue }
            if total >= FileSearcher.maxMatches || fileCount >= FileSearcher.maxFiles { limited = true; break }
            text += found.text
            total += found.matches
            fileCount += 1
            if found.truncated { limited = true }
        }
        return Result(text: text, matches: total, files: fileCount, scanned: files.count, limited: limited)
    }

    /// The Find Results text: a header, the matches by file, and a summary.
    static func report(_ r: Result, for o: Options, elapsed: TimeInterval) -> String {
        let time = String(format: "%.2f", elapsed)
        let matches = "\(r.matches.formatted()) match\(r.matches == 1 ? "" : "es")"
        let files = "\(r.files.formatted()) file\(r.files == 1 ? "" : "s")"
        var text = "Searching \(r.scanned.formatted()) files for “\(o.query)” in \(o.root.path)\n\n"
        text += r.text
        if r.limited {
            text += "Showing the first \(matches) in \(files) (\(time)s). There are more: narrow the search or use Include and Exclude to see them.\n"
        } else {
            text += "\(matches) across \(files) (\(time)s)\n"
        }
        return text
    }

    /// In a Git repository, the files Git doesn't ignore; elsewhere, or with Git turned off in
    /// Settings, every file. Both skip the folders and names in `excludes`.
    static func files(in root: URL, excludes: Set<String>, limit: Int) -> [String] {
        let dir = URL(fileURLWithPath: root.path, isDirectory: true)
        guard Settings.shared.gitEnabled, let listed = GitRepository.find(for: dir)?.unignoredFiles(in: dir) else {
            return ProjectIndex.enumerate(root: root, excludes: excludes, limit: limit)
        }
        let list = ExcludeList(excludes)
        var out: [String] = []
        for rel in listed {
            let parts = rel.split(separator: "/")
            if parts.last == ".DS_Store" || parts.contains(where: { list.names.contains(String($0)) }) { continue }
            if list.hasPaths && list.excludes(relativePath: rel) { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out
    }

    static let maxFileSize = 25_000_000

    /// The text of a file as the editor shows it, with LF line endings, or nil for binary files.
    static func text(of data: Data) -> String? {
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if !utf16 {
            let binary = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress, raw.count > 0 else { return false }
                return memchr(base, 0, min(raw.count, 8000)) != nil
            }
            if binary { return nil }
        }
        let decoded = TextEncoding.decode(data)
        guard !decoded.isBinary else { return nil }
        return LineEnding.normalize(decoded.text, rawData: decoded.encoding == .utf8 ? data : nil).0
    }

    private static func search(_ url: URL, path: String, _ re: NSRegularExpression, isWordChar: ((UInt16) -> Bool)?) -> Found? {
        // Only regular files: opening a FIFO would wait forever.
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size < FileSearcher.maxFileSize else { return nil }
        guard let data = try? Document.readFile(url), !data.isEmpty, data.count < FileSearcher.maxFileSize,
              let s = text(of: data), let found = search(text: s, path: path, re, isWordChar: isWordChar) else { return nil }
        return found
    }

    /// One line of Find Results: its number and its text, shortened.
    static func resultLine(_ line: Int, _ content: String) -> String {
        var content = content
        if content.count > 300 { content = String(content.prefix(300)) + "…" }
        content = content.replacingOccurrences(of: "\t", with: "    ")
        let num = String(line + 1)
        return String(repeating: " ", count: max(1, 6 - num.count)) + num + ": " + content + "\n"
    }

    private static func search(text s: String, path: String, _ re: NSRegularExpression, isWordChar: ((UInt16) -> Bool)?) -> Found? {
        let ns = s as NSString
        let len = ns.length
        var out = ""
        var count = 0
        var truncated = false
        var lastLine = -1
        var line = 0
        var pos = 0
        var lineStart = 0
        FindState.enumerateMatches(re, in: s, range: NSRange(location: 0, length: len), isWordChar: isWordChar) { m in
            let r = m.range
            guard r.length > 0 else { return true }
            if count == FileSearcher.maxMatchesPerFile { truncated = true; return false }
            while pos < r.location {
                if ns.character(at: pos) == 10 { line += 1; lineStart = pos + 1 }
                pos += 1
            }
            count += 1
            if line == lastLine { return true }
            lastLine = line
            var e = r.location
            while e < len && ns.character(at: e) != 10 { e += 1 }
            out += resultLine(line, ns.substring(with: NSRange(location: lineStart, length: e - lineStart)))
            return true
        }
        guard count > 0 else { return nil }
        return Found(text: path + ":\n" + out + "\n", matches: count, truncated: truncated)
    }
}

/// Overlay form for Find in Files.
final class FindInFilesPanel: NSObject, NSTextFieldDelegate {
    unowned let controller: MainWindowController
    private let backdrop = PaletteBackdrop()
    private let panel = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "Find in Files")
    private let errorLabel = NSTextField(labelWithString: "")
    let findField = ThemedTextField(placeholder: "Find")
    let whereField = ThemedTextField(placeholder: "Where (folder)")
    let includeField = ThemedTextField(placeholder: "Include, e.g. *.swift, src/*")
    let excludeField = ThemedTextField(placeholder: "Exclude, e.g. *.min.js")
    private lazy var caseButton: ToolButton = ToolButton(title: "Aa", tooltip: "Match Case\nOnly find text with exactly the same uppercase and lowercase letters.") { [weak self] in self?.caseButton.isOn.toggle() }
    private lazy var wordButton: ToolButton = ToolButton(title: "ab", tooltip: "Whole Word\nOnly match complete words, not parts of longer words.") { [weak self] in self?.wordButton.isOn.toggle() }
    private lazy var regexButton: ToolButton = ToolButton(title: ".*", tooltip: "Regular Expression\nTreat the search as a regular expression.") { [weak self] in self?.regexButton.isOn.toggle() }
    private lazy var findButton: ToolButton = ToolButton(title: "Find", tooltip: "Search all matching files (↩). Results open in a Find Results tab.") { [weak self] in self?.submit() }
    private var lastWhere: String?
    private var lastInclude = ""
    private var lastExclude = ""
    var isVisible: Bool { backdrop.superview != nil }

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
        backdrop.onClick = { [weak self] in self?.close() }
        backdrop.onResize = { [weak self] in self?.layout() }
        backdrop.addSubview(panel)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 11
        panel.layer?.borderWidth = 1
        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.35
        panel.layer?.shadowRadius = 22
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        for f in [findField, whereField, includeField, excludeField] {
            f.field.delegate = self
            panel.addSubview(f)
        }
        findField.fontSize = 14
        findField.field.toolTip = "Text or pattern to search for"
        whereField.field.toolTip = "Folder to search (searched recursively). Defaults to the open folder; ~ is allowed."
        includeField.field.toolTip = "Only search files matching these patterns, separated by commas.\nPatterns without a slash match file names (*.swift); patterns with a slash match paths (src/*)."
        excludeField.field.toolTip = "Skip files matching these patterns, e.g. *.min.js, dist/*.\nFiles ignored by Git (unless Git is off in Settings → Git) and folders listed in Settings → Files are always skipped."
        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        [titleLabel, errorLabel, caseButton, wordButton, regexButton, findButton].forEach(panel.addSubview)
    }

    func show(folder: URL?) {
        guard let content = controller.window?.contentView else { return }
        let theme = ThemeManager.shared.active
        panel.layer?.backgroundColor = theme.panelBackground.cgColor
        panel.layer?.borderColor = theme.chromeBorder.cgColor
        backdrop.appearance = theme.appearance
        titleLabel.textColor = theme.chromeSecondary
        [findField, whereField, includeField, excludeField].forEach { $0.applyTheme() }
        let st = FindState.shared
        // The selection only becomes the shared query when the search runs, so Esc leaves it alone.
        var query = st.query
        if let e = controller.activeEditor {
            let sel = e.textView.selectedRange()
            if sel.length > 0 && sel.length < 300 {
                let s = e.document.string.substring(with: sel)
                if !s.contains("\n") { query = s }
            }
        }
        findField.stringValue = query
        errorLabel.stringValue = ""
        caseButton.isOn = st.caseSensitive
        wordButton.isOn = st.wholeWord
        regexButton.isOn = st.regex
        whereField.stringValue = folder?.path ?? lastWhere ?? controller.folderURL?.path ?? ""
        includeField.stringValue = lastInclude
        excludeField.stringValue = lastExclude
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        if backdrop.superview == nil { content.addSubview(backdrop) }
        layout()
        controller.window?.makeFirstResponder(findField.field)
        findField.field.currentEditor()?.selectAll(nil)
    }

    private func layout() {
        let b = backdrop.bounds
        let w = min(640, b.width - 60)
        panel.frame = NSRect(x: round((b.width - w) / 2), y: 52, width: w, height: 186)
        titleLabel.frame = NSRect(x: 16, y: 12, width: 200, height: 16)
        let fx: CGFloat = 14
        let fw = w - 28
        findField.frame = NSRect(x: fx, y: 36, width: fw - 96, height: 32)
        regexButton.frame = NSRect(x: fx + fw - 90, y: 39, width: 28, height: 26)
        wordButton.frame = NSRect(x: fx + fw - 60, y: 39, width: 28, height: 26)
        caseButton.frame = NSRect(x: fx + fw - 30, y: 39, width: 28, height: 26)
        whereField.frame = NSRect(x: fx, y: 76, width: fw, height: 28)
        let half = (fw - 8) / 2
        includeField.frame = NSRect(x: fx, y: 112, width: half, height: 28)
        excludeField.frame = NSRect(x: fx + half + 8, y: 112, width: half, height: 28)
        let bw = findButton.intrinsicWidth + 16
        findButton.frame = NSRect(x: fx + fw - bw, y: 150, width: bw, height: 26)
        errorLabel.frame = NSRect(x: fx + 2, y: 155, width: fw - bw - 14, height: 16)
    }

    private func showError(_ message: String, focus field: ThemedTextField) {
        errorLabel.stringValue = message
        NSSound.beep()
        window?.makeFirstResponder(field.field)
    }

    func controlTextDidChange(_ obj: Notification) { errorLabel.stringValue = "" }

    func close() {
        backdrop.removeFromSuperview()
        controller.activeEditor?.focus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func submit() {
        let q = findField.stringValue
        guard !q.isEmpty else { showError("Type something to find.", focus: findField); return }
        let whereText = (whereField.stringValue as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: whereText, isDirectory: &isDir), isDir.boolValue else {
            showError("There’s no folder at that path.", focus: whereField)
            return
        }
        let probe = FindState()
        probe.regex = regexButton.isOn
        probe.caseSensitive = caseButton.isOn
        probe.wholeWord = wordButton.isOn
        guard probe.makeRegex(query: q) != nil else {
            showError("That isn’t a valid regular expression.", focus: findField)
            return
        }
        let st = FindState.shared
        st.query = q
        st.caseSensitive = caseButton.isOn
        st.wholeWord = wordButton.isOn
        st.regex = regexButton.isOn
        lastWhere = whereText
        lastInclude = includeField.stringValue
        lastExclude = excludeField.stringValue
        let options = FileSearcher.Options(query: q, regex: st.regex, caseSensitive: st.caseSensitive, wholeWord: st.wholeWord,
                                           root: URL(fileURLWithPath: whereText), include: FileSearcher.patterns(lastInclude),
                                           exclude: FileSearcher.patterns(lastExclude))
        close()
        controller.runFindInFiles(options)
    }

    private var window: NSWindow? { controller.window }
}
