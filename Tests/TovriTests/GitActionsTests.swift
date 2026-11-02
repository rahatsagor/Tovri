import AppKit
import XCTest
@testable import Tovri

/// Stage, Unstage and Discard Changes in the Changes list, run against real temporary repositories.
final class GitActionsTests: XCTestCase {
    private var dir: URL!
    private var trashDir: URL!
    private var trashed: [URL] = []
    private var marker: URL { dir.appendingPathComponent("ran-filter") }
    private var savedEnvironment: [String: String] = [:]
    private let commit = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm"

    override func setUpWithError() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-actions-\(UUID().uuidString)").resolvingSymlinksInPath()
        dir = base.appendingPathComponent("repo")
        trashDir = base.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        savedEnvironment = GitRepository.userEnvironment
        // A home without a .gitconfig, so the person's own filters (Git LFS) don't change the results.
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        GitRepository.userEnvironment = ["HOME": home.path]
        XCTAssertEqual(try shell("git init -q . && git config user.email t@example.com && git config user.name t"), 0)
    }

    override func tearDown() {
        GitRepository.userEnvironment = savedEnvironment
        if let dir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    }

    @discardableResult
    private func shell(_ command: String, in folder: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = folder ?? dir
        p.environment = ["HOME": GitRepository.userEnvironment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func output(_ command: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.environment = ["HOME": GitRepository.userEnvironment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ text: String, _ name: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    private func repo() throws -> GitRepository { try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("x"))) }

    private func changes(_ repo: GitRepository) -> [GitRepository.ChangedFile] {
        var files: [GitRepository.ChangedFile] = []
        let done = expectation(description: "changes")
        repo.changeList { files = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return files
    }

    private func staged(_ repo: GitRepository) -> [String: GitFileStatus] {
        Dictionary(changes(repo).filter(\.staged).map { ($0.path, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    private func unstaged(_ repo: GitRepository) -> [String: GitFileStatus] {
        Dictionary(changes(repo).filter { !$0.staged }.map { ($0.path, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// Stands in for the Trash: moves the item into a folder the test can look in.
    private func trash(_ url: URL) throws {
        let dest = trashDir.appendingPathComponent("\(trashed.count) \(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        trashed.append(dest)
    }

    private let oddNames = ["with space.txt", "ünïcødé.txt", "-dash.txt", "[ab].txt", ":colon.txt", "dir/nested file.txt"]

    // MARK: - Parsing

    func testStatusColumnsSplitIntoStagedAndUnstagedChanges() {
        let raw = [" M wt.txt", "M  idx.txt", "MM both.txt", "R  new.txt", "old.txt", "RM moved.txt", "was.txt", "?? untracked.txt",
                   "!! ignored.txt", "UU conflict.txt", "AA added-both.txt", "DD deleted-both.txt", "AU added-us.txt",
                   "A  added.txt", "AM added-mod.txt", " D wt-deleted.txt", "D  idx-deleted.txt", " A intent.txt",
                   " R intent-new.txt", "intent-old.txt", "T  type.txt", "C  copy.txt", "orig.txt"]
        let entries = GitRepository.parseStatusEntries(Data((raw.joined(separator: "\0") + "\0").utf8))
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        XCTAssertEqual(entries.count, raw.count - 4, "an old path was read as an entry of its own")
        func check(_ path: String, staged: GitFileStatus?, unstaged: GitFileStatus?, status: GitFileStatus, from: String? = nil,
                   line: UInt = #line) {
            guard let e = byPath[path] else { return XCTFail("no entry for \(path)", line: line) }
            XCTAssertEqual(e.staged, staged, "staged \(path)", line: line)
            XCTAssertEqual(e.unstaged, unstaged, "unstaged \(path)", line: line)
            XCTAssertEqual(e.status, status, "status \(path)", line: line)
            XCTAssertEqual(e.originalPath, from, "original path of \(path)", line: line)
        }
        check("wt.txt", staged: nil, unstaged: .modified, status: .modified)
        check("idx.txt", staged: .modified, unstaged: nil, status: .modified)
        check("both.txt", staged: .modified, unstaged: .modified, status: .modified)
        check("new.txt", staged: .renamed, unstaged: nil, status: .renamed, from: "old.txt")
        check("moved.txt", staged: .renamed, unstaged: .modified, status: .renamed, from: "was.txt")
        check("untracked.txt", staged: nil, unstaged: .untracked, status: .untracked)
        check("ignored.txt", staged: nil, unstaged: nil, status: .ignored)
        for c in ["conflict.txt", "added-both.txt", "deleted-both.txt", "added-us.txt"] {
            check(c, staged: nil, unstaged: .conflicted, status: .conflicted)
        }
        check("added.txt", staged: .added, unstaged: nil, status: .added)
        check("added-mod.txt", staged: .added, unstaged: .modified, status: .added)
        check("wt-deleted.txt", staged: nil, unstaged: .deleted, status: .deleted)
        check("idx-deleted.txt", staged: .deleted, unstaged: nil, status: .deleted)
        check("intent.txt", staged: nil, unstaged: .added, status: .modified)
        check("intent-new.txt", staged: nil, unstaged: .renamed, status: .renamed, from: "intent-old.txt")
        check("type.txt", staged: .modified, unstaged: nil, status: .modified)
        check("copy.txt", staged: .added, unstaged: nil, status: .added, from: "orig.txt")
        // The sidebar's combined view is unchanged.
        XCTAssertEqual(GitRepository.parseStatus(Data("MM both.txt\0R  b\0a\0?? n\0".utf8)), ["both.txt": .modified, "b": .renamed, "n": .untracked])
    }

    func testTheListShowsAFileWithStagedAndUnstagedChangesInBothSections() throws {
        try write("one\ntwo\n", "a.txt")
        try shell("git add -A && \(commit) init")
        try write("one\nTWO\n", "a.txt")
        try shell("git add a.txt")
        try write("one\nTWO\nthree\nfour\n", "a.txt")
        try write("x\ny\n", "new.txt")
        let files = changes(try repo())
        let s = try XCTUnwrap(files.first { $0.path == "a.txt" && $0.staged })
        XCTAssertEqual(s.status, .modified)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
        let w = try XCTUnwrap(files.first { $0.path == "a.txt" && !$0.staged })
        XCTAssertEqual(w.added, 2, "the unstaged change was counted against HEAD, not the staged copy")
        XCTAssertEqual(w.removed, 0)
        let n = try XCTUnwrap(files.first { $0.path == "new.txt" })
        XCTAssertFalse(n.staged)
        XCTAssertEqual(n.status, .untracked)
        XCTAssertEqual(n.added, 2)
        XCTAssertEqual(files.count, 3)
    }

    // MARK: - Stage and unstage

    func testStagingAndUnstagingModifiedNewAndDeletedFilesWithAnyName() throws {
        let tracked = oddNames + ["a.txt", "b.txt", "gone.txt"]
        for name in tracked { try write("old \(name)\n", name) }
        try shell("git add -A && \(commit) init")
        for name in oddNames + ["a.txt", "b.txt"] { try write("new \(name)\n", name) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        let newNames = ["new file.txt", "-new.txt", "ñew/ünïcødé new.txt"]
        for name in newNames { try write("fresh\n", name) }
        let repo = try repo()

        // `[ab].txt` is a file name, not a pattern matching a.txt and b.txt.
        let bracket = try XCTUnwrap(changes(repo).first { $0.path == "[ab].txt" })
        XCTAssertEqual(repo.stage([bracket]).done, ["[ab].txt"])
        XCTAssertEqual(Set(staged(repo).keys), ["[ab].txt"])

        let all = changes(repo).filter { !$0.staged }
        let everything = Set(oddNames + ["a.txt", "b.txt", "gone.txt"] + newNames)
        XCTAssertEqual(Set(all.map(\.path)), everything.subtracting(["[ab].txt"]))
        let result = repo.stage(all)
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertTrue(result.refused.isEmpty)
        let s = staged(repo)
        XCTAssertEqual(Set(s.keys), everything)
        XCTAssertEqual(s["gone.txt"], .deleted)
        XCTAssertEqual(s["-new.txt"], .added)
        XCTAssertEqual(s["with space.txt"], .modified)
        XCTAssertTrue(unstaged(repo).isEmpty)

        let back = repo.unstage(changes(repo).filter(\.staged))
        XCTAssertTrue(back.failed.isEmpty, "\(back.failed)")
        XCTAssertTrue(staged(repo).isEmpty)
        let u = unstaged(repo)
        XCTAssertEqual(u["gone.txt"], .deleted)
        XCTAssertEqual(u["-new.txt"], .untracked)
        XCTAssertEqual(u["ünïcødé.txt"], .modified)
        // Unstaging never touches the files themselves.
        XCTAssertEqual(read("-dash.txt"), "new -dash.txt\n")
        XCTAssertEqual(read("ñew/ünïcødé new.txt"), "fresh\n")
        XCTAssertNil(read("gone.txt"))
    }

    func testARenameIsStagedAndUnstagedAsAWhole() throws {
        try write("same content\nmore\nlines\n", "old name.txt")
        try shell("git add -A && \(commit) init && git mv 'old name.txt' 'new name.txt'")
        let repo = try repo()
        let rename = try XCTUnwrap(changes(repo).first)
        XCTAssertTrue(rename.staged)
        XCTAssertEqual(rename.status, .renamed)
        XCTAssertEqual(rename.originalPath, "old name.txt")

        XCTAssertTrue(repo.unstage([rename]).failed.isEmpty)
        XCTAssertTrue(staged(repo).isEmpty, "unstaging the new path left the old path's deletion staged")
        XCTAssertEqual(unstaged(repo), ["old name.txt": .deleted, "new name.txt": .untracked])

        XCTAssertTrue(repo.stage(changes(repo)).failed.isEmpty)
        let again = changes(repo)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.status, .renamed)
        XCTAssertEqual(again.first?.originalPath, "old name.txt")
    }

    func testUnstagingWorksBeforeTheFirstCommit() throws {
        try write("a\n", "a.txt")
        try shell("git add a.txt")
        let repo = try repo()
        XCTAssertEqual(staged(repo), ["a.txt": .added])
        XCTAssertEqual(repo.unstage(changes(repo)).done, ["a.txt"])
        XCTAssertEqual(unstaged(repo), ["a.txt": .untracked])
    }

    // MARK: - Discard

    func testDiscardRestoresFilesAndKeepsWhatWasThereInTheTrash() throws {
        for name in oddNames + ["deleted.txt", "both.txt"] { try write("committed \(name)\n", name) }
        try shell("git add -A && \(commit) init")
        for name in oddNames { try write("edited \(name)\n", name) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("deleted.txt"))
        try write("staged\n", "both.txt")
        try shell("git add both.txt")
        try write("staged\nand more\n", "both.txt")
        let newNames = ["-new file.txt", "ñew.txt"]
        for name in newNames { try write("brand new \(name)\n", name) }
        let repo = try repo()

        let targets = changes(repo).filter { !$0.staged }
        XCTAssertEqual(targets.count, oddNames.count + 2 + newNames.count)
        let result = repo.discard(targets, trash: trash)
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertTrue(result.refused.isEmpty, "\(result.refused)")
        XCTAssertEqual(Set(result.done), Set(targets.map(\.path)))

        for name in oddNames { XCTAssertEqual(read(name), "committed \(name)\n", name) }
        XCTAssertEqual(read("deleted.txt"), "committed deleted.txt\n")
        XCTAssertEqual(read("both.txt"), "staged\n", "discarding went back past the staged copy")
        XCTAssertEqual(staged(repo), ["both.txt": .modified], "discarding touched what was staged")
        XCTAssertTrue(unstaged(repo).isEmpty)
        for name in newNames { XCTAssertNil(read(name), name) }

        // New files went to the Trash as they were; changed files left a copy there, in one folder.
        let names = trashed.map { $0.lastPathComponent }
        for name in newNames {
            let t = try XCTUnwrap(trashed.first { $0.lastPathComponent.hasSuffix(" " + name) }, name)
            XCTAssertEqual(try String(contentsOf: t, encoding: .utf8), "brand new \(name)\n")
        }
        let folder = try XCTUnwrap(trashed.first { $0.lastPathComponent.contains("Discarded changes in repo") }, "\(names)")
        for name in oddNames {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), "edited \(name)\n", name)
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("both.txt"), encoding: .utf8), "staged\nand more\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("deleted.txt").path))
        XCTAssertEqual(trashed.count, newNames.count + 1)
    }

    func testNothingIsDiscardedWhenTheTrashFails() throws {
        try write("committed\n", "a.txt")
        try shell("git add -A && \(commit) init")
        try write("precious edit\n", "a.txt")
        try write("precious new\n", "new.txt")
        let repo = try repo()
        struct NoTrash: Error {}
        let result = repo.discard(changes(repo)) { _ in throw NoTrash() }
        XCTAssertTrue(result.done.isEmpty)
        XCTAssertEqual(Set(result.refused.map(\.path)), ["a.txt", "new.txt"])
        XCTAssertTrue(result.refused.allSatisfy { $0.reason == .notBackedUp })
        XCTAssertEqual(read("a.txt"), "precious edit\n")
        XCTAssertEqual(read("new.txt"), "precious new\n")
    }

    func testConflictedFilesAreNotDiscarded() throws {
        try write("base\n", "c.txt")
        try shell("git add -A && \(commit) init && git checkout -q -b other && echo theirs > c.txt && \(commit) theirs -a && git checkout -q - && echo ours > c.txt && \(commit) ours -a")
        try shell("git -c core.hooksPath=/dev/null merge -q other")
        let repo = try repo()
        let c = try XCTUnwrap(changes(repo).first { $0.path == "c.txt" })
        try XCTSkipUnless(c.status == .conflicted, "the merge didn't conflict")
        let before = read("c.txt")
        let result = repo.discard([c], trash: trash)
        XCTAssertEqual(result.refused.first?.reason, .conflicted)
        XCTAssertEqual(read("c.txt"), before)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDiscardWritesOnlyInsideTheFolderEvenIfTheRepositoryPointsElsewhere() throws {
        try write("committed\n", "a.txt")
        try shell("git add -A && \(commit) init")
        let elsewhere = dir.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "someone else's file\n".write(to: elsewhere.appendingPathComponent("a.txt"), atomically: false, encoding: .utf8)
        try shell("git config core.worktree '\(elsewhere.path)'")
        try write("edited\n", "a.txt")
        let repo = try repo()
        let a = try XCTUnwrap(changes(repo).first { $0.path == "a.txt" })
        XCTAssertEqual(repo.discard([a], trash: trash).done, ["a.txt"])
        XCTAssertEqual(read("a.txt"), "committed\n")
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("a.txt"), encoding: .utf8), "someone else's file\n")
    }

    // MARK: - Filters

    /// A filter that records that it ran, then passes its input through.
    private func makeFilterScript() throws -> URL {
        let script = dir.deletingLastPathComponent().appendingPathComponent("filter.sh")
        try "#!/bin/sh\necho \"$*\" >> '\(marker.path)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testFilesWithAFilterAreRefusedAndTheFilterNeverRuns() throws {
        let script = try makeFilterScript()
        try write("*.bin filter=evil\n*.raw filter=undefined\n", ".gitattributes")
        try write("one\n", "a.bin")
        try write("one\n", "-dash.bin")
        try write("one\n", "plain.txt")
        try write("one\n", "b.raw")
        try shell("git add -A && \(commit) init")
        try shell("git config filter.evil.clean '\(script.path)' && git config filter.evil.smudge '\(script.path)' && git config filter.evil.required true")
        XCTAssertEqual(try shell("git hash-object a.bin"), 0)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "plain git no longer runs the filter, so this test proves nothing")
        try FileManager.default.removeItem(at: marker)

        for name in ["a.bin", "-dash.bin", "plain.txt", "b.raw"] { try write("two\n", name) }
        try write("new\n", "new.bin")
        let repo = try repo()
        XCTAssertEqual(try XCTUnwrap(repo.filteredPaths(["a.bin", "-dash.bin", "new.bin", "plain.txt", "b.raw"])), ["a.bin", "-dash.bin", "new.bin"])

        let result = repo.stage(changes(repo))
        XCTAssertEqual(Set(result.refused.map(\.path)), ["a.bin", "-dash.bin", "new.bin"])
        XCTAssertTrue(result.refused.allSatisfy { $0.reason == .filtered })
        // A filter attribute naming no configured driver changes nothing, so that file is staged.
        XCTAssertEqual(Set(result.done), ["plain.txt", "b.raw"])
        XCTAssertEqual(Set(staged(repo).keys), ["plain.txt", "b.raw"])

        let discard = repo.discard(changes(repo).filter { !$0.staged && $0.status != .untracked }, trash: trash)
        XCTAssertEqual(Set(discard.refused.map(\.path)), ["a.bin", "-dash.bin"])
        XCTAssertEqual(read("a.bin"), "two\n")
        XCTAssertEqual(read("-dash.bin"), "two\n")

        // Deleting a filtered file stores no content, so staging the deletion is fine.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.bin"))
        let deletion = try XCTUnwrap(changes(repo).first { $0.path == "a.bin" })
        XCTAssertEqual(repo.stage([deletion]).done, ["a.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a filter ran")
    }

    func testAFilterFromTheGlobalConfigIsRefusedToo() throws {
        let script = try makeFilterScript()
        try write("*.psd filter=lfs\n", ".gitattributes")
        try write("one\n", "art.psd")
        try shell("git add -A && \(commit) init")
        let home = try XCTUnwrap(GitRepository.userEnvironment["HOME"])
        try "[filter \"lfs\"]\n\tclean = \(script.path)\n\tsmudge = \(script.path)\n\trequired = true\n"
            .write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        try write("two\n", "art.psd")
        let repo = try repo()
        let art = try XCTUnwrap(changes(repo).first)
        XCTAssertEqual(repo.stage([art]).refused.map(\.reason), [.filtered])
        XCTAssertEqual(repo.discard([art], trash: trash).refused.map(\.reason), [.filtered])
        XCTAssertEqual(read("art.psd"), "two\n")
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the global filter ran")
    }

    // MARK: - The window

    private func spin(_ seconds: TimeInterval = 15, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testStagingFromTheListMovesTheFileAndDiscardingReloadsOnlyCleanDocuments() throws {
        let d = UserDefaults.standard
        d.set(true, forKey: Settings.Key.gitChangesAndHistory)
        defer {
            d.removeObject(forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        for name in ["a.txt", "clean.txt", "edited.txt"] { try write("committed\n", name) }
        try shell("git add -A && \(commit) init")
        for name in ["a.txt", "clean.txt", "edited.txt"] { try write("changed on disk\n", name) }
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
        let clean = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("clean.txt")))
        let edited = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("edited.txt")))
        controller.rootView.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(controller.activeEditor)
        editor.textView.performEdits([TextEdit(NSRange(location: 0, length: 0), "unsaved ")], actionName: "Type")
        XCTAssertTrue(edited.isDirty)

        controller.sidebar.showChanges(true)
        let list = try XCTUnwrap(controller.sidebar.subviews.compactMap { $0 as? ChangesView }.first)
        spin { list.files.count == 3 }
        let a = try XCTUnwrap(list.files.first { $0.path == "a.txt" })
        XCTAssertFalse(a.staged)

        controller.sidebar(controller.sidebar, changes: [a], action: .stage)
        spin { list.files.contains { $0.path == "a.txt" && $0.staged } }
        XCTAssertEqual(list.files.filter(\.staged).map(\.path), ["a.txt"])
        XCTAssertFalse(list.files.contains { $0.path == "a.txt" && !$0.staged })

        let repo = try repo()
        let result = repo.discard(list.files.filter { !$0.staged }, trash: trash)
        XCTAssertEqual(Set(result.done), ["clean.txt", "edited.txt"])
        controller.checkExternalChanges()
        XCTAssertEqual(clean.string as String, "committed\n", "a clean document didn't reload")
        XCTAssertEqual(edited.string as String, "unsaved changed on disk\n", "unsaved edits were thrown away")
        XCTAssertTrue(edited.isDirty)
    }

    // MARK: - Patch

    func testPatchShowsStagedUnstagedAndNewFiles() throws {
        try write("one\ntwo\n", "a.txt")
        try shell("git add -A && \(commit) init")
        try write("one\nTWO\n", "a.txt")
        try shell("git add a.txt")
        try write("one\nTWO\nthree\n", "a.txt")
        try write("hello\n", "-new.txt")
        let repo = try repo()
        let files = changes(repo)
        func patch(_ f: [GitRepository.ChangedFile]) -> String {
            var text = ""
            let done = expectation(description: "patch")
            repo.patch(for: f) { text = $0; done.fulfill() }
            wait(for: [done], timeout: 30)
            return text
        }
        let staged = patch(files.filter(\.staged))
        XCTAssertTrue(staged.contains("-two\n+TWO\n"), staged)
        XCTAssertFalse(staged.contains("+three"))
        let unstaged = patch(files.filter { !$0.staged && $0.path == "a.txt" })
        XCTAssertTrue(unstaged.contains("+three\n"), unstaged)
        XCTAssertFalse(unstaged.contains("-two"))
        let new = patch(files.filter { $0.path == "-new.txt" })
        XCTAssertTrue(new.contains("+++ b/-new.txt") && new.contains("+hello\n"), new)
    }
}
