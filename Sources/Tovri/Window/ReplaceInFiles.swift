import AppKit
import CryptoKit

/// Replace in Files without any interface: plans a replace from a search, changes open documents
/// in their editors and other files on disk, and keeps what's needed to undo it.
enum ReplaceInFiles {
    static let actionName = "Replace in Files"

    typealias Edit = (range: NSRange, text: String)

    /// An open document inside the search folder, as it was when the search started.
    struct OpenFile {
        weak var document: Document?
        let url: URL
        let text: String
        let editVersion: Int
        let language: Language
    }

    /// A file the search matched.
    struct Target {
        /// The path searched; for open files, the document's.
        let url: URL
        let matches: Int
        /// What the file held when it was searched; nil for open files.
        let digest: SHA256.Digest?
        let open: OpenFile?
    }

    struct Plan {
        let options: FileSearcher.Options
        let replacement: String
        let result: FileSearcher.Result
        let targets: [Target]
        /// The search stopped early, so replacing would miss matches, or found more than one replace takes.
        var isLimited: Bool {
            result.limited || matches > FileSearcher.maxMatches || targets.count > FileSearcher.maxFiles
        }
        var matches: Int { targets.reduce(0) { $0 + $1.matches } }
        var openTargets: [Target] { targets.filter { $0.open != nil } }
        var diskTargets: [Target] { targets.filter { $0.open == nil } }
    }

    /// What happened to one file.
    struct Outcome {
        let path: String
        var replaced = 0
        /// The changed lines afterwards, in the Find Results format.
        var lines = ""
        /// Why the file was left as it was.
        var skipped: String?
        /// Changed in its open document rather than on disk.
        var inEditor = false
    }

    /// Open documents under `root`, by path relative to it.
    static func openFiles(under root: URL, in documents: [Document]) -> [String: OpenFile] {
        let rootPath = root.realPathURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var out: [String: OpenFile] = [:]
        for d in documents where !d.isTransient {
            guard let url = d.url, !d.isNewFile else { continue }
            let path = url.realPathURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            guard out[rel] == nil, let text = d.string.copy() as? String else { continue }
            out[rel] = OpenFile(document: d, url: url, text: text, editVersion: d.editVersion, language: d.language)
        }
        return out
    }

    /// Searches like Find in Files, with `open` searched instead of their files on disk. Runs on any thread.
    static func plan(_ options: FileSearcher.Options, replacement: String, open: [String: OpenFile],
                     searcher: FileSearcher = FileSearcher()) -> Plan? {
        var o = options
        o.unsaved = open.mapValues(\.text)
        o.languages = open.mapValues(\.language)
        o.recordsHits = true
        guard let result = searcher.run(o) else { return nil }
        o.unsaved = [:]
        var seen = Set<String>()
        var targets: [Target] = []
        for hit in result.hits {
            let f = open[hit.path]
            let url = f?.url ?? o.root.appendingPathComponent(hit.path)
            // Two paths can lead to one file through a symlink; it is changed once.
            guard seen.insert(url.realPathURL.path).inserted else { continue }
            targets.append(Target(url: url, matches: hit.matches, digest: f == nil ? hit.digest : nil, open: f))
        }
        return Plan(options: o, replacement: replacement, result: result, targets: targets)
    }

    /// The replacements for every match in `text` that Find in Files would show, in order.
    static func edits(in text: String, _ re: NSRegularExpression, options o: FileSearcher.Options, replacement: String,
                      isWordChar: ((UInt16) -> Bool)?) -> [Edit] {
        let template = o.regex ? FindState.regexTemplate(replacement) : replacement
        var out: [Edit] = []
        FindState.enumerateMatches(re, in: text, range: NSRange(location: 0, length: (text as NSString).length), isWordChar: isWordChar) { m in
            // Find in Files skips empty matches, so replacing them would change what the preview didn't show.
            guard m.range.length > 0 else { return true }
            out.append((m.range, o.regex ? re.replacementString(for: m, in: text, offset: 0, template: template) : replacement))
            return true
        }
        return out
    }

