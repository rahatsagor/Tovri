import AppKit

/// Opening a commit, or one of its files, from the sidebar's History tab. Everything opens in
/// read-only transient tabs; a single click reuses one preview tab so browsing doesn't fill the tab bar.
extension MainWindowController {
    /// New text over this many UTF-16 units, or old text over `maxHistoryOldText`, opens as a patch instead.
    static let maxHistoryNewText = 3_000_000
    static let maxHistoryOldText = 12_000_000

    func sidebar(_ sidebar: SidebarView, commit: LogCommit, detail: GitRepository.CommitDetail?, action: HistoryAction) {
        guard Settings.shared.gitChangesAndHistory, let repo = sidebar.repository else { return }
        switch action {
        case .openFile(let file, let view, let pinned):
            openCommitFile(file, in: commit, view: view, pinned: pinned, repo: repo)
        case .compareWithCurrent(let file):
            compareCommitFileWithCurrent(file, in: commit, repo: repo)
        case .openCommitPatch(let pinned):
            openCommitPatch(commit, detail: detail, pinned: pinned, repo: repo)
        }
    }

    // MARK: Tabs

    private func historyTab(withKey key: String) -> (EditorGroup, Int)? {
        for g in groups {
            if let i = g.tabs.firstIndex(where: { $0.document.revisionKey == key }) { return (g, i) }
        }
        return nil
    }

    private func previewTab() -> (EditorGroup, Int)? {
        for g in groups {
            if let i = g.tabs.firstIndex(where: { $0.document.isHistoryPreview }) { return (g, i) }
        }
        return nil
    }

    /// Selects the tab already showing `key`, turning a preview into a pinned tab when `pinned`.
    private func selectHistoryTab(withKey key: String, pinned: Bool) -> Bool {
        guard let (g, i) = historyTab(withKey: key) else { return false }
        let previous = window?.firstResponder
        if pinned { g.tabs[i].document.isHistoryPreview = false }
        activate(group: g)
        g.select(i, focus: pinned)
        if !pinned, let previous { window?.makeFirstResponder(previous) }
        return true
    }

    /// Shows `doc`: in the tab that already holds its revision, else in place of the preview tab, else
    /// in a new tab. A single click keeps the keyboard focus in the sidebar.
    @discardableResult
    func showHistoryDocument(_ doc: Document, pinned: Bool) -> EditorTab? {
        if let key = doc.revisionKey, selectHistoryTab(withKey: key, pinned: pinned) { return activeTab }
        doc.isHistoryPreview = !pinned
        let previous = window?.firstResponder
        let tab: EditorTab
        if !pinned, let (g, i) = previewTab() {
            activate(group: g)
            tab = g.add(doc, select: true, at: i)
            g.removeTab(at: i + 1)
        } else {
            activate(group: activeGroup)
            tab = activeGroup.add(doc)
        }
        if pinned {
            activeEditor?.focus()
        } else if let previous {
            window?.makeFirstResponder(previous)
        }
        return tab
    }

    private func makeHistoryDocument(_ text: String, name: String, key: String, language: Language) -> Document {
        let doc = Document(text: text, name: name, language: language)
        doc.isReadOnly = true
        doc.isTransient = true
        doc.revisionKey = key
        return doc
    }

    private var diffLanguage: Language { LanguageRegistry.shared.language(id: "diff") ?? LanguageRegistry.shared.plain }

    /// A newer click on a preview replaces an older one that is still loading.
    private func beginHistoryOpen(pinned: Bool) -> Int {
        if !pinned { historyOpenGeneration += 1 }
        return historyOpenGeneration
    }

    private func isCurrentHistoryOpen(_ token: Int, pinned: Bool) -> Bool {
        Settings.shared.gitChangesAndHistory && (pinned || token == historyOpenGeneration)
    }

    // MARK: Files

