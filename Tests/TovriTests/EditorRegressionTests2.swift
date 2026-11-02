import AppKit
import XCTest
@testable import Tovri

final class EditorRegressionTests2: XCTestCase {
    private func makeEditor(_ text: String, lang: String? = nil) -> EditorView {
        _ = NSApplication.shared
        let language = lang.flatMap { LanguageRegistry.shared.language(id: $0) } ?? LanguageRegistry.shared.plain
        let doc = Document(text: text, name: "Probe", language: language)
        let editor = EditorView(document: doc)
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    private func withFindState(query: String, replacement: String = "", regex: Bool = false, wholeWord: Bool = false,
                               _ body: () throws -> Void) rethrows {
        let state = FindState.shared
        let saved = (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord)
        defer { (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord) = saved }
        state.query = query
        state.replacement = replacement
        state.regex = regex
        state.caseSensitive = true
        state.wholeWord = wholeWord
        try body()
    }

    private func carets(_ tv: EditorTextView) -> [Int] { tv.allSelections.map(\.location) }

    // MARK: Syntax cache

    private func assertStatesMatchFreshLex(_ doc: Document, file: StaticString = #filePath, line: UInt = #line) {
        let cached = Highlighted(document: doc)
        let fresh = Highlighted(doc.language.id, doc.string as String)
        XCTAssertFalse(cached.lineStates.contains(SyntaxEngine.unknown), file: file, line: line)
        XCTAssertEqual(cached.lineStates, fresh.lineStates, file: file, line: line)
        XCTAssertEqual(cached.kinds, fresh.kinds, file: file, line: line)
    }

    func testEditPastTheLexedWindowThenTypingAboveDoesNotTrustUnlexedLines() throws {
        _ = NSApplication.shared
        let js = try XCTUnwrap(LanguageRegistry.shared.language(id: "javascript"))
        let doc = Document(text: String(repeating: "let a = 1;\n", count: 3000), name: "Probe", language: js)
        doc.syntax.ensureStates(through: doc.lines.count - 1, text: doc.string, lines: doc.lines)
        // One edit from line 10 to line 2000 that opens a block comment far below the viewport.
        let start = doc.lines.start(of: 10)
        let end = doc.lines.start(of: 2000)
        var replacement = String(repeating: "let b = 2;\n", count: 1980)
        replacement += "/* open\n"
        doc.textStorage.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        // Coloring re-lexes only the visible lines.
        doc.syntax.ensureStates(through: 60, text: doc.string, lines: doc.lines)
        // Typing a letter on a visible line.
        doc.textStorage.replaceCharacters(in: NSRange(location: doc.lines.start(of: 5), length: 0), with: "x")
        doc.syntax.ensureStates(through: 60, text: doc.string, lines: doc.lines)
        assertStatesMatchFreshLex(doc)
        let h = Highlighted(document: doc)
        XCTAssertEqual(h.kinds[doc.lines.start(of: 2500)], .comment)
    }

    func testReplaceAllBelowTheViewportThenTypingKeepsCommentColorsRight() {
        let e = makeEditor(String(repeating: "let a = 1;\n", count: 4000), lang: "javascript")
        defer { e.close() }
        let lines = e.document.lines
        e.document.syntax.ensureStates(through: lines.count - 1, text: e.document.string, lines: lines)
        // A Replace All style edit: many separate replacements, the last ones far off screen.
        var edits: [TextEdit] = []
        for l in stride(from: 3, to: 3000, by: 7) {
            edits.append(TextEdit(NSRange(location: lines.start(of: l), length: 3), "var"))
        }
        edits.append(TextEdit(NSRange(location: lines.start(of: 3100), length: 0), "/* "))
        e.textView.performEdits(edits, selection: .preserve)
        e.colorizeVisible()
        e.textView.setAllSelections([NSRange(location: lines.start(of: 2), length: 0)], scroll: false)
        e.textView.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.colorizeVisible()
        assertStatesMatchFreshLex(e.document)
        XCTAssertEqual(Highlighted(document: e.document).kinds[e.document.lines.start(of: 3500)], .comment)
    }

    // MARK: Multiple cursors

    func testExtendingSeveralSelectionsBackwardKeepsTheirAnchors() {
        let e = makeEditor("0123456789\n0123456789\n")
        defer { e.close() }
        let tv = e.textView
        tv.setAllSelections([NSRange(location: 8, length: 0), NSRange(location: 19, length: 0)])
        for _ in 0..<3 { tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:))) }
        XCTAssertEqual(tv.allSelections, [NSRange(location: 5, length: 3), NSRange(location: 16, length: 3)])
        tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        XCTAssertEqual(tv.allSelections, [NSRange(location: 6, length: 2), NSRange(location: 17, length: 2)])
        tv.doCommand(by: #selector(NSResponder.moveWordLeftAndModifySelection(_:)))
        XCTAssertEqual(tv.allSelections, [NSRange(location: 0, length: 8), NSRange(location: 11, length: 8)])
    }

    func testExtendingSeveralSelectionsUpAndBackDown() {
        let e = makeEditor("aaaa\nbbbb\ncccc\ndddd\n")
        defer { e.close() }
        let tv = e.textView
        tv.setAllSelections([NSRange(location: 7, length: 0), NSRange(location: 17, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:)))
        XCTAssertEqual(tv.allSelections, [NSRange(location: 2, length: 5), NSRange(location: 12, length: 5)])
        tv.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        XCTAssertEqual(tv.allSelections, [NSRange(location: 7, length: 0), NSRange(location: 17, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        XCTAssertEqual(tv.allSelections, [NSRange(location: 7, length: 5), NSRange(location: 17, length: 3)])
    }

    func testMovingSeveralCaretsDownKeepsTheirColumnAcrossShortLines() {
        let e = makeEditor("0123456789\n01\n0123456789\n0123456789\n01\n0123456789\n")
        defer { e.close() }
        let tv = e.textView
        tv.setAllSelections([NSRange(location: 8, length: 0), NSRange(location: 33, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(carets(tv), [13, 38])
        tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(carets(tv), [22, 47])
        tv.doCommand(by: #selector(NSResponder.moveUp(_:)))
        tv.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(carets(tv), [8, 33])
    }

    func testAutoPairingWithSeveralCaretsFollowsTheSingleCaretRules() throws {
        try XCTSkipUnless(Settings.shared.autoCloseBrackets)
        let over = makeEditor("f()\nf()\n")
        defer { over.close() }
        over.textView.setAllSelections([NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        over.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(over.document.string as String, "f()\nf()\n")
        XCTAssertEqual(carets(over.textView), [3, 7])

        let before = makeEditor("ab\nab\n")
        defer { before.close() }
        before.textView.setAllSelections([NSRange(location: 0, length: 0), NSRange(location: 3, length: 0)])
        before.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(before.document.string as String, "(ab\n(ab\n")

        let mixed = makeEditor("f()\nab\n")
        defer { mixed.close() }
        mixed.textView.setAllSelections([NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        mixed.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(mixed.document.string as String, "f()\nab)\n")
        XCTAssertEqual(carets(mixed.textView), [3, 7])
    }

    func testDeleteLineKeepsACaretForEveryLine() {
        let e = makeEditor("a\n  b\nc\n  d\ne\n")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)])
        e.textView.deleteLine(nil)
        XCTAssertEqual(e.document.string as String, "  b\n  d\ne\n")
        XCTAssertEqual(carets(e.textView), [2, 6])
    }

    func testCommittedMarkedTextReachesEveryCaret() {
        let e = makeEditor("ab\nab\n")
        defer { e.close() }
        let tv = e.textView
        tv.setAllSelections([NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
        tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.extraSelections.count, 1)
        tv.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(e.document.string as String, "abé\nabé\n")
        XCTAssertEqual(carets(tv), [3, 7])
    }

    func testUndoAndRedoOfAMultiCaretEditRestoreEveryCaret() {
        let e = makeEditor("a\na\n")
        defer { e.close() }
        let tv = e.textView
        tv.setAllSelections([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(e.document.string as String, "ax\nax\n")
        e.document.undoManager.undo()
        XCTAssertEqual(e.document.string as String, "a\na\n")
        XCTAssertEqual(tv.allSelections, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        e.document.undoManager.redo()
        XCTAssertEqual(e.document.string as String, "ax\nax\n")
        XCTAssertEqual(tv.allSelections, [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
        e.document.undoManager.undo()
        XCTAssertEqual(tv.allSelections, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
    }

    func testCompletionInsertsAtEveryCaret() {
        let e = makeEditor("fo\nx fo\n")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 2, length: 0), NSRange(location: 7, length: 0)])
        e.textView.insertCompletionAtAllCarets("foo")
        XCTAssertEqual(e.document.string as String, "foo\nx foo\n")
        XCTAssertEqual(carets(e.textView), [3, 9])
    }

    // MARK: Comments

    func testToggleCommentInCSSWrapsEachLineAndUnwrapsAgain() {
        let src = "a {\n  color: red;\n}\n"
        let e = makeEditor(src, lang: "css")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 0, length: e.document.length)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "/* a { */\n  /* color: red; */\n/* } */\n")
        e.textView.setAllSelections([NSRange(location: 0, length: e.document.length)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, src)
    }

    func testToggleCommentOnAFullLineSelectionKeepsTheCloserOnTheLine() {
        let e = makeEditor("<p>hi</p>\n<b>x</b>\n", lang: "html")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 0, length: 10)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "<!-- <p>hi</p> -->\n<b>x</b>\n")
        e.textView.setAllSelections([NSRange(location: 0, length: 19)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "<p>hi</p>\n<b>x</b>\n")
    }

    func testToggleCommentWithSeveralCaretsInCSS() {
        let e = makeEditor("a {}\nb {}\nc {}\n", lang: "css")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "/* a {} */\nb {}\n/* c {} */\n")
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "a {}\nb {}\nc {}\n")
    }

    func testToggleCommentUncommentsABlockCommentedAsAWhole() {
        let e = makeEditor("/* a {\n  b: c;\n} */\n", lang: "css")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 0, length: e.document.length)])
        e.textView.toggleComment(nil)
        XCTAssertEqual(e.document.string as String, "a {\n  b: c;\n}\n")
    }

    func testBlockCommentOnFullLinesClosesBeforeTheNewline() {
        let src = "a {\n  b: c;\n}\n"
        let e = makeEditor(src, lang: "css")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 0, length: e.document.length)])
        e.textView.toggleBlockComment(nil)
        XCTAssertEqual(e.document.string as String, "/* a {\n  b: c;\n} */\n")
        e.textView.setAllSelections([NSRange(location: 0, length: e.document.length)])
        e.textView.toggleBlockComment(nil)
        XCTAssertEqual(e.document.string as String, src)
    }

    // MARK: Folding

    private let python = "def a():\n    x = 1\n    y = 2\ndef b():\n    z = 3\n"

    private func foldedPython() -> EditorView {
        let e = makeEditor(python, lang: "python")
        e.fold(line: 0)
        XCTAssertEqual(e.folds, [NSRange(location: 8, length: 20)])
        e.textView.setAllSelections([NSRange(location: 3, length: 0)], scroll: false)
        return e
    }

    func testDeleteLineOnAFoldedHeaderDeletesTheFold() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.deleteLine(nil)
        XCTAssertEqual(e.document.string as String, "def b():\n    z = 3\n")
    }

    func testMoveLineMovesTheWholeFoldAndKeepsItFolded() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.moveLineDown(nil)
        XCTAssertEqual(e.document.string as String, "def b():\ndef a():\n    x = 1\n    y = 2\n    z = 3\n")
        XCTAssertEqual(e.folds, [NSRange(location: 17, length: 20)])
        XCTAssertEqual(e.textView.selectedRange(), NSRange(location: 12, length: 0))
        e.textView.moveLineUp(nil)
        XCTAssertEqual(e.document.string as String, python)
        XCTAssertEqual(e.folds, [NSRange(location: 8, length: 20)])
    }

    func testMovingALinePastAFoldSkipsTheWholeFold() {
        let e = makeEditor("x = 0\n" + python, lang: "python")
        defer { e.close() }
        e.fold(line: 1)
        e.textView.setAllSelections([NSRange(location: 0, length: 0)], scroll: false)
        e.textView.moveLineDown(nil)
        XCTAssertEqual(e.document.string as String, "def a():\n    x = 1\n    y = 2\nx = 0\ndef b():\n    z = 3\n")
        XCTAssertEqual(e.folds, [NSRange(location: 8, length: 20)])
    }

    func testDuplicateLineCopiesTheWholeFold() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.duplicateLine(nil)
        XCTAssertEqual(e.document.string as String, "def a():\n    x = 1\n    y = 2\n" + python)
        XCTAssertEqual(e.folds, [NSRange(location: 8, length: 20), NSRange(location: 37, length: 20)])
    }

    func testIndentKeepsAFoldedBlockFolded() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.indentLines(nil)
        XCTAssertEqual(e.document.string as String, "    def a():\n        x = 1\n        y = 2\ndef b():\n    z = 3\n")
        XCTAssertEqual(e.folds, [NSRange(location: 12, length: 28)])
    }

    func testLineCutOnAFoldedHeaderCutsTheWholeFold() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.cut(nil)
        XCTAssertEqual(e.document.string as String, "def b():\n    z = 3\n")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "def a():\n    x = 1\n    y = 2\n")
    }

    func testCaretAtTheVisibleEndOfAFoldedLineKeepsItFolded() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 28, length: 0)], scroll: false)
        XCTAssertEqual(e.folds.count, 1)
        e.textView.setAllSelections([NSRange(location: 8, length: 0)], scroll: false)
        XCTAssertEqual(e.folds.count, 1)
        e.textView.setAllSelections([NSRange(location: 14, length: 0)], scroll: false)
        XCTAssertTrue(e.folds.isEmpty)
    }

    func testUnfoldWorksWithTheCaretAfterThePlaceholder() {
        let e = foldedPython()
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 28, length: 0)], scroll: false)
        e.foldAtCaret()
        XCTAssertEqual(e.folds, [NSRange(location: 8, length: 20)])
        e.unfoldAtCaret()
        XCTAssertTrue(e.folds.isEmpty)
    }

    // MARK: Gutter

    func testGutterFindsTheTopOfTheEmptyLastLine() {
        let e = makeEditor("a\nb\n")
        defer { e.close() }
        e.layoutManager.ensureLayout(for: e.textContainer)
        let last = GutterView.top(ofLine: 1, in: e.textView)
        let extra = GutterView.top(ofLine: 2, in: e.textView)
        XCTAssertGreaterThan(extra, last)
        XCTAssertEqual(extra, e.layoutManager.extraLineFragmentRect.minY)
        XCTAssertEqual(GutterView.top(ofLine: 3, in: e.textView), .greatestFiniteMagnitude)
    }

    // MARK: JSON

    func testJSONFormatterAcceptsValidJSONThatFoundationRejects() throws {
        XCTAssertEqual(try JSONFormatter.reformat("[ 1e400 ]", indent: nil), "[1e400]")
        XCTAssertEqual(try JSONFormatter.reformat("{\"a\" : \"\\ud800\"}", indent: nil), "{\"a\":\"\\ud800\"}")
        let deep = String(repeating: "[", count: 5000) + "1" + String(repeating: "]", count: 5000)
        XCTAssertEqual(try JSONFormatter.reformat(deep, indent: nil), deep)
        XCTAssertEqual(try JSONFormatter.reformat("{\"b\":1,\"a\":-0.5E+3}", indent: nil), "{\"b\":1,\"a\":-0.5E+3}")
        for bad in ["[01]", "[1.]", "[.5]", "{\"a\" 1}", "[\"a\nb\"]", "[\"\\x\"]", "[1] [2]", "[", "{\"a\":1,}", "tru", "[1,,2]", "{1:2}"] {
            XCTAssertThrowsError(try JSONFormatter.reformat(bad, indent: nil), bad)
        }
    }

    // MARK: Find

    func testFindInSelectionStartsWithAMultiLineSelectionAndLimitsReplaceAll() {
        withFindState(query: "foo", replacement: "bar") {
            let e = makeEditor("foo\nfoo\nfoo\nfoo\n")
            defer { e.close() }
            e.textView.setAllSelections([NSRange(location: 4, length: 8)])
            e.showFindBar(replace: true)
            let bar = e.findBar!
            XCTAssertEqual(bar.scope, [NSRange(location: 4, length: 8)])
            XCTAssertEqual(e.textView.findMatches, [NSRange(location: 4, length: 3), NSRange(location: 8, length: 3)])
            bar.replaceAll()
            XCTAssertEqual(e.document.string as String, "foo\nbar\nbar\nfoo\n")
            XCTAssertEqual(bar.scope, [NSRange(location: 4, length: 8)])
            bar.dismiss()
            e.textView.setAllSelections([NSRange(location: 0, length: 0)])
            e.showFindBar(replace: true)
            XCTAssertTrue(bar.scope.isEmpty)
            bar.replaceAll()
            XCTAssertEqual(e.document.string as String, "bar\nbar\nbar\nbar\n")
        }
    }

    func testRegexReplacementUnderstandsNewlineTabAndBackslashEscapes() {
        func replaced(_ text: String, _ query: String, _ replacement: String, regex: Bool = true) -> String {
            var out = ""
            withFindState(query: query, replacement: replacement, regex: regex) {
                let e = makeEditor(text)
                defer { e.close() }
                e.showFindBar(replace: true)
                e.findBar!.replaceAll()
                out = e.document.string as String
            }
            return out
        }
        XCTAssertEqual(replaced("a,b", ",", "\\n"), "a\nb")
        XCTAssertEqual(replaced("a,b", ",", "\\t"), "a\tb")
        XCTAssertEqual(replaced("a,b", ",", "\\\\"), "a\\b")
        XCTAssertEqual(replaced("a,b", "(\\w),", "$1\\n"), "a\nb")
        XCTAssertEqual(replaced("a,b", ",", "\\$1"), "a$1b")
        XCTAssertEqual(replaced("a,b", ",", "\\n", regex: false), "a\\nb")
    }

    func testWholeWordSearchStaysFastWithManyMatches() {
        withFindState(query: "ab", wholeWord: true) {
            let e = makeEditor(String(repeating: "ab abc ", count: 40_000))
            defer { e.close() }
            let start = Date()
            e.showFindBar(replace: false)
            XCTAssertEqual(e.textView.findMatches.count, 40_000)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testWholeWordUsesTheEditorsWordCharacters() {
        withFindState(query: "foo.", wholeWord: true) {
            let e = makeEditor("foo. foo.bar xfoo.")
            defer { e.close() }
            e.showFindBar(replace: false)
            XCTAssertEqual(e.textView.findMatches, [NSRange(location: 0, length: 4)])
        }
        withFindState(query: "$el", wholeWord: true) {
            let e = makeEditor("$el = el + $el2", lang: "javascript")
            defer { e.close() }
            e.showFindBar(replace: false)
            XCTAssertEqual(e.textView.findMatches, [NSRange(location: 0, length: 3)])
            FindState.shared.query = "el"
            e.findBar!.queryDidChange()
            XCTAssertEqual(e.textView.findMatches, [NSRange(location: 6, length: 2)])
        }
        withFindState(query: "-x", wholeWord: true) {
            let e = makeEditor("a -x b-x")
            defer { e.close() }
            e.showFindBar(replace: false)
            XCTAssertEqual(e.textView.findMatches, [NSRange(location: 2, length: 2)])
            e.findBar!.dismiss()
            e.textView.setAllSelections([NSRange(location: 0, length: 0)])
            e.findNext(forward: true)
            XCTAssertEqual(e.textView.selectedRange(), NSRange(location: 2, length: 2))
            e.findNext(forward: true)
            XCTAssertEqual(e.textView.selectedRange(), NSRange(location: 2, length: 2))
        }
    }
}
