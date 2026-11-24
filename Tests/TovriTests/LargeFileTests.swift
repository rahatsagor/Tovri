import AppKit
import CryptoKit
import XCTest
@testable import Tovri

final class LargeFileTests: XCTestCase {
    func testASCIILineIndexMatchesTheGeneralScan() {
        for text in ["", "one", "one\n", "\n\nthree\n", "a\nbb\nccc\ndddd", String(repeating: "x = 1\n", count: 5_000) + "tail"] {
            let fast = LineIndex(), slow = LineIndex()
            XCTAssertTrue(fast.rebuild(fromASCII: text))
            slow.rebuild(from: text as NSString)
            XCTAssertEqual(fast.starts, slow.starts, text.prefix(20).debugDescription)
        }
        let index = LineIndex()
        index.rebuild(from: "keep\nme" as NSString)
        XCTAssertFalse(index.rebuild(fromASCII: "café\nnaïve\n"), "text beyond ASCII uses the general scan")
        XCTAssertFalse(index.rebuild(fromASCII: "emoji 😀\n"))
        XCTAssertEqual(index.starts, [0, 5], "a refused rebuild leaves the index alone")
    }

    func testALargeFilesFingerprintIsTheHashOfItsBytesEvenWhenComputedInTheBackground() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, bytes) in [("big.log", PendingFingerprint.backgroundThreshold + 4096), ("small.log", 4096)] {
            let url = dir.appendingPathComponent(name)
            let data = Data(String(repeating: "14:00:01 INFO line\n", count: bytes / 19 + 1).utf8)
            try data.write(to: url)
            let doc = try Document(contentsOf: url)
            XCTAssertEqual(doc.lastReadDiskFingerprint, Data(SHA256.hash(data: data)), name)
            XCTAssertEqual(doc.lines.count, bytes / 19 + 2, name)
            XCTAssertTrue(doc.matchesBackupDiskVersion(doc.lastReadDiskStamp, fingerprint: Data(SHA256.hash(data: data))), name)
        }
    }

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

