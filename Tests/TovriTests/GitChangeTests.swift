import AppKit
import XCTest
@testable import Tovri

final class GitChangeTests: XCTestCase {
    private let pairs: [(String, String)] = [
        ("a\nb\nc\n", "a\nB\nc\n"),
        ("a\nb\nc\n", "a\nb\nx\ny\nc\n"),
        ("a\nb\nc\n", "a\nc\n"),
        ("a\nb", "a"),
        ("a", "a\nb"),
        ("a\nx", "a\ny"),
        ("x\na\n", "a\n"),
        ("a\n", "b\na\n"),
        ("", "hello\n"),
        ("hello\n", ""),
        ("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n", "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\nEIGHT\nnine\n"),
        ("keep\nold 1\nold 2\nkeep\n", "keep\nnew\nkeep\nadded\n"),
    ]

    private func lines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }

    private func revert(_ hunk: DiffHunk, in text: String) -> String {
        let index = LineIndex()
        let ns = text as NSString
        index.rebuild(from: ns)
        let edit = EditorView.revertEdit(for: hunk, lines: index, length: ns.length)
        return ns.replacingCharacters(in: edit.range, with: edit.text)
    }

    func testRevertingEachHunkRemovesExactlyThatChange() {
        for (old, new) in pairs {
            let hunks = GitRepository.diff(old: lines(old), new: lines(new)).hunks
            XCTAssertFalse(hunks.isEmpty, "\(old.debugDescription) → \(new.debugDescription)")
            for h in hunks {
                let result = revert(h, in: new)
                let remaining = GitRepository.diff(old: lines(old), new: lines(result)).hunks
                XCTAssertEqual(remaining.count, hunks.count - 1, "Reverting \(h) in \(new.debugDescription) gave \(result.debugDescription)")
            }
        }
    }

    func testRevertingAllHunksFromTheEndRestoresHead() {
        for (old, new) in pairs {
            var text = new
            for h in GitRepository.diff(old: lines(old), new: lines(new)).hunks.reversed() { text = revert(h, in: text) }
            XCTAssertEqual(text, old, "\(old.debugDescription) → \(new.debugDescription)")
        }
    }

    func testHunkLookupAndNavigationWrap() {
        let diff = GitRepository.diff(old: lines("a\nb\nc\nd\ne\n"), new: lines("A\nb\nc\nd\nE\n"))
        XCTAssertEqual(diff.hunks.map(\.newStart), [0, 4])
        XCTAssertEqual(diff.hunk(at: 0, lineCount: 6)?.oldLines, ["a"])
        XCTAssertNil(diff.hunk(at: 2, lineCount: 6))
        XCTAssertEqual(diff.nextHunk(from: 0, forward: true, lineCount: 6)?.newStart, 4)
        XCTAssertEqual(diff.nextHunk(from: 4, forward: true, lineCount: 6)?.newStart, 0)
        XCTAssertEqual(diff.nextHunk(from: 4, forward: false, lineCount: 6)?.newStart, 0)
        XCTAssertEqual(diff.nextHunk(from: 0, forward: false, lineCount: 6)?.newStart, 4)
    }

    func testDeletionAfterTheLastLineIsFoundOnTheLastLine() {
        let diff = GitRepository.diff(old: lines("a\nb"), new: lines("a"))
        XCTAssertEqual(diff.hunk(at: 0, lineCount: 1)?.oldLines, ["b"])
    }

    func testUnifiedDiffMatchesGitFormat() {
        XCTAssertEqual(GitRepository.unifiedDiff(old: "a\nb\nc\n", new: "a\nB\nc\n", path: "f.txt"),
                       "--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
        XCTAssertEqual(GitRepository.unifiedDiff(old: "", new: "x\n", path: "new.txt"),
                       "--- a/new.txt\n+++ b/new.txt\n@@ -0,0 +1 @@\n+x\n")
        XCTAssertEqual(GitRepository.unifiedDiff(old: "same\n", new: "same\n", path: "f"), "")
    }

    func testUnifiedDiffMarksAMissingFinalNewline() {
        XCTAssertEqual(GitRepository.unifiedDiff(old: "a\nb\n", new: "a\nb", path: "f"),
                       "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+b\n\\ No newline at end of file\n")
    }

    func testNextChangeWrapsPastADeletionAtTheEnd() {
        let diff = GitRepository.diff(old: lines("a\nb\nc"), new: lines("A\nb"))
        let count = 2
        var line = 0
        var visited: [Int] = []
        for _ in 0..<4 {
            guard let h = diff.nextHunk(from: line, forward: true, lineCount: count) else { break }
            line = min(h.newStart, count - 1)
            visited.append(line)
        }
        XCTAssertEqual(visited, [1, 0, 1, 0])
    }

    func testUnifiedDiffSplitsDistantChangesIntoSeparateHunks() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...20).map { "line \($0)" }
        newLines[1] = "changed 2"
        newLines[18] = "changed 19"
        let diff = GitRepository.unifiedDiff(old: old, new: newLines.joined(separator: "\n") + "\n", path: "f")
        let headers = diff.split(separator: "\n").filter { $0.hasPrefix("@@") }
        XCTAssertEqual(headers, ["@@ -1,5 +1,5 @@", "@@ -16,5 +16,5 @@"])
    }

    func testStatusSkipsTheOldPathOfRenamesAndCopiesInEitherColumn() {
        let entries = ["R  new.txt", "old.txt", " R moved.txt", "was.txt", "C  copy.txt", "orig.txt",
                       " M edited.txt", "?? fresh.txt", "UU both.txt"]
        let status = GitRepository.parseStatus(Data((entries.joined(separator: "\0") + "\0").utf8))
        XCTAssertEqual(status.count, 6)
        XCTAssertEqual(status["new.txt"], .renamed)
        XCTAssertEqual(status["moved.txt"], .renamed)
        XCTAssertEqual(status["copy.txt"], .added)
        XCTAssertEqual(status["edited.txt"], .modified)
        XCTAssertEqual(status["fresh.txt"], .untracked)
        XCTAssertEqual(status["both.txt"], .conflicted)
        XCTAssertNil(status["old.txt"])
        XCTAssertNil(status["was.txt"])
        XCTAssertNil(status["orig.txt"])
    }

    func testCommandsThatRunTooLongAreStopped() {
        let start = Date()
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["10"], environment: [:], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(GitRepository.runProcess(URL(fileURLWithPath: "/bin/echo"), ["hi"], environment: [:]), Data("hi\n".utf8))
        XCTAssertNil(GitRepository.runProcess(URL(fileURLWithPath: "/usr/bin/false"), [], environment: [:]))
    }

    func testARepositoryIsForgottenOnceItsGitFolderIsGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-find-\(UUID().uuidString)").resolvingSymlinksInPath()
        let dotGit = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        XCTAssertEqual(GitRepository.find(for: file)?.root.path, dir.standardizedFileURL.path)
        try FileManager.default.removeItem(at: dotGit)
        XCTAssertNil(GitRepository.find(for: file))
    }

    private func makeRepository(committed: String, current: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-hunks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("f.txt")
        try committed.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "git init -q . && git add f.txt && git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm init"]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try current.write(to: file, atomically: true, encoding: .utf8)
        return dir
    }

    private func waitForHunks(_ doc: Document, count: Int) {
        let deadline = Date().addingTimeInterval(10)
        while doc.gitDiff.hunks.count != count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testChangeNavigationStartsFromTheShownChangeAndTheCardFitsItsText() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let committed = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = committed.split(separator: "\n").map(String.init)
        lines[4] = "line five, rewritten with enough words to need a wide popover"
        lines.insert("an added line", at: 5)
        lines[20] = "LINE 21"
        let dir = try makeRepository(committed: committed, current: lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
        controller.rootView.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(controller.activeEditor)
        doc.refreshGitBaseline()
        waitForHunks(doc, count: 2)
        let hunks = doc.gitDiff.hunks
        XCTAssertEqual(hunks.map(\.newStart), [4, 20])
        XCTAssertEqual(GitChangeCard.summary(of: hunks[0]), "Changed · 1 line → 2 lines")
        XCTAssertEqual(GitChangeCard.summary(of: hunks[1]), "Changed · 1 line → 1 line")

        // The caret stays on line 1, as after clicking a gutter marker.
        editor.textView.setAllSelections([NSRange(location: 0, length: 0)])
        XCTAssertTrue(editor.gotoChange(forward: true, from: hunks[0].newStart))
        XCTAssertEqual(doc.lines.line(containing: editor.textView.selectedRange().location), hunks[1].newStart)
        XCTAssertTrue(editor.gotoChange(forward: false, from: hunks[1].newStart))
        XCTAssertEqual(doc.lines.line(containing: editor.textView.selectedRange().location), hunks[0].newStart)

        editor.showGitChange(hunks[0])
        let card = try XCTUnwrap(editor.changeCard)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.bounds.contains(card.frame), "card at \(card.frame) is outside the editor \(editor.bounds)")
        let content = try XCTUnwrap(card.subviews.first)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        for label in labels where !label.stringValue.isEmpty {
            XCTAssertTrue(content.bounds.contains(label.frame), "“\(label.stringValue)” at \(label.frame) is outside the card")
            XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.fittingSize.width, "“\(label.stringValue)” is cut off")
        }
        XCTAssertEqual(Set(labels.map(\.stringValue)), ["Changed · 1 line → 2 lines", "1 of 2"])
        // Removed line, then the two lines that replaced it.
        let rows = try XCTUnwrap(content.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? HunkRowsView }.first).rows
        XCTAssertEqual(rows.map(\.kind), [.removed, .added, .added])
        XCTAssertEqual(rows.first?.text.string, "line 5")
        // Moving the caret closes the card, and the gutter click toggles it.
        editor.textView.setAllSelections([NSRange(location: 3, length: 0)])
        XCTAssertNil(editor.changeCard)
        editor.showGitChange(hunks[1], toggle: true)
        XCTAssertNotNil(editor.changeCard)
        editor.showGitChange(hunks[1], toggle: true)
        XCTAssertNil(editor.changeCard)
    }

