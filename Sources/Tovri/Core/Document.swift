import AppKit
import CryptoKit

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
    private(set) var lastReadDiskFingerprint: Data?
    private var restoredDiskConflict = false

    private func setDiskBaseline(_ stamp: DiskStamp?, fingerprint: Data? = nil) {
        diskStamp = stamp
        lastReadDiskFingerprint = fingerprint
        restoredDiskConflict = false
    }

    func matchesBackupDiskVersion(_ stamp: DiskStamp?, fingerprint: Data?) -> Bool {
        guard !restoredDiskConflict, let stamp, let current = diskStamp else { return false }
        // Old sessions can still use an exact stamp; a different mount needs proof of the bytes.
        if stamp == current && fingerprint == nil { return true }
        guard let fingerprint, fingerprint == lastReadDiskFingerprint else { return false }
        return stamp == current || (stamp.device != current.device && stamp.size == current.size
            && stamp.seconds == current.seconds && stamp.nanoseconds == current.nanoseconds)
    }

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
    private var savedEncoding: TextEncoding = .utf8
    private var savedEncodingWasDetected = false
    var savedFormat: (encoding: TextEncoding, lineEnding: LineEnding, encodingWasDetected: Bool) {
        (savedEncoding, savedLineEnding, savedEncodingWasDetected)
    }
    private var cleanCheckScheduled = false
    private var isBulkLoading = false
    private var wasDirty = false
    var suppressBookmarkAdjust = false
    private var bookmarkRestoredInUndo = false
    private var symbolCache: (version: Int, languageID: String, symbols: [EditorView.Symbol])?

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
        nc.addObserver(self, selector: #selector(clearBookmarkUndoFlag), name: .NSUndoManagerDidUndoChange, object: undoManager)
        nc.addObserver(self, selector: #selector(clearBookmarkUndoFlag), name: .NSUndoManagerDidRedoChange, object: undoManager)
        applyBaseAttributes()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        monitor?.cancel()
        WaitRegistry.shared.documentMayHaveClosed(self, stillOpen: false)
    }

    @objc private func clearBookmarkUndoFlag() {
        bookmarkRestoredInUndo = false
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

    var attributesKey: String { "\(font.fontName)|\(font.pointSize)|\(Settings.shared.fontWeight.rawValue)|\(indentWidth)|\(Settings.shared.ligatureAttribute)" }

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

    private func load(from url: URL, encoding preferred: TextEncoding?, incremental: Bool = false) throws {
        let (data, stamp) = try Perf.measure("  read") { try Document.readFileWithStamp(url) }
        let decoded = Perf.measure("  decode") { TextEncoding.decode(data, preferred: preferred) }
        guard !decoded.isBinary else { throw DocumentError.binaryFile }
        let (text, ending) = Perf.measure("  line endings") { LineEnding.normalize(decoded.text, rawData: decoded.encoding == .utf8 ? data : nil) }
        encoding = decoded.encoding
        encodingWasDetected = decoded.detected
        lineEnding = ending
        setDiskBaseline(stamp, fingerprint: Data(SHA256.hash(data: data)))
        fileMissing = false
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        if !languageWasSetManually {
            language = LanguageRegistry.shared.language(forFileName: url.lastPathComponent, firstLine: firstLine)
        }
        if !indentationWasSetManually {
            Perf.measure("  indentation") { applyDetectedOrLanguageIndentation(in: text as NSString) }
        }
        applyEditorConfig(for: url, applyFormatToEmpty: isNewFile || text.isEmpty)
        if incremental && textStorage.length > 0 {
            applyIncrementalReload(text)
        } else {
            Perf.measure("  setContent") { setContent(text) }
        }
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
        Perf.measure("  hash") { markClean() }
        startMonitoring()
        refreshGitBaseline()
    }

    private func setContent(_ text: String) {
        appliedAttributesKey = attributesKey
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

    private func applyIncrementalReload(_ newText: String) {
        let oldNS = textStorage.mutableString
        let newNS = newText as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length
        let limit = min(oldLen, newLen)
        var p = 0
        while p < limit && oldNS.character(at: p) == newNS.character(at: p) { p += 1 }
        if p == oldLen && p == newLen {
            allEditors.forEach { ($0 as? EditorView)?.colorizeVisible() }
            return
        }
        if p > 0 && p < oldLen && UTF16.isTrailSurrogate(oldNS.character(at: p)) { p -= 1 }
        var s = 0
        while s < limit - p && oldNS.character(at: oldLen - 1 - s) == newNS.character(at: newLen - 1 - s) { s += 1 }
        if s > 0 && oldLen - s < oldLen && UTF16.isTrailSurrogate(oldNS.character(at: oldLen - s)) { s -= 1 }
        let removedLen = oldLen - p - s
        let insertedLen = newLen - p - s
        guard removedLen + insertedLen < oldLen / 2 else {
            setContent(newText)
            allEditors.forEach { $0.documentDidReload() }
            return
        }
        let replaced = NSRange(location: p, length: removedLen)
        let inserted = newNS.substring(with: NSRange(location: p, length: insertedLen))
        let delta = insertedLen - removedLen
        let editedRange = NSRange(location: p, length: insertedLen)
        isBulkLoading = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: replaced, with: inserted)
        if insertedLen > 0 {
            textStorage.setAttributes(baseAttributes, range: editedRange)
        }
        textStorage.endEditing()
        isBulkLoading = false
        let r = lines.update(editedRange: editedRange, delta: delta, text: textStorage.mutableString)
        lastEditLines = r
        bookmarks.adjust(editedRange: editedRange, delta: delta, change: r, lines: lines, textLength: textStorage.length)
        syntax.linesChanged(firstLine: r.firstLine, removed: r.removed, inserted: r.inserted)
        editVersion += 1
        for e in allEditors {
            e.documentDidEdit(range: editedRange, delta: delta)
            if let ev = e as? EditorView {
                ev.findBar?.documentDidReload()
                ev.textView.sizeToFit()
                ev.minimap.needsDisplay = true
            }
        }
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
    func restoreBuffer(_ text: String, from source: BackupSource? = nil, diskStamp backupStamp: DiskStamp? = nil,
                       diskFingerprint backupFingerprint: Data? = nil) {
        setContent(text)
        undoManager.removeAllActions()
        if let source { restoredFrom = (source, editVersion) }
        dirtyFlag = !matchesSavedVersion()
        dirtyOnlyFromDeletion = false
        // Preserve the original baseline for future backups, and flag a conflict even when
        // the metadata is identical and only the bytes differ.
        if dirtyFlag, url != nil, let backupStamp, !matchesBackupDiskVersion(backupStamp, fingerprint: backupFingerprint) {
            diskStamp = backupStamp
            lastReadDiskFingerprint = backupFingerprint
            restoredDiskConflict = true
        }
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
        let wasPopulated = length > 0
        // A pending Save with Encoding choice describes the next write, not the bytes on disk.
        try load(from: url, encoding: preferred ?? (savedEncodingWasDetected ? nil : savedEncoding), incremental: wasPopulated)
        undoManager.removeAllActions()
        if !wasPopulated { allEditors.forEach { $0.documentDidReload() } }
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
        applyEditorConfig(for: url, applyFormatToEmpty: isNewFile || length == 0)
        if attributesKey != appliedAttributesKey { applyBaseAttributes() }
    }

    private func applyEditorConfig(for url: URL, applyFormatToEmpty: Bool) {
        let ec = EditorConfig.properties(for: url)
        editorConfig = ec
        guard !ec.values.isEmpty else { return }
        applyEditorConfigIndentation(ec)
        if applyFormatToEmpty {
            if let le = ec.lineEnding { lineEnding = le }
            if let enc = ec.encoding { encoding = enc }
        }
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
        var edits: [(range: NSRange, text: String)] = []
        if trim, let re = try? NSRegularExpression(pattern: "[ \\t]+$", options: [.anchorsMatchLines]) {
            edits = re.matches(in: string as String, range: NSRange(location: 0, length: length)).map { ($0.range, "") }
        }
        if insertFinalNewline && length > 0 {
            var effectiveEnd = length
            if let lastTrim = edits.last, NSMaxRange(lastTrim.range) == length {
                effectiveEnd = lastTrim.range.location
            }
            if effectiveEnd > 0 && string.character(at: effectiveEnd - 1) != 10 {
                edits.append((NSRange(location: length, length: 0), "\n"))
            }
        }
        guard !edits.isEmpty else { return }
        _ = applyReplaceEdits(edits, actionName: trim ? "Trim Trailing Whitespace" : "Insert Final Newline")
    }

    /// The indentation Settings → Editor sets for the language, as last applied.
    private var appliedLanguageIndentation: Settings.Indentation?
    private var indentationFollowsSettings = true

    /// Indentation detected from the text comes first, so editing a file keeps its style; the
    /// language's setting covers new files and text without clear indentation. `.editorconfig`
    /// is applied after both and wins over them.
    private func applyDetectedOrLanguageIndentation(in source: NSString? = nil) {
        appliedLanguageIndentation = Settings.shared.indentation(forLanguage: language.id)
        if !detectIndentation(in: source) { applyLanguageIndentation() }
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
    private func detectIndentation(in source: NSString? = nil) -> Bool {
        guard Settings.shared.detectIndentation else { return false }
        let s = source ?? textStorage.mutableString
        let totalLen = s.length
        var tabs = 0, spaces = 0
        var widths: [Int: Int] = [:]
        var prevIndent = 0
        var pos = 0
        var line = 0
        while pos < totalLen && line < 1000 {
            let nl = s.range(of: "\n", options: .literal, range: NSRange(location: pos, length: totalLen - pos))
            let end = nl.location == NSNotFound ? totalLen : nl.location
            defer {
                pos = nl.location == NSNotFound ? totalLen : nl.location + 1
                line += 1
            }
            guard end > pos else { continue }
            let c = s.character(at: pos)
            if c == 9 { tabs += 1; continue }
            var n = 0
            var i = pos
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
        if !suppressBookmarkAdjust && !bookmarkRestoredInUndo {
            let oldBookmarks = bookmarks.lines
            bookmarks.adjust(editedRange: editedRange, delta: delta, change: r, lines: lines, textLength: textStorage.length)
            if bookmarks.lines != oldBookmarks && !undoManager.isUndoing && !undoManager.isRedoing {
                let afterBookmarks = bookmarks.lines
                undoManager.registerUndo(withTarget: self) { doc in
                    doc.restoreBookmarksWithUndo(oldBookmarks, next: afterBookmarks)
                }
            }
        }
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

    func setBookmarksWithUndo(_ new: [Int], from previous: [Int]? = nil) {
        let old = previous ?? bookmarks.lines
        let normalized = Array(Set(new.filter { $0 >= 0 && $0 < lines.count })).sorted()
        guard normalized != old || bookmarks.lines != normalized else { return }
        bookmarks.set(normalized, lineCount: lines.count)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.restoreBookmarksWithUndo(old, next: normalized)
        }
    }

    func setBookmarksWithoutUndo(_ new: [Int]) {
        bookmarks.set(new, lineCount: lines.count)
    }

    private func restoreBookmarksWithUndo(_ target: [Int], next current: [Int]) {
        bookmarkRestoredInUndo = true
        bookmarks.set(target, lineCount: lines.count)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.restoreBookmarksWithUndo(current, next: target)
        }
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self)
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
        guard !fileMissing, length == savedLength,
              url == nil || (lineEnding == savedLineEnding && encoding == savedEncoding),
              let h = savedHash else { return false }
        return Document.contentHash(string) == h
    }

    private func markClean() {
        dirtyFlag = false
        dirtyOnlyFromDeletion = false
        savedLength = length
        savedHash = length <= 64_000_000 ? Document.contentHash(string) : nil
        savedLineEnding = lineEnding
        savedEncoding = encoding
        savedEncodingWasDetected = encodingWasDetected
    }

    /// Changes the encoding the next save writes, as an undoable edit without touching disk.
    @discardableResult
    func setEncoding(_ newEncoding: TextEncoding) -> Bool {
        guard newEncoding != encoding else { return true }
        guard Document.encode(string, encoding: newEncoding, lineEnding: lineEnding) != nil else { return false }
        let old = encoding
        encoding = newEncoding
        undoManager.registerUndo(withTarget: self) { _ = $0.setEncoding(old) }
        undoManager.setActionName("Change Encoding")
        dirtyFlag = !matchesSavedVersion()
        postStateChange(force: true)
        SessionStore.shared.setNeedsSave()
        return true
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

    func restoreUntitledName(_ name: String) {
        untitledName = name
        if name == "Untitled" {
            Document.untitledCounter = max(Document.untitledCounter, 1)
        } else if name.hasPrefix("Untitled "), let n = Int(name.dropFirst("Untitled ".count)), n > 0 {
            Document.untitledCounter = max(Document.untitledCounter, n)
        }
    }

    func markDirtyForRestoredBuffer() {
        dirtyFlag = true
        postStateChange(force: true)
    }

    // MARK: Saving

    private var preflightEncoded: (version: Int, encoding: TextEncoding, lineEnding: LineEnding, data: Data)?

    private static func resolveDestination(_ url: URL) -> URL {
        var current = url.resolvingSymlinksInPath()
        for _ in 0..<32 {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let n = readlink(current.path, &buf, buf.count - 1)
            guard n > 0 else { break }
            buf[n] = 0
            let target = String(cString: buf)
            let next = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : URL(fileURLWithPath: target, relativeTo: current.deletingLastPathComponent())
            current = next.standardizedFileURL.resolvingSymlinksInPath()
        }
        return current
    }

    /// Checks whether saving to `target` (or the file's own URL when nil) would replace external
    /// changes on disk without permission or fail text encoding.
    func checkBeforeSaving(to target: URL? = nil, replacingExternalChanges: Bool = false) throws {
        guard let dest = target ?? url else { return }
        let resolved = Document.resolveDestination(dest)
        if target == nil && !replacingExternalChanges, let current = DiskStamp(resolved),
           isNewFile || restoredDiskConflict || current != diskStamp {
            throw DocumentError.modifiedOnDisk
        }
        guard let data = Document.encode(textStorage.mutableString, encoding: encoding, lineEnding: lineEnding) else {
            throw DocumentError.encodingFailed(encoding)
        }
        preflightEncoded = (editVersion, encoding, lineEnding, data)
    }

    func save(to target: URL? = nil, replacingExternalChanges: Bool = false) throws {
        defer { preflightEncoded = nil }
        guard let dest = target ?? url else { return }
        let resolved = Document.resolveDestination(dest)
        if target == nil && !replacingExternalChanges, let current = DiskStamp(resolved),
           isNewFile || restoredDiskConflict || current != diskStamp {
            throw DocumentError.modifiedOnDisk
        }
        let data = try Perf.measure("  encode") { () throws -> Data in
            if let cached = preflightEncoded,
               cached.version == editVersion,
               cached.encoding == encoding,
               cached.lineEnding == lineEnding {
                return cached.data
            }
            guard let d = Document.encode(textStorage.mutableString, encoding: encoding, lineEnding: lineEnding) else {
                throw DocumentError.encodingFailed(encoding)
            }
            return d
        }
        let pendingHistory = LocalHistory.shared.prepareBeforeOverwrite(of: resolved, with: data)
        do {
            try Document.writeFile(data, replacing: resolved) { pendingHistory?.captureNow() }
            pendingHistory?.commit()
        } catch {
            pendingHistory?.discard()
            throw error
        }
        let nameChanged = url != dest
        let wasUntitled = url == nil
        url = dest
        untitledName = dest.lastPathComponent
        setDiskBaseline(DiskStamp(resolved), fingerprint: Data(SHA256.hash(data: data)))
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

    /// Unicode encodings can be converted in chunks without copying the whole buffer. Legacy
    /// encoders need the complete text to compose characters and handle conversion boundaries.
    static func encode(_ s: NSString, encoding: TextEncoding, lineEnding: LineEnding) -> Data? {
        let len = s.length
        let canChunk: Bool
        switch encoding {
        case .utf8, .utf8BOM, .utf16LE, .utf16BE: canChunk = true
        default: canChunk = false
        }
        if len <= 262_144 || !canChunk {
            var text = s as String
            if lineEnding != .lf { text = text.replacingOccurrences(of: "\n", with: lineEnding.string) }
            return encoding.encode(text)
        }
        var out = Data()
        out.reserveCapacity(len + (lineEnding == .crlf ? max(1024, len / 40) : 16))
        if !encoding.bom.isEmpty { out.append(contentsOf: encoding.bom) }
        let chunk = 262_144
        var pos = 0
        while pos < len {
            var end = min(len, pos + chunk)
            if end < len && UTF16.isLeadSurrogate(s.character(at: end - 1)) { end += 1 }
            var piece = s.substring(with: NSRange(location: pos, length: end - pos))
            if lineEnding != .lf { piece = piece.replacingOccurrences(of: "\n", with: lineEnding.string) }
            guard let d = piece.data(using: encoding.stringEncoding, allowLossyConversion: false) else { return nil }
            out.append(d)
            pos = end
        }
        return out
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
    /// new file first. A file with other hard links, or in a folder that can't take the temp
    /// file, is written in place instead; `willOverwriteInPlace` runs before each such write.
    static func writeFile(_ data: Data, replacing url: URL, willOverwriteInPlace: (() -> Void)? = nil) throws {
        let path = url.path
        let fm = FileManager.default
        let existing = try? fm.attributesOfItem(atPath: path)
        // rename(2) only needs a writable folder, so it would replace a file the user can't write.
        if existing != nil && access(path, W_OK) != 0 {
            throw writeError(errno, path: path)
        }
        var info = stat()
        let hasInfo = existing != nil && stat(path, &info) == 0
        // A new file would split the path from the file's other hard links, which would keep the old text.
        if hasInfo && info.st_nlink > 1 && (info.st_mode & S_IFMT) == S_IFREG {
            willOverwriteInPlace?()
            try writeInPlace(data, path: path)
            return
        }
        var temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tovri-\(UUID().uuidString)").path
        // New files get the usual 0666 & ~umask; replacements stay private until they carry the original mode.
        var fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, existing == nil ? 0o666 : 0o600)
        if fd < 0 && errno == ENAMETOOLONG {
            // The name plus the temp prefix can pass the 255-byte file name limit.
            temp = url.deletingLastPathComponent().appendingPathComponent(".tovri-\(UUID().uuidString)").path
            fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, existing == nil ? 0o666 : 0o600)
        }
        if fd < 0 && (errno == EACCES || errno == EPERM) && hasInfo && (info.st_mode & S_IFMT) == S_IFREG {
            // The folder can't take a temp file. Try to restore the old bytes if the in-place write fails.
            willOverwriteInPlace?()
            try writeInPlace(data, path: path)
            return
        }
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
    /// are read first for a best-effort rollback if the write fails.
    private static func writeInPlace(_ data: Data, path: String) throws {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw writeError(errno, path: path) }
        defer { close(fd) }
        let old: Data
        do { old = try readAll(fd, path: path) } catch { throw writeError(EIO, path: path) }
        // Copy-on-write volumes need room for the whole new text before the old blocks are freed.
        var fs = statfs()
        if fstatfs(fd, &fs) == 0,
           !fitsAvailableSpace(neededBytes: data.count, availableBlocks: UInt64(fs.f_bavail), blockSize: UInt64(fs.f_bsize)) {
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

    static func fitsAvailableSpace(neededBytes: Int, availableBlocks: UInt64, blockSize: UInt64) -> Bool {
        guard neededBytes > 0 else { return true }
        let (avail, overflow) = availableBlocks.multipliedReportingOverflow(by: blockSize)
        return overflow || avail >= UInt64(neededBytes)
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
    static func readFile(_ url: URL, maxBytes: Int = Int.max) throws -> Data {
        try readFileWithStamp(url, maxBytes: maxBytes).data
    }

    static func readFileWithStamp(_ url: URL, maxBytes: Int = Int.max) throws -> (data: Data, stamp: DiskStamp) {
        let path = url.path
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw readError(errno, path: path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw readError(errno, path: path) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw DocumentError.notAFile }
        let data = try readAll(fd, info: info, path: path, maxBytes: maxBytes)
        return (data, DiskStamp(info: info))
    }

    private static func readAll(_ fd: Int32, path: String, maxBytes: Int = Int.max) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw readError(errno, path: path) }
        return try readAll(fd, info: info, path: path, maxBytes: maxBytes)
    }

    private static func readAll(_ fd: Int32, info: stat, path: String, maxBytes: Int) throws -> Data {
        if info.st_size > off_t(maxBytes) { throw readError(EFBIG, path: path) }
        // One spare byte lets the final read report the end without growing the buffer.
        var data = Data(count: max(Int(info.st_size), 0) + 1)
        var filled = 0
        while true {
            if filled == data.count {
                guard data.count <= maxBytes else { throw readError(EFBIG, path: path) }
                data.count += min(max(1 << 16, data.count / 4), max(1, maxBytes - data.count + 1))
            }
            let n = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw readError(errno, path: path)
            }
            if n == 0 { break }
            filled += n
            if filled > maxBytes { throw readError(EFBIG, path: path) }
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
    private var gitBaselineGeneration = 0
    private var gitDiffGeneration = 0

    /// What the baseline was read from: the file, its encoding and HEAD's commit.
    private var gitBaselineSource: String?

    /// Fetches the file's contents at HEAD and recomputes the gutter diff. Running git is skipped
    /// when HEAD still points at the commit the current baseline came from.
    func refreshGitBaseline(
        fetchHead: (GitRepository, URL, @escaping (Data?) -> Void) -> Void = {
            $0.headContents(of: $1, maxBytes: 12_000_000, $2)
        }
    ) {
        guard Settings.shared.gitGutter, let url, length < 3_000_000, let repo = GitRepository.find(for: url) else {
            // After Save As outside the repository the old file's HEAD copy no longer applies.
            clearGitBaseline()
            return
        }
        let enc = encoding
        let source = repo.headToken.map { "\(url.path)\n\(enc.rawValue)\n\($0)" }
        // The cached baseline also supersedes a request that hasn't finished yet.
        gitBaselineGeneration += 1
        if let source, source == gitBaselineSource, gitBaseline != nil {
            scheduleGitDiff(delay: 0)
            return
        }
        let gen = gitBaselineGeneration
        fetchHead(repo, url) { [weak self] data in
            guard let self, self.gitBaselineGeneration == gen, self.url == url, self.encoding == enc, Settings.shared.gitGutter else { return }
            let decoded = data.map { TextEncoding.decode($0, preferred: enc, preferUTF8IfValid: true) }
            guard let decoded, !decoded.isBinary, decoded.text.utf16.count < 3_000_000 else { self.clearGitBaseline(); return }
            self.gitBaseline = LineEnding.normalize(decoded.text, rawData: nil).0
            self.gitBaselineSource = source
            // A diff still running against the old baseline must not land over the new one.
            self.gitDiffGeneration += 1
            self.scheduleGitDiff(delay: 0)
        }
    }

    /// Drops the committed copy and the diff, e.g. when Git features are turned off.
    func clearGitBaseline() {
        gitBaseline = nil
        gitBaselineSource = nil
        gitBaselineGeneration += 1
        gitDiffGeneration += 1
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
            guard self.length < 3_000_000 else {
                self.clearGitBaseline()
                return
            }
            guard let base = self.gitBaseline else { return }
            self.gitDiffGeneration += 1
            let gen = self.gitDiffGeneration
            let current = self.string.copy() as! NSString
            let version = self.editVersion
            DispatchQueue.global(qos: .utility).async {
                let diff = GitRepository.diff(oldText: base, newText: current as String)
                DispatchQueue.main.async {
                    guard gen == self.gitDiffGeneration else { return }
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
        let fd = open(url.resolvingSymlinksInPath().path, O_EVTONLY | O_CLOEXEC)
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
        return !restoredDiskConflict && current == diskStamp ? .unchanged : .modified
    }

    func acknowledgeDiskVersion() {
        guard let url else { return }
        setDiskBaseline(DiskStamp(url))
    }

    /// Keeps unsaved edits in memory after an explicit Git discard restored the file on disk,
    /// updating `diskStamp` so external-change checks do not raise a contradictory conflict sheet.
    func syncDiskBaselineAfterDiscard() {
        guard let url else { return }
        setDiskBaseline(DiskStamp(url))
        fileMissing = false
        dirtyOnlyFromDeletion = false
        savedHash = nil
        dirtyFlag = true
        postStateChange(force: true)
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
    private var wordWaiters: [() -> Void] = []

    /// Words in the document whose first two letters (case-insensitive) match `prefix`.
    func completionWords(prefix: String, onReady: (() -> Void)? = nil) -> [String] {
        let now = Date.timeIntervalSinceReferenceDate
        if wordsVersion != editVersion && length < 4_000_000 {
            if let onReady { wordWaiters.append(onReady) }
            if !wordsBuilding && (now - wordsBuiltAt > 2 || cachedWords.isEmpty) {
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
                        let waiters = self.wordWaiters
                        self.wordWaiters = []
                        waiters.forEach { $0() }
                    }
                }
            }
        }
        return cachedWords[String(prefix.lowercased().prefix(2))] ?? []
    }

    private static let nonWordSeparators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
        .union(.controlCharacters)

    private static func extractWords(_ s: NSString) -> [String] {
        var set = Set<String>()
        let n = s.length
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: n)
        defer { buf.deallocate() }
        s.getCharacters(buf, range: NSRange(location: 0, length: n))
        func isNonASCIIWord(_ c: unichar) -> Bool {
            if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
            return Unicode.Scalar(c).map { !nonWordSeparators.contains($0) } ?? false
        }
        func isCompletionStart(_ c: unichar) -> Bool {
            if c < 128 { return isAlphaU(c) || c == 95 || c == 36 }
            return isNonASCIIWord(c)
        }
        func isCompletionCont(_ c: unichar) -> Bool {
            if c < 128 { return isWordU(c) || c == 36 }
            return isNonASCIIWord(c)
        }
        var i = 0
        while i < n {
            let c = buf[i]
            if isCompletionStart(c) {
                let start = i
                while i < n && isCompletionCont(buf[i]) { i += 1 }
                if i - start >= 3 && i - start <= 64 {
                    set.insert(String(utf16CodeUnits: buf + start, count: i - start))
                }
            } else if isDigitU(c) {
                while i < n && isCompletionCont(buf[i]) { i += 1 }
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

    init(info: stat) {
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
        inode = info.st_ino
        device = info.st_dev
    }

    /// stat(2) follows symlinks and, unlike URL resource values, is never served from a cache.
    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        self.init(info: info)
    }
}

/// Keeps one Document per file so the same file opened in several tabs/windows shares a buffer.
final class DocumentRegistry {
    static let shared = DocumentRegistry()
    private let lock = NSLock()
    private var byPath: [String: WeakDocument] = [:]

    private struct WeakDocument { weak var doc: Document? }

    private func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    func existing(for url: URL) -> Document? {
        let path = key(url)
        lock.lock()
        defer { lock.unlock() }
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
        let path = d.url.map(key)
        lock.lock()
        byPath = byPath.filter { $0.value.doc != nil && $0.value.doc !== d }
        if let path { byPath[path] = WeakDocument(doc: d) }
        lock.unlock()
    }

    func allDocuments() -> [Document] {
        lock.lock()
        defer { lock.unlock() }
        return byPath.values.compactMap { $0.doc }
    }
}

final class RecentFiles {
    static let shared = RecentFiles()
    private let key: String
    private let probe: (String) -> URL?
    private let maxItems = 24
    private let lock = NSLock()
    private var existingCache: [URL]?
    /// Items added in this session that have not yet been verified by a background disk probe.
    private var unprobedAdditions: [String: (generation: Int, url: URL)] = [:]
    private var mutationGeneration = 0
    private var pendingUpdates: [() -> Void] = []
    private var checking = false

    init(defaultsKey: String = "recentItems", probe: @escaping (String) -> URL? = RecentFiles.probeOnDisk) {
        self.key = defaultsKey
        self.probe = probe
    }

    static func probeOnDisk(_ path: String) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: isDir.boolValue)
    }

    var paths: [String] {
        AppRuntime.defaults.stringArray(forKey: key) ?? []
    }

    var items: [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    /// Recent items known to exist on disk, refreshed off the main thread so drawing the empty
    /// state, opening menus, or invoking the palette never touches the filesystem on the main
    /// thread—even on a cold cache. Uses `URL(fileURLWithPath:isDirectory:)` because single-arg
    /// `URL(fileURLWithPath:)` synchronously stats every path on the caller.
    func availableItems(onUpdate: (() -> Void)? = nil) -> [URL] {
        let currentPaths = paths
        if currentPaths.isEmpty {
            lock.lock()
            existingCache = []
            unprobedAdditions.removeAll()
            lock.unlock()
            return []
        }
        lock.lock()
        let visible = resolvedLocked(for: currentPaths)
        if let onUpdate { pendingUpdates.append(onUpdate) }
        let shouldStart = !checking
        let startGen = mutationGeneration
        if shouldStart { checking = true }
        lock.unlock()
        if shouldStart {
            startBackgroundRefresh(for: currentPaths, generation: startGen, previousVisible: visible)
        }
        return visible
    }

    private func resolvedLocked(for currentPaths: [String]) -> [URL] {
        if let cached = existingCache {
            let byPath = Dictionary(uniqueKeysWithValues: cached.map { ($0.path, $0) })
            return currentPaths.compactMap { byPath[$0] ?? unprobedAdditions[$0]?.url }
        }
        return currentPaths.compactMap { unprobedAdditions[$0]?.url }
    }

    private func startBackgroundRefresh(for snapshot: [String], generation startGen: Int, previousVisible: [URL]) {
        let probe = self.probe
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let existing = snapshot.compactMap(probe)
            DispatchQueue.main.async {
                guard let self else { return }
                let latestPaths = self.paths
                let probedSet = Set(snapshot)
                self.lock.lock()
                for p in snapshot {
                    if let entry = self.unprobedAdditions[p], entry.generation <= startGen {
                        self.unprobedAdditions.removeValue(forKey: p)
                    }
                }
                var merged = existing
                let seen = Set(merged.map(\.path))
                for p in latestPaths where !seen.contains(p) {
                    if let pending = self.unprobedAdditions[p]?.url { merged.append(pending) }
                }
                let byPath = Dictionary(uniqueKeysWithValues: merged.map { ($0.path, $0) })
                let ordered = latestPaths.compactMap { byPath[$0] }
                let changed = self.existingCache != ordered || previousVisible != ordered
                self.existingCache = ordered
                let callbacks = self.pendingUpdates
                self.pendingUpdates.removeAll()
                let nextGen = self.mutationGeneration
                let needsFollowUp = latestPaths.contains { !probedSet.contains($0) }
                self.checking = needsFollowUp
                self.lock.unlock()
                if changed {
                    for cb in callbacks { cb() }
                }
                if needsFollowUp {
                    self.startBackgroundRefresh(for: latestPaths, generation: nextGen, previousVisible: ordered)
                }
            }
        }
    }

    func add(_ url: URL) {
        let normalized = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        var list = AppRuntime.defaults.stringArray(forKey: key) ?? []
        list.removeAll { $0 == normalized.path }
        list.insert(normalized.path, at: 0)
        if list.count > maxItems { list = Array(list.prefix(maxItems)) }
        AppRuntime.defaults.set(list, forKey: key)
        lock.lock()
        mutationGeneration += 1
        unprobedAdditions[normalized.path] = (mutationGeneration, normalized)
        if var c = existingCache {
            c.removeAll { $0.path == normalized.path }
            c.insert(normalized, at: 0)
            existingCache = Array(c.prefix(maxItems))
        }
        lock.unlock()
        if key == "recentItems" && !AppRuntime.isRunningTests {
            NSDocumentController.shared.noteNewRecentDocumentURL(normalized)
        }
    }

    func clear() {
        AppRuntime.defaults.removeObject(forKey: key)
        lock.lock()
        mutationGeneration += 1
        existingCache = []
        unprobedAdditions.removeAll()
        lock.unlock()
        if key == "recentItems" && !AppRuntime.isRunningTests {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
    }
}

extension Document {
    func symbols() -> [EditorView.Symbol] {
        if let c = symbolCache, c.version == editVersion, c.languageID == language.id { return c.symbols }
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
        symbolCache = (editVersion, language.id, out)
        return out
    }
}
