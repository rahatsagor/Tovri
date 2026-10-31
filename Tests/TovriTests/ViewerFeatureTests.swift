import XCTest
@testable import Tovri

final class ViewerFeatureTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    // MARK: EditorConfig

    func testEditorConfigSectionsNearerFilesAndRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("web/src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try """
        root = true

        [*]
        indent_style = space
        indent_size = 4
        trim_trailing_whitespace = true

        [*.{js,ts}]
        indent_size = 2

        [Makefile]
        indent_style = tab

        [docs/**.md]
        trim_trailing_whitespace = false
        """.write(to: root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        try "[*.ts]\nindent_size = 3\n".write(to: root.appendingPathComponent("web/.editorconfig"), atomically: true, encoding: .utf8)

        let py = EditorConfig.properties(for: root.appendingPathComponent("a.py"))
        XCTAssertEqual(py.indentsWithTabs, false)
        XCTAssertEqual(py.indentSize, 4)
        XCTAssertEqual(py.trimTrailingWhitespace, true)
        XCTAssertEqual(EditorConfig.properties(for: sub.appendingPathComponent("x.js")).indentSize, 2)
        XCTAssertEqual(EditorConfig.properties(for: sub.appendingPathComponent("x.ts")).indentSize, 3)
        XCTAssertEqual(EditorConfig.properties(for: root.appendingPathComponent("lib/Makefile")).indentsWithTabs, true)
        XCTAssertEqual(EditorConfig.properties(for: root.appendingPathComponent("docs/guide/a.md")).trimTrailingWhitespace, false)
        XCTAssertEqual(EditorConfig.properties(for: root.appendingPathComponent("other/docs/a.md")).trimTrailingWhitespace, true)
    }

    func testEditorConfigGlobs() {
        func matches(_ glob: String, _ path: String) -> Bool {
            EditorConfig.globMatches(glob, directory: "/p", path: path)
        }
        XCTAssertTrue(matches("*.swift", "/p/a/b/c.swift"))
        XCTAssertFalse(matches("*.swift", "/p/a/c.swiftx"))
        XCTAssertTrue(matches("lib/*.js", "/p/lib/a.js"))
        XCTAssertFalse(matches("lib/*.js", "/p/lib/x/a.js"))
        XCTAssertTrue(matches("lib/**.js", "/p/lib/x/a.js"))
        XCTAssertTrue(matches("{package.json,.travis.yml}", "/p/x/.travis.yml"))
        XCTAssertTrue(matches("file{1..3}.txt", "/p/file2.txt"))
        XCTAssertFalse(matches("file{1..3}.txt", "/p/file4.txt"))
        XCTAssertTrue(matches("[!a]bc", "/p/xbc"))
        XCTAssertFalse(matches("[!a]bc", "/p/abc"))
        XCTAssertTrue(matches("src/**/*.ts", "/p/src/a.ts"))
        XCTAssertTrue(matches("src/**/*.ts", "/p/src/x/y/a.ts"))
        XCTAssertTrue(matches("**/b.txt", "/p/b.txt"))
        XCTAssertTrue(matches("{a,{b,c}}.md", "/p/c.md"))
        XCTAssertTrue(matches("v{-3..3}.txt", "/p/v-2.txt"))
        XCTAssertFalse(matches("v{-3..3}.txt", "/p/v4.txt"))
        XCTAssertTrue(matches("[a-c]x", "/p/bx"))
        XCTAssertTrue(matches("\\*.md", "/p/*.md"))
        XCTAssertFalse(matches("\\*.md", "/p/a.md"))
        XCTAssertFalse(matches("*.md", "/q/a.md"))
    }

    func testHostileEditorConfigGlobsMatchQuickly() {
        let path = "/p/" + String(repeating: "a", count: 300)
        let start = Date()
        XCTAssertFalse(EditorConfig.globMatches("**a**a**a**a**a**a**a**a**a**aX", directory: "/p", path: path))
        XCTAssertFalse(EditorConfig.globMatches("*?*?*?*?*?*?*?*?*?*?X", directory: "/p", path: path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testEditorConfigAppliesIndentationButNeverRewritesExistingLineEndings() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "root = true\n[*]\nindent_style = tab\ntab_width = 8\nend_of_line = crlf\n".write(to: dir.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let existing = dir.appendingPathComponent("a.c")
        try "int x;\n".write(to: existing, atomically: true, encoding: .utf8)
        let doc = try Document(contentsOf: existing)
        XCTAssertTrue(doc.indentUsesTabs)
        XCTAssertEqual(doc.indentWidth, 8)
        XCTAssertEqual(doc.lineEnding, .lf)
        let fresh = Document(newFileAt: dir.appendingPathComponent("b.c"))
        XCTAssertEqual(fresh.lineEnding, .crlf)
        XCTAssertTrue(fresh.indentUsesTabs)
    }

    // MARK: JSON

    func testFormatJSONKeepsKeyOrderNumbersAndEscapes() throws {
        let src = #"{"b":1.50,"a":[1,2,{}],"s":"x\"{,}:y","e":[],"u":"é"}"#
        XCTAssertEqual(try JSONFormatter.reformat(src, indent: "  "), """
        {
          "b": 1.50,
          "a": [
            1,
            2,
            {}
          ],
          "s": "x\\"{,}:y",
          "e": [],
          "u": "é"
        }
        """)
        let pretty = try JSONFormatter.reformat(src, indent: "\t")
        XCTAssertEqual(try JSONFormatter.reformat(pretty, indent: nil), src)
    }

    func testFormatJSONRejectsInvalidInput() {
        XCTAssertThrowsError(try JSONFormatter.reformat("{\"a\": }", indent: "  "))
        XCTAssertThrowsError(try JSONFormatter.reformat("[1,2,]", indent: "  "))
        XCTAssertThrowsError(try JSONFormatter.reformat("{\"a\":1 , }", indent: nil))
        XCTAssertThrowsError(try JSONFormatter.reformat("{\"a\": 1} // comment", indent: "  "))
    }

    // MARK: Word count

    func testWordCount() {
        func count(_ s: String) -> Int { Document.countWords(s as NSString, in: NSRange(location: 0, length: (s as NSString).length)) }
        XCTAssertEqual(count(""), 0)
        XCTAssertEqual(count("Hello, world!"), 2)
        XCTAssertEqual(count("don’t stop — well-known it's"), 4)
        XCTAssertEqual(count("# Title\n\n- item one\n- item two"), 5)
        XCTAssertEqual(count("naïve café 123"), 3)
        XCTAssertEqual(count("emoji 🎉 here"), 3)
    }

    func testOnlyProseFilesAreSpellCheckedAndCounted() {
        let dir = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        func prose(_ name: String) -> Bool { Document(newFileAt: dir.appendingPathComponent(name)).isProse }
        XCTAssertTrue(prose("notes.txt"))
        XCTAssertTrue(prose("README.md"))
        XCTAssertTrue(prose("README"))
        XCTAssertFalse(prose("app.log"))
        XCTAssertFalse(prose("yarn.lock"))
        XCTAssertFalse(prose("server.pem"))
        XCTAssertTrue(Document().isProse)
    }

    func testKeyFilesOpenAsTextUnlessTheyAreKeynote() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pem = dir.appendingPathComponent("server.key")
        try "-----BEGIN PRIVATE KEY-----\n".write(to: pem, atomically: true, encoding: .utf8)
        XCTAssertFalse(MainWindowController.prefersQuickLook(pem))
        let keynote = dir.appendingPathComponent("talk.key")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: keynote)
        XCTAssertTrue(MainWindowController.prefersQuickLook(keynote))
    }

    // MARK: Quick Look

    func testQuickLookOnlyForNonTextFiles() {
        for name in ["photo.png", "scan.pdf", "clip.mov", "song.mp3", "report.docx", "data.xlsx"] {
            XCTAssertTrue(MainWindowController.prefersQuickLook(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["app.ts", "icon.svg", "notes.txt", "README.md", "main.swift", "Makefile", "data.json", "noext"] {
            XCTAssertFalse(MainWindowController.prefersQuickLook(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    // MARK: Following a growing file

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

    private func append(_ text: String, to url: URL, bumpingDateBy seconds: TimeInterval) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)], ofItemAtPath: url.path)
        // URL resource values stay cached until the run loop turns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testCaretAtTheEndFollowsAGrowingFileAndOtherwiseStaysPut() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent.log")
        try "line 1\nline 2\n".write(to: url, atomically: true, encoding: .utf8)
        try withController { controller in
            let doc = try XCTUnwrap(controller.open(url: url))
            controller.rootView.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.activeEditor)
            editor.textView.setAllSelections([NSRange(location: doc.length, length: 0)])
            try append("line 3\n", to: url, bumpingDateBy: 5)
            controller.handleDiskChange(doc)
            XCTAssertEqual(doc.string as String, "line 1\nline 2\nline 3\n")
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: doc.length, length: 0))

            editor.textView.setAllSelections([NSRange(location: 2, length: 0)])
            try append("line 4\n", to: url, bumpingDateBy: 10)
            controller.handleDiskChange(doc)
            XCTAssertTrue((doc.string as String).hasSuffix("line 4\n"))
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
        }
    }
}
