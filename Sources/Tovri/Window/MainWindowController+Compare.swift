import AppKit

/// Comparing the editor with text other than the last commit (the saved file, the clipboard,
/// another file, an earlier version kept by Local History), and Local History itself. These
/// comparisons use the same inline view, gutter markers, change card and Revert Change as
/// Compare with Last Commit, and work whether or not Git is turned on.
extension MainWindowController {
    /// Files and clipboard text compared with are read whole and diffed by line; larger ones are refused.
    static let maxComparedSize = 20_000_000
    static let localHistoryListTag = "localHistory"
    /// Where Compare with Clipboard reads from; tests use a private pasteboard.
    static var comparisonPasteboard = NSPasteboard.general

    enum ComparisonReadProblem: Error, Equatable {
        case notAFile, tooLarge, binary, unreadable
    }

    // MARK: Compare with Saved

    @objc func compareWithSaved(_ sender: Any?) {
        guard let e = activeEditor, !e.document.isTransient, e.document.url != nil, !e.document.isNewFile else { NSSound.beep(); return }
        if e.comparisonSource == .saved { e.setComparing(false); return }
        guard e.document.isDirty else { statusBar.flash("“\(e.document.displayName)” has no unsaved changes"); return }
        compareWithSavedFile(e, quiet: false)
    }

    /// Reads the file on disk and compares the editor with it. `quiet` refreshes an existing
    /// comparison after a save without a message.
    private func compareWithSavedFile(_ e: EditorView, quiet: Bool) {
        let doc = e.document
        guard let url = doc.url else { return }
        loadComparisonText(at: url, encoding: doc.encoding) { [weak self, weak e] result in
            guard let self, let e, e.document === doc, doc.url == url else { return }
            if quiet && e.comparisonSource != .saved { return }
            switch result {
            case .success(let text):
                self.show(e, comparedWith: text, label: "the saved file", source: .saved, quiet: quiet)
            case .failure(let problem):
                if !quiet { self.statusBar.flash(MainWindowController.message(for: problem, name: url.lastPathComponent)) }
            }
        }
    }

    /// Keeps Compare with Saved current once the document is saved or reloaded.
    func comparisonDocumentStateChanged(_ doc: Document) {
        guard !doc.isDirty else { return }
        for e in groups.flatMap({ $0.tabs }).compactMap({ $0.editor }) where e.document === doc && e.comparisonSource == .saved {
            compareWithSavedFile(e, quiet: true)
        }
    }

    // MARK: Compare with Clipboard

    @objc func compareWithClipboard(_ sender: Any?) {
        guard let e = activeEditor, !e.document.isTransient else { NSSound.beep(); return }
        if e.comparisonSource == .clipboard { e.setComparing(false); return }
        guard let text = MainWindowController.comparisonPasteboard.string(forType: .string) else {
            statusBar.flash("The clipboard has no text to compare with")
            return
        }
        guard text.utf16.count <= MainWindowController.maxComparedSize else {
            statusBar.flash("The text on the clipboard is too large to compare")
            return
        }
        show(e, comparedWith: LineEnding.normalize(text, rawData: nil).0, label: "the clipboard", source: .clipboard)
    }

    // MARK: Compare with File

    @objc func compareWithFile(_ sender: Any?) {
        guard let e = activeEditor, !e.document.isTransient, let window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Compare"
        panel.message = "Choose a file to compare “\(e.document.displayName)” with."
        panel.directoryURL = e.document.url?.deletingLastPathComponent() ?? folderURL
        panel.beginSheetModal(for: window) { [weak self, weak e] response in
            guard response == .OK, let self, let e, let url = panel.url else { return }
            self.compare(e, withFileAt: url)
        }
    }

    func compare(_ e: EditorView, withFileAt url: URL) {
        let doc = e.document
        loadComparisonText(at: url, encoding: nil) { [weak self, weak e] result in
            guard let self, let e, e.document === doc else { return }
            switch result {
            case .success(let text):
                self.show(e, comparedWith: text, label: "“\(url.lastPathComponent)”", source: .file(url))
            case .failure(let problem):
                self.statusBar.flash(MainWindowController.message(for: problem, name: url.lastPathComponent))
            }
        }
    }

