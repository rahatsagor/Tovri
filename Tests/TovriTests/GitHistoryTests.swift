import AppKit
import XCTest
@testable import Tovri

/// The sidebar's History tab: parsing git's output, the commit graph, reading history from real
/// temporary repositories, and opening commits and their files in the window.
final class GitHistoryTests: XCTestCase {
    private var base: URL!
    private var dir: URL!
    private var savedEnvironment: [String: String] = [:]
    private var marker: URL { base.appendingPathComponent("ran-program") }
    private let commit = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -q"

    override func setUpWithError() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-history-\(UUID().uuidString)").resolvingSymlinksInPath()
        dir = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedEnvironment = GitRepository.userEnvironment
        // A home without a .gitconfig, so the person's own filters (Git LFS) don't change the results.
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        GitRepository.userEnvironment = ["HOME": home.path]
        XCTAssertEqual(try shell("git init -q -b main . && git config user.email t@example.com && git config user.name t"), 0)
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

    private func write(_ text: String, _ name: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func repo() throws -> GitRepository { try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("x"))) }

    private func spin(_ seconds: TimeInterval = 20, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func log(_ repo: GitRepository, tip: String = "HEAD", _ query: String = "", skip: Int = 0, limit: Int = 200,
                     topo: Bool = false) -> [LogCommit] {
        var result: [LogCommit]?
        let done = expectation(description: "log")
        repo.log(from: tip, query: HistoryQuery(query), skip: skip, limit: limit, topoOrder: topo, cancellation: nil) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result ?? []
    }

    private func detail(_ repo: GitRepository, _ c: LogCommit) -> GitRepository.CommitDetail? {
        var result: GitRepository.CommitDetail?
        let done = expectation(description: "detail")
        repo.commitDetail(sha: c.sha, parents: c.parents) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result
    }

    private func patch(_ repo: GitRepository, _ c: LogCommit, paths: [String]? = nil) -> String? {
        var result: String?
        let done = expectation(description: "patch")
        repo.commitPatch(sha: c.sha, parent: c.parents.first, paths: paths) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result
    }

    private func contents(_ repo: GitRepository, _ path: String, at sha: String) -> Data? {
        var result: Data?
        let done = expectation(description: "contents")
        repo.contents(of: path, at: sha) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return result
    }

    private func commits(_ subjects: [String]) throws {
        for s in subjects {
            try write(s + "\n", "f.txt")
            XCTAssertEqual(try shell("git add -A && \(commit) -m '\(s)'"), 0)
        }
    }

    private func fake(_ sha: String, _ parents: [String] = []) -> LogCommit {
        LogCommit(sha: sha, shortSHA: String(sha.prefix(7)), parents: parents, author: "A", date: Date(timeIntervalSince1970: 0), subject: sha, refs: [])
    }

    // MARK: - Parsing

    private func record(_ sha: String, parents: String = "", refs: String = "", subject: String = "s") -> String {
        "\(sha)\u{1f}\(sha.prefix(7))\u{1f}\(parents)\u{1f}Ann\u{1f}1700000000\u{1f}\(refs)\u{1f}\(subject)\0"
    }

    func testParseLogReadsRootNormalAndMergeCommits() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let data = Data((record(c, parents: "\(a) \(b)", subject: "Merge x") + record(b, parents: a) + record(a)).utf8)
        let out = GitRepository.parseLog(data)
        XCTAssertEqual(out.map(\.parents), [[a, b], [a], []])
        XCTAssertEqual(out.map(\.subject), ["Merge x", "s", "s"])
        XCTAssertEqual(out[0].shortSHA, String(c.prefix(7)))
        XCTAssertEqual(out[0].author, "Ann")
        XCTAssertEqual(out[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(out[0].refs, [])
        XCTAssertEqual(GitRepository.parseLog(Data()), [])
    }

    func testParseLogKeepsASubjectWithTheFieldSeparatorAndUnicode() {
        let sha = String(repeating: "d", count: 40)
        let subject = "বাংলা ünï\u{1f}code \u{1f} end"
        let out = GitRepository.parseLog(Data(record(sha, subject: subject).utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.subject, subject)
    }

    func testParseLogReadsFullRefDecorations() {
        let sha = String(repeating: "e", count: 40)
        let full = "HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/main, refs/remotes/origin/HEAD, refs/heads/topic/x, refs/heads/feat,x, tag: refs/tags/v2,rc, refs/stash"
        XCTAssertEqual(GitRepository.parseLog(Data(record(sha, refs: full).utf8)).first?.refs, [
            RefLabel(name: "main", kind: .branch, isCheckedOut: true),
            RefLabel(name: "v1", kind: .tag, isCheckedOut: false),
            RefLabel(name: "origin/main", kind: .remoteBranch, isCheckedOut: false),
            RefLabel(name: "topic/x", kind: .branch, isCheckedOut: false),
            RefLabel(name: "feat,x", kind: .branch, isCheckedOut: false),
            RefLabel(name: "v2,rc", kind: .tag, isCheckedOut: false),
        ])
        XCTAssertEqual(GitRepository.parseLog(Data(record(sha, refs: "HEAD, refs/heads/other").utf8)).first?.refs, [
            RefLabel(name: "HEAD", kind: .detachedHead, isCheckedOut: true),
            RefLabel(name: "other", kind: .branch, isCheckedOut: false),
        ])
        XCTAssertEqual(GitRepository.parseLog(Data(record(sha, refs: "").utf8)).first?.refs, [])
    }

    func testHistoryQueryReadsWordsAuthorsAndPaths() {
        XCTAssertTrue(HistoryQuery("").isEmpty)
        XCTAssertTrue(HistoryQuery("   ").isEmpty)
        let q = HistoryQuery("fix  bug author:ann path:src/app")
        XCTAssertEqual(q.words, "fix bug")
        XCTAssertEqual(q.authors, ["ann"])
        XCTAssertEqual(q.paths, ["src/app"])
        XCTAssertFalse(q.isEmpty)
        XCTAssertFalse(HistoryQuery("author:ann").isEmpty)

        let quoted = HistoryQuery("path:\"My Folder\" author:\"Ann Lee\" done path:b")
        XCTAssertEqual(quoted.words, "done")
        XCTAssertEqual(quoted.authors, ["Ann Lee"])
        XCTAssertEqual(quoted.paths, ["My Folder", "b"])

        let bare = HistoryQuery("author: path: x")
        XCTAssertEqual(bare.words, "author: path: x")
        XCTAssertTrue(bare.authors.isEmpty && bare.paths.isEmpty)
        XCTAssertEqual(HistoryQuery("path:\"open ended").paths, ["open ended"])
        XCTAssertEqual(HistoryQuery("a  b\tc").words, "a b c")

        XCTAssertEqual(q.logArguments, ["--regexp-ignore-case", "--fixed-strings", "--grep=fix bug", "--author=ann"])
    }

    func testNameStatusAndNumstatReadRenamesBinariesAndOddNames() {
        let names = "D\0gone.txt\0A\0new file.txt\0R100\0old.txt\0renamed.txt\0M\0ünï.txt\0T\0link\0C75\0a.txt\0copy.txt\0M\0tab\tname.txt\0"
        let files = GitRepository.parseNameStatus(Data(names.utf8))
        XCTAssertEqual(files.map(\.path), ["gone.txt", "new file.txt", "renamed.txt", "ünï.txt", "link", "copy.txt", "tab\tname.txt"])
        XCTAssertEqual(files.map(\.status), [.deleted, .added, .renamed, .modified, .modified, .added, .modified])
        XCTAssertEqual(files[2].originalPath, "old.txt")
        XCTAssertNil(files[5].originalPath)

        let numbers = "3\t1\tnew file.txt\0-\t-\tbin.dat\05\t0\t\0old.txt\0renamed.txt\0" + "1\t2\ttab\tname.txt\0"
        let counts = GitRepository.parseNumstat(Data(numbers.utf8))
        XCTAssertEqual(counts["new file.txt"]?.added, 3)
        XCTAssertNil(counts["bin.dat"])
        XCTAssertEqual(counts["renamed.txt"]?.added, 5)
        XCTAssertEqual(counts["tab\tname.txt"]?.removed, 2)
    }

    // MARK: - Commit graph

    func testGraphKeepsALinearHistoryInOneLane() {
        var state = CommitGraph.State()
        let rows = CommitGraph.layout([fake("c3", ["c2"]), fake("c2", ["c1"]), fake("c1")], state: &state)
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.continuing), [[0], [0], []])
        XCTAssertEqual(rows.map(\.isMerge), [false, false, false])
        XCTAssertEqual(state.lanes.compactMap { $0 }, [])
    }

    func testGraphOpensALaneForABranchAndClosesItAtTheMerge() {
        var state = CommitGraph.State()
        // m merges a and b, which both descend from base.
        let rows = CommitGraph.layout([fake("m", ["a", "b"]), fake("a", ["base"]), fake("b", ["base"]), fake("base")], state: &state)
        XCTAssertEqual(rows.map(\.lane), [0, 0, 1, 0])
        XCTAssertTrue(rows[0].isMerge)
        XCTAssertEqual(rows[0].continuing, [0, 1])
        XCTAssertTrue(rows[0].edges.contains(CommitGraph.Edge(from: 0, to: 1, half: .bottom)))
        XCTAssertEqual(rows[1].continuing, [0, 1], "the branch's lane must carry on past the first parent")
        XCTAssertTrue(rows[2].edges.contains(CommitGraph.Edge(from: 1, to: 1, half: .top)))
        XCTAssertTrue(rows[2].edges.contains(CommitGraph.Edge(from: 1, to: 0, half: .bottom)), "the branch joins base's lane")
        XCTAssertTrue(rows[3].edges.contains(CommitGraph.Edge(from: 0, to: 0, half: .top)))
        XCTAssertEqual(rows[3].continuing, [])
    }

    func testGraphGivesAnOctopusMergeOneLanePerParent() {
        var state = CommitGraph.State()
        let rows = CommitGraph.layout([fake("m", ["a", "b", "c"]), fake("a"), fake("b"), fake("c")], state: &state)
        XCTAssertEqual(rows[0].laneCount, 3)
        XCTAssertEqual(rows[0].continuing, [0, 1, 2])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 1, 2])
        XCTAssertEqual(rows[2].continuing, [2])
    }

    func testGraphLaidOutPageByPageEqualsOneCall() {
        var commits: [LogCommit] = []
        for i in 0..<120 {
            let parents = [i + 1 < 120 ? "c\(i + 1)" : nil, i % 7 == 0 && i + 9 < 120 ? "c\(i + 9)" : nil, i % 31 == 0 && i + 5 < 120 ? "c\(i + 5)" : nil].compactMap { $0 }
            commits.append(fake("c\(i)", parents))
        }
        var whole = CommitGraph.State()
        let all = CommitGraph.layout(commits, state: &whole)
        var paged = CommitGraph.State()
        var pieces: [CommitGraph.Row] = []
        for start in stride(from: 0, to: commits.count, by: 25) {
            pieces += CommitGraph.layout(Array(commits[start..<min(start + 25, commits.count)]), state: &paged)
        }
        XCTAssertEqual(pieces, all)
        XCTAssertEqual(paged, whole)
        XCTAssertGreaterThan(all.map(\.laneCount).max() ?? 0, 1)
    }

    // MARK: - Cancellation

    func testCancellingStopsARunningProcessAndRefusesToStartOne() {
        let before = GitCancellation()
        before.cancel()
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: "/bin/echo"), ["hi"], environment: [:], cancellation: before))

        let running = GitCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { running.cancel() }
        let start = Date()
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["10"], environment: [:], cancellation: running))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(GitRepository.runProcess(URL(fileURLWithPath: "/bin/echo"), ["hi"], environment: [:], cancellation: GitCancellation()), Data("hi\n".utf8))
    }

    func testACancelledLogReturnsNil() throws {
        try commits(["one"])
        let cancel = GitCancellation()
        cancel.cancel()
        var called = false
        var result: [LogCommit]? = []
        let done = expectation(description: "log")
        try repo().log(from: "HEAD", query: HistoryQuery(), skip: 0, limit: 10, topoOrder: false, cancellation: cancel) { result = $0; called = true; done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertTrue(called)
        XCTAssertNil(result)
    }

    // MARK: - Reading history

    func testHeadCommitIsReadWithoutRunningGit() throws {
        let repo = try repo()
        XCTAssertTrue(repo.isUnborn)
        XCTAssertNil(repo.headCommitSHA)
        try commits(["one"])
        XCTAssertFalse(repo.isUnborn)
        let sha = try XCTUnwrap(repo.headCommitSHA)
        XCTAssertEqual(sha.count, 40)
        XCTAssertEqual(log(repo).first?.sha, sha)
    }

    func testPagesConcatenateToTheWholeHistory() throws {
        try commits((1...10).map { "c\($0)" })
        let repo = try repo()
        let whole = log(repo, limit: 100)
        XCTAssertEqual(whole.map(\.subject), (1...10).reversed().map { "c\($0)" })
        var pages: [LogCommit] = []
        for skip in stride(from: 0, to: 12, by: 3) { pages += log(repo, skip: skip, limit: 3) }
        XCTAssertEqual(pages, whole)
        XCTAssertEqual(log(repo, skip: 3, limit: 3, topo: true).map(\.subject), ["c7", "c6", "c5"])
        XCTAssertEqual(whole.first?.refs.first, RefLabel(name: "main", kind: .branch, isCheckedOut: true))
        XCTAssertEqual(whole.first?.parents.count, 1)
        XCTAssertEqual(whole.last?.parents, [])
    }

    func testAPinnedTipKeepsPagesConsistentWhenHeadMoves() throws {
        try commits((1...6).map { "c\($0)" })
        let repo = try repo()
        let tip = try XCTUnwrap(repo.headCommitSHA)
        let first = log(repo, tip: tip, limit: 3)
        try commits(["new"])
        XCTAssertEqual(log(repo, limit: 1).first?.subject, "new")
        let second = log(repo, tip: tip, skip: 3, limit: 3)
        XCTAssertEqual((first + second).map(\.subject), ["c6", "c5", "c4", "c3", "c2", "c1"])
    }

    func testSearchMatchesMessagesAuthorsAndPathsLiterally() throws {
        try write("1\n", "src/a.swift")
        try shell("git add -A && git -c user.name=Alice -c user.email=a@x -c core.hooksPath=/dev/null commit -q -m 'Fix(parser): handle x'")
        try write("2\n", "[ab].txt")
        try shell("git add -A && git -c user.name=Bob -c user.email=b@x -c core.hooksPath=/dev/null commit -q -m 'fix: other'")
        try write("3\n", "a.txt")
        try write("3\n", "docs/readme.md")
        try shell("git add -A && git -c user.name=Alice -c user.email=a@x -c core.hooksPath=/dev/null commit -q -m 'docs: update'")
        let repo = try repo()
        XCTAssertEqual(log(repo, "fix(").map(\.subject), ["Fix(parser): handle x"], "a search is literal and ignores case")
        XCTAssertEqual(Set(log(repo, "FIX").map(\.subject)), ["Fix(parser): handle x", "fix: other"])
        XCTAssertEqual(log(repo, "author:alice").map(\.subject), ["docs: update", "Fix(parser): handle x"])
        XCTAssertEqual(log(repo, "author:BOB").map(\.subject), ["fix: other"])
        XCTAssertEqual(log(repo, "author:alice fix").map(\.subject), ["Fix(parser): handle x"])
        XCTAssertEqual(log(repo, "path:src").map(\.subject), ["Fix(parser): handle x"], "a folder matches what is under it")
        XCTAssertEqual(log(repo, "path:[ab].txt").map(\.subject), ["fix: other"], "a path is not a pattern")
        XCTAssertEqual(log(repo, "path:docs path:src").count, 2)
        XCTAssertEqual(log(repo, "nothing like this").count, 0)
    }

    func testTheCommitGraphFileIsFoundOnlyWhenItExists() throws {
        try commits(["a", "b", "c"])
        let repo = try repo()
        try shell("rm -rf .git/objects/info/commit-graph .git/objects/info/commit-graphs")
        XCTAssertFalse(repo.hasCommitGraph)
        try shell("git commit-graph write --reachable")
        XCTAssertTrue(repo.hasCommitGraph)
        XCTAssertEqual(log(repo, topo: true).map(\.subject), ["c", "b", "a"])
    }

    // MARK: - Commit details and patches

    private func historyWithRenameBinaryAndDelete() throws {
        try write((1...20).map { "line \($0)" }.joined(separator: "\n") + "\n", "old.txt")
        try write("remove me\n", "del.txt")
        try write("keep\n", "keep.txt")
        try Data([0, 1, 2, 3, 0]).write(to: dir.appendingPathComponent("bin.dat"))
        try shell("git add -A && \(commit) -m root")
        try shell("git mv old.txt new.txt && git rm -q del.txt")
        try write((1...20).map { $0 == 5 ? "line five" : "line \($0)" }.joined(separator: "\n") + "\n", "new.txt")
        try Data([0, 1, 2, 3, 4, 0]).write(to: dir.appendingPathComponent("bin.dat"))
        try write("x\n", "with space.txt")
        try write("y\n", "ünï.txt")
        try write("z\n", "[ab].txt")
        try write("t\n", "tab\tname.txt")
        try shell("git add -A && \(commit) -m 'rename and more'")
    }

    func testCommitDetailListsRenamesBinariesDeletionsAndOddNames() throws {
        try historyWithRenameBinaryAndDelete()
        let repo = try repo()
        let all = log(repo)
        let d = try XCTUnwrap(detail(repo, all[0]))
        XCTAssertEqual(d.message, "rename and more")
        XCTAssertEqual(d.authorName, "t")
        XCTAssertEqual(d.authorEmail, "t@example.com")
        XCTAssertEqual(d.hiddenFileCount, 0)
        let byPath = Dictionary(uniqueKeysWithValues: d.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["new.txt"]?.status, .renamed)
        XCTAssertEqual(byPath["new.txt"]?.originalPath, "old.txt")
        XCTAssertEqual(byPath["new.txt"]?.added, 1)
        XCTAssertEqual(byPath["new.txt"]?.removed, 1)
        XCTAssertEqual(byPath["del.txt"]?.status, .deleted)
        XCTAssertEqual(byPath["del.txt"]?.removed, 1)
        XCTAssertEqual(byPath["bin.dat"]?.status, .modified)
        XCTAssertNil(byPath["bin.dat"]?.added, "a binary file has no line counts")
        for name in ["with space.txt", "ünï.txt", "[ab].txt", "tab\tname.txt"] {
            XCTAssertEqual(byPath[name]?.status, .added, name.debugDescription)
            XCTAssertEqual(byPath[name]?.added, 1, name.debugDescription)
        }
        XCTAssertNil(byPath["old.txt"], "a rename must not also list the old name")
    }

    func testCommitDetailOfARootCommitAndAMerge() throws {
        try historyWithRenameBinaryAndDelete()
        try shell("git switch -q -c side HEAD~1 && echo side > side.txt && git add -A && \(commit) -m side")
        try shell("git switch -q main && echo main > main.txt && git add -A && \(commit) -m mainline")
        try shell("git merge -q --no-ff side -m 'Merge side'")
        let repo = try repo()
        let all = log(repo)
        let merge = try XCTUnwrap(all.first)
        XCTAssertEqual(merge.parents.count, 2)
        let m = try XCTUnwrap(detail(repo, merge))
        XCTAssertEqual(m.parents, merge.parents)
        // Compared with the first parent (main), so only what the side branch brought in.
        XCTAssertTrue(m.files.contains { $0.path == "side.txt" && $0.status == .added }, "\(m.files)")
        XCTAssertFalse(m.files.contains { $0.path == "main.txt" })

        let root = try XCTUnwrap(all.last)
        XCTAssertEqual(root.parents, [])
        let r = try XCTUnwrap(detail(repo, root))
        XCTAssertEqual(Set(r.files.map(\.path)), ["old.txt", "del.txt", "keep.txt", "bin.dat"])
        XCTAssertTrue(r.files.allSatisfy { $0.status == .added })
        XCTAssertEqual(r.files.first { $0.path == "old.txt" }?.added, 20)
        XCTAssertEqual(r.message, "root")
    }

    func testCommitPatchShowsRenamesAndCanBeLimitedToPaths() throws {
        try historyWithRenameBinaryAndDelete()
        let repo = try repo()
        let all = log(repo)
        let full = try XCTUnwrap(patch(repo, all[0]))
        XCTAssertTrue(full.contains("rename from old.txt"), full)
        XCTAssertTrue(full.contains("rename to new.txt"))
        XCTAssertTrue(full.contains("deleted file mode"))
        XCTAssertFalse(full.hasPrefix("commit "), "the header is added by the window")
        let both = try XCTUnwrap(patch(repo, all[0], paths: ["old.txt", "new.txt"]))
        XCTAssertTrue(both.contains("rename from old.txt"))
        XCTAssertFalse(both.contains("del.txt"))
        let onlyNew = try XCTUnwrap(patch(repo, all[0], paths: ["new.txt"]))
        XCTAssertTrue(onlyNew.contains("new file mode"), "without the old path a rename reads as an added file")
        let root = try XCTUnwrap(patch(repo, all[1]))
        XCTAssertTrue(root.contains("+line 1\n"))
        XCTAssertEqual(patch(repo, all[0], paths: ["[ab].txt"])?.contains("+z"), true)
    }

    func testHistoryNeverRunsProgramsNamedByTheRepository() throws {
        let evil = base.appendingPathComponent("evil.sh")
        try "#!/bin/sh\necho \"$*\" >> '\(marker.path)'\ncat\n".write(to: evil, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evil.path)
        let hooks = base.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for name in ["post-checkout", "post-commit", "reference-transaction", "pre-commit"] {
            let hook = hooks.appendingPathComponent(name)
            try FileManager.default.copyItem(at: evil, to: hook)
        }
        try write("*.txt diff=evil filter=evil\n", ".gitattributes")
        try write("one\n", "a.txt")
        try shell("git add -A && \(commit) -m one")
        try write("two\n", "a.txt")
        try shell("git add -A && \(commit) -m two")
        try shell("""
        git config diff.external '\(evil.path)'
        git config diff.evil.textconv '\(evil.path)'
        git config filter.evil.clean '\(evil.path)'
        git config filter.evil.smudge '\(evil.path)'
        git config core.hooksPath '\(hooks.path)'
        git config core.fsmonitor '\(evil.path)'
        git config log.showSignature true
        git config gpg.program '\(evil.path)'
        """)
        XCTAssertEqual(try shell("git log -p --ext-diff -n 1 > /dev/null"), 0)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "plain git no longer runs the program, so this test proves nothing")
        try FileManager.default.removeItem(at: marker)

        let repo = try repo()
        let all = log(repo)
        XCTAssertEqual(all.map(\.subject), ["two", "one"])
        _ = try XCTUnwrap(detail(repo, all[0]))
        _ = try XCTUnwrap(patch(repo, all[0]))
        _ = try XCTUnwrap(patch(repo, all[0], paths: ["a.txt"]))
        XCTAssertNotNil(contents(repo, "a.txt", at: all[0].sha))
        _ = log(repo, "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "history ran a program named by the repository")
    }

    // MARK: - The window

    private func withWindow(_ body: (MainWindowController) throws -> Void) throws {
        let d = AppRuntime.defaults
        d.set(true, forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            controller.teardown()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
        controller.rootView.layoutSubtreeIfNeeded()
        try body(controller)
    }

    private func historyView(_ c: MainWindowController) -> HistoryView? { c.sidebar.subviews.compactMap { $0 as? HistoryView }.first }

    private func showHistory(_ c: MainWindowController, commits count: Int) throws -> HistoryView {
        c.sidebar.showHistory()
        c.rootView.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(historyView(c))
        spin { view.commits.count == count }
        XCTAssertEqual(view.commits.count, count)
        return view
    }

    private func items(_ view: HistoryView) -> [HistoryItem] {
        (0..<view.list.numberOfRows).compactMap { view.list.item(atRow: $0) as? HistoryItem }
    }

    private func commitItem(_ view: HistoryView, _ subject: String) throws -> HistoryItem {
        try XCTUnwrap(items(view).first { $0.kind == .commit && $0.commit?.subject == subject })
    }

    /// Opens the commit as the History list does and returns its tab's overview.
    @discardableResult
    private func openCommit(_ c: MainWindowController, _ view: HistoryView, _ subject: String, pinned: Bool = false) throws -> CommitOverviewView {
        view.open(try commitItem(view, subject), pinned: pinned)
        spin { c.activeDocument?.commitOverview?.commit.subject == subject && c.activeEditor?.commitOverview != nil }
        XCTAssertEqual(c.activeDocument?.commitOverview?.commit.subject, subject)
        return try XCTUnwrap(c.activeEditor?.commitOverview)
    }

    private func fileIndex(_ ov: CommitOverviewView, _ path: String) throws -> Int {
        try XCTUnwrap(ov.model.detail.files.firstIndex { $0.path == path }, path)
    }

    private func toolButton(_ c: MainWindowController, startingWith title: String) -> ToolButton? {
        c.activeGroup.container.subviews.compactMap { $0 as? ToolButton }.first { $0.toolTip?.hasPrefix(title) == true }
    }

    private func thirdCommitWithABody() throws {
        try write("third\n", "third.txt")
        try shell("git add -A && \(commit) -m 'Third change' -m 'First paragraph of the body.' -m 'Second paragraph.'")
    }

    private func tabNames(_ c: MainWindowController) -> [String] { c.groups.flatMap { $0.tabs.map { $0.document.displayName } } }

    func testTheGitTabsAppearOnlyInARepositoryWithTheSettingOn() throws {
        try commits(["one"])
        let plain = base.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let d = AppRuntime.defaults
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            controller.teardown()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let tabs = { controller.sidebar.subviews.compactMap { $0 as? SidebarTabs }.first }
        XCTAssertTrue(Settings.shared.gitChangesAndHistory, "on by default")
        d.set(false, forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabs()?.isHidden, true, "turned off")
        controller.sidebar.showChanges(true)
        XCTAssertFalse(controller.sidebar.isShowingChanges)

        d.set(true, forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertNotNil(controller.sidebar.repository)
        XCTAssertEqual(tabs()?.isHidden, false)
        controller.sidebar.showChanges(true)
        XCTAssertTrue(controller.sidebar.isShowingGitTab && controller.sidebar.isShowingChanges)
        XCTAssertFalse(controller.sidebar.isShowingHistory)

        // A folder that isn't a repository shows only Files.
        controller.setFolder(plain)
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertNil(controller.sidebar.repository)
        XCTAssertEqual(tabs()?.isHidden, true)
        XCTAssertFalse(controller.sidebar.isShowingGitTab)
        controller.sidebar.showChanges(true)
        controller.sidebar.showHistory()
        XCTAssertFalse(controller.sidebar.isShowingGitTab)
        XCTAssertFalse(controller.sidebar.subviews.contains { $0 is ChangesView || $0 is HistoryView })

        try shell("git init -q .", in: plain)
        controller.refreshGitStatus()
        spin(5) { controller.sidebar.repository != nil }
        XCTAssertNotNil(controller.sidebar.repository)
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabs()?.isHidden, false)

        d.set(false, forKey: Settings.Key.gitChangesAndHistory)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabs()?.isHidden, true)
        XCTAssertFalse(controller.sidebar.isShowingGitTab)
    }

    func testTurningTheFeatureOffDropsBothViews() throws {
        try commits(["one"])
        try withWindow { c in
            c.sidebar.showChanges(true)
            XCTAssertNotNil(c.sidebar.subviews.first { $0 is ChangesView })
            _ = try showHistory(c, commits: 1)
            XCTAssertNotNil(historyView(c))
            AppRuntime.defaults.set(false, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            XCTAssertNil(historyView(c))
            XCTAssertFalse(c.sidebar.subviews.contains { $0 is ChangesView })
        }
    }

    func testTheTabStripsReportTheirSelectionToAccessibility() throws {
        try commits(["one"])
        try withWindow { c in
            let tabs = try XCTUnwrap(c.sidebar.subviews.compactMap { $0 as? SidebarTabs }.first)
            let views = try XCTUnwrap(c.sidebar.subviews.compactMap { $0 as? GitViewTabs }.first)
            XCTAssertEqual(tabs.accessibilityValue() as? String, "Files")
            XCTAssertEqual(views.accessibilityLabel(), "Git view")
            XCTAssertEqual(views.accessibilityRole(), .radioGroup)
            XCTAssertTrue(tabs.accessibilityPerformPress())
            XCTAssertEqual(tabs.accessibilityValue() as? String, "Git")
            XCTAssertTrue(c.sidebar.isShowingChanges)
            XCTAssertEqual(views.accessibilityValue() as? String, "Changes")
            XCTAssertTrue(views.accessibilityPerformPress())
            XCTAssertEqual(views.accessibilityValue() as? String, "History")
            XCTAssertTrue(c.sidebar.isShowingHistory)
            XCTAssertTrue(views.accessibilityPerformPress())
            XCTAssertTrue(c.sidebar.isShowingChanges)
            XCTAssertTrue(tabs.accessibilityPerformPress())
            XCTAssertEqual(tabs.accessibilityValue() as? String, "Files")
            // The Git sub-tab is remembered while Files shows.
            views.selected = .history
            XCTAssertTrue(tabs.accessibilityPerformPress())
            XCTAssertTrue(c.sidebar.isShowingHistory)
        }
    }

    func testHistoryIsOnlyCreatedAndLoadedOnceShown() throws {
        try commits(["one", "two", "three"])
        try withWindow { c in
            XCTAssertNil(historyView(c))
            c.sidebar.showChanges(true)
            XCTAssertNil(historyView(c), "the Changes list must not create History")
            let view = try showHistory(c, commits: 3)
            XCTAssertEqual(view.commits.map(\.subject), ["three", "two", "one"])
            XCTAssertTrue(view.style.showsGraph)
            XCTAssertEqual(items(view).compactMap(\.graph).count, 3)
            XCTAssertNil(view.emptyMessage)
            XCTAssertEqual(view.usesTopoOrder, false)
        }
    }

    func testAnEmptyRepositoryShowsNoCommitsYetWithoutRunningGit() throws {
        try withWindow { c in
            c.sidebar.showHistory()
            let view = try XCTUnwrap(historyView(c))
            XCTAssertEqual(view.emptyMessage, "No commits yet")
            XCTAssertFalse(view.isLoading)
        }
    }

    func testHistoryReloadsWhenHeadMovesAndLazilyWhileHidden() throws {
        try commits(["one", "two"])
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            try commits(["three"])
            c.refreshGitStatus()
            spin { view.commits.count == 3 }
            XCTAssertEqual(view.commits.first?.subject, "three")

            c.sidebar.showChanges(true)
            try commits(["four"])
            c.refreshGitStatus()
            spin(2) { false }
            XCTAssertEqual(view.commits.count, 3, "a hidden History must not reload")
            c.sidebar.showHistory()
            spin { view.commits.count == 4 }
            XCTAssertEqual(view.commits.first?.subject, "four")
        }
    }

    func testSearchWaitsForTheTypingToPauseAndReturnSearchesAtOnce() throws {
        try commits(["alpha", "beta", "gamma"])
        try withWindow { c in
            let view = try showHistory(c, commits: 3)
            view.searchField.stringValue = "beta"
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertTrue(view.query.isEmpty, "searching must wait for a pause in typing")
            spin { view.commits.map(\.subject) == ["beta"] }
            XCTAssertEqual(view.commits.map(\.subject), ["beta"])
            XCTAssertFalse(view.style.showsGraph, "search results are a flat list")

            view.searchField.stringValue = "zzz"
            XCTAssertTrue(view.control(view.searchField.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(view.query.words, "zzz")
            spin { view.emptyMessage == "No matching commits" }
            XCTAssertEqual(view.emptyMessage, "No matching commits")

            XCTAssertTrue(view.control(view.searchField.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertEqual(view.searchField.stringValue, "")
            spin { view.commits.count == 3 }
            XCTAssertEqual(view.commits.count, 3)
            XCTAssertTrue(view.style.showsGraph)
        }
    }

    func testScrollingNearTheEndReadsTheNextPage() throws {
        let stream = (1...450).map { i in
            "commit refs/heads/main\nmark :\(i)\ncommitter t <t@example.com> \(1_700_000_000 + i) +0000\ndata \(String(i).utf8.count + 2)\nc\(i)\n" + (i > 1 ? "from :\(i - 1)\n" : "") + "\n"
        }.joined()
        try stream.write(to: base.appendingPathComponent("stream"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try shell("git fast-import --quiet < '\(base.appendingPathComponent("stream").path)' && git reset -q --hard main"), 0)
        try withWindow { c in
            let view = try showHistory(c, commits: HistoryView.pageSize)
            view.scrollToEnd()
            spin { view.commits.count == 2 * HistoryView.pageSize }
            XCTAssertEqual(view.commits.count, 2 * HistoryView.pageSize)
            view.scrollToEnd()
            spin { view.commits.count == 450 }
            XCTAssertEqual(view.commits.count, 450)
            XCTAssertEqual(Set(view.commits.map(\.sha)).count, 450, "pages must not repeat commits")
            XCTAssertEqual(view.commits.last?.subject, "c1")
        }
    }

    func testClickingACommitOpensItsOverviewInThePreviewTab() throws {
        try historyWithRenameBinaryAndDelete()
        try thirdCommitWithABody()
        try withWindow { c in
            let view = try showHistory(c, commits: 3)
            let start = c.activeGroup.tabs.count
            let ov = try openCommit(c, view, "rename and more")
            let doc = try XCTUnwrap(c.activeDocument)
            let commit = ov.model.commit
            XCTAssertTrue(doc.isReadOnly && doc.isTransient && doc.isHistoryPreview)
            XCTAssertEqual(doc.revisionKey, "\(commit.sha)::commit")
            XCTAssertEqual(doc.language.id, "diff")
            XCTAssertEqual(c.activeEditor?.showsCommitOverview, true)
            XCTAssertEqual(c.activeGroup.tabs.count, start + 1)
            XCTAssertEqual(ov.rows.count, 2 + ov.model.detail.files.count)
            XCTAssertTrue((doc.string as String).hasPrefix("commit \(commit.sha)\nAuthor: t <t@example.com>\nDate:   "))
            XCTAssertTrue((doc.string as String).contains("diff --git a/old.txt b/new.txt"))
            XCTAssertEqual(ov.model.patchLines.count, ov.model.detail.files.count)
            XCTAssertFalse(ov.model.patchTooLarge)
            let tab = try XCTUnwrap(c.activeGroup.tabBar.items.first { $0.title == doc.displayName })
            XCTAssertTrue(tab.tooltip.hasPrefix(commit.sha) && tab.tooltip.hasSuffix("rename and more"), tab.tooltip)

            // The card shows the author and message; a long body makes it taller.
            let card = try XCTUnwrap(ov.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CommitCardCell)
            XCTAssertTrue(card.accessibilityLabel()?.contains("rename and more, t,") == true, card.accessibilityLabel() ?? "")
            XCTAssertTrue(card.accessibilityLabel()?.hasSuffix("commit \(commit.shortSHA)") == true)
            let short = CommitCardCell.layout(for: ov.model, width: 700).total
            let third = try openCommit(c, view, "Third change")
            XCTAssertEqual(CommitCardCell.messageBody(third.model.detail), "First paragraph of the body.\n\nSecond paragraph.")
            XCTAssertGreaterThan(CommitCardCell.layout(for: third.model, width: 700).total, short)
        }
    }

    func testAnotherClickReplacesThePreviewAndPinningKeepsATab() throws {
        try historyWithRenameBinaryAndDelete()
        try thirdCommitWithABody()
        try withWindow { c in
            let view = try showHistory(c, commits: 3)
            let start = c.activeGroup.tabs.count
            let first = try openCommit(c, view, "rename and more")
            let firstDoc = try XCTUnwrap(c.activeDocument)
            try openCommit(c, view, "Third change")
            XCTAssertEqual(c.activeGroup.tabs.count, start + 1, "the second click replaces the preview")
            XCTAssertFalse(c.groups.flatMap { $0.tabs }.contains { $0.document === firstDoc })
            _ = first

            // Double-click or Return pins and focuses the list in the tab.
            try openCommit(c, view, "root", pinned: true)
            let pinned = try XCTUnwrap(c.activeDocument)
            XCTAssertFalse(pinned.isHistoryPreview)
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2)
            XCTAssertTrue(c.window?.firstResponder === c.activeEditor?.commitOverview?.table, "the overview's list should have focus")
            try openCommit(c, view, "rename and more")
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2, "the preview is reused beside the pinned tab")
            XCTAssertTrue(c.groups.flatMap { $0.tabs }.contains { $0.document === pinned })

            // Opening a commit that has a tab selects it.
            try openCommit(c, view, "root")
            XCTAssertTrue(c.activeDocument === pinned)
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2)
        }
    }

    func testArrowKeysOpenTheCommitWhereTheSelectionStops() throws {
        try historyWithRenameBinaryAndDelete()
        try thirdCommitWithABody()
        try withWindow { c in
            let view = try showHistory(c, commits: 3)
            let start = c.activeGroup.tabs.count
            for row in [0, 1, 2] {
                view.list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                view.selectionChanged(fromKeyboard: true)
            }
            XCTAssertEqual(c.activeGroup.tabs.count, start, "nothing opens while the arrow key is still moving")
            spin { c.activeDocument?.commitOverview != nil }
            XCTAssertEqual(c.activeDocument?.commitOverview?.commit.subject, "root")
            spin(1) { false }
            XCTAssertEqual(c.activeGroup.tabs.count, start + 1, "only the commit where it stopped opened")

            // Choosing from the mouse is not delayed, and a selection from the mouse never schedules one.
            view.list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            view.selectionChanged(fromKeyboard: false)
            spin(1) { false }
            XCTAssertEqual(c.activeDocument?.commitOverview?.commit.subject, "root")
        }
    }

    func testEverySectionLineStartsTheFileItNames() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            let doc = try XCTUnwrap(c.activeDocument)
            for (i, file) in ov.model.detail.files.enumerated() {
                let range = doc.lines.range(of: ov.model.patchLines[i], textLength: doc.length)
                let line = (doc.string as NSString).substring(with: range)
                XCTAssertTrue(line.hasPrefix("diff --git "), line)
                // Git quotes and escapes names with tabs or non-ASCII characters in this header.
                XCTAssertTrue(line.contains(file.path) || line.hasPrefix("diff --git \"a/"), "\(line) should name \(file.path)")
            }
        }
    }

    func testClickingAFileShowsItsSectionOfThePatchAtTheTop() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            let editor = try XCTUnwrap(c.activeEditor)
            let doc = try XCTUnwrap(c.activeDocument)
            let index = 2
            ov.selectFile(index)
            XCTAssertEqual(ov.selectedFileIndex, index)
            ov.table.onReturn?(false)
            XCTAssertFalse(editor.showsCommitOverview)
            XCTAssertTrue(ov.isHidden)
            let start = doc.lines.start(of: ov.model.patchLines[index])
            XCTAssertTrue(NSLocationInRange(start, editor.textView.visibleCharacterRange), "the file's section should be on screen")
            XCTAssertLessThanOrEqual(editor.textView.visibleCharacterRange.location, start)
            XCTAssertEqual(editor.topVisibleLine, ov.model.patchLines[index], accuracy: 1)
            // The tab bar's Overview button goes back.
            toolButton(c, startingWith: "Overview")?.onClick?()
            XCTAssertTrue(editor.showsCommitOverview)
        }
    }

    func testTheAccessoryButtonsSwitchBetweenOverviewAndPatch() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            try openCommit(c, view, "rename and more")
            let overview = try XCTUnwrap(toolButton(c, startingWith: "Overview"))
            let patch = try XCTUnwrap(toolButton(c, startingWith: "Patch"))
            XCTAssertFalse(overview.isHidden || patch.isHidden)
            XCTAssertEqual(overview.toolTip, "Overview\nThe commit’s message and changed files.")
            XCTAssertEqual(patch.toolTip, "Patch\nEvery change in this commit. Find and copy work here.")
            XCTAssertTrue(overview.isOn && !patch.isOn)
            patch.onClick?()
            XCTAssertEqual(c.activeEditor?.showsCommitOverview, false)
            XCTAssertTrue(patch.isOn && !overview.isOn)
            overview.onClick?()
            XCTAssertEqual(c.activeEditor?.showsCommitOverview, true)
            XCTAssertTrue(overview.isOn && !patch.isOn)
            // Plain files show neither.
            _ = c.open(url: dir.appendingPathComponent("keep.txt"))
            XCTAssertTrue(toolButton(c, startingWith: "Overview")?.isHidden == true)
        }
    }

    func testFindAndGoToLineSwitchTheOverviewToThePatch() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            try openCommit(c, view, "rename and more")
            let editor = try XCTUnwrap(c.activeEditor)
            editor.showFindBar(replace: false)
            XCTAssertFalse(editor.showsCommitOverview)
            XCTAssertEqual(editor.findBar?.isHidden, false)
            editor.setShowsCommitOverview(true)
            XCTAssertTrue(editor.findBar?.isHidden ?? true, "the find bar closes with the overview")
            editor.goTo(line: 3)
            XCTAssertFalse(editor.showsCommitOverview)
        }
    }

    func testOpeningAFilesChangesFromTheOverviewPinsTheCommitTab() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let start = c.activeGroup.tabs.count
            let ov = try openCommit(c, view, "rename and more")
            let commitDoc = try XCTUnwrap(c.activeDocument)
            XCTAssertTrue(commitDoc.isHistoryPreview)
            ov.selectFile(try fileIndex(ov, "new.txt"))
            ov.table.onReturn?(true)
            spin { c.activeEditor?.comparisonLabel != nil && c.activeEditor?.inlineDiff != nil }
            let doc = try XCTUnwrap(c.activeDocument)
            XCTAssertTrue(doc.isReadOnly && doc.isTransient && doc.isHistoryPreview)
            XCTAssertEqual(doc.revisionKey?.hasSuffix(":new.txt:changes"), true)
            XCTAssertFalse(commitDoc.isHistoryPreview, "using the commit tab keeps it")
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2)
            XCTAssertTrue(c.groups.flatMap { $0.tabs }.contains { $0.document === commitDoc })
            let editor = try XCTUnwrap(c.activeEditor)
            XCTAssertEqual(editor.comparisonSource, .commit)
            XCTAssertEqual(editor.inlineDiff?.added, 1)
            XCTAssertEqual(editor.inlineDiff?.deleted, 1)
            XCTAssertTrue(c.statusBar.flashText?.contains("+1 −1 in new.txt") == true, c.statusBar.flashText ?? "")
            // Restore This Version stays off for a read-only document.
            let restore = NSMenuItem(title: "Restore", action: #selector(MainWindowController.restoreComparedVersion(_:)), keyEquivalent: "")
            XCTAssertEqual(c.validateComparisonItem(restore), false)
        }
    }

    func testDeletedAddedAndBinaryFilesOpenFromTheOverview() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            func open(_ path: String) throws {
                ov.onAction?(.openFile(ov.model.detail.files[try fileIndex(ov, path)], .changes, pinned: false))
            }
            try open("del.txt")
            spin { c.activeEditor?.inlineDiff != nil && c.activeDocument?.displayName.hasSuffix("(deleted)") == true }
            XCTAssertTrue(c.activeDocument?.displayName.hasSuffix("(deleted)") == true, c.activeDocument?.displayName ?? "")
            XCTAssertEqual(c.activeDocument?.length, 0)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.deleted, 1)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.added, 0)

            try open("with space.txt")
            spin { c.activeDocument?.displayName.hasPrefix("with space.txt") == true && c.activeEditor?.inlineDiff?.added == 1 }
            XCTAssertEqual(c.activeEditor?.inlineDiff?.added, 1)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.deleted, 0)

            let tabs = c.activeGroup.tabs.count
            try open("bin.dat")
            spin { c.statusBar.flashText?.contains("isn’t a text file") == true }
            XCTAssertEqual(c.statusBar.flashText, "“bin.dat” isn’t a text file")
            XCTAssertEqual(c.activeGroup.tabs.count, tabs)
        }
    }

    func testOpeningAFileAsAPatchAndAsItWasFromTheOverview() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            let renamed = ov.model.detail.files[try fileIndex(ov, "new.txt")]
            let log = ov.model.commit
            ov.onAction?(.openFile(renamed, .patch, pinned: true))
            spin { c.activeDocument?.displayName == "new.txt @ \(log.shortSHA) — Patch" }
            let doc = try XCTUnwrap(c.activeDocument)
            XCTAssertEqual(doc.language.id, "diff")
            XCTAssertTrue((doc.string as String).contains("rename from old.txt"))
            XCTAssertTrue(doc.isReadOnly && !doc.isHistoryPreview)

            ov.onAction?(.openFile(renamed, .file, pinned: true))
            spin { c.activeDocument?.displayName == "new.txt @ \(log.shortSHA)" }
            XCTAssertEqual(c.activeDocument?.revisionKey, "\(log.sha):new.txt:file")
            XCTAssertTrue((c.activeDocument?.string as String?)?.contains("line five") == true)
            XCTAssertFalse(c.activeEditor?.isComparing == true)
        }
    }

    func testCompareWithCurrentFileWorksFromTheOverview() throws {
        try historyWithRenameBinaryAndDelete()
        try write("line 1\nchanged now\n", "keep.txt")
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "root")
            ov.onAction?(.compareWithCurrent(ov.model.detail.files[try fileIndex(ov, "keep.txt")]))
            spin { c.activeEditor?.comparisonSource != nil }
            XCTAssertEqual(c.activeEditor?.comparisonSource, .commit)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "keep.txt")
        }
    }

    func testAParentLinkOpensTheParentCommit() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            let doc = try XCTUnwrap(c.activeDocument)
            let parent = try XCTUnwrap(ov.model.commit.parents.first)
            ov.onOpenParent?(parent)
            spin { c.activeDocument?.commitOverview?.commit.sha == parent }
            XCTAssertEqual(c.activeDocument?.commitOverview?.commit.subject, "root")
            XCTAssertFalse(doc.isHistoryPreview, "following a link keeps the tab it came from")
            XCTAssertTrue(c.groups.flatMap { $0.tabs }.contains { $0.document === doc })
        }
    }

    func testAMergeCommitsOverviewNamesBothParents() throws {
        try historyWithRenameBinaryAndDelete()
        try shell("git switch -q -c side HEAD~1 && echo side > side.txt && git add -A && \(commit) -m side")
        try shell("git switch -q main && echo main > main.txt && git add -A && \(commit) -m mainline")
        try shell("git merge -q --no-ff side -m 'Merge side'")
        try withWindow { c in
            let view = try showHistory(c, commits: 5)
            let ov = try openCommit(c, view, "Merge side")
            XCTAssertEqual(ov.model.commit.parents.count, 2)
            XCTAssertTrue((c.activeDocument?.string as String?)?.contains("\nMerge: ") == true)
            XCTAssertTrue(ov.model.detail.files.contains { $0.path == "side.txt" })
        }
    }

    func testAnOversizedPatchStillListsTheFiles() throws {
        try historyWithRenameBinaryAndDelete()
        let repo = try repo()
        let all = log(repo)
        let d = try XCTUnwrap(detail(repo, all[0]))
        let built = MainWindowController.commitText(detail: d, patch: nil)
        XCTAssertTrue(built.tooLarge)
        XCTAssertEqual(built.patchLines, [])
        XCTAssertTrue(built.text.hasSuffix("The patch for this commit is too large to show here (over 20 MB).\n"), built.text)
        let model = CommitOverviewModel(repoRoot: repo.root, commit: all[0], detail: d, patchLines: built.patchLines, patchTooLarge: built.tooLarge)
        let view = CommitOverviewView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.rows.count, 2 + d.files.count)
        var shown: Int?
        view.onShowPatch = { shown = $0 }
        view.selectFile(1)
        view.table.onReturn?(false)
        XCTAssertEqual(shown, 1)
    }

    func testACommitTabMovedToAnotherGroupStillShowsItsOverview() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            try openCommit(c, view, "rename and more", pinned: true)
            c.splitTabRight(nil)
            c.rootView.layoutSubtreeIfNeeded()
            XCTAssertEqual(c.groups.count, 2)
            let editor = try XCTUnwrap(c.activeEditor)
            XCTAssertTrue(editor.hasCommitOverview && editor.showsCommitOverview)
            XCTAssertEqual(c.activeDocument?.commitOverview?.commit.subject, "rename and more")
            XCTAssertGreaterThan(editor.commitOverview?.table.numberOfRows ?? 0, 2)
        }
    }

    func testAThemeChangeRestylesTheOverview() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let ov = try openCommit(c, view, "rename and more")
            let rows = ov.table.numberOfRows
            for name in ["Tovri Day", "Tovri Dark"] {
                ThemeManager.shared.preview(try XCTUnwrap(ThemeManager.shared.theme(named: name)))
                c.rootView.layoutSubtreeIfNeeded()
                XCTAssertEqual(ov.table.numberOfRows, rows)
                XCTAssertNotNil(ov.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            }
            ThemeManager.shared.preview(nil)
        }
    }

    func testTheSidebarListHasNoExpandedRowsAndItsMenuOffersCommitActions() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            XCTAssertEqual(view.list.numberOfRows, 2)
            XCTAssertTrue(items(view).allSatisfy { $0.kind == .commit })
        }
    }

    func testCommitDetailCacheKeepsTheMostRecentlyUsed() {
        var cache = CommitDetailCache()
        func make(_ i: Int) -> GitRepository.CommitDetail {
            GitRepository.CommitDetail(sha: "sha\(i)", parents: [], authorName: "", authorEmail: "", authorDate: Date(), committerName: "",
                                       commitDate: Date(), message: "", files: [], hiddenFileCount: 0)
        }
        for i in 0..<CommitDetailCache.capacity { cache.insert(make(i)) }
        XCTAssertNotNil(cache.detail(for: "sha0"))
        cache.insert(make(1000))
        XCTAssertEqual(cache.count, CommitDetailCache.capacity)
        XCTAssertNotNil(cache.detail(for: "sha0"), "a recently read detail stays")
        XCTAssertNil(cache.detail(for: "sha1"), "the least recently used one goes")
    }

    func testAvatarsAreStableAndTakeUpToTwoInitials() {
        XCTAssertEqual(AvatarView.initials(name: "Rahat Sagor", email: "r@x"), "RS")
        XCTAssertEqual(AvatarView.initials(name: "ann", email: "a@x"), "A")
        XCTAssertEqual(AvatarView.initials(name: "Ann Marie Lee", email: "a@x"), "AM")
        XCTAssertEqual(AvatarView.initials(name: "", email: "zed@x"), "Z")
        XCTAssertEqual(AvatarView.stableIndex("Ann@X.com", count: 8), AvatarView.stableIndex("ann@x.com", count: 8))
        XCTAssertTrue((0..<8).contains(AvatarView.stableIndex("whoever@example.com", count: 8)))
    }

    func testCommitPatchHeaderMarksMerges() {
        let detail = GitRepository.CommitDetail(sha: String(repeating: "a", count: 40), parents: ["1234567890", "abcdefabcdef"], authorName: "Ann",
                                                authorEmail: "ann@x", authorDate: Date(timeIntervalSince1970: 0), committerName: "Ann",
                                                commitDate: Date(timeIntervalSince1970: 0), message: "Subject\n\nBody line", files: [], hiddenFileCount: 0)
        let header = MainWindowController.commitPatchHeader(detail)
        XCTAssertTrue(header.contains("\nMerge: 1234567 abcdefa\n"))
        XCTAssertTrue(header.contains("Author: Ann <ann@x>\n"))
        XCTAssertTrue(header.hasSuffix("\n\n    Subject\n\n    Body line\n\n"), header)
    }
}