    /// `text` with `edits` applied, and where each replacement starts in it.
    static func applying(_ edits: [Edit], to text: NSString) -> (text: String, starts: [Int]) {
        let out = NSMutableString(capacity: text.length)
        var starts: [Int] = []
        var pos = 0
        for e in edits {
            out.append(text.substring(with: NSRange(location: pos, length: e.range.location - pos)))
            starts.append(out.length)
            out.append(e.text)
            pos = NSMaxRange(e.range)
        }
        out.append(text.substring(from: pos))
        return (out as String, starts)
    }

    /// The lines holding `locations` (ascending), in the Find Results format.
    static func resultLines(_ s: NSString, at locations: [Int]) -> String {
        let len = s.length
        var out = ""
        var line = 0
        var pos = 0
        var lineStart = 0
        var lastLine = -1
        for loc in locations {
            while pos < min(loc, len) {
                if s.character(at: pos) == 10 { line += 1; lineStart = pos + 1 }
                pos += 1
            }
            if line == lastLine { continue }
            lastLine = line
            var e = pos
            while e < len && s.character(at: e) != 10 { e += 1 }
            out += FileSearcher.resultLine(line, s.substring(with: NSRange(location: lineStart, length: e - lineStart)))
        }
        return out
    }

    // MARK: Applying

    /// Replaces in the plan's open documents, each as one undoable edit that leaves it unsaved. Main thread.
    static func applyInEditors(_ plan: Plan, batch: ReplaceBatch) -> [Outcome] {
        guard let re = FileSearcher.regex(for: plan.options) else { return [] }
        var outcomes: [Outcome] = []
        for t in plan.targets {
            guard let f = t.open else { continue }
            var out = Outcome(path: f.url.path, inEditor: true)
            guard let doc = f.document, doc.url == f.url else {
                out.skipped = "It was closed or moved after the search. Search again to include it."
                outcomes.append(out)
                continue
            }
            guard doc.editVersion == f.editVersion else {
                out.skipped = "It was edited after the search. Search again to include it."
                outcomes.append(out)
                continue
            }
            guard !doc.isReadOnly else {
                out.skipped = "It’s open as read-only."
                outcomes.append(out)
                continue
            }
            let text = doc.string as String
            let isWordChar = plan.options.wholeWord ? FindState.wordCharTest(doc.language) : nil
            let edits = edits(in: text, re, options: plan.options, replacement: plan.replacement, isWordChar: isWordChar)
            guard !edits.isEmpty else {
                out.skipped = "It no longer has any matches."
                outcomes.append(out)
                continue
            }
            let starts = doc.applyReplaceEdits(edits, actionName: actionName)
            batch.noteEdited(doc, path: f.url.path)
            out.replaced = edits.count
            out.lines = resultLines(doc.string, at: starts)
            outcomes.append(out)
        }
        return outcomes
    }

