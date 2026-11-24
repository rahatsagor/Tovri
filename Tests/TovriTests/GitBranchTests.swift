import AppKit
import XCTest
@testable import Tovri

/// Switching branches: listing them, the checks that refuse a switch that would lose work, and the
/// window's status bar item, picker and alerts. Run against real temporary repositories.
final class GitBranchTests: XCTestCase {
    private var base: URL!
    private var dir: URL!
    private var savedEnvironment: [String: String] = [:]
    private var marker: URL { base.appendingPathComponent("ran-program") }
    private let commit = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -q"

    override func setUpWithError() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-branches-\(UUID().uuidString)").resolvingSymlinksInPath()
        dir = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedEnvironment = GitRepository.userEnvironment
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        GitRepository.userEnvironment = ["HOME": home.path]
        // main has a.txt, shared.txt and an ignored .env.local; feature changes a.txt, adds new.txt and
        // tracks .env.local.
        XCTAssertEqual(try shell("""
        git init -q -b main . && git config user.email t@example.com && git config user.name t
        echo main > a.txt && echo same > shared.txt && printf '.env.local\\n' > .gitignore
        git add -A && \(commit) -m base
        git switch -q -c feature
        echo feature > a.txt && echo new > new.txt && echo tracked > .env.local
        git add -A && git add -f .env.local && \(commit) -m 'feature work'
        git switch -q main
        """), 0)
    }

    override func tearDown() {
        AppRuntime.defaults.removeObject(forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        GitRepository.userEnvironment = savedEnvironment
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - Helpers

    @discardableResult
    private func shell(_ command: String, in folder: URL? = nil) throws -> Int32 {
        try run(command, in: folder).status
    }

    private func run(_ command: String, in folder: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = folder ?? dir
        p.environment = ["HOME": GitRepository.userEnvironment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func write(_ text: String, _ name: String, in folder: URL? = nil) throws {
        let url = (folder ?? dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func read(_ name: String, in folder: URL? = nil) -> String? {
        try? String(contentsOf: (folder ?? dir).appendingPathComponent(name), encoding: .utf8)
    }

    private func repo(_ folder: URL? = nil) throws -> GitRepository {
        try XCTUnwrap(GitRepository.find(for: (folder ?? dir).appendingPathComponent("x")))
    }

    /// HEAD, the index and the work tree, so a refusal can be shown to have changed nothing.
    private func snapshot() throws -> String {
        try run("cat .git/HEAD; git ls-files -s; git status --porcelain=v1 -uall --ignored; cat a.txt shared.txt .env.local 2>/dev/null").output
    }

    private func assertRefused(_ expected: GitRepository.SwitchRefusal, to target: GitRepository.BranchTarget = .local("feature"),
                               unsaved: Set<String> = [], line: UInt = #line) throws {
        let before = try snapshot()
        XCTAssertEqual(try repo().switchBranch(to: target, unsavedPaths: unsaved), .refused(expected), line: line)
        XCTAssertEqual(try snapshot(), before, "a refusal must change nothing", line: line)
    }

    private func spin(_ seconds: TimeInterval = 20, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func makeEvilScript() throws -> URL {
        let script = base.appendingPathComponent("evil.sh")
        try "#!/bin/sh\necho \"$*\" >> '\(marker.path)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // MARK: - Listing

    func testParseBranchesReadsLocalRemoteCurrentAndUpstream() {
        let lines = [
            "refs/heads/main\0main\0*\01700000100\0abc1234\0origin/main\0Fix: a\u{1f}b",
            "refs/heads/feat/x\0feat/x\0 \01700000000\0def5678\0\0Subject two",
            "refs/remotes/origin/HEAD\0origin\0 \01700000100\0abc1234\0\0Fix",
            "refs/remotes/origin/topic\0origin/topic\0 \01600000000\0aaa1111\0\0On the remote",
        ].joined(separator: "\n") + "\n"
        let list = GitRepository.parseBranches(Data(lines.utf8))
        XCTAssertEqual(list.map(\.name), ["main", "feat/x", "origin/topic"])
        XCTAssertEqual(list[0], GitRepository.Branch(refName: "refs/heads/main", name: "main", isRemote: false, isCurrent: true,
                                                    date: Date(timeIntervalSince1970: 1_700_000_100), shortSHA: "abc1234",
                                                    upstream: "origin/main", subject: "Fix: a\u{1f}b"))
        XCTAssertFalse(list[1].isCurrent)
        XCTAssertNil(list[1].upstream)
        XCTAssertTrue(list[2].isRemote)
        XCTAssertEqual(list[2].localName, "topic")
        XCTAssertEqual(list[1].localName, "feat/x")
    }

    func testBranchesListsLocalAndRemoteTrackingBranchesOfAClone() throws {
        let clone = base.appendingPathComponent("clone")
        try shell("git clone -q '\(dir.path)' clone", in: base)
        var list: [GitRepository.Branch]?
        let done = expectation(description: "branches")
        try repo(clone).branches { list = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let branches = try XCTUnwrap(list)
        XCTAssertEqual(Set(branches.map(\.name)), ["main", "origin/main", "origin/feature"], "origin/HEAD is not a branch")
        XCTAssertEqual(branches.filter(\.isCurrent).map(\.name), ["main"])
        XCTAssertEqual(branches.first { $0.name == "main" }?.upstream, "origin/main")
        XCTAssertEqual(branches.first { $0.name == "origin/feature" }?.subject, "feature work")
    }

    // MARK: - Switching

    func testSwitchingChangesTheFilesAndMovesHead() throws {
        XCTAssertEqual(try repo().switchBranch(to: .local("feature"), unsavedPaths: []), .switched("feature"))
        XCTAssertEqual(read("a.txt"), "feature\n")
        XCTAssertEqual(read("new.txt"), "new\n")
        XCTAssertEqual(try repo().currentBranchName, "feature")
        XCTAssertEqual(try repo().switchBranch(to: .local("feature"), unsavedPaths: []), .refused(.alreadyOn))
        XCTAssertEqual(try repo().switchBranch(to: .local("main"), unsavedPaths: []), .switched("main"))
        XCTAssertEqual(read("a.txt"), "main\n")
        XCTAssertNil(read("new.txt"))
    }

    func testAChangeToAFileThatIsTheSameOnBothBranchesComesAlong() throws {
        try write("edited\n", "shared.txt")
        XCTAssertEqual(try repo().switchBranch(to: .local("feature"), unsavedPaths: ["unrelated.txt"]), .switched("feature"))
        XCTAssertEqual(read("shared.txt"), "edited\n")
        XCTAssertEqual(read("a.txt"), "feature\n")
    }

    func testRefusesUncommittedChangesToADifferingFile() throws {
        try write("dirty\n", "a.txt")
        try assertRefused(.uncommitted(["a.txt"]))
        XCTAssertEqual(read("a.txt"), "dirty\n")
    }

    func testRefusesStagedChangesToADifferingFile() throws {
        try write("staged\n", "a.txt")
        try shell("git add a.txt")
        try assertRefused(.uncommitted(["a.txt"]))
    }

    func testRefusesAnUntrackedFileAtAPathTheTargetAdds() throws {
        try write("mine\n", "new.txt")
        try assertRefused(.untracked(["new.txt"]))
        XCTAssertEqual(read("new.txt"), "mine\n")
    }

    func testRefusesAnIgnoredFileAtAPathTheTargetTracks() throws {
        try write("my secret\n", ".env.local")
        XCTAssertEqual(try run("git status --porcelain --ignored").output.contains("!! .env.local"), true)
        try assertRefused(.untracked([".env.local"]))
        XCTAssertEqual(read(".env.local"), "my secret\n")
    }

    func testRefusesAnUnsavedPath() throws {
        try assertRefused(.unsaved(["a.txt"]), unsaved: ["a.txt", "other.txt"])
    }

    func testRefusesAFileThatUsesAConfiguredFilterWithoutRunningIt() throws {
        let evil = try makeEvilScript()
        try write("*.bin filter=fake\n", ".gitattributes")
        try write("one\n", "x.bin")
        try shell("git add -A && \(commit) -m bin && git switch -q -c other && echo two > x.bin && git add -A && \(commit) -m 'bin two' && git switch -q main")
        try shell("git config filter.fake.clean '\(evil.path)' && git config filter.fake.smudge '\(evil.path)'")
        let before = try? String(contentsOf: dir.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(try repo().switchBranch(to: .local("other"), unsavedPaths: []), .refused(.filtered(["x.bin"])))
        XCTAssertEqual(read("x.bin"), "one\n")
        XCTAssertEqual(try? String(contentsOf: dir.appendingPathComponent(".git/HEAD")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the filter ran")
    }

    func testRefusesAGitattributesFileOnlyTheTargetHas() throws {
        let evil = try makeEvilScript()
        try shell("git switch -q -c attrs && echo '*.dat filter=fake' > .gitattributes && git add -A && \(commit) -m attrs && git switch -q main")
        try shell("git config filter.fake.clean '\(evil.path)' && git config filter.fake.smudge '\(evil.path)'")
        XCTAssertEqual(try repo().switchBranch(to: .local("attrs"), unsavedPaths: []), .refused(.filtered([".gitattributes"])))
        XCTAssertNil(read(".gitattributes"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAMergeInProgressMakesGitRefuseAndTheFailureCarriesItsMessage() throws {
        try shell("echo main2 > a.txt && git add -A && \(commit) -m main2 && git branch same")
        try shell("git merge feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/MERGE_HEAD").path))
        guard case .failed(let text) = try repo().switchBranch(to: .local("same"), unsavedPaths: []) else { return XCTFail("expected a failure") }
        XCTAssertTrue(text.contains("cannot switch branch while merging"), text)
    }

    func testARemoteBranchCreatesATrackingLocalBranch() throws {
        let clone = base.appendingPathComponent("clone")
        try shell("git clone -q '\(dir.path)' clone", in: base)
        let repo = try repo(clone)
        XCTAssertEqual(repo.switchBranch(to: .remote("origin/feature"), unsavedPaths: []), .switched("feature"))
        XCTAssertEqual(repo.currentBranchName, "feature")
        XCTAssertEqual(read("a.txt", in: clone), "feature\n")
        XCTAssertEqual(try run("git rev-parse --abbrev-ref feature@{upstream}", in: clone).output, "origin/feature\n")
        XCTAssertEqual(repo.switchBranch(to: .remote("origin/feature"), unsavedPaths: []), .refused(.alreadyExists))
    }

    func testCreatingABranchKeepsTheFilesAndMovesHead() throws {
        try write("dirty\n", "a.txt")
        XCTAssertEqual(try repo().switchBranch(to: .create("feat/new"), unsavedPaths: ["a.txt"]), .created("feat/new"))
        XCTAssertEqual(try repo().currentBranchName, "feat/new")
        XCTAssertEqual(read("a.txt"), "dirty\n")
        XCTAssertEqual(try run("git rev-parse HEAD main").output.split(separator: "\n").count, 2)
    }

    func testCreatingRejectsBadAndExistingNames() throws {
        let repo = try repo()
        for bad in ["bad..name", "-x", "", "--detach", "with space", "ends.lock"] {
            XCTAssertEqual(repo.switchBranch(to: .create(bad), unsavedPaths: []), .refused(.invalidName), bad.debugDescription)
        }
        XCTAssertEqual(repo.switchBranch(to: .create("feature"), unsavedPaths: []), .refused(.alreadyExists))
        XCTAssertEqual(repo.currentBranchName, "main")
        XCTAssertEqual(repo.switchBranch(to: .local("-x"), unsavedPaths: []), .refused(.invalidName))
    }

    func testCreatingWorksBeforeTheFirstCommit() throws {
        let empty = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try shell("git init -q -b main .", in: empty)
        let repo = try repo(empty)
        XCTAssertTrue(repo.isUnborn)
        XCTAssertEqual(repo.switchBranch(to: .create("first"), unsavedPaths: []), .created("first"))
        XCTAssertEqual(repo.currentBranchName, "first")
    }

    func testAPostCheckoutHookNamedByTheRepositoryNeverRuns() throws {
        let evil = try makeEvilScript()
        let hooks = base.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: evil, to: hooks.appendingPathComponent("post-checkout"))
        try shell("git config core.hooksPath '\(hooks.path)'")
        try shell("git switch -q feature && git switch -q main")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "plain git no longer runs the hook, so this test proves nothing")
        try FileManager.default.removeItem(at: marker)
        XCTAssertEqual(try repo().switchBranch(to: .local("feature"), unsavedPaths: []), .switched("feature"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the hook ran")
    }

    func testPerformSwitchCompletesOnTheMainQueue() throws {
        var outcome: GitRepository.SwitchOutcome?
        try repo().performSwitch(to: .local("feature"), unsavedPaths: []) { outcome = $0; XCTAssertTrue(Thread.isMainThread) }
        spin { outcome != nil }
        XCTAssertEqual(outcome, .switched("feature"))
    }

    // MARK: - Standard error

    func testStandardErrorIsCapturedCappedAndDrained() {
        let errors = GitErrorCapture()
        let start = Date()
        let out = GitRepository.runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo oops >&2; head -c 300000 /dev/zero | tr '\\0' x >&2; echo hi"],
                                           environment: [:], standardError: errors)
        XCTAssertEqual(out, Data("hi\n".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(errors.text.utf8.count, GitErrorCapture.limit)
        XCTAssertTrue(errors.text.hasPrefix("oops\n"))
        let quiet = GitErrorCapture()
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo bad >&2; exit 3"], environment: [:], standardError: quiet))
        XCTAssertEqual(quiet.text, "bad\n")
    }

    // MARK: - The window

    private func withWindow(open file: String? = "a.txt", _ body: (MainWindowController) throws -> Void) throws {
        AppRuntime.defaults.set(true, forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        _ = NSApplication.shared
        let c = MainWindowController()
        defer {
            c.teardown()
            c.window?.delegate = nil
            c.window?.close()
        }
        c.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
        if let file { _ = c.open(url: dir.appendingPathComponent(file)) }
        c.rootView.layoutSubtreeIfNeeded()
        try body(c)
    }

    private func texts(in view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    private func branchElement(_ c: MainWindowController) -> DrawnAccessibilityElement? {
        (c.statusBar.accessibilityChildren() as? [DrawnAccessibilityElement])?.first { $0.accessibilityLabel()?.hasPrefix("Git branch") == true }
    }

    func testTheBranchIsAButtonOnlyWhileTheSettingIsOn() throws {
        try withWindow { c in
            XCTAssertEqual(c.statusBar.values[.branch], "main")
            XCTAssertTrue(c.statusBar.branchIsClickable)
            XCTAssertEqual(branchElement(c)?.accessibilityRole(), .button)
            XCTAssertTrue(branchElement(c)?.accessibilityPerformPress() == true)
            XCTAssertTrue(c.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.showBranches(_:)), keyEquivalent: "")))

            AppRuntime.defaults.set(false, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            XCTAssertEqual(c.statusBar.values[.branch], "main")
            XCTAssertFalse(c.statusBar.branchIsClickable)
            XCTAssertEqual(branchElement(c)?.accessibilityRole(), .staticText)
            XCTAssertFalse(branchElement(c)?.accessibilityPerformPress() == true)
            XCTAssertFalse(c.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.showBranches(_:)), keyEquivalent: "")))
            c.showBranches(nil)
            XCTAssertEqual(c.statusBar.flashText, "Turn on Git tab, file history and branches in Settings → Git")
        }
    }

    func testChoosingABranchSwitchesAndRefreshesTheWindow() throws {
        try withWindow { c in
            let doc = try XCTUnwrap(c.activeDocument)
            c.sidebar.showHistory()
            c.rootView.layoutSubtreeIfNeeded()
            let history = try XCTUnwrap(c.sidebar.subviews.compactMap { $0 as? HistoryView }.first)
            spin { history.commits.count == 1 }
            XCTAssertEqual(history.commits.first?.subject, "base")

            c.showBranches(nil)
            spin { c.palette.listTag == MainWindowController.branchesListTag }
            let items = c.palette.shownItems
            XCTAssertEqual(items.map(\.title), ["New Branch…", "feature", "main"])
            XCTAssertEqual(items[2].icon, "checkmark")
            XCTAssertTrue(items[2].detail.hasPrefix("Current branch · base"), items[2].detail)
            XCTAssertEqual(items[1].icon, "arrow.triangle.branch")
            XCTAssertTrue(items[1].detail.hasSuffix("· feature work"), items[1].detail)

            items[2].action()
            XCTAssertEqual(c.statusBar.flashText, "Already on “main”")
            items[1].action()
            spin { c.statusBar.values[.branch] == "feature" }
            XCTAssertEqual(c.statusBar.values[.branch], "feature")
            XCTAssertEqual(c.statusBar.flashText, "Switched to “feature”")
            spin { history.commits.first?.subject == "feature work" }
            XCTAssertEqual(history.commits.first?.subject, "feature work")
            spin { (doc.string as String) == "feature\n" }
            XCTAssertEqual(doc.string as String, "feature\n", "a clean open document reloads at once")
            XCTAssertNil(c.statusBar.message)
        }
    }

    func testARefusedSwitchExplainsWhichFilesAreInTheWay() throws {
        try withWindow { c in
            try write("dirty\n", "a.txt")
            let repo = try repo()
            c.switchBranch(.local("feature"), label: "feature", in: repo)
            let sheet = try XCTUnwrap({ () -> NSWindow? in spin(10) { c.window?.attachedSheet != nil }; return c.window?.attachedSheet }())
            let shown = texts(in: try XCTUnwrap(sheet.contentView))
            XCTAssertTrue(shown.contains("Can’t switch to “feature”"), "\(shown)")
            XCTAssertTrue(shown.contains { $0.contains("have changes that aren’t committed, and they’re different on “feature”:\n\na.txt\n\nCommit or discard") }, "\(shown)")
            XCTAssertEqual(read("a.txt"), "dirty\n")
            if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }
            XCTAssertFalse(c.isSwitchingBranch)
        }
    }

    func testRefusalTextsListEightPathsAndCountTheRest() {
        let paths = (1...11).map { "f\($0).txt" }
        let text = MainWindowController.refusalText(.untracked(paths), label: "x")
        XCTAssertTrue(text.contains("f8.txt\nand 3 more\n\nMove or delete them first."), text)
        XCTAssertFalse(text.contains("f9.txt"))
        XCTAssertEqual(MainWindowController.refusalText(.invalidName, label: "a..b"), "“a..b” isn’t a valid branch name.")
        XCTAssertEqual(MainWindowController.refusalText(.alreadyExists, label: "x"), "A branch named “x” already exists.")
    }
}
