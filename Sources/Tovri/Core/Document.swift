import AppKit

protocol DocumentEditor: AnyObject {
    func documentDidEdit(range: NSRange, delta: Int)
    func documentDidReload()
    func documentLanguageDidChange()
    func documentGitDiffDidChange()
}

extension Notification.Name {
    /// Posted when a document's name, dirty state or file status changes.
    static let documentStateDidChange = Notification.Name("TovriDocumentStateDidChange")
    /// Posted (debounced) when the file backing a document is written, replaced or removed.
    static let documentFileDidChangeOnDisk = Notification.Name("TovriDocumentFileDidChangeOnDisk")
}

enum DocumentError: LocalizedError {
    case encodingFailed(TextEncoding)
    case notAFile
    case binaryFile
    case modifiedOnDisk

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let e): return "The document contains characters that can’t be saved using \(e.rawValue)."
        case .notAFile: return "The item is not a regular file."
        case .binaryFile: return "This appears to be a binary file and can’t be opened as text."
        case .modifiedOnDisk: return "The file has been changed by another application since Tovri last read it."
        }
    }
}

final class Document: NSObject, NSTextStorageDelegate {
    private static var untitledCounter = 0

    let id = UUID()
    private(set) var url: URL?
    private(set) var untitledName: String
    let textStorage = NSTextStorage()
    let lines = LineIndex()
    let bookmarks = Bookmarks()
    private(set) var language: Language
    private(set) var syntax: SyntaxEngine
    let undoManager = UndoManager()

    var encoding: TextEncoding = .utf8 { didSet { encodingWasDetected = false } }
    /// The encoding came from looking at the bytes rather than from a choice, so reading the file
    /// again detects it afresh: a file another program converted must not be decoded the old way.
    private(set) var encodingWasDetected = false
    var lineEnding: LineEnding = .lf
    var indentUsesTabs: Bool
    var indentWidth: Int
    /// Chosen in the status bar or by converting indentation; detection and `.editorconfig` then leave it alone.
    private(set) var indentationWasSetManually = false
    var isReadOnly = false
    /// Transient documents (find results, generated help) never prompt to save.
    var isTransient = false
    /// For a Changes tab, the document it compares with the last commit.
    weak var changesSource: Document?
    var isFindResults: Bool { language === LanguageRegistry.shared.findResults }
    /// The file's identity, modification time and size when Tovri last read or wrote it.
    private var diskStamp: DiskStamp?
    var lastReadDiskStamp: DiskStamp? { diskStamp }
    private(set) var fileMissing = false
    private(set) var editVersion = 0
    var languageWasSetManually = false
    /// Not yet on disk; created on first save.
    private(set) var isNewFile = false

    /// Dirty state is content-based: any user edit marks the document dirty, and after undo/redo a
    /// content hash is compared with the last saved version so undoing back to it clears the flag.
    private var dirtyFlag = false
    /// Set when the only reason for `dirtyFlag` is that the file vanished from disk.
    private var dirtyOnlyFromDeletion = false
    private var savedLength = 0
    private var savedHash: UInt64?
    private var savedLineEnding: LineEnding = .lf
    private var cleanCheckScheduled = false
    private var isBulkLoading = false
    private var wasDirty = false

    private let editors = NSHashTable<AnyObject>.weakObjects()

    var isDirty: Bool { !isTransient && dirtyFlag }
    var displayName: String { url?.lastPathComponent ?? untitledName }
    var length: Int { textStorage.length }
    var string: NSString { textStorage.mutableString }

    init(untitled: Void = ()) {
        Document.untitledCounter += 1
        untitledName = Document.untitledCounter == 1 ? "Untitled" : "Untitled \(Document.untitledCounter)"
        language = LanguageRegistry.shared.plain
        syntax = SyntaxEngine(language: language, lineCount: 1)
        indentUsesTabs = !Settings.shared.insertSpaces
        indentWidth = Settings.shared.tabWidth
        super.init()
        commonInit()
        applyLanguageIndentation()
        markClean()
    }

    init(contentsOf url: URL, encoding preferred: TextEncoding? = nil) throws {
        untitledName = url.lastPathComponent
        language = LanguageRegistry.shared.plain
        syntax = SyntaxEngine(language: language, lineCount: 1)
        indentUsesTabs = !Settings.shared.insertSpaces
        indentWidth = Settings.shared.tabWidth
        self.url = url
        super.init()
        commonInit()
        try load(from: url, encoding: preferred)
    }

    /// A new, unsaved document bound to a path that doesn't exist yet (e.g. `tovri new.txt`).
    init(newFileAt url: URL) {
        untitledName = url.lastPathComponent
        language = LanguageRegistry.shared.language(forFileName: url.lastPathComponent)
        syntax = SyntaxEngine(language: language, lineCount: 1)
        indentUsesTabs = !Settings.shared.insertSpaces
        indentWidth = Settings.shared.tabWidth
        self.url = url
        isNewFile = true
        super.init()
        commonInit()
        applyLanguageIndentation()
        applyEditorConfig()
        markClean()
    }

    init(text: String, name: String, language: Language) {
        untitledName = name
        self.language = language
        syntax = SyntaxEngine(language: language, lineCount: 1)
        indentUsesTabs = false
        indentWidth = 4
        super.init()
        indentationFollowsSettings = false
        commonInit()
        let (normalized, ending) = LineEnding.normalize(text, rawData: nil)
        lineEnding = ending
        setContent(normalized)
        markClean()
    }