final class LargeFileBenchmarkTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestIsolationObserver.install()
    }

    func testLargeFileEntryPointBenchmarks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOVRI_RUN_BENCHMARKS"] == "1",
                          "Set TOVRI_RUN_BENCHMARKS=1 to run large-file entry-point benchmarks")
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovri-bench-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        AppRuntime.defaults.set(false, forKey: Settings.Key.gitEnabled)
        defer {
            AppRuntime.defaults.removeObject(forKey: Settings.Key.gitEnabled)
            Settings.shared.reloadFromDefaults()
        }

        // Prepare a 200,000-line (~10.4 MB) Swift source file on disk beside an .editorconfig.
        try "root = true\n\n[*.swift]\nindent_style = space\nindent_size = 4\n"
            .write(to: dir.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let lineTemplate = "let computedItemValue = computeScore(offset: 42) // sample source line\n"
        var largeText = ""
        largeText.reserveCapacity(200_000 * lineTemplate.utf8.count)
        for _ in 0..<200_000 { largeText.append(lineTemplate) }
        let largeURL = dir.appendingPathComponent("LargeFixture.swift")
        try largeText.write(to: largeURL, atomically: true, encoding: .utf8)
        let bytesCount = largeText.utf8.count

        let c = MainWindowController()
        defer {
            for g in c.groups { for t in g.tabs { t.close() } }
            c.teardown()
            c.window?.delegate = nil
            c.window?.close()
        }
        c.rootView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        // 1. Real disk open -> DocumentRegistry + EditorConfig + EditorView + first viewport layout & colorize.
        let tOpen0 = CACurrentMediaTime()
        let doc = try XCTUnwrap(c.open(url: largeURL))
        let editor = try XCTUnwrap(c.activeEditor)
        editor.setWordWrap(false)
        c.rootView.layoutSubtreeIfNeeded()
        editor.colorizeVisible()
        let openMs = (CACurrentMediaTime() - tOpen0) * 1000
        let firstUnlaid = editor.layoutManager.firstUnlaidCharacterIndex()
        XCTAssertLessThan(firstUnlaid, doc.length / 10, "Open laid out too much of the 200k-line document")

        // 2. Interactive top-of-file keystroke latency (50 edits at line 1).
        editor.textView.setAllSelections([NSRange(location: 0, length: 0)], scroll: false)
        var keySamples: [Double] = []
        keySamples.reserveCapacity(50)
        for _ in 0..<50 {
            let k0 = CACurrentMediaTime()
            editor.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.layoutManager.ensureLayout(for: editor.textContainer)
            editor.colorizeVisible()
            keySamples.append((CACurrentMediaTime() - k0) * 1000)
        }
        let sortedKeys = keySamples.sorted()
        let keyMedianMs = sortedKeys[sortedKeys.count / 2]
        let keyP95Ms = sortedKeys[Int(Double(sortedKeys.count - 1) * 0.95)]

        // Undo back to clean before tail reload test later.
        doc.undoManager.removeAllActions()
        try doc.reload()

        // 3. Jump to EOF + layout at line 200,000.
        let tEof0 = CACurrentMediaTime()
        editor.goTo(line: doc.lines.count)
        editor.layoutSubtreeIfNeeded()
        let eofMs = (CACurrentMediaTime() - tEof0) * 1000

        // 4. Incremental log tail reload (append 200 lines at EOF & reloadPreservingViews).
        let fh = try FileHandle(forUpdating: largeURL)
        try fh.seekToEnd()
        let tailAppend = String(repeating: "let appendedTailEntry = true // tail-append line\n", count: 200)
        try fh.write(contentsOf: Data(tailAppend.utf8))
        try fh.close()
        let tReload0 = CACurrentMediaTime()
        XCTAssertTrue(c.reloadPreservingViews(doc))
        let tailReloadMs = (CACurrentMediaTime() - tReload0) * 1000

        // 5. 100,000-line Patience + Myers line diff.
        var oldDiffLines: [String] = []
        oldDiffLines.reserveCapacity(100_000)
        for i in 0..<100_000 { oldDiffLines.append("let row_\(i % 997) = value_\(i) // row \(i)") }
        var newDiffLines = oldDiffLines
        for idx in stride(from: 500, to: 100_000, by: 5_000) {
            newDiffLines[idx] = "let modified_\(idx) = true"
            if idx + 1 < newDiffLines.count { newDiffLines[idx + 1] = "let extra_\(idx) = false" }
        }
        let oldStr = oldDiffLines.joined(separator: "\n") + "\n"
        let newStr = newDiffLines.joined(separator: "\n") + "\n"
        let tDiff0 = CACurrentMediaTime()
        let diff = GitRepository.diff(oldText: oldStr, newText: newStr)
        let diffMs = (CACurrentMediaTime() - tDiff0) * 1000
        XCTAssertEqual(diff.hunks.count, 20)

        // 6. Workspace FileSearcher across 500 files (~20 MB total).
        let wsDir = dir.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        let chunkBody = String(repeating: "func sampleWork() { let item = 1 }\n", count: 1100) + "// uniqueNeedleToken\n"
        for i in 0..<500 {
            let sub = wsDir.appendingPathComponent("mod\(i % 10)")
            if i < 10 { try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true) }
            try chunkBody.write(to: sub.appendingPathComponent("file_\(i).swift"), atomically: true, encoding: .utf8)
        }
        let searchOpts = FileSearcher.Options(query: "uniqueNeedleToken", regex: false, caseSensitive: true,
                                              wholeWord: true, root: wsDir, include: [], exclude: [])
        let tSearch0 = CACurrentMediaTime()
        let searchRes = try XCTUnwrap(FileSearcher().run(searchOpts))
        let searchMs = (CACurrentMediaTime() - tSearch0) * 1000
        XCTAssertEqual(searchRes.files, 500)
        XCTAssertEqual(searchRes.matches, 500)

        print(String(format: "BENCHMARK disk_open_200k_lines bytes=%d open_ms=%.2f firstUnlaid=%d docLen=%d", bytesCount, openMs, firstUnlaid, doc.length))
        print(String(format: "BENCHMARK keystroke_top_200k_lines median_ms=%.2f p95_ms=%.2f", keyMedianMs, keyP95Ms))
        print(String(format: "BENCHMARK jump_eof_200k_lines eof_ms=%.2f", eofMs))
        print(String(format: "BENCHMARK tail_reload_200_lines_on_200k reload_ms=%.2f", tailReloadMs))
        print(String(format: "BENCHMARK patience_diff_100k_lines diff_ms=%.2f hunks=%d", diffMs, diff.hunks.count))
        print(String(format: "BENCHMARK workspace_search_500_files_20mb search_ms=%.2f matches=%d", searchMs, searchRes.matches))
    }
}
