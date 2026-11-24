import AppKit

/// Switching branches from the status bar or Go → Switch Branch…. The switch itself, and the checks
/// that nothing would be lost, are in `GitRepository.switchBranch`.
extension MainWindowController {
    static let branchesListTag = "branches"

    @objc func showBranches(_ sender: Any?) {
        guard Settings.shared.gitChangesAndHistory else {
            statusBar.flash("Turn on Git tab, file history and branches in Settings → Git")
            return
        }
        guard let base = activeDocument?.url ?? folderURL, let repo = GitRepository.find(for: base) else {
            statusBar.flash("Not in a Git repository")
            return
        }
        guard !isSwitchingBranch else { statusBar.flash("Still switching branches…"); return }
        repo.branches { [weak self] list in
            guard let self, Settings.shared.gitChangesAndHistory else { return }
            guard let list else { self.statusBar.flash("Couldn’t read the branches"); return }
            self.presentBranches(list, in: repo)
        }
    }

    private func presentBranches(_ list: [GitRepository.Branch], in repo: GitRepository) {
        let theme = ThemeManager.shared.active
        func trailing(_ b: GitRepository.Branch) -> NSAttributedString {
            NSAttributedString(string: b.shortSHA, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: theme.chromeSecondary])
        }
        func when(_ b: GitRepository.Branch) -> String { b.date.map(HistoryView.relativeDate) ?? "" }
        func detail(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }

        var items = [PaletteItem(title: "New Branch…", detail: "Create a branch at the current commit and switch to it", icon: "plus") { [weak self] in
            self?.promptForNewBranch(in: repo)
        }]
        let locals = list.filter { !$0.isRemote }
        let localNames = Set(locals.map(\.name))
        for b in locals {
            var item = PaletteItem(title: b.name, detail: b.isCurrent ? detail(["Current branch", b.subject]) : detail([when(b), b.subject]),
                                   icon: b.isCurrent ? "checkmark" : "arrow.triangle.branch") { [weak self] in
                if b.isCurrent { self?.statusBar.flash("Already on “\(b.name)”") } else { self?.switchBranch(.local(b.name), label: b.name, in: repo) }
            }
            item.trailing = trailing(b)
            items.append(item)
        }
        for b in list where b.isRemote && !localNames.contains(b.localName) {
            var item = PaletteItem(title: b.name, detail: detail(["Remote", when(b), b.subject]), icon: "cloud") { [weak self] in
                self?.switchBranch(.remote(b.name), label: b.name, in: repo)
            }
            item.trailing = trailing(b)
            items.append(item)
        }
        palette.showList(placeholder: "Switch to branch", items: items, label: "Branches",
                         tip: "Uncommitted changes come with you unless the branch changes the same files",
                         tag: MainWindowController.branchesListTag)
    }

    private func promptForNewBranch(in repo: GitRepository) {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Creates a branch at the current commit and switches to it. Your files don’t change."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let create = { [weak self] in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self?.switchBranch(.create(name), label: name, in: repo)
        }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { create() }
            return
        }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { create() } }
    }

    /// Switches in the background, with the open documents' unsaved paths so the checks can refuse.
    func switchBranch(_ target: GitRepository.BranchTarget, label: String, in repo: GitRepository) {
        guard !isSwitchingBranch else { statusBar.flash("Still switching branches…"); return }
        isSwitchingBranch = true
        statusBar.message = "Switching to “\(label)”…"
        let unsaved = Set(allOpenDocuments().filter(\.isDirty).compactMap { $0.url.flatMap(repo.relativePath) })
        repo.performSwitch(to: target, unsavedPaths: unsaved) { [weak self] outcome in
            guard let self else { return }
            self.isSwitchingBranch = false
            self.statusBar.message = nil
            self.finishSwitch(outcome, label: label)
        }
    }

    private func finishSwitch(_ outcome: GitRepository.SwitchOutcome, label: String) {
        switch outcome {
        case .switched(let name):
            branchDidChange()
            statusBar.flash("Switched to “\(name)”")
        case .created(let name):
            branchDidChange()
            statusBar.flash("Created “\(name)” and switched to it")
        case .refused(.alreadyOn):
            statusBar.flash("Already on “\(label)”")
        case .refused(let refusal):
            showBranchAlert("Can’t switch to “\(label)”", MainWindowController.refusalText(refusal, label: label))
        case .failed(let text):
            let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            let shown = lines.prefix(12).joined(separator: "\n")
            showBranchAlert("Git couldn’t switch to “\(label)”", shown.isEmpty ? "Git stopped with an error." : shown)
        }
    }

    /// The files are different now: bring open documents, the status, History and gutters up to date.
    private func branchDidChange() {
        checkExternalChanges()
        refreshGitStatus()
        if Settings.shared.gitGutter { allOpenDocuments().forEach { $0.refreshGitBaseline() } }
        updateStatusBar()
    }

    private func showBranchAlert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func pathList(_ paths: [String], limit: Int = 8) -> String {
        var lines = Array(paths.prefix(limit))
        if paths.count > limit { lines.append("and \(paths.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    static func refusalText(_ refusal: GitRepository.SwitchRefusal, label: String) -> String {
        switch refusal {
        case .unsaved(let p):
            return "These files have unsaved changes and are different on “\(label)”:\n\n\(pathList(p))\n\nSave and commit them, or revert them, first."
        case .uncommitted(let p):
            return "These files have changes that aren’t committed, and they’re different on “\(label)”:\n\n\(pathList(p))\n\nCommit or discard those changes first, or stash them in Terminal."
        case .untracked(let p):
            return "Switching would replace these files, which Git doesn’t track or ignores:\n\n\(pathList(p))\n\nMove or delete them first."
        case .filtered(let p):
            return "These files use Git LFS or another filter that Tovri doesn’t run:\n\n\(pathList(p))\n\nSwitch branches in Terminal instead."
        case .invalidName:
            return "“\(label)” isn’t a valid branch name."
        case .alreadyExists:
            return "A branch named “\(label)” already exists."
        case .alreadyOn:
            return "Already on “\(label)”."
        }
    }
}
