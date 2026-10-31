import AppKit
import XCTest
@testable import Tovri

final class EditorGeometryTests: XCTestCase {
    private func withEditor(_ text: String, _ body: (EditorView) -> Void) {
        _ = NSApplication.shared
        let doc = Document(text: text, name: "Geometry", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.scrollPastEnd = true
        editor.setWordWrap(false)
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        editor.textView.layoutManager?.ensureLayout(for: editor.textContainer)
        editor.textView.sizeToFit()
        editor.textView.setFrameSize(editor.textView.frame.size)
        body(editor)
    }

    func testShortDocumentsHaveNoVerticalScrollRange() {
        for text in ["", "hello", String(repeating: "line\n", count: 12)] {
            withEditor(text) { editor in
                XCTAssertLessThanOrEqual(editor.textView.frame.height,
                                         editor.scrollView.contentView.bounds.height + 1)
            }
        }
    }

    func testDeletingLongDocumentRemovesStaleScrollSpace() {
        withEditor(String(repeating: "line\n", count: 200)) { editor in
            XCTAssertGreaterThan(editor.textView.frame.height, 700)
            editor.scrollPosition = CGPoint(x: 0, y: 2500)
            editor.document.replaceAllContent("short\nfile\n")
            editor.layoutSubtreeIfNeeded()
            editor.textView.sizeToFit()
            XCTAssertLessThanOrEqual(editor.textView.frame.height,
                                     editor.scrollView.contentView.bounds.height + 1)
            XCTAssertEqual(editor.scrollPosition.y, 0, accuracy: 1)
        }
    }

    func testRestoredScrollPositionIsClampedForShortFile() {
        withEditor("short\nfile\n") { editor in
            editor.scrollPosition = CGPoint(x: 0, y: 500)
            XCTAssertEqual(editor.scrollPosition.y, 0, accuracy: 1)
        }
    }

    func testLongDocumentStillAllowsScrollPastEnd() {
        withEditor(String(repeating: "line\n", count: 200)) { editor in
            let content = max(editor.layoutManager.usedRect(for: editor.textContainer).maxY,
                              editor.layoutManager.extraLineFragmentRect.maxY)
                + editor.textView.textContainerInset.height * 2
            XCTAssertGreaterThan(editor.textView.frame.height, content + 100)
        }
    }

    func testDisablingScrollPastEndRemovesOnlyThePadding() {
        withEditor(String(repeating: "line\n", count: 200)) { editor in
            let padded = editor.textView.frame.height
            editor.textView.scrollPastEnd = false
            editor.textView.setFrameSize(editor.textView.frame.size)
            let natural = CGFloat(editor.document.lines.count) * editor.textView.lineHeight + 12
            XCTAssertEqual(editor.textView.frame.height, natural, accuracy: 1)
            XCTAssertGreaterThan(padded, natural)
        }
    }

    func testGrowingWindowToFitContentRemovesScrollRange() {
        withEditor(String(repeating: "line\n", count: 40)) { editor in
            editor.frame.size.height = 1600
            editor.needsLayout = true
            editor.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.textView.frame.height, 1600, accuracy: 1)
        }
    }

    func testWrappedContentUsesItsVisualHeight() {
        withEditor(String(repeating: "long text ", count: 1200)) { editor in
            editor.setWordWrap(true)
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.sizeToFit()
            editor.textView.setFrameSize(editor.textView.frame.size)
            XCTAssertGreaterThan(editor.textView.frame.height, 700)
            editor.document.replaceAllContent("short wrapped file")
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.sizeToFit()
            editor.textView.setFrameSize(editor.textView.frame.size)
            XCTAssertEqual(editor.textView.frame.height, 700, accuracy: 1)
        }
    }

    func testFoldingAFileDownToOneBlockRemovesExtraScrollSpace() {
        withEditor("block {\n" + String(repeating: "    line\n", count: 200) + "}\n") { editor in
            editor.fold(line: 0)
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.sizeToFit()
            editor.textView.setFrameSize(editor.textView.frame.size)
            XCTAssertEqual(editor.textView.frame.height, 700, accuracy: 1)
            editor.unfoldAll()
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.sizeToFit()
            XCTAssertGreaterThan(editor.textView.frame.height, 700)
        }
    }
}
