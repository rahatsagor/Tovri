import AppKit
import XCTest
@testable import Tovri

/// Regression tests for ways a repository, a document or the command line tool could make Tovri
/// run a program, read without limit or hang. Each attack is first shown to work with plain git,
/// so a test can't pass only because its setup no longer triggers anything.
final class GitSecurityHardeningTests: XCTestCase {
    private var dir: URL!
    private var marker: URL { dir.appendingPathComponent("pwned") }
    private var savedEnvironment: [String: String] = [:]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-harden-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedEnvironment = GitRepository.userEnvironment
    }

    override func tearDown() {
        GitRepository.userEnvironment = savedEnvironment
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func shell(_ command: String, in folder: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = folder ?? dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A script that records that it ran, then passes its input through like a filter.
    private func makeEvilScript() throws -> URL {
        let script = dir.appendingPathComponent("evil.sh")
        try "#!/bin/sh\necho \"$*\" >> '\(marker.path)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private let commit = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm"

    private func initRepository(_ folder: URL? = nil) throws {
        XCTAssertEqual(try shell("git init -q . && git config user.email t@example.com && git config user.name t", in: folder), 0)
    }

    private func assertGitRanTheScript(_ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "plain git no longer runs the script \(what), so this test proves nothing")
        try FileManager.default.removeItem(at: marker)
    }

    private func history(_ repo: GitRepository, of url: URL) -> [GitRepository.Commit] {
        var commits: [GitRepository.Commit] = []
        let done = expectation(description: "history")
        repo.history(of: url) { commits = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return commits
    }

    private func changedFiles(_ repo: GitRepository) -> [GitRepository.ChangedFile] {
        var files: [GitRepository.ChangedFile] = []
        let done = expectation(description: "changes")
        repo.changedFiles { files = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return files
    }

    private func status(_ repo: GitRepository) -> [String: GitFileStatus] {
        var result: [String: GitFileStatus] = [:]
        let done = expectation(description: "status")
        repo.status { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result
    }

    // MARK: - Programs named by the repository

    func testFileHistoryDoesNotCheckSignaturesWithTheRepositorysProgram() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let evil = try makeEvilScript()
        try initRepository()
        // A commit that changes a.txt and carries a signature, which git checks with gpg.program.
        try shell("""
        echo one > a.txt && git add a.txt && \(commit) init
        echo two > a.txt && git add a.txt
        tree=$(git write-tree) && parent=$(git rev-parse HEAD)
        printf 'tree %s\\nparent %s\\nauthor t <t@example.com> 1700000000 +0000\\ncommitter t <t@example.com> 1700000000 +0000\\ngpgsig -----BEGIN PGP SIGNATURE-----\\n \\n iQ==\\n -----END PGP SIGNATURE-----\\n\\nsigned\\n' "$tree" "$parent" > ../commit-\(dir.lastPathComponent)
        git update-ref HEAD "$(git hash-object -t commit -w ../commit-\(dir.lastPathComponent))"
        rm ../commit-\(dir.lastPathComponent)
        git config log.showSignature true
        git config gpg.program '\(evil.path)'
        """)
        XCTAssertEqual(try shell("git log -n 5 --format=%s --follow -- a.txt"), 0)
        try assertGitRanTheScript("for a signed commit")

        let file = dir.appendingPathComponent("a.txt")
        let repo = try XCTUnwrap(GitRepository.find(for: file))
        XCTAssertEqual(history(repo, of: file).map(\.subject), ["signed", "init"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "File History ran the repository's gpg.program")

        // The SSH and X.509 signature programs are switched off as well.
        try shell("git config --unset gpg.program && git config gpg.format ssh && git config gpg.ssh.program '\(evil.path)' && git config gpg.x509.program '\(evil.path)'")
        _ = history(repo, of: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "File History ran the repository's gpg.ssh.program")
    }

    func testStatusDoesNotRunAFilterWhoseNameContainsAnEqualsSign() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let evil = try makeEvilScript()
        try initRepository()
        try shell("""
        echo 'a.txt filter=x=y' > .gitattributes && echo one > a.txt
        git add -A && \(commit) init
        git config 'filter.x=y.clean' '\(evil.path)' && git config 'filter.x=y.required' true
        echo two > a.txt
        """)
        // `-c filter.x=y.clean=` is read as `filter.x` = `y.clean=`, so the filter still runs.
        XCTAssertEqual(try shell("git -c 'filter.x=y.clean=' -c 'filter.x=y.required=false' status --porcelain"), 0)
        try assertGitRanTheScript("for a filter named x=y")

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        XCTAssertEqual(status(repo)["a.txt"], .modified)
        XCTAssertEqual(changedFiles(repo).map(\.path), ["a.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran the filter named x=y")
    }

    func testChangedFileCountsDoNotRunDiffProgramsOrTextConversions() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let evil = try makeEvilScript()
        try initRepository()
        try shell("""
        echo 'a.txt diff=conv' > .gitattributes && printf 'one\\ntwo\\n' > a.txt
        git add -A && \(commit) init
        git config diff.conv.textconv '\(evil.path)' && git config diff.conv.command '\(evil.path)' && git config diff.external '\(evil.path)'
        printf 'one\\nTWO\\nthree\\n' > a.txt
        """)
        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        let files = changedFiles(repo)
        XCTAssertEqual(files.first?.added, 2)
        XCTAssertEqual(files.first?.removed, 1)
        var data: Data?
        let read = expectation(description: "HEAD copy")
        repo.headContents(of: dir.appendingPathComponent("a.txt")) { data = $0; read.fulfill() }
        wait(for: [read], timeout: 30)
        XCTAssertEqual(data, Data("one\ntwo\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran a diff program configured by the repository")
    }

    func testChangedFilesDoNotLookInsideSubmodules() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let evil = try makeEvilScript()
        try initRepository()
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try initRepository(sub)
        try shell("echo one > s.txt && git add -A && \(commit) sub", in: sub)
        try shell("echo top > top.txt && git add -A && \(commit) init")
        // The submodule's own filter has a name the outer repository's config doesn't list.
        try shell("""
        echo 's.txt filter=inner' > .gitattributes
        git config filter.inner.clean '\(evil.path)' && git config filter.inner.required true
        echo two > s.txt
        """, in: sub)
        try shell("echo changed > top.txt")
        XCTAssertEqual(try shell("git diff --numstat HEAD --"), 0)
        try assertGitRanTheScript("inside a submodule")

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("top.txt")))
        XCTAssertEqual(changedFiles(repo).map(\.path), ["top.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran a filter configured inside a submodule")
    }

    func testNoTransportRunsEvenWhenTheRepositoryAllowsIt() throws {
        let git = try XCTUnwrap(GitRepository.executable, "git is not installed")
        let evil = try makeEvilScript()
        try "#!/bin/sh\necho \"$*\" >> '\(marker.path)'\nexit 1\n".write(to: evil, atomically: true, encoding: .utf8)
        try initRepository()
        // A partial clone fetches missing objects from its promisor remote; this one is a command.
        try shell("git config protocol.ext.allow always && git config protocol.allow always")
        XCTAssertNotEqual(try shell("git fetch -q 'ext::\(evil.path)'"), 0)
        try assertGitRanTheScript("for an ext:: remote")

        let env = GitRepository.environment(GitRepository.safetySettings)
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: git), ["-C", dir.path, "fetch", "-q", "ext::\(evil.path)"], environment: env))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran a transport the repository allowed")
    }

    func testFilterSettingsCoverEveryNameExactly() throws {
        let entries = [
            "filter.lfs.clean\ngit-lfs clean -- %f",
            "filter.x=y.required\ntrue",
            "filter.with.dots.smudge\nx",
            "filter.sp ace \"q\".process\nmulti\nline value",
            "filter.bare.clean",
            "filter..clean\nempty name",
            "filter.clean\nno name",
        ]
        let data = Data((entries.joined(separator: "\0") + "\0").utf8)
        let settings = try XCTUnwrap(GitRepository.filterSettings(data))
        let keys = Set(settings.map(\.key))
        for name in ["lfs", "x=y", "with.dots", "sp ace \"q\"", "bare", ""] {
            for key in ["clean", "smudge", "process"] {
                XCTAssertTrue(keys.contains("filter.\(name).\(key)"), "no override for \(key) of \(name.debugDescription)")
            }
            XCTAssertTrue(settings.contains { $0.key == "filter.\(name).required" && $0.value == "false" })
        }
        XCTAssertEqual(settings.count, 6 * 4)
        XCTAssertTrue(settings.allSatisfy { $0.key.hasSuffix(".required") ? $0.value == "false" : $0.value.isEmpty })
        // A name git can't be given in the environment stops git from running at all.
        XCTAssertNil(GitRepository.filterSettings(Data([0x66, 0x69, 0x6c, 0x74, 0x65, 0x72, 0x2e, 0xff, 0x2e, 0x63, 0x0a, 0x78, 0x00])))
        XCTAssertEqual(GitRepository.filterSettings(Data())?.count, 0)
    }

    func testSettingsReachGitWithoutBeingSplitAtTheEqualsSign() {
        let env = GitRepository.environment([("filter.x=y.clean", ""), ("core.hooksPath", "/dev/null")])
        XCTAssertEqual(env["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "filter.x=y.clean")
        XCTAssertEqual(env["GIT_CONFIG_VALUE_0"], "")
        XCTAssertEqual(env["GIT_CONFIG_KEY_1"], "core.hooksPath")
        XCTAssertEqual(env["GIT_CONFIG_VALUE_1"], "/dev/null")
        XCTAssertEqual(env["GIT_ALLOW_PROTOCOL"], "")
        XCTAssertEqual(env["GIT_NO_LAZY_FETCH"], "1")
        XCTAssertEqual(env["GIT_LITERAL_PATHSPECS"], "1")
        XCTAssertEqual(env["HOME"], GitRepository.userEnvironment["HOME"])
        let safety = Dictionary(uniqueKeysWithValues: GitRepository.safetySettings.map { ($0.key, $0.value) })
        XCTAssertEqual(safety["log.showSignature"], "false")
        for program in ["gpg.program", "gpg.openpgp.program", "gpg.ssh.program", "gpg.x509.program"] {
            XCTAssertEqual(safety[program], "false", program)
        }
        XCTAssertEqual(safety["core.fsmonitor"], "false")
        XCTAssertEqual(safety["core.hooksPath"], "/dev/null")
    }

    func testOnlyAGitThatHonorsTheSafetySettingsIsUsed() {
        XCTAssertTrue(GitRepository.isSupported(version: "git version 2.39.5 (Apple Git-154)\n"))
        XCTAssertTrue(GitRepository.isSupported(version: "git version 2.31.0"))
        XCTAssertTrue(GitRepository.isSupported(version: "git version 2.45.0.rc1"))
        XCTAssertTrue(GitRepository.isSupported(version: "git version 3.0.0"))
        XCTAssertFalse(GitRepository.isSupported(version: "git version 2.30.9"))
        XCTAssertFalse(GitRepository.isSupported(version: "git version 1.9.5"))
        XCTAssertFalse(GitRepository.isSupported(version: "hub version 2.40"))
        XCTAssertFalse(GitRepository.isSupported(version: ""))
    }

    // MARK: - Paths

    func testFileHistoryTreatsTheFileNameLiterally() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        try initRepository()
        try shell("""
        echo a > a.txt && git add a.txt && \(commit) 'add a'
        echo b > b.txt && git add b.txt && \(commit) 'add b'
        echo x > '[ab].txt' && git add -A && \(commit) 'add brackets'
        echo y > ':a.txt' && git add -A && \(commit) 'add colon'
        """)
        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        XCTAssertEqual(history(repo, of: dir.appendingPathComponent("[ab].txt")).map(\.subject), ["add brackets"])
        XCTAssertEqual(history(repo, of: dir.appendingPathComponent(":a.txt")).map(\.subject), ["add colon"])
        XCTAssertEqual(history(repo, of: dir.appendingPathComponent("a.txt")).map(\.subject), ["add a"])
    }

    // MARK: - The user's global config

    func testTheGlobalIgnoreFileIsHonoredAndGlobalFiltersStayOff() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let evil = try makeEvilScript()
        let home = dir.appendingPathComponent("home")
        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try ".DS_Store\n.idea/\n".write(to: home.appendingPathComponent(".config/git/ignore"), atomically: true, encoding: .utf8)
        try initRepository(repoDir)
        try shell("echo 'a.txt filter=global' > .gitattributes && echo one > a.txt && git add -A && \(commit) init", in: repoDir)
        try shell("mkdir .idea && echo x > .idea/workspace.xml && echo x > .DS_Store && echo new > kept.txt && echo two > a.txt", in: repoDir)
        try "[filter \"global\"]\n\tclean = \(evil.path)\n\trequired = true\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        GitRepository.userEnvironment = ["HOME": home.path]

        let repo = try XCTUnwrap(GitRepository.find(for: repoDir.appendingPathComponent("a.txt")))
        let st = status(repo)
        XCTAssertEqual(st["kept.txt"], .untracked)
        XCTAssertEqual(st["a.txt"], .modified)
        XCTAssertNil(st[".DS_Store"], "a file ignored only by the global ignore file was listed as new")
        XCTAssertNil(st[".idea/workspace.xml"])
        XCTAssertEqual(Set(changedFiles(repo).map(\.path)), ["a.txt", "kept.txt"])
        XCTAssertEqual(Set(try XCTUnwrap(repo.unignoredFiles(in: repoDir))), [".gitattributes", "a.txt", "kept.txt"])
        var ignored: [String] = []
        let listed = expectation(description: "ignored")
        repo.ignored { ignored = $0; listed.fulfill() }
        wait(for: [listed], timeout: 30)
        XCTAssertEqual(Set(ignored), [".DS_Store", ".idea"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran a filter from the global config")

        // core.excludesFile with a ~ path, as most people write it, is expanded with the home folder.
        try "*.secret\n".write(to: home.appendingPathComponent("my-ignore"), atomically: true, encoding: .utf8)
        try "[core]\n\texcludesFile = ~/my-ignore\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try "x\n".write(to: repoDir.appendingPathComponent("key.secret"), atomically: true, encoding: .utf8)
        let again = status(repo)
        XCTAssertEqual(again["kept.txt"], .untracked)
        XCTAssertNil(again["key.secret"])
    }

    // MARK: - Untracked files

    func testLineCountsReadOnlySmallRegularFiles() throws {
        let fm = FileManager.default
        let text = dir.appendingPathComponent("three.txt")
        try "a\nb\nc".write(to: text, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: text)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("zero.txt"), withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("random.txt"), withDestinationURL: URL(fileURLWithPath: "/dev/urandom"))
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("pipe.txt").path, 0o600), 0)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("pipe-link.txt"), withDestinationURL: dir.appendingPathComponent("pipe.txt"))
        fm.createFile(atPath: dir.appendingPathComponent("empty.txt").path, contents: Data())
        fm.createFile(atPath: dir.appendingPathComponent("big.txt").path, contents: Data(repeating: 10, count: 4_000_001))
        fm.createFile(atPath: dir.appendingPathComponent("binary.bin").path, contents: Data([65, 0, 66]))
        try fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)

        let start = Date()
        XCTAssertEqual(GitRepository.lineCount(of: text), 3)
        XCTAssertEqual(GitRepository.lineCount(of: dir.appendingPathComponent("link.txt")), 3)
        XCTAssertEqual(GitRepository.lineCount(of: dir.appendingPathComponent("empty.txt")), 0)
        for name in ["zero.txt", "random.txt", "pipe.txt", "pipe-link.txt", "big.txt", "binary.bin", "folder", "missing.txt"] {
            XCTAssertNil(GitRepository.lineCount(of: dir.appendingPathComponent(name)), name)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "counting lines read a device or waited on a pipe")
    }

    // MARK: - Markdown preview

    func testRemoteImagesLoadOnlyFromTovrisOwnBar() throws {
        _ = NSApplication.shared
        let shell = MarkdownPreviewView.shell(theme: ThemeManager.shared.active, fontSize: 13, allowRemote: false)
        XCTAssertFalse(shell.contains("remote-load"), "the page still has a button the document could restyle")
        XCTAssertFalse(shell.contains("remote: true"))

        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        preview.allowsRemoteContent = false
        var requests = 0
        preview.onRequestRemoteContent = { requests += 1 }
        preview.loadShell(theme: ThemeManager.shared.active, fontSize: 13)
        func loadButton(in view: NSView) -> NSButton? {
            for v in view.subviews {
                if let b = v as? NSButton, b.title == "Load Remote Images" { return b }
                if let b = loadButton(in: v) { return b }
            }
            return nil
        }
        let button = try XCTUnwrap(loadButton(in: preview))
        XCTAssertTrue(button.superview?.isHidden ?? false, "the bar showed before anything was blocked")

        preview.remoteContentWasBlocked()
        preview.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(button.superview)
        XCTAssertFalse(bar.isHidden)
        XCTAssertGreaterThan(bar.frame.height, 0)
        XCTAssertEqual(bar.frame.maxY, preview.bounds.maxY)
        button.performClick(nil)
        XCTAssertEqual(requests, 1)

        // A new page hides the bar until its own content is blocked.
        preview.loadShell(theme: ThemeManager.shared.active, fontSize: 13)
        XCTAssertTrue(bar.isHidden)
        preview.allowsRemoteContent = true
        preview.remoteContentWasBlocked()
        XCTAssertTrue(bar.isHidden, "the bar offered to load images that are already allowed")
    }

    func testPreviewResourcesShareOneBudgetPerPage() throws {
        let mb = 1024 * 1024
        let base = "tovri-preview://file/docs/"
        let key = { (s: String) in PreviewResourceBudget.key(for: try XCTUnwrap(URL(string: base + s))) }
        XCTAssertEqual(try key("big.mp4#t=10"), base + "big.mp4")
        XCTAssertNotEqual(try key("big.mp4?1"), try key("big.mp4?2"))
        XCTAssertEqual(try key("big.mp4?1"), try key("big.mp4?1#x"))

        let budget = PreviewResourceBudget()
        XCTAssertTrue(budget.admit(try key("big.mp4"), size: 64 * mb))
        // The same URL again, as after an edit, costs nothing.
        for _ in 0..<10 { XCTAssertTrue(budget.admit(try key("big.mp4"), size: 64 * mb)) }
        XCTAssertEqual(budget.total, 64 * mb)
        var admitted = 1
        for i in 1...100 where budget.admit(try key("big.mp4?\(i)"), size: 64 * mb) { admitted += 1 }
        XCTAssertEqual(admitted, PreviewResourceBudget.limit / (64 * mb))
        XCTAssertLessThanOrEqual(budget.total, PreviewResourceBudget.limit)
        XCTAssertTrue(budget.admit(try key("big.mp4?3"), size: 64 * mb), "a URL that was admitted stopped loading")
    }
}