    private func commonInit() {
        textStorage.delegate = self
        undoManager.levelsOfUndo = 0
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        applyBaseAttributes()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitor?.cancel()
    }

    // MARK: Editors

    func addEditor(_ e: DocumentEditor) { editors.add(e) }
    func removeEditor(_ e: DocumentEditor) { editors.remove(e) }
    var editorCount: Int { editors.allObjects.count }
    private var allEditors: [DocumentEditor] { editors.allObjects.compactMap { $0 as? DocumentEditor } }

    // MARK: Attributes

    var font: NSFont { Settings.shared.font }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        p.defaultTabInterval = space * CGFloat(indentWidth)
        p.tabStops = []
        p.lineBreakMode = .byWordWrapping
        return p
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: ThemeManager.shared.active.foreground, .paragraphStyle: paragraphStyle,
         .ligature: Settings.shared.ligatureAttribute]
    }

    func applyBaseAttributes() {
        appliedAttributesKey = attributesKey
        let attrs = baseAttributes
        isBulkLoading = true
        textStorage.beginEditing()
        textStorage.setAttributes(attrs, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        isBulkLoading = false
    }

    private var appliedAttributesKey = ""

    private var attributesKey: String { "\(font.fontName)|\(font.pointSize)|\(indentWidth)|\(Settings.shared.ligatureAttribute)" }

    @objc private func settingsChanged() {
        var indentationChanged = false
        if indentationFollowsSettings, !indentationWasSetManually,
           Settings.shared.indentation(forLanguage: language.id) != appliedLanguageIndentation {
            indentUsesTabs = !Settings.shared.insertSpaces
            indentWidth = Settings.shared.tabWidth
            applyDetectedOrLanguageIndentation()
            applyEditorConfigIndentation(editorConfig)
            indentationChanged = true
        }
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
        if indentationChanged { postStateChange(force: true) }
    }

    func setIndentation(tabs: Bool, width: Int) {
        indentationWasSetManually = true
        indentUsesTabs = tabs
        indentWidth = width
        applyBaseAttributes()
        postStateChange(force: true)
    }

    @objc func themeChanged() {
        let fg = ThemeManager.shared.active.foreground
        isBulkLoading = true
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: fg, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        isBulkLoading = false
    }

    // MARK: Loading

    private func load(from url: URL, encoding preferred: TextEncoding?) throws {
        // Resource values describe a symlink itself rather than the file it points to.
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == false { throw DocumentError.notAFile }
        let stamp = DiskStamp(url)
        let data = try Perf.measure("  read") { try Document.readFile(url) }
        let decoded = Perf.measure("  decode") { TextEncoding.decode(data, preferred: preferred) }
        guard !decoded.isBinary else { throw DocumentError.binaryFile }
        let (text, ending) = Perf.measure("  line endings") { LineEnding.normalize(decoded.text, rawData: decoded.encoding == .utf8 ? data : nil) }
        encoding = decoded.encoding
        encodingWasDetected = decoded.detected
        lineEnding = ending
        diskStamp = stamp
        fileMissing = false
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        if !languageWasSetManually {
            language = LanguageRegistry.shared.language(forFileName: url.lastPathComponent, firstLine: firstLine)
        }
        Perf.measure("  setContent") { setContent(text) }
        if !indentationWasSetManually { Perf.measure("  indentation") { applyDetectedOrLanguageIndentation() } }
        applyEditorConfig()
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
        Perf.measure("  hash") { markClean() }
        startMonitoring()
        refreshGitBaseline()
    }

    private func setContent(_ text: String) {
        isBulkLoading = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.setAttributes(baseAttributes, range: NSRange(location: 0, length: textStorage.length))
        textStorage.endEditing()
        isBulkLoading = false
        Perf.measure("  line index") { lines.rebuild(from: textStorage.mutableString) }
        bookmarks.clamp(lineCount: lines.count)
        syntax.reset(language: language, lineCount: lines.count)
        editVersion += 1
    }

    /// Replaces the content programmatically (reload, find results). Clears undo history.
    func replaceAllContent(_ text: String) {
        setContent(text)
        undoManager.removeAllActions()
        markClean()
        allEditors.forEach { $0.documentDidReload() }
        postStateChange(force: true)
    }

    /// Restores an unsaved buffer (hot exit) on top of the file's saved state, keeping the saved
    /// hash so the document reads as dirty only if the buffer actually differs from disk.
    /// `backupStamp` is the file's state when the backup was taken.
    func restoreBuffer(_ text: String, from source: BackupSource? = nil, diskStamp backupStamp: DiskStamp? = nil) {
        setContent(text)
        undoManager.removeAllActions()
        if let source { restoredFrom = (source, editVersion) }
        dirtyFlag = !matchesSavedVersion()
        dirtyOnlyFromDeletion = false
        // The buffer was edited against an older version of the file. Keeping that version's stamp
        // makes saving ask before it replaces what another program wrote meanwhile.
        if dirtyFlag, let backupStamp, let current = diskStamp, backupStamp != current { diskStamp = backupStamp }
        allEditors.forEach { $0.documentDidReload() }
        postStateChange(force: true)
    }

    /// Identifies the buffer a hot-exit backup was written from: the document and its edit version.
    struct BackupSource: Equatable {
        let id: UUID
        let version: Int
    }

    var backupSource: BackupSource { BackupSource(id: id, version: editVersion) }

    /// The backup this buffer was restored from, and the edit version right after restoring it.
    private var restoredFrom: (source: BackupSource, editVersion: Int)?

    /// Remembers which buffer a restored tab showed, so an older backup of it isn't applied on top.
    func noteSessionSource(_ source: BackupSource) {
        if restoredFrom == nil && !dirtyFlag { restoredFrom = (source, editVersion) }
    }

    enum BackupRestore { case apply, skip, keepSeparately }

    /// Decides how to restore a backup into this document when another tab may already have
    /// restored or edited it: an older backup of the same buffer is skipped, and a backup of
    /// independent edits never replaces unsaved text.
    func restoreDecision(forBackup text: String, from source: BackupSource?) -> BackupRestore {
        if let source {
            if source.id == id && source.version <= editVersion { return .skip }
            if let r = restoredFrom, r.source.id == source.id, source.version <= r.source.version { return .skip }
        }
        guard dirtyFlag else { return .apply }
        if string.isEqual(to: text) { return .skip }
        if let source, let r = restoredFrom, r.source.id == source.id, r.editVersion == editVersion { return .apply }
        return .keepSeparately
    }

    func reload(encoding preferred: TextEncoding? = nil) throws {
        guard let url else { return }
        try load(from: url, encoding: preferred ?? (encodingWasDetected ? nil : encoding))
        undoManager.removeAllActions()
        allEditors.forEach { $0.documentDidReload() }
        postStateChange(force: true)
    }

    // MARK: EditorConfig

    private(set) var editorConfig = EditorConfig.Properties()

    /// The cleanups for saving to `target` (the file's own location when nil), so Save As follows
    /// the `.editorconfig` of the folder it saves into.
    func saveCleanups(to target: URL? = nil) -> (trimTrailingWhitespace: Bool, insertFinalNewline: Bool) {
        let ec = target.map { EditorConfig.properties(for: $0) } ?? editorConfig
        return (ec.trimTrailingWhitespace ?? Settings.shared.trimTrailingWhitespace,
                ec.insertFinalNewline ?? Settings.shared.ensureNewlineAtEOF)
    }

    /// Indentation follows the project unless the user chose it; line endings and charset only
    /// apply to files that have no content yet, so opening a file never rewrites it.
    private func applyEditorConfig() {
        guard let url else { return }
        let ec = EditorConfig.properties(for: url)
        editorConfig = ec
        guard !ec.values.isEmpty else { return }
        applyEditorConfigIndentation(ec)
        if isNewFile || length == 0 {
            if let le = ec.lineEnding { lineEnding = le }
            if let enc = ec.encoding { encoding = enc }
        }
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
    }

    private func applyEditorConfigIndentation(_ ec: EditorConfig.Properties) {
        guard !indentationWasSetManually else { return }
        if let tabs = ec.indentsWithTabs { indentUsesTabs = tabs }
        if let width = indentUsesTabs ? (ec.tabWidth ?? ec.indentSize) : (ec.indentSize ?? ec.tabWidth) {
            indentWidth = min(max(width, 1), 16)
        }
    }

    /// After Save As or a move, the file follows the `.editorconfig` of its new folder instead of
    /// the old one; indentation is worked out again as if the file had been opened there.
    private func followEditorConfig() {
        guard let url else { return }
        let ec = EditorConfig.properties(for: url)
        guard ec != editorConfig else { return }
        editorConfig = ec
        guard !indentationWasSetManually else { return }
        indentUsesTabs = !Settings.shared.insertSpaces
        indentWidth = Settings.shared.tabWidth
        applyDetectedOrLanguageIndentation()
        applyEditorConfigIndentation(ec)
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
    }

    /// Trims trailing whitespace and adds the final newline for a document without an editor
    /// (Save All, saving on quit), as one undoable change, so it saves the same bytes as ⌘S.
    func applySaveCleanups(trimTrailingWhitespace trim: Bool, insertFinalNewline: Bool) {
        guard !isReadOnly else { return }
        var edits: [(NSRange, String)] = []
        if trim, let re = try? NSRegularExpression(pattern: "[ \\t]+$", options: [.anchorsMatchLines]) {
            edits = re.matches(in: string as String, range: NSRange(location: 0, length: length)).map { ($0.range, "") }
        }
        if insertFinalNewline && length > 0 && string.character(at: length - 1) != 10 {
            edits.append((NSRange(location: length, length: 0), "\n"))
        }
        guard !edits.isEmpty else { return }
        undoManager.beginUndoGrouping()
        for (range, replacement) in edits.reversed() { replaceText(in: range, with: replacement) }
        undoManager.setActionName(trim ? "Trim Trailing Whitespace" : "Insert Final Newline")
        undoManager.endUndoGrouping()
    }

    private func replaceText(in range: NSRange, with replacement: String) {
        let old = string.substring(with: range)
        let undoRange = NSRange(location: range.location, length: (replacement as NSString).length)
        undoManager.registerUndo(withTarget: self) { $0.replaceText(in: undoRange, with: old) }
        textStorage.replaceCharacters(in: range, with: replacement)
    }

    /// The indentation Settings → Editor sets for the language, as last applied.
    private var appliedLanguageIndentation: Settings.Indentation?
    private var indentationFollowsSettings = true

    /// Indentation detected from the text comes first, so editing a file keeps its style; the
    /// language's setting covers new files and text without clear indentation. `.editorconfig`
    /// is applied after both and wins over them.
    private func applyDetectedOrLanguageIndentation() {
        appliedLanguageIndentation = Settings.shared.indentation(forLanguage: language.id)
        if !detectIndentation() { applyLanguageIndentation() }
    }

    /// Uses the indentation Settings → Editor sets for the document's language, if any.
    @discardableResult
    private func applyLanguageIndentation() -> Bool {
        let setting = Settings.shared.indentation(forLanguage: language.id)
        appliedLanguageIndentation = setting
        guard indentationFollowsSettings, !indentationWasSetManually, let setting else { return false }
        indentUsesTabs = setting.tabs
        indentWidth = setting.width
        return true
    }

    /// Whether the text showed its indentation style.
    @discardableResult
    private func detectIndentation() -> Bool {
        guard Settings.shared.detectIndentation else { return false }
        let s = textStorage.mutableString
        var tabs = 0, spaces = 0
        var widths: [Int: Int] = [:]
        var prevIndent = 0
        let limit = min(lines.count, 1000)
        for line in 0..<limit {
            let start = lines.start(of: line)
            let end = line + 1 < lines.count ? lines.start(of: line + 1) - 1 : s.length
            guard end > start else { continue }
            let c = s.character(at: start)
            if c == 9 { tabs += 1; continue }
            var n = 0
            var i = start
            while i < end && s.character(at: i) == 32 { n += 1; i += 1 }
            if i >= end { continue }
            if n > 0 { spaces += 1 }
            let diff = abs(n - prevIndent)
            if diff > 1 && diff <= 8 { widths[diff, default: 0] += 1 }
            prevIndent = n
        }
        if tabs > spaces && tabs > 0 {
            indentUsesTabs = true
            if let setting = Settings.shared.indentation(forLanguage: language.id) { indentWidth = setting.width }
            return true
        } else if spaces > 0 {
            indentUsesTabs = false
            if let best = widths.max(by: { $0.value < $1.value })?.key { indentWidth = best }
            return true
        }
        return false
    }

    // MARK: Language

    func setLanguage(_ lang: Language, manual: Bool = true) {
        guard lang !== language else { return }
        language = lang
        if manual { languageWasSetManually = true }
        syntax.reset(language: lang, lineCount: lines.count)
        if indentationFollowsSettings, !indentationWasSetManually,
           Settings.shared.indentation(forLanguage: lang.id) != appliedLanguageIndentation {
            indentUsesTabs = !Settings.shared.insertSpaces
            indentWidth = Settings.shared.tabWidth
            applyDetectedOrLanguageIndentation()
            applyEditorConfigIndentation(editorConfig)
            if attributesKey != appliedAttributesKey { applyBaseAttributes() }
        }
        allEditors.forEach { $0.documentLanguageDidChange() }
        postStateChange(force: true)
    }

    // MARK: Editing bookkeeping

    /// Lines touched by the most recent edit, for editors that keep per-line state.
    private(set) var lastEditLines: (firstLine: Int, removed: Int, inserted: Int) = (0, 0, 0)

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isBulkLoading else { return }
        let r = lines.update(editedRange: editedRange, delta: delta, text: textStorage.mutableString)
        lastEditLines = r
        bookmarks.adjust(editedRange: editedRange, delta: delta, change: r, lines: lines, textLength: textStorage.length)
        syntax.linesChanged(firstLine: r.firstLine, removed: r.removed, inserted: r.inserted)
        editVersion += 1
        dirtyFlag = true
        dirtyOnlyFromDeletion = false
        if undoManager.isUndoing || undoManager.isRedoing { scheduleCleanCheck() }
        for e in allEditors { e.documentDidEdit(range: editedRange, delta: delta) }
        postStateChange()
        SessionStore.shared.setNeedsSave()
        AutoSave.shared.documentDidEdit(self)
        if gitBaseline != nil { scheduleGitDiff(delay: 0.35) }
    }

    private func scheduleCleanCheck() {
        guard !cleanCheckScheduled else { return }
        cleanCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cleanCheckScheduled = false
            if self.matchesSavedVersion() {
                self.dirtyFlag = false
                self.postStateChange()
            }
        }
    }

    /// With the file gone from disk, matching the last saved text no longer means nothing would be lost.
    private func matchesSavedVersion() -> Bool {
        guard !fileMissing, length == savedLength, url == nil || lineEnding == savedLineEnding, let h = savedHash else { return false }
        return Document.contentHash(string) == h
    }

    private func markClean() {
        dirtyFlag = false
        dirtyOnlyFromDeletion = false
        savedLength = length
        savedHash = length <= 64_000_000 ? Document.contentHash(string) : nil
        savedLineEnding = lineEnding
    }

    /// Changes the line endings the next save writes. It is an unsaved, undoable change like an edit.
    func setLineEnding(_ ending: LineEnding) {
        guard ending != lineEnding else { return }
        let old = lineEnding
        lineEnding = ending
        undoManager.registerUndo(withTarget: self) { $0.setLineEnding(old) }
        undoManager.setActionName("Change Line Endings")
        dirtyFlag = !matchesSavedVersion()
        postStateChange(force: true)
        SessionStore.shared.setNeedsSave()
    }

    /// Fast 64-bit hash of the UTF-16 contents, processed in chunks.
    static func contentHash(_ s: NSString) -> UInt64 {
        let n = s.length
        let chunk = 1 << 16
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var h: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(n)
        var pos = 0
        while pos < n {
            let len = min(chunk, n - pos)
            s.getCharacters(buf, range: NSRange(location: pos, length: len))
            var i = 0
            while i + 4 <= len {
                let v = UInt64(buf[i]) | UInt64(buf[i + 1]) << 16 | UInt64(buf[i + 2]) << 32 | UInt64(buf[i + 3]) << 48
                h = (h ^ v) &* 0x100000001B3
                h ^= h >> 29
                i += 4
            }
            while i < len { h = (h ^ UInt64(buf[i])) &* 0x100000001B3; i += 1 }
            pos += len
        }
        return h
    }

    private func postStateChange(force: Bool = false) {
        let d = isDirty
        if force || d != wasDirty {
            wasDirty = d
            NotificationCenter.default.post(name: .documentStateDidChange, object: self)
        }
    }

    func restoreUntitledName(_ name: String) { untitledName = name }

    func markDirtyForRestoredBuffer() {
        dirtyFlag = true
        postStateChange(force: true)
    }

    // MARK: Saving

    func save(to target: URL? = nil, replacingExternalChanges: Bool = false) throws {
        guard let dest = target ?? url else { return }
        let resolved = dest.resolvingSymlinksInPath()
        if target == nil && !replacingExternalChanges, let current = DiskStamp(resolved), isNewFile || current != diskStamp {
            throw DocumentError.modifiedOnDisk
        }
        var text = textStorage.mutableString as String
        if lineEnding != .lf { text = text.replacingOccurrences(of: "\n", with: lineEnding.string) }
        guard let data = encoding.encode(text) else { throw DocumentError.encodingFailed(encoding) }
        LocalHistory.shared.recordBeforeOverwrite(of: resolved, with: data)
        try Document.writeFile(data, replacing: resolved)
        let nameChanged = url != dest
        let wasUntitled = url == nil
        url = dest
        untitledName = dest.lastPathComponent
        diskStamp = DiskStamp(resolved)
        fileMissing = false
        markClean()
        if nameChanged || isNewFile { startMonitoring() }
        isNewFile = false
        if wasUntitled { applyEditorConfig() } else if nameChanged { followEditorConfig() }
        DocumentRegistry.shared.register(self)
        refreshGitBaseline()
        if nameChanged && !languageWasSetManually {
            let lang = LanguageRegistry.shared.language(forFileName: dest.lastPathComponent, firstLine: firstLine())
            if lang !== language { setLanguage(lang, manual: false) }
        }
        if nameChanged { RecentFiles.shared.add(dest) }
        postStateChange(force: true)
    }

    /// Follows a file that was renamed or moved (e.g. from the sidebar) without writing it, so unsaved
    /// edits stay unsaved and the moved file keeps its contents.
    func fileDidMove(to newURL: URL) {
        url = newURL
        untitledName = newURL.lastPathComponent
        fileMissing = false
        startMonitoring()
        DocumentRegistry.shared.register(self)
        followEditorConfig()
        refreshGitBaseline()
        if !languageWasSetManually {
            let lang = LanguageRegistry.shared.language(forFileName: newURL.lastPathComponent, firstLine: firstLine())
            if lang !== language { setLanguage(lang, manual: false) }
        }
        postStateChange(force: true)
    }

    /// Writes beside the destination and renames into place, so a failed write never truncates the
    /// original. The rename would drop the old file's metadata, so mode, ownership, ACL, extended
    /// attributes (Finder tags, quarantine), the hidden flag and creation date are copied onto the
    /// new file first.
    static func writeFile(_ data: Data, replacing url: URL) throws {
        let path = url.path
        let fm = FileManager.default
        let existing = try? fm.attributesOfItem(atPath: path)
        // rename(2) only needs a writable folder, so it would replace a file the user can't write.
        if existing != nil && access(path, W_OK) != 0 {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        var info = stat()
        let hasInfo = existing != nil && stat(path, &info) == 0
        // A new file would split the path from the file's other hard links, which would keep the old text.
        if hasInfo && info.st_nlink > 1 && (info.st_mode & S_IFMT) == S_IFREG {
            try writeInPlace(data, path: path)
            return
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tovri-\(UUID().uuidString)").path
        // New files get the usual 0666 & ~umask; replacements stay private until they carry the original mode.
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, existing == nil ? 0o666 : 0o600)
        guard fd >= 0 else { throw writeError(errno, path: path) }
        var failure = writeAll(data, to: fd)
        if failure == 0 && fsync(fd) != 0 { failure = errno }
        if failure == 0, let existing {
            copyfile(path, temp, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            // Only flags that describe the file to the user; immutable, append-only and compression
            // flags belong to the old file's storage or would block the rename.
            let kept = hasInfo ? info.st_flags & UInt32(UF_HIDDEN | UF_NODUMP) : 0
            if kept != 0 { _ = fchflags(fd, kept) }
            if let owner = existing[.ownerAccountID] as? NSNumber, let group = existing[.groupOwnerAccountID] as? NSNumber,
               fchown(fd, owner.uint32Value, group.uint32Value) != 0 {
                _ = fchown(fd, uid_t.max, group.uint32Value)
            }
            if let mode = existing[.posixPermissions] as? NSNumber { fchmod(fd, mode_t(truncatingIfNeeded: mode.intValue)) }
        }
        close(fd)
        if failure == 0, let created = existing?[.creationDate] {
            try? fm.setAttributes([.creationDate: created], ofItemAtPath: temp)
        }
        if failure == 0 && rename(temp, path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temp)
            throw writeError(failure, path: path)
        }
    }

    /// Overwrites a file that has other hard links, so every link sees the new text. The old bytes
    /// are read first and written back if the write fails partway.
    private static func writeInPlace(_ data: Data, path: String) throws {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw writeError(errno, path: path) }
        defer { close(fd) }
        let old: Data
        do { old = try readAll(fd, path: path) } catch { throw writeError(EIO, path: path) }
        // Copy-on-write volumes need room for the whole new text before the old blocks are freed.
        var fs = statfs()
        if fstatfs(fd, &fs) == 0 && UInt64(fs.f_bavail) * UInt64(fs.f_bsize) < UInt64(data.count) {
            throw writeError(ENOSPC, path: path)
        }
        var failure = writeAll(data, to: fd)
        if failure == 0 && ftruncate(fd, off_t(data.count)) != 0 { failure = errno }
        if failure == 0 && fsync(fd) != 0 { failure = errno }
        guard failure != 0 else { return }
        if writeAll(old, to: fd) == 0 { _ = ftruncate(fd, off_t(old.count)) }
        _ = fsync(fd)
        throw writeError(failure, path: path)
    }

    /// Writes all of `data` from the start of the file; returns 0 or the errno of the failure.
    private static func writeAll(_ data: Data, to fd: Int32) -> Int32 {
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, base + done, raw.count - done, off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                done += n
            }
        }
        return failure
    }

    /// Reads with read(2) rather than mapping the file: touching a mapped page after another
    /// program truncates the file (log rotation, for one) crashes the app with SIGBUS.
    static func readFile(_ url: URL) throws -> Data {
        let path = url.path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw readError(errno, path: path) }
        defer { close(fd) }
        return try readAll(fd, path: path)
    }

    private static func readAll(_ fd: Int32, path: String) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw readError(errno, path: path) }
        // One spare byte lets the final read report the end without growing the buffer.
        var data = Data(count: max(Int(info.st_size), 0) + 1)
        var filled = 0
        while true {
            if filled == data.count { data.count += max(1 << 16, data.count / 4) }
            let n = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw readError(errno, path: path)
            }
            if n == 0 { break }
            filled += n
        }
        data.count = filled
        return data
    }

    private static func readError(_ code: Int32, path: String) -> CocoaError {
        let kind: CocoaError.Code
        switch code {
        case ENOENT: kind = .fileReadNoSuchFile
        case EACCES, EPERM: kind = .fileReadNoPermission
        default: kind = .fileReadUnknown
        }
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: underlying])
    }

    private static func writeError(_ code: Int32, path: String) -> CocoaError {
        let kind: CocoaError.Code
        switch code {
        case EACCES, EPERM: kind = .fileWriteNoPermission
        case ENOSPC, EDQUOT: kind = .fileWriteOutOfSpace
        case EROFS: kind = .fileWriteVolumeReadOnly
        default: kind = .fileWriteUnknown
        }
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: underlying])
    }

    func firstLine() -> String {
        let r = lines.range(of: 0, textLength: length)
        return string.substring(with: NSRange(location: r.location, length: min(r.length, 200)))
    }

    // MARK: Git

    private(set) var gitDiff = LineDiff()
    private var gitDiffVersion = -1
    private var gitBaseline: String?

    var isGitDiffCurrent: Bool { gitDiffVersion == editVersion }
    private var gitDiffScheduled = false
    private var gitGeneration = 0

    /// What the baseline was read from: the file, its encoding and HEAD's commit.
    private var gitBaselineSource: String?

    /// Fetches the file's contents at HEAD and recomputes the gutter diff. Running git is skipped
    /// when HEAD still points at the commit the current baseline came from.
    func refreshGitBaseline() {
        guard Settings.shared.gitGutter, let url, length < 3_000_000, let repo = GitRepository.find(for: url) else {
            // After Save As outside the repository the old file's HEAD copy no longer applies.
            clearGitBaseline()
            return
        }
        let enc = encoding
        let source = repo.headToken.map { "\(url.path)\n\(enc.rawValue)\n\($0)" }
        if let source, source == gitBaselineSource, gitBaseline != nil {
            scheduleGitDiff(delay: 0)
            return
        }
        repo.headContents(of: url) { [weak self] data in
            guard let self, self.url == url, Settings.shared.gitGutter else { return }
            let decoded = data.map { TextEncoding.decode($0, preferred: enc) }
            guard let decoded, !decoded.isBinary else { self.clearGitBaseline(); return }
            self.gitBaseline = LineEnding.normalize(decoded.text, rawData: nil).0
            self.gitBaselineSource = source
            self.scheduleGitDiff(delay: 0)
        }
    }

    /// Drops the committed copy and the diff, e.g. when Git features are turned off.
    func clearGitBaseline() {
        gitBaseline = nil
        gitBaselineSource = nil
        gitGeneration += 1
        guard !gitDiff.isEmpty || !gitDiff.hunks.isEmpty else { return }
        gitDiff = LineDiff()
        allEditors.forEach { $0.documentGitDiffDidChange() }
    }

    /// False until HEAD's copy has loaded, and for files Git doesn't track.
    var hasGitBaseline: Bool { gitBaseline != nil }

    /// Unified diff of the buffer, including unsaved edits, against HEAD.
    func unifiedDiffAgainstHead() -> String? {
        guard let base = gitBaseline, let url, let repo = GitRepository.find(for: url),
              let path = repo.relativePath(url) else { return nil }
        return GitRepository.unifiedDiff(old: base, new: string as String, path: path)
    }

    private func scheduleGitDiff(delay: TimeInterval) {
        guard !gitDiffScheduled else { return }
        gitDiffScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.gitDiffScheduled = false
            guard let base = self.gitBaseline, self.length < 3_000_000 else { return }
            self.gitGeneration += 1
            let gen = self.gitGeneration
            let current = self.string.copy() as! NSString
            let version = self.editVersion
            DispatchQueue.global(qos: .utility).async {
                let old = base.split(separator: "\n", omittingEmptySubsequences: false)
                let newText = current as String
                let new = newText.split(separator: "\n", omittingEmptySubsequences: false)
                let diff = GitRepository.diff(old: old, new: new)
                DispatchQueue.main.async {
                    guard gen == self.gitGeneration else { return }
                    self.gitDiff = diff
                    self.gitDiffVersion = version
                    self.allEditors.forEach { $0.documentGitDiffDidChange() }
                }
            }
        }
    }

    // MARK: File monitoring

    private var monitor: DispatchSourceFileSystemObject?
    private var diskEventPending = false

    func startMonitoring() {
        monitor?.cancel()
        monitor = nil
        guard let url else { return }
        let fd = open(url.resolvingSymlinksInPath().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // Most editors save atomically, replacing the inode; watch the new file.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.startMonitoring()
                    self?.diskEventOccurred()
                }
            } else {
                self.diskEventOccurred()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        monitor = src
    }

    private func diskEventOccurred() {
        guard !diskEventPending else { return }
        diskEventPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.diskEventPending = false
            NotificationCenter.default.post(name: .documentFileDidChangeOnDisk, object: self)
        }
    }

    /// The file vanished from disk; keep the buffer and treat it as unsaved.
    func markDeletedOnDisk() {
        guard !dirtyFlag else { return }
        dirtyFlag = true
        dirtyOnlyFromDeletion = true
        postStateChange(force: true)
    }

    // MARK: External changes

    enum DiskStatus { case unchanged, modified, deleted }

    func checkDiskStatus() -> DiskStatus {
        guard let url, !isNewFile else { return .unchanged }
        guard let current = DiskStamp(url) else {
            if !fileMissing { fileMissing = true; postStateChange(force: true) }
            return .deleted
        }
        if fileMissing {
            fileMissing = false
            // Unsaved only because the file was gone: once it is back, an unedited buffer is clean
            // again, so a file that returns (switching Git branches) reloads instead of asking.
            if dirtyFlag && (dirtyOnlyFromDeletion || matchesSavedVersion()) { dirtyFlag = false }
            dirtyOnlyFromDeletion = false
            postStateChange(force: true)
        }
        // The watcher can't be re-armed while the file is missing; resume once it is back.
        if monitor == nil { startMonitoring() }
        return current == diskStamp ? .unchanged : .modified
    }

    func acknowledgeDiskVersion() {
        guard let url else { return }
        diskStamp = DiskStamp(url)
    }

    // MARK: Word count

    /// Markdown, plain text and other formats people write prose in.
    var isProse: Bool {
        if ["markdown", "rst", "latex"].contains(language.id) { return true }
        guard language.id == "plain", !isTransient else { return false }
        // Plain text is also the fallback for logs, lock files and keys, which aren't prose.
        guard let url else { return true }
        let name = url.deletingPathExtension().lastPathComponent.uppercased()
        return ["txt", "text"].contains(url.pathExtension.lowercased())
            || (url.pathExtension.isEmpty && ["README", "CHANGELOG", "NOTES", "TODO", "AUTHORS", "LICENSE"].contains(name))
    }

    private var wordCountCache: (version: Int, count: Int)?
    private var wordCountScheduled = false

    /// The document's word count, possibly from an earlier version while a recount runs in the
    /// background; `updated` is called when a newer count is ready.
    func wordCount(updated: @escaping () -> Void) -> Int? {
        if let c = wordCountCache, c.version == editVersion { return c.count }
        if !wordCountScheduled && length < 20_000_000 {
            wordCountScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                let snapshot = self.string.copy() as! NSString
                let version = self.editVersion
                DispatchQueue.global(qos: .utility).async {
                    let count = Document.countWords(snapshot, in: NSRange(location: 0, length: snapshot.length))
                    DispatchQueue.main.async {
                        self.wordCountScheduled = false
                        self.wordCountCache = (version, count)
                        updated()
                    }
                }
            }
        }
        return wordCountCache?.count
    }

    /// Counts runs of letters and digits; an apostrophe or hyphen between letters stays inside a word.
    static func countWords(_ s: NSString, in range: NSRange) -> Int {
        let n = range.length
        guard n > 0 else { return 0 }
        let chunk = 1 << 16
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: min(chunk, n) + 1)
        defer { buf.deallocate() }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols).union(.controlCharacters)
        func isWordChar(_ c: unichar) -> Bool {
            if c < 0x80 { return isAlphaU(c) || isDigitU(c) }
            if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
            return !separators.contains(Unicode.Scalar(c)!)
        }
        var count = 0
        var inWord = false
        var pendingJoiner = false
        var pos = range.location
        let end = NSMaxRange(range)
        while pos < end {
            let len = min(chunk, end - pos)
            s.getCharacters(buf, range: NSRange(location: pos, length: len))
            for k in 0..<len {
                let c = buf[k]
                if isWordChar(c) {
                    if !inWord && !pendingJoiner { count += 1 }
                    inWord = true
                    pendingJoiner = false
                } else if inWord && (c == 39 || c == 0x2019 || c == 45) {
                    inWord = false
                    pendingJoiner = true
                } else {
                    inWord = false
                    pendingJoiner = false
                }
            }
            pos += len
        }
        return count
    }

    // MARK: Words for completion

    private var cachedWords: [String: [String]] = [:]
    private var wordsVersion = -1
    private var wordsBuilding = false
    private var wordsBuiltAt: TimeInterval = 0

    /// Words in the document whose first two letters (case-insensitive) match `prefix`.
    func completionWords(prefix: String) -> [String] {
        let now = Date.timeIntervalSinceReferenceDate
        if wordsVersion != editVersion && !wordsBuilding && length < 4_000_000 && (now - wordsBuiltAt > 2 || cachedWords.isEmpty) {
            wordsBuilding = true
            wordsBuiltAt = now
            let snapshot = textStorage.mutableString.copy() as! NSString
            let version = editVersion
            DispatchQueue.global(qos: .userInitiated).async {
                var words: [String: [String]] = [:]
                for w in Document.extractWords(snapshot) { words[String(w.lowercased().prefix(2)), default: []].append(w) }
                for k in words.keys { words[k]?.sort { $0.utf16.count < $1.utf16.count } }
                DispatchQueue.main.async {
                    self.cachedWords = words
                    self.wordsVersion = version
                    self.wordsBuilding = false
                }
            }
        }
        return cachedWords[String(prefix.lowercased().prefix(2))] ?? []
    }

    private static func extractWords(_ s: NSString) -> [String] {
        var set = Set<String>()
        let n = s.length
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: n)
        defer { buf.deallocate() }
        s.getCharacters(buf, range: NSRange(location: 0, length: n))
        var i = 0
        while i < n {
            let c = buf[i]
            if isAlphaU(c) || c == 95 || c == 36 || c >= 128 {
                let start = i
                while i < n && (isWordU(buf[i]) || buf[i] == 36) { i += 1 }
                if i - start >= 3 && i - start <= 64 {
                    set.insert(String(utf16CodeUnits: buf + start, count: i - start))
                }
            } else if isDigitU(c) {
                while i < n && isWordU(buf[i]) { i += 1 }
            } else {
                i += 1
            }
        }
        return Array(set)
    }
}