    /// Thread-safe stop flag.
    final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    /// Replaces in the plan's files that weren't open, saving each the way the editor would.
    /// Files in `openPaths` (real paths) were opened since the search and are left alone. Runs on any thread.
    static func applyOnDisk(_ plan: Plan, batch: ReplaceBatch, openPaths: Set<String> = [], history: LocalHistory? = nil,
                            cancel: Cancellation? = nil, progress: ((Int) -> Void)? = nil) -> [Outcome] {
        let targets = plan.diskTargets
        guard !targets.isEmpty, let re = FileSearcher.regex(for: plan.options) else { return [] }
        let rootPath = plan.options.root.realPathURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var outcomes = [Outcome?](repeating: nil, count: targets.count)
        let lock = NSLock()
        var done = 0
        outcomes.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                let t = targets[i]
                if cancel?.isCancelled == true {
                    ptr[i] = Outcome(path: t.url.path, skipped: "Left as it was, because the replace was stopped.")
                    return
                }
                ptr[i] = replaceOnDisk(t, re, plan: plan, rootPrefix: prefix, openPaths: openPaths, batch: batch, history: history)
                lock.lock()
                done += 1
                let n = done
                lock.unlock()
                progress?(n)
            }
        }
        return outcomes.compactMap { $0 }
    }

    private static func replaceOnDisk(_ t: Target, _ re: NSRegularExpression, plan: Plan, rootPrefix: String,
                                      openPaths: Set<String>, batch: ReplaceBatch, history: LocalHistory?) -> Outcome {
        var out = Outcome(path: t.url.path)
        func skip(_ why: String) -> Outcome {
            out.skipped = why
            return out
        }
        let real = t.url.realPathURL
        // A link inside the folder can point anywhere; searching through it is harmless, writing isn't.
        guard real.path.hasPrefix(rootPrefix) else { return skip("It’s a link to a file outside the folder, so it was left alone.") }
        if openPaths.contains(real.path) { return skip("It was opened after the search. Search again to change it in the editor.") }
        let data: Data
        do { data = try Document.readFile(real) } catch {
            if !FileManager.default.fileExists(atPath: real.path) { return skip("It was moved or deleted after the search.") }
            return skip("Tovri couldn’t read it.")
        }
        guard let digest = t.digest, SHA256.hash(data: data) == digest else {
            return skip("It changed after the search. Search again to include it.")
        }
        let decoded = TextEncoding.decode(data)
        guard !decoded.isBinary else { return skip("It looks like a binary file.") }
        let (text, ending) = LineEnding.normalize(decoded.text, rawData: decoded.encoding == .utf8 ? data : nil)
        // The editor keeps one kind of line ending and reads some bytes in a way that can't be
        // written back exactly; such a file would change in places the replace didn't touch.
        guard encode(text, decoded.encoding, ending) == data else {
            return skip("Saving it would also change parts of the file outside the matches, such as mixed line endings. Open it and replace there instead.")
        }
        let isWordChar = plan.options.wholeWord
            ? FindState.wordCharTest(LanguageRegistry.shared.language(forFileName: t.url.lastPathComponent)) : nil
        let edits = edits(in: text, re, options: plan.options, replacement: plan.replacement, isWordChar: isWordChar)
        guard !edits.isEmpty else { return skip("It no longer has any matches.") }
        let (newText, starts) = applying(edits, to: text as NSString)
        guard let newData = encode(newText, decoded.encoding, ending) else {
            return skip("The new text has characters that can’t be saved in \(decoded.encoding.rawValue), the file’s encoding.")
        }
        guard access(real.path, W_OK) == 0 else {
            return skip(errno == EROFS ? "It’s on a disk that can’t be written to." : "You don’t have permission to change it.")
        }
        guard let backup = batch.keep(data) else {
            return skip("Tovri couldn’t keep a copy of it for Undo Replace, so it was left alone.")
        }
        history?.recordBeforeOverwrite(of: real, with: newData)
        do {
            try Document.writeFile(newData, replacing: real)
        } catch {
            batch.discard(backup)
            return skip(error.localizedDescription)
        }
        batch.noteSaved(ReplaceBatch.Saved(url: real, path: t.url.path, backup: backup, written: SHA256.hash(data: newData)))
        out.replaced = edits.count
        out.lines = resultLines(newText as NSString, at: starts)
        return out
    }

    /// The bytes the editor would save for `text`.
    static func encode(_ text: String, _ encoding: TextEncoding, _ ending: LineEnding) -> Data? {
        encoding.encode(ending == .lf ? text : text.replacingOccurrences(of: "\n", with: ending.string))
    }

    // MARK: Reports

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    /// The Find Results text after a replace.
    static func report(_ plan: Plan, _ outcomes: [Outcome], stopped: Bool) -> String {
        let o = plan.options
        let saved = outcomes.filter { $0.skipped == nil && !$0.inEditor }
        let edited = outcomes.filter { $0.skipped == nil && $0.inEditor }
        let skipped = outcomes.filter { $0.skipped != nil }
        let with = plan.replacement.isEmpty ? "Removed “\(o.query)”" : "Replaced “\(o.query)” with “\(plan.replacement)”"
        var text = "\(with) in \(o.root.path)\(stopped ? " (stopped before the end)" : "")\n\n"
        func section(_ title: String, _ list: [Outcome]) {
            guard !list.isEmpty else { return }
            let n = list.reduce(0) { $0 + $1.replaced }
            text += "\(title): \(count(list.count, "file")), \(count(n, "replacement"))\n\n"
            for f in list { text += f.path + ":\n" + f.lines + "\n" }
        }
        section("Saved", saved)
        section("Changed in the editor, not saved yet", edited)
        if !skipped.isEmpty {
            text += "Left as they were: \(count(skipped.count, "file"))\n\n"
            for f in skipped { text += "\(f.path) — \(f.skipped ?? "")\n" }
            text += "\n"
        }
        if saved.isEmpty && edited.isEmpty {
            text += "Nothing was replaced.\n"
        } else {
            text += "To undo, choose Find → Undo Replace in Files.\n"
        }
        return text
    }
}