    private func openCommitFile(_ file: GitRepository.CommitFile, in commit: LogCommit, view: CommitFileView, pinned: Bool, repo: GitRepository) {
        let name = (file.path as NSString).lastPathComponent
        let suffix: String
        switch view {
        case .changes: suffix = "changes"
        case .patch: suffix = "patch"
        case .file: suffix = "file"
        }
        let key = "\(commit.sha):\(file.path):\(suffix)"
        if selectHistoryTab(withKey: key, pinned: pinned) { return }
        let token = beginHistoryOpen(pinned: pinned)
        switch view {
        case .changes:
            openChanges(file, in: commit, key: key, name: name, pinned: pinned, token: token, repo: repo)
        case .patch:
            openFilePatch(file, in: commit, pinned: pinned, token: token, repo: repo)
        case .file:
            openFileBlob(file, in: commit, key: key, name: name, pinned: pinned, token: token, repo: repo)
        }
    }

    private static func decodeBlob(_ data: Data) -> (text: String, isBinary: Bool) {
        let decoded = TextEncoding.decode(data, preferred: nil, preferUTF8IfValid: true)
        return (LineEnding.normalize(decoded.text, rawData: nil).0, decoded.isBinary)
    }

    private func openChanges(_ file: GitRepository.CommitFile, in commit: LogCommit, key: String, name: String,
                             pinned: Bool, token: Int, repo: GitRepository) {
        let parent = commit.parents.first
        let needsNew = file.status != .deleted
        let needsOld = file.status != .added && parent != nil
        var newData: Data? = Data()
        var oldData: Data? = Data()
        let group = DispatchGroup()
        if needsNew {
            group.enter()
            repo.contents(of: file.path, at: commit.sha) { newData = $0; group.leave() }
        }
        if needsOld, let parent {
            group.enter()
            repo.contents(of: file.originalPath ?? file.path, at: parent) { oldData = $0; group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
            guard let newData, let oldData else {
                self.openFilePatch(file, in: commit, pinned: pinned, token: token, repo: repo,
                                   notice: "“\(name)” can’t be compared inline, so it opens as a patch")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let new = MainWindowController.decodeBlob(newData)
                let old = MainWindowController.decodeBlob(oldData)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
                    if new.isBinary || old.isBinary {
                        self.statusBar.flash("“\(name)” isn’t a text file")
                        return
                    }
                    if new.text.utf16.count > MainWindowController.maxHistoryNewText || old.text.utf16.count > MainWindowController.maxHistoryOldText {
                        self.openFilePatch(file, in: commit, pinned: pinned, token: token, repo: repo,
                                           notice: "Too large to compare inline; showing the patch")
                        return
                    }
                    let title = "\(name) @ \(commit.shortSHA)" + (file.status == .deleted ? " (deleted)" : "")
                    let language = LanguageRegistry.shared.language(forFileName: name, firstLine: new.text.split(separator: "\n", maxSplits: 1).first.map(String.init))
                    let doc = self.makeHistoryDocument(new.text, name: title, key: key, language: language)
                    guard let tab = self.showHistoryDocument(doc, pinned: pinned), tab.document === doc,
                          let editor = tab.editor else { return }
                    let label = parent.map { String($0.prefix(7)) } ?? "an empty file"
                    editor.compare(withBase: old.text, label: label, source: .commit) { [weak self] d in
                        let subject = commit.subject.isEmpty ? "" : " “\(commit.subject)”"
                        self?.statusBar.flash("\(commit.shortSHA)\(subject): +\(d.added) −\(d.deleted) in \(name)")
                    }
                }
            }
        }
    }

    private func openFilePatch(_ file: GitRepository.CommitFile, in commit: LogCommit, pinned: Bool, token: Int, repo: GitRepository,
                               notice: String? = nil) {
        let name = (file.path as NSString).lastPathComponent
        let key = "\(commit.sha):\(file.path):patch"
        if selectHistoryTab(withKey: key, pinned: pinned) { return }
        let paths = [file.originalPath, file.path].compactMap { $0 }
        repo.commitPatch(sha: commit.sha, parent: commit.parents.first, paths: paths) { [weak self] text in
            guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
            guard let text else {
                self.statusBar.flash("The patch for “\(name)” is too large to show (over \(GitRepository.maxBlobSize / 1_000_000) MB)")
                return
            }
            let doc = self.makeHistoryDocument(text, name: "\(name) @ \(commit.shortSHA) — Patch", key: key, language: self.diffLanguage)
            self.showHistoryDocument(doc, pinned: pinned)
            if let notice { self.statusBar.flash(notice) }
        }
    }