    // MARK: Reading what's compared

    func loadComparisonText(at url: URL, encoding: TextEncoding?, completion: @escaping (Result<String, ComparisonReadProblem>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MainWindowController.comparisonText(at: url, encoding: encoding)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The text of a regular file of at most `maxComparedSize` bytes, decoded like a file being
    /// opened (preferring `encoding`) and with line endings normalized as in the editor.
    static func comparisonText(at url: URL, encoding: TextEncoding?) -> Result<String, ComparisonReadProblem> {
        do {
            let data = try LocalHistory.readRegularFile(url.resolvingSymlinksInPath(), limit: maxComparedSize)
            return comparisonText(from: data, encoding: encoding)
        } catch LocalHistory.ReadProblem.notAFile {
            return .failure(.notAFile)
        } catch LocalHistory.ReadProblem.tooLarge {
            return .failure(.tooLarge)
        } catch {
            return .failure(.unreadable)
        }
    }

    static func comparisonText(from data: Data, encoding: TextEncoding?) -> Result<String, ComparisonReadProblem> {
        let decoded = TextEncoding.decode(data, preferred: encoding)
        guard !decoded.isBinary else { return .failure(.binary) }
        return .success(LineEnding.normalize(decoded.text, rawData: nil).0)
    }

    static func message(for problem: ComparisonReadProblem, name: String) -> String {
        switch problem {
        case .notAFile: return "“\(name)” isn’t a regular file, so it can’t be compared"
        case .tooLarge: return "“\(name)” is too large to compare (over \(maxComparedSize / 1_000_000) MB)"
        case .binary: return "“\(name)” isn’t a text file, so it can’t be compared"
        case .unreadable: return "Couldn’t read “\(name)”"
        }
    }

    private func show(_ e: EditorView, comparedWith base: String, label: String, source: ComparisonSource, quiet: Bool = false) {
        e.compare(withBase: base, label: label, source: source) { [weak self] d in
            guard let self, !quiet else { return }
            if d.isEmpty {
                self.statusBar.flash("No changes compared with \(label). Edits show here as you type.")
            } else if case .snapshot = source {
                self.statusBar.flash("Comparing with \(label): +\(d.added) −\(d.deleted). File → Restore This Version brings it back; ⎋ stops.")
            } else {
                self.statusBar.flash("Comparing with \(label): +\(d.added) −\(d.deleted). Press ⎋ to stop.")
            }
        }
    }

    // MARK: Local History

    /// Lists the earlier versions Tovri kept of the active file; choosing one compares with it.
    @objc func showLocalHistory(_ sender: Any?) {
        guard let e = activeEditor, !e.document.isTransient, let url = e.document.url else {
            statusBar.flash("Save the file to start keeping its local history")
            return
        }
        LocalHistory.shared.snapshots(for: url) { [weak self, weak e] list in
            guard let self, let e, e.document.url == url else { return }
            guard !list.isEmpty else {
                self.statusBar.flash("No earlier versions of “\(url.lastPathComponent)” yet. Tovri keeps one each time you save over the file.")
                return
            }
            let theme = ThemeManager.shared.active
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            let now = Date()
            let items = list.map { s -> PaletteItem in
                let when = relative.localizedString(for: s.modified, relativeTo: now)
                var item = PaletteItem(title: when.prefix(1).uppercased() + when.dropFirst(),
                                       detail: MainWindowController.versionDate(s.modified)) { [weak self, weak e] in
                    guard let self, let e else { return }
                    self.compare(e, withSnapshot: s, of: url)
                }
                item.twoLine = true
                item.icon = "clock.arrow.circlepath"
                item.trailing = NSAttributedString(string: ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: theme.chromeSecondary])
                return item
            }
            self.palette.showList(placeholder: "Earlier versions of “\(url.lastPathComponent)”", items: items, label: "Local History",
                                  tip: "Choose a version to compare the file with it", tag: MainWindowController.localHistoryListTag)
        }
    }

    func compare(_ e: EditorView, withSnapshot s: LocalHistory.Snapshot, of url: URL) {
        let doc = e.document
        let encoding = doc.encoding
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak e] in
            let result = LocalHistory.shared.data(of: s, for: url).map { MainWindowController.comparisonText(from: $0, encoding: encoding) }
                ?? .failure(.unreadable)
            DispatchQueue.main.async { [weak self, weak e] in
                guard let self, let e, e.document === doc else { return }
                switch result {
                case .success(let text):
                    self.show(e, comparedWith: text, label: "the version from \(MainWindowController.versionDate(s.modified))", source: .snapshot(s))
                case .failure(.binary):
                    self.statusBar.flash("That version of “\(url.lastPathComponent)” isn’t text")
                case .failure:
                    self.statusBar.flash("That version of “\(url.lastPathComponent)” is no longer in Local History")
                }
            }
        }
    }

    /// "Today at 2:05 PM", "12 Mar 2025 at 9:41 AM".
    static func versionDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// Replaces the document's text with the version it's compared with, as one edit that Undo
    /// takes back. Nothing is saved.
    @objc func restoreComparedVersion(_ sender: Any?) {
        guard let e = activeEditor, case .snapshot = e.comparisonSource, let base = e.comparisonBase,
              let label = e.comparisonLabel, !e.document.isReadOnly else { NSSound.beep(); return }
        guard let edit = MainWindowController.restoreEdit(from: e.document.string, to: base as NSString) else {
            statusBar.flash("The text already matches \(label)")
            return
        }
        e.textView.performEdits([edit], actionName: "Restore Version")
        statusBar.flash("Restored \(label). It isn’t saved yet, and Undo brings back your text.")
    }

    /// One edit turning `current` into `target`, covering only the lines that differ so the
    /// unchanged text around it keeps its folds and position. Nil when they already match.
    static func restoreEdit(from current: NSString, to target: NSString) -> TextEdit? {
        let a = current, b = target
        let n = min(a.length, b.length)
        var p = 0
        while p < n && a.character(at: p) == b.character(at: p) { p += 1 }
        if p == a.length && p == b.length { return nil }
        // Cut at line starts, which can't fall inside a surrogate pair.
        while p > 0 && a.character(at: p - 1) != 10 { p -= 1 }
        var s = 0
        while s < n - p && a.character(at: a.length - 1 - s) == b.character(at: b.length - 1 - s) { s += 1 }
        while s > 0 && a.length - s - 1 >= 0 && a.character(at: a.length - s - 1) != 10 { s -= 1 }
        let replaced = NSRange(location: p, length: a.length - s - p)
        let text = b.substring(with: NSRange(location: p, length: b.length - s - p))
        return TextEdit(replaced, text)
    }

    @objc func clearLocalHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Local History?"
        alert.informativeText = "Tovri will delete the earlier versions it kept of all your files. The files themselves aren’t changed. This can’t be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if self.palette.listTag == MainWindowController.localHistoryListTag { self.palette.close(cancelled: true) }
            LocalHistory.shared.clear { [weak self] in self?.statusBar.flash("Local history cleared") }
        }
    }

    // MARK: Validation

    /// Enables the commands in this file; nil for any other item.
    func validateComparisonItem(_ item: NSMenuItem) -> Bool? {
        let e = activeEditor
        let doc = e?.document
        let comparable = doc.map { !$0.isTransient } ?? false
        switch item.action {
        case #selector(compareWithSaved(_:)):
            let on = e?.comparisonSource == .saved
            item.state = on ? .on : .off
            guard let doc, comparable, doc.url != nil, !doc.isNewFile else { return false }
            return on || doc.isDirty
        case #selector(compareWithClipboard(_:)):
            item.state = e?.comparisonSource == .clipboard ? .on : .off
            return comparable
        case #selector(compareWithFile(_:)):
            return comparable
        case #selector(showLocalHistory(_:)):
            return comparable && doc?.url != nil
        case #selector(restoreComparedVersion(_:)):
            guard case .snapshot = e?.comparisonSource else { return false }
            return doc?.isReadOnly == false
        case #selector(clearLocalHistory(_:)):
            return true
        default:
            return nil
        }
    }
}
