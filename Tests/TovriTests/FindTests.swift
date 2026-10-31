import AppKit
import XCTest
@testable import Tovri

final class FindTests: XCTestCase {
    func testReloadReplacesCachedMatchesAndFindNextUsesTheNewBuffer() {
        withFind("foo 123 foo", query: "foo", replacement: "") { editor, bar in
            XCTAssertEqual(editor.textView.findMatches.count, 2)
            editor.document.replaceAllContent("xfoo")
            XCTAssertEqual(editor.textView.findMatches, [NSRange(location: 1, length: 3)])
            bar.step(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 3))
            editor.document.replaceAllContent("x")
            XCTAssertTrue(editor.textView.findMatches.isEmpty)
        }
    }

    func testReloadInvalidatesAnOutstandingBackgroundSearch() {
        withFind(String(repeating: "foo ", count: 100_000), query: "foo", replacement: "") { editor, _ in
            editor.document.replaceAllContent("xfoo")
            let completed = expectation(description: "Allow the older background result to return")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completed.fulfill() }
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(editor.textView.findMatches, [NSRange(location: 1, length: 3)])
        }
    }

    private func withFind(_ text: String, query: String, replacement: String,
                          _ body: (EditorView, FindBar) -> Void) {
        _ = NSApplication.shared
        let state = FindState.shared
        let saved = (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord)
        defer {
            (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord) = saved
        }
        state.query = query
        state.replacement = replacement
        state.regex = true
        state.caseSensitive = true
        state.wholeWord = false
        let doc = Document(text: text, name: "Find", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.showFindBar(replace: true)
        body(editor, editor.findBar!)
    }

    func testZeroWidthMatchesCanBeFoundAndSteppedThrough() {
        withFind("a\nb", query: "^", replacement: "> ") { editor, bar in
            XCTAssertEqual(editor.textView.findMatches, [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
            bar.step(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
            bar.step(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
        }
    }

    func testReplaceAllCanInsertAtLineStarts() {
        withFind("a\nb", query: "^", replacement: "> ") { editor, bar in
            bar.replaceAll()
            XCTAssertEqual(editor.document.string as String, "> a\n> b")
        }
    }

    func testReplaceCurrentHonorsLookbehindOutsideTheSelection() {
        withFind("foobar", query: "(?<=foo)bar", replacement: "qux") { editor, bar in
            editor.textView.setAllSelections([NSRange(location: 3, length: 3)], scroll: false)
            bar.replaceCurrent()
            XCTAssertEqual(editor.document.string as String, "fooqux")
        }
    }

    func testSelectionBoundaryIsNotAnArtificialLineStart() {
        withFind("a cat\ncat", query: "^cat", replacement: "dog") { editor, bar in
            editor.textView.setAllSelections([NSRange(location: 2, length: 3)], scroll: false)
            bar.replaceCurrent()
            XCTAssertEqual(editor.document.string as String, "a cat\ncat")
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 6, length: 3))
        }
    }

    func testReplacingZeroWidthMatchAdvancesPastTheOriginalCharacter() {
        withFind("aa", query: "(?=a)", replacement: "x") { editor, bar in
            bar.replaceCurrent()
            XCTAssertEqual(editor.document.string as String, "xaa")
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
            bar.replaceCurrent()
            XCTAssertEqual(editor.document.string as String, "xaxa")
        }
    }

    func testZeroWidthNavigationAlsoWorksWithTheFindBarClosed() {
        withFind("a\nb", query: "^", replacement: "") { editor, bar in
            bar.dismiss()
            editor.findNext(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
            editor.findNext(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
            editor.findNext(forward: false)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
        }
    }

    func testHiddenFindBarDoesNotTurnTheCaretIntoALineStart() {
        withFind("a cat\ncat", query: "^cat", replacement: "") { editor, bar in
            bar.dismiss()
            editor.textView.setAllSelections([NSRange(location: 2, length: 0)], scroll: false)
            editor.findNext(forward: true)
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 6, length: 3))
        }
    }
}
