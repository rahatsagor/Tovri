import AppKit
import XCTest
@testable import Tovri

final class LargeFileTests: XCTestCase {
    private func withLargeEditor(_ text: String, _ body: (EditorView) throws -> Void) rethrows {
        _ = NSApplication.shared
        let doc = Document(text: text, name: "Large.d.ts", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.scrollPastEnd = true
        editor.setWordWrap(false)
        editor.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        editor.minimap.frame = NSRect(x: 0, y: 0, width: 100, height: 700)
        try body(editor)
    }

    func testEndOfLargeFileDoesNotHaveAnEmptyScrollableTail() {
        let lines = String(repeating: "export interface Example { value: string }\n", count: 16_364)
        for suffix in ["", "last line without a newline"] {
            withLargeEditor(lines + suffix) { editor in
                editor.goTo(line: editor.document.lines.count)
                editor.scrollPosition = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
                let last = editor.textView.caretRect(at: editor.document.length)
                XCTAssertTrue(editor.textView.visibleRect.intersects(last), "EOF must remain visible at maximum scroll")
                XCTAssertLessThanOrEqual(editor.textView.frame.height - last.maxY, 700)
            }
        }
    }

    func testMinimapShowsEOFAsSoonAsTheLastSourceLineIsVisible() throws {
        try withLargeEditor(String(repeating: "line\n", count: 16_364)) { editor in
            editor.goTo(line: editor.document.lines.count)
            let geometry = try XCTUnwrap(editor.minimap.geometry())
            XCTAssertEqual(geometry.start + geometry.visibleRows, editor.document.lines.count)
            XCTAssertEqual(geometry.viewportY + geometry.viewportHeight, geometry.contentHeight, accuracy: 0.5)
            editor.scrollPosition = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
            let atLimit = try XCTUnwrap(editor.minimap.geometry())
            XCTAssertEqual(atLimit.viewportY + atLimit.viewportHeight, atLimit.contentHeight, accuracy: 0.5)
        }
    }

    func testMinimapViewportExcludesEstimatedOffscreenLines() throws {
        try withLargeEditor(String(repeating: "line\n", count: 16_364)) { editor in
            let geometry = try XCTUnwrap(editor.minimap.geometry())
            let maximumVisibleLines = Int(ceil(editor.textView.visibleRect.height / editor.textView.lineHeight)) + 2
            XCTAssertLessThanOrEqual(geometry.visibleLineCount, maximumVisibleLines)
            XCTAssertLessThan(geometry.viewportHeight, geometry.contentHeight)
        }
    }

    func testMinimapClickTargetsTheSourceLineUnderThePointer() throws {
        try withLargeEditor(String(repeating: "line\n", count: 20_000)) { editor in
            editor.scrollLineToTop(8000)
            let geometry = try XCTUnwrap(editor.minimap.geometry())
            let target = geometry.start + 30
            let rowHeight = geometry.contentHeight / CGFloat(geometry.visibleRows)
            editor.minimap.scroll(toMinimapY: 30.5 * rowHeight)
            let location = editor.document.lines.start(of: target)
            XCTAssertTrue(editor.textView.visibleRect.intersects(editor.textView.caretRect(at: location)),
                          "Clicking the minimap must show that source line instead of jumping by a global pixel fraction")
        }
    }

    func testFullLayoutUpdatesTheEOFScrollLimit() {
        withLargeEditor(String(repeating: "line\n", count: 16_364)) { editor in
            editor.goTo(line: editor.document.lines.count)
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.textView.sizeToFit()
            editor.scrollPosition = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
            XCTAssertTrue(editor.textView.visibleRect.intersects(editor.textView.caretRect(at: editor.document.length)))
        }
    }

    func testMinimapDragReachesTheTrueEndOfTheFile() throws {
        try withLargeEditor(String(repeating: "line\n", count: 16_364)) { editor in
            let geometry = try XCTUnwrap(editor.minimap.geometry())
            editor.minimap.dragViewport(toMinimapY: geometry.contentHeight, grabOffset: 0)
            let last = editor.textView.caretRect(at: editor.document.length)
            XCTAssertTrue(editor.textView.visibleRect.intersects(last), "minimap=\(geometry), visible=\(editor.textView.visibleRect), EOF=\(last), frame=\(editor.textView.frame)")
            let atEnd = try XCTUnwrap(editor.minimap.geometry())
            XCTAssertEqual(atEnd.viewportY + atEnd.viewportHeight, atEnd.contentHeight, accuracy: 0.5)
        }
    }

    func testWrappedLargeFileStopsAtItsVisualEndAfterResizing() {
        let paragraph = String(repeating: "long wrapped text ", count: 40) + "\n"
        withLargeEditor(String(repeating: paragraph, count: 2000)) { editor in
            editor.setWordWrap(true)
            for width: CGFloat in [700, 1100] {
                editor.frame.size.width = width
                editor.needsLayout = true
                editor.layoutSubtreeIfNeeded()
                editor.goTo(line: editor.document.lines.count)
                editor.scrollPosition = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
                XCTAssertTrue(editor.textView.visibleRect.intersects(editor.textView.caretRect(at: editor.document.length)))
            }
        }
    }

    func testLargeFileWithoutScrollPastEndStopsAtTheLastLine() {
        withLargeEditor(String(repeating: "line\n", count: 16_364)) { editor in
            editor.textView.scrollPastEnd = false
            editor.goTo(line: editor.document.lines.count)
            editor.scrollPosition = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
            let last = editor.textView.caretRect(at: editor.document.length)
            XCTAssertEqual(editor.textView.visibleRect.maxY, last.maxY + editor.textView.textContainerInset.height, accuracy: 1)
        }
    }

    func testOpeningALargeFileDoesNotLayOutTheWholeBuffer() {
        _ = NSApplication.shared
        let text = String(repeating: "let value = 42 // large-file fixture\n", count: 200_000)
        let started = Date.timeIntervalSinceReferenceDate
        let doc = Document(text: text, name: "Large.swift", language: LanguageRegistry.shared.language(forFileName: "Large.swift"))
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.setWordWrap(false)
        editor.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        editor.colorizeVisible()
        XCTAssertTrue(editor.layoutManager.allowsNonContiguousLayout)
        XCTAssertLessThan(editor.layoutManager.firstUnlaidCharacterIndex(), doc.length / 10)
        XCTAssertEqual(doc.lines.count, 200_001)
        XCTAssertGreaterThan(editor.textView.frame.height, 1_000_000)
        print("Large-file fixture: \(text.utf8.count) bytes, 200,001 lines; open + viewport \(Date.timeIntervalSinceReferenceDate - started)s")
    }
}