/// What one Replace in Files changed, so it can be undone: a copy of each file it saved, as it
/// was before, and the open documents it edited.
final class ReplaceBatch {
    struct Saved {
        /// The real path that was written.
        let url: URL
        /// The path as shown in the results.
        let path: String
        let backup: URL
        /// What Tovri wrote, to tell whether the file changed since.
        let written: SHA256.Digest
    }

    struct Edited {
        weak var document: Document?
        let path: String
        /// The document's version right after the replace.
        let editVersion: Int
    }

    private let lock = NSLock()
    private var _saved: [Saved] = []
    private(set) var edited: [Edited] = []
    private var folder: URL?

    var saved: [Saved] { lock.lock(); defer { lock.unlock() }; return _saved }
    var isEmpty: Bool { saved.isEmpty && edited.isEmpty }

    deinit {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Writes a private copy of `original` and returns where, or nil if it couldn't be written.
    func keep(_ original: Data) -> URL? {
        lock.lock()
        if folder == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Tovri Replace \(UUID().uuidString)", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil {
                folder = dir
            }
        }
        let dir = folder
        lock.unlock()
        guard let url = dir?.appendingPathComponent(UUID().uuidString) else { return nil }
        do { try original.write(to: url, options: .withoutOverwriting) } catch { return nil }
        return url
    }

    func discard(_ backup: URL) { try? FileManager.default.removeItem(at: backup) }

    func noteSaved(_ s: Saved) {
        lock.lock(); _saved.append(s); lock.unlock()
    }

    func noteEdited(_ doc: Document, path: String) {
        edited.append(Edited(document: doc, path: path, editVersion: doc.editVersion))
    }

    /// Why `s` can't be put back, or nil if it still holds exactly what Tovri wrote.
    func problem(with s: Saved) -> String? {
        guard let data = try? Document.readFile(s.url) else {
            return FileManager.default.fileExists(atPath: s.url.path) ? "Tovri couldn’t read it." : "It was moved or deleted after the replace."
        }
        return SHA256.hash(data: data) == s.written ? nil : "It changed after the replace."
    }

    /// Puts back the file as it was before the replace, unless it changed since. Returns why not, or nil.
    func restore(_ s: Saved) -> String? {
        if let problem = problem(with: s) { return problem }
        guard let original = try? Data(contentsOf: s.backup) else { return "Tovri’s copy of it is gone." }
        do { try Document.writeFile(original, replacing: s.url) } catch { return error.localizedDescription }
        return nil
    }

    /// Whether undo in `e`'s document would take back exactly the replace. Main thread.
    func canUndo(_ e: Edited) -> Bool {
        guard let doc = e.document else { return false }
        return doc.editVersion == e.editVersion && doc.undoManager.canUndo && doc.undoManager.undoActionName == ReplaceInFiles.actionName
    }
}

