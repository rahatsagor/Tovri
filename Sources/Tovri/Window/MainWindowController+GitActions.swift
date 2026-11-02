import AppKit

/// Stage, Unstage, Discard Changes and Open Changes as Patch from the sidebar's Changes list.
extension MainWindowController {
    func sidebar(_ sidebar: SidebarView, changes files: [GitRepository.ChangedFile], action: ChangeListAction) {
        guard !files.isEmpty, let folder = folderURL, let repo = GitRepository.find(for: folder) else { return }
        switch action {
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(files.map { repo.root.appendingPathComponent($0.path) })
        case .patch:
            showPatch(of: files, in: repo)
        case .stage:
            repo.perform({ $0.stage(files) }) { [weak self] in self?.finishGitAction($0, files: files, verb: "stage") }
        case .unstage:
            repo.perform({ $0.unstage(files) }) { [weak self] in self?.finishGitAction($0, files: files, verb: "unstage") }
        case .discard:
            confirmDiscard(files, root: repo.root) { [weak self] in
                repo.perform({ $0.discard(files) }) { self?.finishGitAction($0, files: files, verb: "discard") }
            }
        }
    }

    private static func name(_ path: String) -> String { "“\((path as NSString).lastPathComponent)”" }

    /// "“a.txt”, “b.txt” and 3 more"
    private static func list(_ paths: [String], limit: Int = 6) -> String {
        let names = paths.prefix(limit).map(name)
        let more = paths.count - names.count
        if more > 0 { return names.joined(separator: ", ") + " and \(more) more" }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private func confirmDiscard(_ files: [GitRepository.ChangedFile], root: URL, then discard: @escaping () -> Void) {
        let paths = files.map(\.path)
        let new = files.filter { $0.status == .untracked }
        let changed = files.filter { $0.status != .untracked && $0.status != .deleted }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = files.count == 1 ? "Discard changes to \(Self.name(paths[0]))?" : "Discard changes to \(files.count) files?"
        var info: [String] = []
        if files.count > 1 { info.append(Self.list(paths) + ".") }
        info.append(files.count == 1 ? "The changes will be lost, and Git can’t undo this." : "Their changes will be lost, and Git can’t undo this.")
        if !changed.isEmpty {
            info.append(changed.count == 1 && files.count == 1
                ? "Tovri first puts a copy of the file as it is now in the Trash, in a folder named “Discarded changes”."
                : "Tovri first puts a copy of each changed file as it is now in the Trash, in a folder named “Discarded changes”.")
        }
        if !new.isEmpty {
            info.append(new.count == 1 && files.count == 1 ? "This file is new, so it is moved to the Trash."
                                                           : "New files are moved to the Trash.")
        }
        let targets = Set(files.map { root.appendingPathComponent($0.path).standardizedFileURL.resolvingSymlinksInPath().path })
        let unsaved = allOpenDocuments().filter { d in
            d.isDirty && d.url.map { targets.contains($0.standardizedFileURL.resolvingSymlinksInPath().path) } == true
        }
        if !unsaved.isEmpty {
            info.append("Unsaved edits to \(Self.list(unsaved.map(\.displayName))) stay open in Tovri.")
        }
        alert.informativeText = info.joined(separator: " ")
        let discardButton = alert.addButton(withTitle: "Discard Changes")
        discardButton.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return must not destroy work, so it cancels.
        discardButton.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { discard() }
            return
        }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { discard() } }
    }

    private func finishGitAction(_ r: GitRepository.ActionResult, files: [GitRepository.ChangedFile], verb: String) {
        // Discarding rewrote files: clean documents reload, and ones with unsaved edits ask, as for
        // any change on disk. Then the list, sidebar colors, changed count and gutters catch up.
        checkExternalChanges()
        refreshGitStatus()
        if Settings.shared.gitGutter { allOpenDocuments().forEach { $0.refreshGitBaseline() } }

        var problems: [String] = []
        let filtered = r.refused.filter { $0.reason == .filtered }.map(\.path)
        if !filtered.isEmpty {
            let what = verb == "discard" ? "discard its changes" : verb
            problems.append(filtered.count == 1
                ? "\(Self.name(filtered[0])) uses a Git filter (like Git LFS), so \(what) in Terminal."
                : "\(Self.list(filtered)) use a Git filter (like Git LFS), so \(verb == "discard" ? "discard their changes" : verb + " them") in Terminal.")
        }
        let conflicted = r.refused.filter { $0.reason == .conflicted }.map(\.path)
        if !conflicted.isEmpty {
            problems.append("\(Self.list(conflicted)) \(conflicted.count == 1 ? "has" : "have") a merge conflict. Resolve it in the editor, then stage the file.")
        }
        let notBackedUp = r.refused.filter { $0.reason == .notBackedUp }.map(\.path)
        if !notBackedUp.isEmpty {
            problems.append("Tovri couldn’t put a copy of \(Self.list(notBackedUp)) in the Trash, so the changes were kept.")
        }
        if !r.failed.isEmpty {
            problems.append("Git couldn’t \(verb) \(Self.list(r.failed)). Try again, or check the repository in Terminal.")
        }

        let past = ["stage": "Staged", "unstage": "Unstaged", "discard": "Discarded changes to"][verb] ?? verb
        let done = Set(r.done)
        let doneCount = Set(files.map(\.path)).filter(done.contains).count
        guard !problems.isEmpty else {
            if doneCount > 0 { statusBar.flash(doneCount == 1 ? "\(past) \(Self.name(r.done[0]))" : "\(past) \(doneCount) files") }
            return
        }
        let alert = NSAlert()
        let notDone = Set(files.map(\.path)).count - doneCount
        let action = ["stage": "staged", "unstage": "unstaged", "discard": "discarded"][verb] ?? verb
        alert.messageText = files.count == 1 ? "\(Self.name(files[0].path)) wasn’t \(action)"
            : notDone == 1 ? "1 file wasn’t \(action)" : "\(notDone) files weren’t \(action)"
        alert.informativeText = problems.joined(separator: "\n\n") + (doneCount > 0 ? "\n\n\(past) \(doneCount == 1 ? "1 other file" : "\(doneCount) other files")." : "")
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Opens the files' changes as a read-only patch, as git would write it.
    private func showPatch(of files: [GitRepository.ChangedFile], in repo: GitRepository) {
        repo.patch(for: files) { [weak self] text in
            guard let self else { return }
            guard !text.isEmpty else { self.statusBar.flash("No changes to show"); return }
            let section = files.allSatisfy(\.staged) ? "Staged Changes" : "Changes"
            let name = files.count == 1 ? "\((files[0].path as NSString).lastPathComponent) — \(section)" : "\(files.count) Files — \(section)"
            for g in self.groups {
                if let i = g.tabs.firstIndex(where: { $0.document.isTransient && $0.document.url == nil
                    && $0.document.changesSource == nil && $0.document.displayName == name }) {
                    g.tabs[i].document.replaceAllContent(text)
                    self.activate(group: g)
                    g.select(i)
                    return
                }
            }
            let lang = LanguageRegistry.shared.language(id: "diff") ?? LanguageRegistry.shared.plain
            let doc = Document(text: text, name: name, language: lang)
            doc.isReadOnly = true
            doc.isTransient = true
            self.activeGroup.add(doc)
        }
    }
}
