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

    /// Expands the commit and returns its file rows.
    private func expand(_ view: HistoryView, _ subject: String) throws -> [HistoryItem] {
        let item = try commitItem(view, subject)
        view.activate(item, pinned: false)
        spin { self.items(view).contains { $0.kind == .file || $0.kind == .moreFiles } }
        return items(view).filter { $0.kind == .file }
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
        controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
        controller.rootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabs()?.isHidden, true, "off by default")
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

    func testExpandingACommitListsItsFilesAndCachesTheDetail() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let files = try expand(view, "rename and more")
            XCTAssertTrue(files.map { $0.file?.path ?? "" }.contains("new.txt"))
            let summary = try XCTUnwrap(items(view).first { $0.kind == .summary })
            XCTAssertEqual(summary.detail?.message, "rename and more")
            XCTAssertEqual(view.cachedDetailCount, 1)
            let commit = try commitItem(view, "rename and more")
            // Collapsing releases the rows but not the cached detail.
            view.activate(commit, pinned: false)
            XCTAssertTrue(items(view).allSatisfy { $0.kind == .commit })
            view.activate(commit, pinned: false)
            spin { self.items(view).contains { $0.kind == .file } }
            XCTAssertEqual(view.cachedDetailCount, 1)
        }
    }

    func testOpeningAFilesChangesShowsAReadOnlyTransientComparison() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let files = try expand(view, "rename and more")
            let renamed = try XCTUnwrap(files.first { $0.file?.path == "new.txt" })
            view.activate(renamed, pinned: false)
            spin { c.activeEditor?.comparisonLabel != nil && c.activeEditor?.inlineDiff != nil }
            let doc = try XCTUnwrap(c.activeDocument)
            XCTAssertTrue(doc.isReadOnly && doc.isTransient && doc.isHistoryPreview)
            XCTAssertTrue(doc.displayName.hasPrefix("new.txt @ "), doc.displayName)
            XCTAssertEqual(doc.revisionKey?.hasSuffix(":new.txt:changes"), true)
            let editor = try XCTUnwrap(c.activeEditor)
            XCTAssertTrue(editor.isComparing)
            XCTAssertEqual(editor.comparisonSource, .commit)
            XCTAssertEqual(editor.inlineDiff?.added, 1)
            XCTAssertEqual(editor.inlineDiff?.deleted, 1)
            XCTAssertTrue((doc.string as String).contains("line five"))
            XCTAssertTrue(c.statusBar.flashText?.contains("+1 −1 in new.txt") == true, c.statusBar.flashText ?? "")

            // Restore This Version stays off for a read-only document.
            let restore = NSMenuItem(title: "Restore", action: #selector(MainWindowController.restoreComparedVersion(_:)), keyEquivalent: "")
            XCTAssertEqual(c.validateComparisonItem(restore), false)
            c.restoreComparedVersion(nil)
            XCTAssertTrue((doc.string as String).contains("line five"))
        }
    }

    func testSingleClicksShareOnePreviewTabAndPinnedTabsStay() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let files = try expand(view, "rename and more")
            let byPath = Dictionary(uniqueKeysWithValues: files.compactMap { i in i.file.map { ($0.path, i) } })
            let start = c.activeGroup.tabs.count
            view.activate(try XCTUnwrap(byPath["new.txt"]), pinned: false)
            spin { c.activeGroup.tabs.count == start + 1 && c.activeEditor?.inlineDiff != nil }
            XCTAssertEqual(c.activeGroup.tabs.count, start + 1)
            view.activate(try XCTUnwrap(byPath["keep.txt"] ?? byPath["with space.txt"]), pinned: false)
            spin { c.activeDocument?.displayName.hasPrefix("with space.txt") == true || c.activeDocument?.displayName.hasPrefix("keep.txt") == true }
            XCTAssertEqual(c.activeGroup.tabs.count, start + 1, "a second click must replace the preview, not add a tab")
            XCTAssertEqual(c.activeDocument?.displayName.hasPrefix("with space.txt"), true)
            XCTAssertEqual(tabNames(c).filter { $0.contains(" @ ") }.count, 1)

            // Pinned keeps its tab, and the next click gets a new preview.
            view.activate(try XCTUnwrap(byPath["ünï.txt"]), pinned: true)
            spin { c.activeDocument?.displayName.hasPrefix("ünï.txt") == true }
            let pinned = try XCTUnwrap(c.activeDocument)
            XCTAssertFalse(pinned.isHistoryPreview)
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2, "a pinned open adds a tab and leaves the preview alone")
            view.activate(try XCTUnwrap(byPath["[ab].txt"]), pinned: false)
            spin { c.activeDocument?.displayName.hasPrefix("[ab].txt") == true }
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2, "the next click replaces the preview and keeps the pinned tab")
            XCTAssertTrue(c.groups.flatMap { $0.tabs }.contains { $0.document === pinned })
            XCTAssertFalse(tabNames(c).contains { $0.hasPrefix("with space.txt") })

            // Opening again selects the tab that has it.
            view.activate(try XCTUnwrap(byPath["ünï.txt"]), pinned: false)
            spin { c.activeDocument === pinned }
            XCTAssertTrue(c.activeDocument === pinned)
            XCTAssertEqual(c.activeGroup.tabs.count, start + 2)
        }
    }

    func testDeletedAddedAndBinaryFilesOpenAsTheirChanges() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let files = try expand(view, "rename and more")
            let byPath = Dictionary(uniqueKeysWithValues: files.compactMap { i in i.file.map { ($0.path, i) } })

            view.activate(try XCTUnwrap(byPath["del.txt"]), pinned: false)
            spin { c.activeEditor?.inlineDiff != nil && c.activeDocument?.displayName.hasSuffix("(deleted)") == true }
            XCTAssertTrue(c.activeDocument?.displayName.hasSuffix("(deleted)") == true, c.activeDocument?.displayName ?? "")
            XCTAssertEqual(c.activeDocument?.length, 0)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.deleted, 1)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.added, 0)

            view.activate(try XCTUnwrap(byPath["with space.txt"]), pinned: false)
            spin { c.activeDocument?.displayName.hasPrefix("with space.txt") == true && c.activeEditor?.inlineDiff?.added == 1 }
            XCTAssertEqual(c.activeEditor?.inlineDiff?.added, 1)
            XCTAssertEqual(c.activeEditor?.inlineDiff?.deleted, 0)

            let tabs = c.activeGroup.tabs.count
            view.activate(try XCTUnwrap(byPath["bin.dat"]), pinned: false)
            spin { c.statusBar.flashText?.contains("isn’t a text file") == true }
            XCTAssertEqual(c.statusBar.flashText, "“bin.dat” isn’t a text file")
            XCTAssertEqual(c.activeGroup.tabs.count, tabs)
            XCTAssertTrue(c.activeDocument?.displayName.hasPrefix("with space.txt") == true)
        }
    }

    func testOpeningAFileAsAPatchAndAsItWas() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let files = try expand(view, "rename and more")
            let renamed = try XCTUnwrap(files.first { $0.file?.path == "new.txt" }?.file)
            let log = view.commits.first { $0.subject == "rename and more" }!
            c.sidebar(c.sidebar, commit: log, detail: nil, action: .openFile(renamed, .patch, pinned: true))
            spin { c.activeDocument?.displayName == "new.txt @ \(log.shortSHA) — Patch" }
            let doc = try XCTUnwrap(c.activeDocument)
            XCTAssertEqual(doc.language.id, "diff")
            XCTAssertTrue((doc.string as String).contains("rename from old.txt"))
            XCTAssertTrue(doc.isReadOnly && !doc.isHistoryPreview)

            c.sidebar(c.sidebar, commit: log, detail: nil, action: .openFile(renamed, .file, pinned: true))
            spin { c.activeDocument?.displayName == "new.txt @ \(log.shortSHA)" }
            XCTAssertEqual(c.activeDocument?.revisionKey, "\(log.sha):new.txt:file")
            XCTAssertTrue((c.activeDocument?.string as String?)?.contains("line five") == true)
            XCTAssertFalse(c.activeEditor?.isComparing == true)
        }
    }

    func testOpeningACommitAsAPatchShowsItsHeaderAndDiff() throws {
        try historyWithRenameBinaryAndDelete()
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let item = try commitItem(view, "rename and more")
            let commit = try XCTUnwrap(item.commit)
            view.activate(item, pinned: true)
            spin { c.activeDocument?.revisionKey == "\(commit.sha)::patch" }
            let doc = try XCTUnwrap(c.activeDocument)
            let text = doc.string as String
            XCTAssertTrue(text.hasPrefix("commit \(commit.sha)\nAuthor: t <t@example.com>\nDate:   "), String(text.prefix(120)))
            XCTAssertTrue(text.contains("\n\n    rename and more\n"))
            XCTAssertTrue(text.contains("diff --git a/old.txt b/new.txt"))
            XCTAssertEqual(doc.language.id, "diff")
            XCTAssertTrue(doc.displayName.hasPrefix("\(commit.shortSHA) — rename and more"))
            XCTAssertTrue(doc.isReadOnly && doc.isTransient && !doc.isHistoryPreview)
        }
    }

    func testCompareWithCurrentFileComparesTheWorkingFileWithTheCommit() throws {
        try historyWithRenameBinaryAndDelete()
        try write("line 1\nchanged now\n", "keep.txt")
        try withWindow { c in
            let view = try showHistory(c, commits: 2)
            let log = try XCTUnwrap(view.commits.last)
            let file = GitRepository.CommitFile(path: "keep.txt", originalPath: nil, status: .added, added: 1, removed: 0)
            c.sidebar(c.sidebar, commit: log, detail: nil, action: .compareWithCurrent(file))
            spin { c.activeEditor?.comparisonSource != nil }
            XCTAssertEqual(c.activeEditor?.comparisonSource, .commit)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "keep.txt")
        }
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

        let target = five[2_500]
        time("commitDetail") {
            let done = expectation(description: "detail")
            repo.commitDetail(sha: target.sha, parents: target.parents) { XCTAssertNotNil($0); done.fulfill() }
            wait(for: [done], timeout: 60)
        }
    }
}