/// A file's identity, modification time and size. Any difference counts as a change: restoring a
/// backup or syncing can set an older time, coarse-timestamp file systems can keep the time while
/// the size changes, and a same-size replacement within one timestamp tick gets a new inode.
struct DiskStamp: Codable, Equatable {
    let seconds: Int
    let nanoseconds: Int
    let size: Int64
    let inode: UInt64
    let device: Int32

    /// stat(2) follows symlinks and, unlike URL resource values, is never served from a cache.
    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
        inode = info.st_ino
        device = info.st_dev
    }
}

/// Keeps one Document per file so the same file opened in several tabs/windows shares a buffer.
final class DocumentRegistry {
    static let shared = DocumentRegistry()
    private var byPath: [String: WeakDocument] = [:]

    private struct WeakDocument { weak var doc: Document? }

    private func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    func existing(for url: URL) -> Document? {
        let path = key(url)
        guard let doc = byPath[path]?.doc, let currentURL = doc.url, key(currentURL) == path else {
            byPath.removeValue(forKey: path)
            return nil
        }
        return doc
    }

    func open(_ url: URL, encoding: TextEncoding? = nil) throws -> Document {
        if let d = existing(for: url) { return d }
        let d = try Document(contentsOf: url, encoding: encoding)
        register(d)
        return d
    }

    func register(_ d: Document) {
        byPath = byPath.filter { $0.value.doc != nil && $0.value.doc !== d }
        if let url = d.url { byPath[key(url)] = WeakDocument(doc: d) }
    }

    func allDocuments() -> [Document] { byPath.values.compactMap { $0.doc } }
}

final class RecentFiles {
    static let shared = RecentFiles()
    private let key = "recentItems"
    private let maxItems = 24

    var items: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        if list.count > maxItems { list = Array(list.prefix(maxItems)) }
        UserDefaults.standard.set(list, forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

extension Document {
    func symbols() -> [EditorView.Symbol] {
        guard let re = language.symbolRegex, length < 20_000_000 else { return [] }
        let ns = string
        var out: [EditorView.Symbol] = []
        re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: length)) { m, _, stop in
            guard let m, m.numberOfRanges > 1 else { return }
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { return }
            let name = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            out.append(EditorView.Symbol(name: name, line: lines.line(containing: r.location), range: r))
            if out.count > 20_000 { stop.pointee = true }
        }
        return out
    }
}