/// Opt-in: `TOVRI_RUN_BENCHMARKS=1 swift test -c release --filter GitHistoryBenchmark`.
final class GitHistoryBenchmarkTests: XCTestCase {
    func testHistoryReadsOnALargeRepository() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOVRI_RUN_BENCHMARKS"] == "1",
                          "Set TOVRI_RUN_BENCHMARKS=1 to run the History benchmarks")
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-history-bench-\(UUID().uuidString)").resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let saved = GitRepository.userEnvironment
        GitRepository.userEnvironment = ["HOME": base.path]
        defer { GitRepository.userEnvironment = saved }

        func shell(_ command: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = dir
            p.environment = ["HOME": base.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, command)
        }

        // 50,000 commits on main, and a side commit merged back in after every tenth.
        let count = 50_000
        var stream = ""
        stream.reserveCapacity(count * 220)
        var lastMain = 0
        var mark = 0
        for i in 1...count {
            var merge: Int?
            if i % 10 == 0 {
                mark += 1
                let side = mark
                stream += "commit refs/heads/side\nmark :\(side)\ncommitter t <t@example.com> \(1_600_000_000 + i) +0000\ndata 5\nside\n"
                stream += lastMain > 0 ? "from :\(lastMain)\n" : ""
                stream += "M 644 inline side.txt\ndata 2\n\(i % 10)\n\n"
                merge = side
            }
            mark += 1
            stream += "commit refs/heads/main\nmark :\(mark)\ncommitter t <t@example.com> \(1_600_000_000 + i) +0000\ndata \(String(i).utf8.count + 2)\nc\(i)\n"
            if lastMain > 0 { stream += "from :\(lastMain)\n" }
            if let merge { stream += "merge :\(merge)\n" }
            stream += "M 644 inline f.txt\ndata \(String(i).utf8.count)\n\(i)\n\n"
            lastMain = mark
        }
        try stream.write(to: base.appendingPathComponent("stream"), atomically: true, encoding: .utf8)
        try shell("git init -q -b main . && git fast-import --quiet < '\(base.appendingPathComponent("stream").path)' && git reset -q --hard main")

        func time<T>(_ label: String, _ body: () -> T) -> T {
            let start = CFAbsoluteTimeGetCurrent()
            let value = body()
            print(String(format: "[history-bench] %@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - start) * 1000))
            return value
        }
        func page(_ repo: GitRepository, limit: Int, topo: Bool) -> [LogCommit] {
            var result: [LogCommit] = []
            let done = expectation(description: "log")
            repo.log(from: "HEAD", query: HistoryQuery(), skip: 0, limit: limit, topoOrder: topo, cancellation: nil) { result = $0 ?? []; done.fulfill() }
            wait(for: [done], timeout: 120)
            return result
        }

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("x")))
        try shell("rm -rf .git/objects/info/commit-graph .git/objects/info/commit-graphs")
        XCTAssertFalse(repo.hasCommitGraph)
        print("[history-bench] commits: \(count + count / 10)")
        for topo in [false, true] {
            let first = time("first page, no commit-graph, topo-order \(topo)") { page(repo, limit: HistoryView.pageSize, topo: topo) }
            XCTAssertEqual(first.count, HistoryView.pageSize)
        }
        try shell("git commit-graph write --reachable")
        XCTAssertTrue(repo.hasCommitGraph)
        for topo in [false, true] {
            let first = time("first page, commit-graph, topo-order \(topo)") { page(repo, limit: HistoryView.pageSize, topo: topo) }
            XCTAssertEqual(first.count, HistoryView.pageSize)
        }

        let five = page(repo, limit: HistoryView.maxCommits, topo: true)
        XCTAssertEqual(five.count, HistoryView.maxCommits)
        var rows: [CommitGraph.Row] = []
        time("CommitGraph.layout of \(five.count) commits") {
            var state = CommitGraph.State()
            rows = CommitGraph.layout(five, state: &state)
        }
        XCTAssertEqual(rows.count, five.count)

        try shell("mkdir many && for i in $(seq 1 1000); do echo $i > many/f$i.txt; done && git add -A && git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -q -m 'a thousand files'")
        let big = page(repo, limit: 1, topo: false)[0]
        let opened = CFAbsoluteTimeGetCurrent()
        var detail: GitRepository.CommitDetail?
        var patch: String?
        let both = expectation(description: "open commit")
        both.expectedFulfillmentCount = 2
        repo.commitDetail(sha: big.sha, parents: big.parents) { detail = $0; both.fulfill() }
        repo.commitPatch(sha: big.sha, parent: big.parents.first, paths: nil) { patch = $0; both.fulfill() }
        wait(for: [both], timeout: 60)
        let built = MainWindowController.commitText(detail: try XCTUnwrap(detail), patch: patch)
        let model = CommitOverviewModel(repoRoot: repo.root, commit: big, detail: try XCTUnwrap(detail), patchLines: built.patchLines)
        print(String(format: "[history-bench] open a 1,000-file commit tab (detail + patch + model): %.1f ms", (CFAbsoluteTimeGetCurrent() - opened) * 1000))
        XCTAssertEqual(model.detail.files.count, 1_000)
        XCTAssertEqual(model.patchLines.count, 1_000)

        let target = five[2_500]
        time("commitDetail") {
            let done = expectation(description: "detail")
            repo.commitDetail(sha: target.sha, parents: target.parents) { XCTAssertNotNil($0); done.fulfill() }
            wait(for: [done], timeout: 60)
        }
    }
}