extension Document {
    /// Applies sorted, non-overlapping edits as one undoable change and returns where each
    /// replacement starts afterwards.
    func applyReplaceEdits(_ edits: [ReplaceInFiles.Edit], actionName: String) -> [Int] {
        breakTextViewUndoCoalescing()
        undoManager.beginUndoGrouping()
        replaceRanges(edits)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        breakTextViewUndoCoalescing()
        var starts: [Int] = []
        var delta = 0
        for e in edits {
            starts.append(e.range.location + delta)
            delta += (e.text as NSString).length - e.range.length
        }
        return starts
    }

    private func replaceRanges(_ edits: [ReplaceInFiles.Edit]) {
        var inverse: [ReplaceInFiles.Edit] = []
        var delta = 0
        for e in edits {
            let length = (e.text as NSString).length
            inverse.append((NSRange(location: e.range.location + delta, length: length), string.substring(with: e.range)))
            delta += length - e.range.length
        }
        undoManager.registerUndo(withTarget: self) { $0.replaceRanges(inverse) }
        textStorage.beginEditing()
        for e in edits.reversed() { textStorage.replaceCharacters(in: e.range, with: e.text) }
        textStorage.endEditing()
    }

    /// Text views merge consecutive typing into one undo step; an edit made around them must not
    /// become part of it.
    private func breakTextViewUndoCoalescing() {
        for lm in textStorage.layoutManagers {
            for tc in lm.textContainers { tc.textView?.breakUndoCoalescing() }
        }
    }
}

extension MainWindowController {
    @objc func undoReplaceInFiles(_ sender: Any?) { replaceInFiles.undoLast() }
}

/// Replace in Files for one window: searches, shows the matches and asks before changing
/// anything, replaces with progress, reports what happened and can undo the last replace.
final class ReplaceInFilesController {
    private weak var controller: MainWindowController?
    private var progressSheet: ReplaceProgressSheet?
    private(set) var lastBatch: ReplaceBatch?
    private(set) var isBusy = false
    /// Answers the confirmation instead of asking, for tests.
    var confirmsAutomatically: Bool?

    init(controller: MainWindowController) { self.controller = controller }

    var canUndo: Bool { !isBusy && lastBatch.map { !$0.isEmpty } == true }

    private var allDocuments: [Document] {
        guard let controller else { return [] }
        return (NSApp.delegate as? AppDelegate)?.controllers.flatMap { $0.allOpenDocuments() } ?? controller.allOpenDocuments()
    }

    private var window: NSWindow? {
        guard let w = controller?.window, w.isVisible else { return nil }
        return w
    }

