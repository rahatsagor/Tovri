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

    func testChangeNavigationStartsFromTheShownChangeAndThePopoverFitsItsText() throws {
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
        XCTAssertEqual(GitChangePopover.summary(of: hunks[0]), "1 line changed, 1 added")
        XCTAssertEqual(GitChangePopover.summary(of: hunks[1]), "1 line changed")

        // The caret stays on line 1, as after clicking a gutter marker.
        editor.textView.setAllSelections([NSRange(location: 0, length: 0)])
        XCTAssertTrue(editor.gotoChange(forward: true, from: hunks[0].newStart))
        XCTAssertEqual(doc.lines.line(containing: editor.textView.selectedRange().location), hunks[1].newStart)
        XCTAssertTrue(editor.gotoChange(forward: false, from: hunks[1].newStart))
        XCTAssertEqual(doc.lines.line(containing: editor.textView.selectedRange().location), hunks[0].newStart)

        let popover = GitChangePopover(hunk: hunks[0], editor: editor)
        let root = popover.view
        XCTAssertEqual(popover.preferredContentSize, root.frame.size)
        let inner = root.bounds.insetBy(dx: 11.5, dy: 11.5)
        for sub in root.subviews {
            XCTAssertTrue(inner.contains(sub.frame), "\(sub) at \(sub.frame) is outside the padding of \(root.bounds)")
            if let label = sub as? NSTextField {
                XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.fittingSize.width, "“\(label.stringValue)” is cut off")
            }
        }
        let texts = root.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("Since the last commit · change 1 of 2"), "\(texts)")
    }
}