func testNumstatCountsLinesAndSkipsBinaryFiles() {
        let out = ["3\t1\tsrc/a.ts", "-\t-\timage.png", "2\t0\t", "old/name.ts", "new/name.ts", "0\t4\tgone.txt", ""].joined(separator: "\0")
        let counts = GitRepository.parseNumstat(Data(out.utf8))
        XCTAssertEqual(counts["src/a.ts"]?.added, 3)
        XCTAssertEqual(counts["src/a.ts"]?.removed, 1)
        XCTAssertNil(counts["image.png"])
        XCTAssertEqual(counts["new/name.ts"]?.added, 2)
        XCTAssertNil(counts["old/name.ts"])
        XCTAssertEqual(counts["gone.txt"]?.removed, 4)
    }

    func testRemovedLinesAreShownAboveTheLinesThatReplacedThem() {
        let diff = GitRepository.diff(old: lines("a\nb\nc\nd\ne"), new: lines("a\nB\nc\nx\ny\ne"))
        let inline = InlineDiff(diff: diff, lineCount: 6)
        XCTAssertEqual(inline.gaps.above, [1: 1, 3: 1])
        XCTAssertEqual(inline.changed, IndexSet([1, 3, 4]))
        XCTAssertEqual(inline.added, 3)
        XCTAssertEqual(inline.deleted, 2)
        // Removed text at the very end, after a last line without a newline.
        let tail = InlineDiff(diff: GitRepository.diff(old: lines("a\nb\nc"), new: lines("a")), lineCount: 1)
        XCTAssertEqual(tail.gaps.trailing, 2)
        XCTAssertTrue(tail.gaps.above.isEmpty)
    }

    func testRemovedLinesFollowTheirTextWhileLinesAreInsertedAbove() {
        let diff = GitRepository.diff(old: lines("a\nb\nc\nd"), new: lines("a\nb\nc\nD"))
        let inline = InlineDiff(diff: diff, lineCount: 4)
        XCTAssertEqual(inline.gaps.above, [3: 1])
        // Two new lines typed after line 0.
        XCTAssertTrue(inline.applyEdit(firstLine: 0, removed: 0, inserted: 2))
        XCTAssertEqual(inline.gaps.above, [5: 1])
        XCTAssertEqual(inline.changed, IndexSet([5]))
        // Typing within a line moves nothing.
        XCTAssertFalse(inline.applyEdit(firstLine: 1, removed: 0, inserted: 0))
    }

    func testTheCardShowsChangesToBlankLines() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        // A blank line replaced, a blank line added, and a blank line removed.
        let dir = try makeRepository(committed: "a\n\nb\nc\nd\n\ne\n", current: "a\nx\nb\n\nc\nd\ne\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try withController { controller in
            let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            controller.rootView.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.activeEditor)
            doc.refreshGitBaseline()
            waitForHunks(doc, count: 3)
            XCTAssertEqual(doc.gitDiff.hunks.count, 3)
            for hunk in doc.gitDiff.hunks {
                editor.showGitChange(hunk)
                let card = try XCTUnwrap(editor.changeCard, "no card for \(hunk)")
                card.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(card.frame.height, GitChangeCard.headerHeight)
                let rows = try XCTUnwrap(card.subviews.first?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? HunkRowsView }.first)
                XCTAssertEqual(rows.rows.count, hunk.oldLines.count + hunk.newCount)
                XCTAssertGreaterThanOrEqual(rows.rowHeight, 18)
                editor.closeChangeCard()
            }
            XCTAssertTrue(editor.setComparing(true))
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.display()
        }
    }

    func testHistoryRecordsKeepTheirPathAcrossRenames() {
        let out = "\u{1e}aaa111\u{1f}aaa\u{1f}Ann\u{1f}1700000000\u{1f}Rename it\0\nnew.txt\0\u{1e}bbb222\u{1f}bbb\u{1f}Bo\u{1f}1600000000\u{1f}First: a, b\0\nold\nname.txt\0"
        let commits = GitRepository.parseHistory(Data(out.utf8), fallbackPath: "new.txt")
        XCTAssertEqual(commits.map(\.shortSHA), ["aaa", "bbb"])
        XCTAssertEqual(commits.map(\.path), ["new.txt", "old\nname.txt"])
        XCTAssertEqual(commits[1].subject, "First: a, b")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testChangesListAndHistoryStayAwayUntilTurnedOn() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: Settings.Key.gitChangesAndHistory) }
        let dir = try makeRepository(committed: "one\ntwo\n", current: "one\nTWO\nthree\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git add f.txt && git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm second && printf 'one\\nTWO\\nthree\\nfour\\n' > f.txt", in: dir)
        try withController { controller in
            controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
            let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            controller.rootView.layoutSubtreeIfNeeded()
            // Off by default: no switcher, no list, and File History does nothing.
            XCTAssertFalse(Settings.shared.gitChangesAndHistory)
            controller.sidebar.showChanges(true)
            XCTAssertFalse(controller.sidebar.isShowingChanges)
            XCTAssertFalse(controller.sidebar.subviews.contains { $0 is ChangesView })
            controller.showFileHistory(nil)
            XCTAssertFalse(controller.rootView.subviews.contains { $0 is PaletteBackdrop })

            d.set(true, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            controller.sidebar.showChanges(true)
            XCTAssertTrue(controller.sidebar.isShowingChanges)
            let list = try XCTUnwrap(controller.sidebar.subviews.compactMap { $0 as? ChangesView }.first)
            let deadline = Date().addingTimeInterval(10)
            while list.files.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(list.files.map(\.path), ["f.txt"])
            XCTAssertEqual(list.files.first?.added, 1)
            XCTAssertEqual(list.files.first?.removed, 0)

            // Compare with the first commit: "two" was replaced and two lines were added since.
            let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("f.txt")))
            var commits: [GitRepository.Commit] = []
            repo.history(of: dir.appendingPathComponent("f.txt")) { commits = $0 }
            while commits.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(commits.map(\.subject), ["second", "init"])
            let editor = try XCTUnwrap(controller.activeEditor)
            var shown: InlineDiff?
            editor.compare(withBase: "one\ntwo\n", label: "first") { shown = $0 }
            while shown == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(shown?.added, 3)
            XCTAssertEqual(shown?.deleted, 1)
            XCTAssertEqual(editor.comparisonLabel, "first")
            XCTAssertEqual(editor.layoutManager.gaps?.above, [1: 1])
            // Editing keeps comparing with the commit, not with HEAD.
            editor.textView.performEdits([TextEdit(NSRange(location: doc.length, length: 0), "five\n")], actionName: "Type")
            shown = nil
            let until = Date().addingTimeInterval(5)
            while editor.inlineDiff?.added != 4 && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(editor.inlineDiff?.added, 4)
            editor.cancelOperationFallback()
            XCTAssertFalse(editor.isComparing)
            XCTAssertNil(editor.comparisonLabel)

            d.set(false, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertFalse(controller.sidebar.subviews.contains { $0 is ChangesView }, "the list stayed in memory after turning it off")
        }
    }

    /// Returns as soon as `done`; the long ceiling only matters when the machine stalls.
    private func spin(_ seconds: TimeInterval = 30, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testComparingWithAnEarlierCommitDrivesMarkersNavigationAndRevert() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let d = UserDefaults.standard
        d.set(true, forKey: Settings.Key.gitChangesAndHistory)
        defer { d.removeObject(forKey: Settings.Key.gitChangesAndHistory) }
        // The working file matches HEAD, so only the comparison has changes.
        let dir = try makeRepository(committed: "one\ntwo\nthree\n", current: "one\nTWO\nthree\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git add f.txt && git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm second", in: dir)
        try withController { controller in
            let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            controller.rootView.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.activeEditor)
            doc.refreshGitBaseline()
            spin(until: { doc.hasGitBaseline })
            XCTAssertTrue(doc.gitDiff.hunks.isEmpty)
            XCTAssertFalse(editor.gotoChange(forward: true))

            var shown: InlineDiff?
            editor.compare(withBase: "one\ntwo\nthree\n", label: "abc1234") { shown = $0 }
            spin(until: { shown != nil })
            XCTAssertEqual(editor.lineDiff.hunks.count, 1)
            XCTAssertNotNil(editor.gitHunk(at: 1), "the gutter marker didn't follow the comparison")
            editor.textView.setAllSelections([NSRange(location: 0, length: 0)])
            XCTAssertTrue(editor.gotoChange(forward: true), "Next Change found nothing while comparing with a commit")
            XCTAssertEqual(doc.lines.line(containing: editor.textView.selectedRange().location), 1)
            XCTAssertNotNil(editor.changeCard)
            // Revert restores the commit's text, and the comparison is then empty.
            editor.revertGitChange(try XCTUnwrap(editor.gitHunkAtCaret))
            XCTAssertEqual(doc.string as String, "one\ntwo\nthree\n")
            spin(until: { editor.lineDiff.hunks.isEmpty && editor.isLineDiffCurrent })
            XCTAssertTrue(editor.lineDiff.hunks.isEmpty)
            editor.setComparing(false)
            XCTAssertNil(editor.comparisonLabel)
        }
    }

    func testFileHistoryKeepsUnusualFileNamesExactly() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-names-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let odd = "we\"ird\tna\nme.txt"
        try "a\n".write(to: dir.appendingPathComponent("বাংলা.swift"), atomically: true, encoding: .utf8)
        try "b\n".write(to: dir.appendingPathComponent(odd), atomically: true, encoding: .utf8)
        let g = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null"
        try shell("git init -q . && git add -A && \(g) commit -qm one && git mv বাংলা.swift নতুন.swift && \(g) commit -qm rename", in: dir)
        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent(odd)))
        for (name, paths) in [("নতুন.swift", ["নতুন.swift", "বাংলা.swift"]), (odd, [odd])] {
            // No window is open here, so the run loop is spun by XCTest's waiter: a bare
            // RunLoop.run can return without delivering the main-queue completion.
            var commits: [GitRepository.Commit] = []
            let listed = expectation(description: "history of \(name)")
            repo.history(of: dir.appendingPathComponent(name)) { commits = $0; listed.fulfill() }
            wait(for: [listed], timeout: 30)
            XCTAssertEqual(commits.map(\.path), paths)
            guard let oldest = commits.last else { continue }
            var data: Data?
            let read = expectation(description: "contents of \(name)")
            repo.contents(of: oldest.path, at: oldest.sha) { data = $0; read.fulfill() }
            wait(for: [read], timeout: 30)
            XCTAssertNotNil(data, "couldn't read \(name.debugDescription) at its first commit")
        }
    }

    func testTurningHistoryOffClosesAnOpenHistoryListAndStopsComparing() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let d = UserDefaults.standard
        d.set(true, forKey: Settings.Key.gitChangesAndHistory)
        defer { d.removeObject(forKey: Settings.Key.gitChangesAndHistory) }
        let dir = try makeRepository(committed: "one\n", current: "two\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try withController { controller in
            _ = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            controller.rootView.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.activeEditor)
            let paletteOpen = { controller.rootView.subviews.contains { $0 is PaletteBackdrop } }
            controller.showFileHistory(nil)
            spin(until: paletteOpen)
            XCTAssertTrue(paletteOpen())

            d.set(false, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            spin(1, until: { !paletteOpen() })
            XCTAssertFalse(paletteOpen(), "the history list stayed open after turning the feature off")
            var shown = false
            editor.compare(withBase: "one\n", label: "abc1234") { _ in shown = true }
            spin(1, until: { shown })
            XCTAssertFalse(shown)
            XCTAssertFalse(editor.isComparing)
            XCTAssertNil(editor.comparisonLabel)

            // A comparison already being computed is dropped when the feature is turned off.
            d.set(true, forKey: Settings.Key.gitChangesAndHistory)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            editor.compare(withBase: "one\n", label: "abc1234") { _ in shown = true }
            d.set(false, forKey: Settings.Key.gitChangesAndHistory)
            spin(1, until: { shown })
            XCTAssertFalse(shown)
            XCTAssertFalse(editor.isComparing)
        }
    }

    func testHeadTokenFollowsNewCommits() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try makeRepository(committed: "a\n", current: "b\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("f.txt")))
        let before = try XCTUnwrap(repo.headToken)
        XCTAssertEqual(repo.headToken, before)
        try shell("git add f.txt && git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm two", in: dir)
        XCTAssertNotEqual(repo.headToken, before)
    }

    private func shell(_ command: String, in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    private func withController(_ body: (MainWindowController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        try body(controller)
    }

    func testComparingOpensRowsForRemovedLinesAndKeepsTheCaretOnTheText() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let committed = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = committed.split(separator: "\n").map(String.init)
        lines.remove(at: 2)
        lines.remove(at: 2)
        lines[5] = "changed"
        let dir = try makeRepository(committed: committed, current: lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try withController { controller in
            let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            controller.rootView.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.activeEditor)
            editor.textView.scrollPastEnd = false
            doc.refreshGitBaseline()
            waitForHunks(doc, count: 2)
            let lh = editor.textView.lineHeight
            editor.textView.setFrameSize(editor.textView.frame.size)
            let plainHeight = editor.layoutManager.usedRect(for: editor.textContainer).height
            let plainCaret = editor.textView.caretRect(at: doc.lines.start(of: 2))

            XCTAssertTrue(editor.setComparing(true))
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            XCTAssertTrue(editor.layoutManager.hasGaps)
            XCTAssertEqual(editor.layoutManager.gaps?.above, [2: 2, 5: 1])
            // Two removed rows above line 2 and one above line 5 (the changed line).
            XCTAssertEqual(editor.layoutManager.usedRect(for: editor.textContainer).height, plainHeight + 3 * lh, accuracy: 0.5)
            let caret = editor.textView.caretRect(at: doc.lines.start(of: 2))
            XCTAssertEqual(caret.height, lh, accuracy: 0.5)
            XCTAssertEqual(caret.minY, plainCaret.minY + 2 * lh, accuracy: 0.5)
            XCTAssertEqual(editor.textView.lineRect(forCharacter: doc.lines.start(of: 2)).height, lh, accuracy: 0.5)
            // A word highlight on a line with a gap covers only the text.
            let word = editor.textView.rects(for: NSRange(location: doc.lines.start(of: 2), length: 4))
            XCTAssertEqual(word.first?.height ?? 0, lh, accuracy: 0.5)

            editor.cancelOperationFallback()
            XCTAssertFalse(editor.isComparing)
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            XCTAssertFalse(editor.layoutManager.hasGaps)
            XCTAssertEqual(editor.layoutManager.usedRect(for: editor.textContainer).height, plainHeight, accuracy: 0.5)
        }
    }

    func testTurningGitOffStopsLoadingCommittedCopiesAndStatus() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: Settings.Key.gitEnabled); d.removeObject(forKey: Settings.Key.gitGutter) }
        let dir = try makeRepository(committed: "a\n", current: "b\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try withController { controller in
            d.set(false, forKey: Settings.Key.gitGutter)
            let doc = try XCTUnwrap(controller.open(url: dir.appendingPathComponent("f.txt")))
            doc.refreshGitBaseline()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertFalse(doc.hasGitBaseline, "the committed copy was loaded with the gutter off")
            XCTAssertNil(controller.activeEditor?.gitHunkAtCaret)

            d.set(true, forKey: Settings.Key.gitGutter)
            doc.refreshGitBaseline()
            waitForHunks(doc, count: 1)
            XCTAssertTrue(doc.hasGitBaseline)

            d.set(false, forKey: Settings.Key.gitEnabled)
            XCTAssertFalse(Settings.shared.gitGutter)
            XCTAssertFalse(Settings.shared.gitNeedsStatus)
            doc.refreshGitBaseline()
            XCTAssertFalse(doc.hasGitBaseline)
            XCTAssertTrue(doc.gitDiff.hunks.isEmpty)
            controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
            controller.updateStatusBar()
            XCTAssertEqual(controller.statusBar.values[.branch], "")
            XCTAssertEqual(controller.statusBar.values[.changes], "")
            XCTAssertEqual(controller.changedFileCount, 0)
        }
    }

    func testTheSidebarEdgeCanBeGrabbedOverTheEditor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-edge-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        withController { controller in
            controller.setFolder(URL(fileURLWithPath: dir.path, isDirectory: true))
            _ = controller.open(url: dir.appendingPathComponent("a.txt"))
            controller.rootView.layoutSubtreeIfNeeded()
            let edge = controller.sidebar.frame.maxX
            for dx: CGFloat in [-3, 0, 3] {
                let p = NSPoint(x: edge + dx, y: 300)
                let hit = controller.rootView.hitTest(controller.rootView.convert(p, to: controller.rootView.superview))
                XCTAssertTrue(hit is DividerView, "\(dx) pt from the edge hit \(String(describing: hit))")
            }
        }
    }
}