    private func alert(_ message: String, _ info: String, buttons: [String] = ["OK"], _ done: ((Int) -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        buttons.forEach { a.addButton(withTitle: $0) }
        if let answer = confirmsAutomatically { done?(answer ? 0 : buttons.count - 1); return }
        let respond: (NSApplication.ModalResponse) -> Void = { r in done?(r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        if let w = window { a.beginSheetModal(for: w, completionHandler: respond) } else { respond(a.runModal()) }
    }

    func start(_ options: FileSearcher.Options, replacement: String, completion: (() -> Void)? = nil) {
        guard let c = controller else { return }
        guard !isBusy else {
            NSSound.beep()
            c.statusBar.flash("Tovri is still busy with the last replace.")
            return
        }
        isBusy = true
        let open = ReplaceInFiles.openFiles(under: options.root, in: allDocuments)
        let searcher = FileSearcher()
        c.statusBar.message = "Searching for “\(options.query)”…"
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = ReplaceInFiles.plan(options, replacement: replacement, open: open, searcher: searcher)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self else { return }
                self.controller?.statusBar.message = nil
                guard let plan else {
                    self.isBusy = false
                    NSSound.beep()
                    completion?()
                    return
                }
                self.preview(plan, elapsed: elapsed, completion: completion)
            }
        }
    }

    private func highlight(_ o: FileSearcher.Options) -> NSRegularExpression? {
        let st = FindState()
        st.regex = o.regex
        st.caseSensitive = o.caseSensitive
        st.wholeWord = o.wholeWord
        return st.makeRegex(query: o.query)
    }

    private func preview(_ plan: ReplaceInFiles.Plan, elapsed: TimeInterval, completion: (() -> Void)?) {
        guard let c = controller else { isBusy = false; return }
        c.showFindResults(FileSearcher.report(plan.result, for: plan.options, elapsed: elapsed), highlight: highlight(plan.options))
        if plan.isLimited {
            isBusy = false
            alert("Too many matches to replace at once",
                  "Replace in Files changes up to \(FileSearcher.maxMatches.formatted()) matches in up to \(FileSearcher.maxFiles.formatted()) files, and up to \(FileSearcher.maxMatchesPerFile.formatted()) matches in one file, at a time. This search found more. Narrow the search, or use Include and Exclude to replace in smaller parts.")
            completion?()
            return
        }
        guard !plan.targets.isEmpty else {
            isBusy = false
            NSSound.beep()
            c.statusBar.flash("No matches to replace")
            completion?()
            return
        }
        let go: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            if ok { self.apply(plan, completion: completion) } else { self.isBusy = false; completion?() }
        }
        let q = plan.options.query
        let open = plan.openTargets
        let dirty = open.filter { $0.open?.document?.isDirty == true }.count
        let disk = plan.targets.count - open.count
        var info = plan.replacement.isEmpty ? "Each match of “\(q)” is removed." : "Each match of “\(q)” is replaced with “\(plan.replacement)”."
        info += " Find Results shows every line that changes."
        if disk > 0 { info += "\n\n\(ReplaceInFiles.count(disk, "file")) \(disk == 1 ? "is" : "are") saved right away." }
        if !open.isEmpty {
            info += "\n\n\(ReplaceInFiles.count(open.count, "file")) open in Tovri \(open.count == 1 ? "is" : "are") changed in the editor instead"
            info += dirty > 0 ? ", including \(dirty) with unsaved edits. They stay unsaved, and the files on disk aren’t changed until you save them."
                              : ". They stay unsaved until you save them."
        }
        info += "\n\nYou can undo the replace with Find → Undo Replace in Files."
        alert("Replace \(ReplaceInFiles.count(plan.matches, "match", "matches")) in \(ReplaceInFiles.count(plan.targets.count, "file"))?", info,
              buttons: ["Replace", "Cancel"]) { go($0 == 0) }
    }

    private func apply(_ plan: ReplaceInFiles.Plan, completion: (() -> Void)?) {
        let batch = ReplaceBatch()
        let inEditor = ReplaceInFiles.applyInEditors(plan, batch: batch)
        let openPaths = Set(allDocuments.compactMap { $0.url?.realPathURL.path })
        let disk = plan.diskTargets.count
        let cancel = ReplaceInFiles.Cancellation()
        let history = LocalHistory.shared
        var sheet: ReplaceProgressSheet?
        if disk > 0, window != nil {
            let s = ReplaceProgressSheet(total: disk) { cancel.cancel() }
            sheet = s
            progressSheet = s
            // Most replaces finish before a sheet would be noticed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak s] in
                guard let self, let s, self.progressSheet === s, let w = self.window else { return }
                w.beginSheet(s.window)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let onDisk = ReplaceInFiles.applyOnDisk(plan, batch: batch, openPaths: openPaths, history: history, cancel: cancel) { n in
                DispatchQueue.main.async { sheet?.update(n) }
            }
            DispatchQueue.main.async {
                self?.finish(plan, inEditor + onDisk, batch: batch, stopped: cancel.isCancelled, completion: completion)
            }
        }
    }

