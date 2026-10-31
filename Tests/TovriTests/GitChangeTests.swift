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
}