    private func openFileBlob(_ file: GitRepository.CommitFile, in commit: LogCommit, key: String, name: String,
                              pinned: Bool, token: Int, repo: GitRepository) {
        repo.contents(of: file.path, at: commit.sha) { [weak self] data in
            guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
            guard let data else {
                self.statusBar.flash("Couldn’t read “\(name)” at \(commit.shortSHA)")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let blob = MainWindowController.decodeBlob(data)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
                    if blob.isBinary {
                        self.statusBar.flash("“\(name)” isn’t a text file")
                        return
                    }
                    let language = LanguageRegistry.shared.language(forFileName: name, firstLine: blob.text.split(separator: "\n", maxSplits: 1).first.map(String.init))
                    let doc = self.makeHistoryDocument(blob.text, name: "\(name) @ \(commit.shortSHA)", key: key, language: language)
                    self.showHistoryDocument(doc, pinned: pinned)
                }
            }
        }
    }

    private func compareCommitFileWithCurrent(_ file: GitRepository.CommitFile, in commit: LogCommit, repo: GitRepository) {
        let url = repo.root.appendingPathComponent(file.path)
        guard let doc = open(url: url), let editor = activeEditor, editor.document === doc else { return }
        let c = GitRepository.Commit(sha: commit.sha, shortSHA: commit.shortSHA, author: commit.author, date: commit.date,
                                     subject: commit.subject, path: file.path)
        compare(editor, with: c, in: repo)
    }

    // MARK: Commits

    private func openCommitPatch(_ commit: LogCommit, detail: GitRepository.CommitDetail?, pinned: Bool, repo: GitRepository) {
        let key = "\(commit.sha)::patch"
        if selectHistoryTab(withKey: key, pinned: pinned) { return }
        let token = beginHistoryOpen(pinned: pinned)
        guard let detail else {
            repo.commitDetail(sha: commit.sha, parents: commit.parents) { [weak self] loaded in
                guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
                guard let loaded else { self.statusBar.flash("Couldn’t read commit \(commit.shortSHA)"); return }
                self.loadCommitPatch(commit, detail: loaded, key: key, pinned: pinned, token: token, repo: repo)
            }
            return
        }
        loadCommitPatch(commit, detail: detail, key: key, pinned: pinned, token: token, repo: repo)
    }

    private func loadCommitPatch(_ commit: LogCommit, detail: GitRepository.CommitDetail, key: String, pinned: Bool, token: Int,
                                 repo: GitRepository) {
        repo.commitPatch(sha: commit.sha, parent: commit.parents.first, paths: nil) { [weak self] patch in
            guard let self, self.isCurrentHistoryOpen(token, pinned: pinned) else { return }
            guard let patch else {
                self.statusBar.flash("The patch for commit \(commit.shortSHA) is too large to show (over \(GitRepository.maxBlobSize / 1_000_000) MB)")
                return
            }
            let subject = commit.subject.count > 40 ? String(commit.subject.prefix(39)) + "…" : commit.subject
            let name = subject.isEmpty ? "\(commit.shortSHA) — Patch" : "\(commit.shortSHA) — \(subject)"
            let doc = self.makeHistoryDocument(MainWindowController.commitPatchHeader(detail) + patch, name: name, key: key,
                                               language: self.diffLanguage)
            self.showHistoryDocument(doc, pinned: pinned)
        }
    }

    /// The top of `git show`: the commit, its parents when it is a merge, the author, date and message.
    static func commitPatchHeader(_ detail: GitRepository.CommitDetail) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        var out = "commit \(detail.sha)\n"
        if detail.parents.count > 1 { out += "Merge: " + detail.parents.map { String($0.prefix(7)) }.joined(separator: " ") + "\n" }
        out += "Author: \(detail.authorName) <\(detail.authorEmail)>\n"
        out += "Date:   \(formatter.string(from: detail.authorDate))\n\n"
        for line in detail.message.split(separator: "\n", omittingEmptySubsequences: false) {
            out += line.isEmpty ? "\n" : "    \(line)\n"
        }
        return out + "\n"
    }
}