    private func closeProgress() {
        if let s = progressSheet, let parent = s.window.sheetParent { parent.endSheet(s.window) }
        progressSheet = nil
    }

    private func finish(_ plan: ReplaceInFiles.Plan, _ outcomes: [ReplaceInFiles.Outcome], batch: ReplaceBatch, stopped: Bool,
                        completion: (() -> Void)?) {
        closeProgress()
        isBusy = false
        if !batch.isEmpty { lastBatch = batch }
        guard let c = controller else { return }
        let literal = plan.options.regex || plan.replacement.isEmpty ? nil
            : try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: plan.replacement))
        // A pattern that never matches clears the search's highlights from the previous text.
        c.showFindResults(ReplaceInFiles.report(plan, outcomes, stopped: stopped), highlight: literal ?? (try? NSRegularExpression(pattern: "(?!)")))
        let changed = outcomes.filter { $0.skipped == nil }
        let saved = changed.filter { !$0.inEditor }.count
        let edited = changed.count - saved
        let skipped = outcomes.count - changed.count
        let n = changed.reduce(0) { $0 + $1.replaced }
        c.statusBar.flash(changed.isEmpty ? "Nothing was replaced" : "Replaced \(ReplaceInFiles.count(n, "match", "matches"))")
        var lines: [String] = []
        if stopped { lines.append("You stopped the replace before it reached every file.") }
        if saved > 0 { lines.append("\(ReplaceInFiles.count(saved, "file")) saved.") }
        if edited > 0 { lines.append("\(ReplaceInFiles.count(edited, "open file")) changed in the editor, not saved yet.") }
        if skipped > 0 { lines.append("\(ReplaceInFiles.count(skipped, "file")) left as \(skipped == 1 ? "it was" : "they were"); Find Results says why.") }
        let title = changed.isEmpty ? "Nothing was replaced"
            : "Replaced \(ReplaceInFiles.count(n, "match", "matches")) in \(ReplaceInFiles.count(changed.count, "file"))"
        alert(title, lines.joined(separator: "\n"), buttons: batch.isEmpty ? ["OK"] : ["OK", "Undo Replace"]) { [weak self] r in
            if r == 1 { self?.undoLast() }
            completion?()
        }
    }

    // MARK: Undo

    /// Puts back what the last replace changed, except files and documents changed since.
    func undoLast(completion: (() -> Void)? = nil) {
        guard let batch = lastBatch, !isBusy else { NSSound.beep(); return }
        isBusy = true
        let dirty = Set(allDocuments.filter(\.isDirty).compactMap { $0.url?.realPathURL.path })
        let editors = batch.edited.map { (edit: $0, ok: batch.canUndo($0)) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = batch.saved.map { s -> (ReplaceBatch.Saved, String?) in
                (s, dirty.contains(s.url.path) ? "It’s open with unsaved edits." : batch.problem(with: s))
            }
            DispatchQueue.main.async { self?.confirmUndo(batch, files: files, editors: editors, completion: completion) }
        }
    }

    private func confirmUndo(_ batch: ReplaceBatch, files: [(ReplaceBatch.Saved, String?)],
                             editors: [(edit: ReplaceBatch.Edited, ok: Bool)], completion: (() -> Void)?) {
        let kept = files.compactMap { f in f.1.map { (f.0.path, $0) } }
            + editors.filter { !$0.ok }.map { ($0.edit.path, "It was edited after the replace.") }
        let restoreFiles = files.filter { $0.1 == nil }.map { $0.0 }
        let undoEditors = editors.filter { $0.ok }.map { $0.edit }
        let restorable = restoreFiles.count + undoEditors.count
        let go: () -> Void = { [weak self] in
            self?.performUndo(batch, files: restoreFiles, editors: undoEditors, kept: kept, completion: completion)
        }
        if kept.isEmpty { go(); return }
        let names = kept.prefix(5).map { ($0.0 as NSString).lastPathComponent }.joined(separator: ", ") + (kept.count > 5 ? "…" : "")
        guard restorable > 0 else {
            isBusy = false
            lastBatch = nil
            alert("Nothing to undo", "Every file changed after the replace, so Tovri left them as they are: \(names).")
            completion?()
            return
        }
        alert("\(ReplaceInFiles.count(kept.count, "file")) changed after the replace",
              "Tovri won’t undo \(kept.count == 1 ? "it" : "those"), so the newer changes are kept: \(names). Undo the replace in the other \(ReplaceInFiles.count(restorable, "file"))?",
              buttons: ["Undo in \(ReplaceInFiles.count(restorable, "File"))", "Cancel"]) { [weak self] r in
            if r == 0 { go() } else { self?.isBusy = false; completion?() }
        }
    }

    private func performUndo(_ batch: ReplaceBatch, files: [ReplaceBatch.Saved], editors: [ReplaceBatch.Edited],
                             kept: [(String, String)], completion: (() -> Void)?) {
        var undone: [String] = []
        var left = kept
        for e in editors {
            // Checked again: the confirmation can stay open while the document is edited.
            if batch.canUndo(e), let doc = e.document { doc.undoManager.undo(); undone.append(e.path) } else { left.append((e.path, "It was edited after the replace.")) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var restored: [String] = []
            var failed: [(String, String)] = []
            for s in files {
                if let problem = batch.restore(s) { failed.append((s.path, problem)) } else { restored.append(s.path) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if self.lastBatch === batch { self.lastBatch = nil }
                let all = restored + undone
                var text = "Undid Replace in Files\n\n"
                if !restored.isEmpty { text += "Restored on disk: \(ReplaceInFiles.count(restored.count, "file"))\n" + restored.map { $0 + "\n" }.joined() + "\n" }
                if !undone.isEmpty { text += "Undone in the editor: \(ReplaceInFiles.count(undone.count, "file"))\n" + undone.map { $0 + "\n" }.joined() + "\n" }
                let notDone = left + failed
                if !notDone.isEmpty {
                    text += "Left as they are: \(ReplaceInFiles.count(notDone.count, "file"))\n" + notDone.map { "\($0.0) — \($0.1)\n" }.joined()
                }
                self.controller?.showFindResults(text, highlight: try? NSRegularExpression(pattern: "(?!)"))
                self.controller?.statusBar.flash(all.isEmpty ? "Nothing was undone" : "Undid Replace in \(ReplaceInFiles.count(all.count, "file"))")
                completion?()
            }
        }
    }
}

/// Progress for a replace on disk, with a button to stop it.
private final class ReplaceProgressSheet: NSObject {
    let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private lazy var stopButton = NSButton(title: "Stop", target: self, action: #selector(stop))
    private let total: Int
    private let onStop: () -> Void

    init(total: Int, onStop: @escaping () -> Void) {
        self.total = total
        self.onStop = onStop
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 116), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 116))
        label.frame = NSRect(x: 20, y: 80, width: 360, height: 18)
        label.lineBreakMode = .byTruncatingTail
        bar.frame = NSRect(x: 20, y: 54, width: 360, height: 16)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        stopButton.frame = NSRect(x: 290, y: 12, width: 90, height: 30)
        stopButton.bezelStyle = .rounded
        stopButton.keyEquivalent = "\u{1b}"
        stopButton.toolTip = "Stop after the files being saved now. Files already changed stay changed; Undo Replace in Files puts them back."
        [label, bar, stopButton].forEach(content.addSubview)
        window.contentView = content
        update(0)
    }

    func update(_ done: Int) {
        // Files finish on several threads, so updates can arrive out of order.
        guard Double(done) >= bar.doubleValue else { return }
        bar.doubleValue = Double(done)
        if stopButton.isEnabled { label.stringValue = "Replacing in \(done.formatted()) of \(total.formatted()) files…" }
    }

    @objc private func stop() {
        stopButton.isEnabled = false
        label.stringValue = "Stopping…"
        onStop()
    }
}
