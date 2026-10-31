import AppKit
import XCTest
@testable import Tovri

/// Loading and saving must reproduce the user's bytes exactly unless they edit, and every failure
/// must leave both the file on disk and the buffer in memory intact.
final class FileSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TovriFiles-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Read-only fixtures must be made writable again before they can be removed.
        if let items = FileManager.default.enumerator(atPath: directory.path) {
            for case let item as String in items { chmod(directory.appendingPathComponent(item).path, 0o755) }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func append(_ text: String, to doc: Document) {
        doc.textStorage.replaceCharacters(in: NSRange(location: doc.length, length: 0), with: text)
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static let samples: [TextEncoding: String] = [
        .utf8: "Grüße, 世界 🌏 👩‍👩‍👧 e\u{301}",
        .utf8BOM: "Grüße, 世界 🌏 👩‍👩‍👧 e\u{301}",
        .utf16LE: "Grüße, 世界 🌏 👩‍👩‍👧 𝄞",
        .utf16BE: "Grüße, 世界 🌏 👩‍👩‍👧 𝄞",
        .windows1252: "Café – “quoted” €5 Œuvre",
        .latin1: "Café ñ ÿ ± ß",
        .macRoman: "Café ∑ π ﬁ ≈",
        .shiftJIS: "こんにちは 日本語 ｶﾀｶﾅ \\ ~",
        .gb18030: "你好，世界 😀 ①",
        .eucKR: "안녕하세요 세계",
    ]

    // MARK: Round trips

    func testUnmodifiedSaveIsByteExactForEveryEncodingAndLineEnding() throws {
        for encoding in TextEncoding.allCases {
            let sample = try XCTUnwrap(Self.samples[encoding])
            let longLine = String(repeating: "ascii " + sample, count: 6_000)
            let variants: [String: String] = [
                "lf": "first \(sample)\nsecond\n",
                "crlf": "first \(sample)\r\nsecond\r\n",
                "cr": "first \(sample)\rsecond\r",
                "no-trailing-newline": "first\n\(sample)",
                "empty": "",
                "only-lf": "\n\n\n",
                "only-crlf": "\r\n\r\n",
                "long-line": longLine + "\n" + longLine,
            ]
            for (name, text) in variants {
                let original = try XCTUnwrap(encoding.encode(text), "\(encoding.rawValue) can't encode \(name)")
                let url = try file("\(encoding.rawValue)-\(name).txt", original)
                let doc = try Document(contentsOf: url, encoding: encoding)
                XCTAssertEqual(doc.encoding, encoding, "\(encoding.rawValue) \(name)")
                XCTAssertFalse(doc.isDirty, "\(encoding.rawValue) \(name)")
                XCTAssertFalse((doc.string as String).contains("\r"), "\(encoding.rawValue) \(name)")
                try doc.save()
                XCTAssertEqual(try bytes(url), original, "\(encoding.rawValue) \(name) changed on an unmodified save")
            }
        }
    }

    func testDetectedEncodingsRoundTripWithoutAPreference() throws {
        let cases: [(String, Data, TextEncoding)] = [
            ("utf8", Data("plain ✓ 🌏\n".utf8), .utf8),
            ("utf8-bom", Data([0xEF, 0xBB, 0xBF]) + Data("bom ✓\n".utf8), .utf8BOM),
            ("utf16le", try XCTUnwrap(TextEncoding.utf16LE.encode("wide 🌏\r\n")), .utf16LE),
            ("utf16be", try XCTUnwrap(TextEncoding.utf16BE.encode("wide 🌏\r\n")), .utf16BE),
            ("cp1252", Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x0A]), .windows1252),
            ("latin1", Data([0x41, 0x81, 0x8D, 0xE9, 0x0A]), .latin1),
        ]
        for (name, original, expected) in cases {
            let url = try file(name + ".txt", original)
            let doc = try Document(contentsOf: url)
            XCTAssertEqual(doc.encoding, expected, name)
            try doc.save()
            XCTAssertEqual(try bytes(url), original, name)
        }
    }

    func testEverySingleByteValueRoundTripsThroughTheEightBitFallbacks() throws {
        let all = Data((1...255).map { UInt8($0) }.filter { $0 != 0x0D })
        let url = try file("all-bytes.txt", all)
        let doc = try Document(contentsOf: url)
        XCTAssertEqual(doc.encoding, .latin1)
        try doc.save()
        XCTAssertEqual(try bytes(url), all)

        let undefinedIn1252: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
        let cp1252 = Data(all.filter { !undefinedIn1252.contains($0) })
        let cpURL = try file("cp1252-bytes.txt", cp1252)
        let cpDoc = try Document(contentsOf: cpURL)
        XCTAssertEqual(cpDoc.encoding, .windows1252)
        try cpDoc.save()
        XCTAssertEqual(try bytes(cpURL), cp1252)

        for encoding in [TextEncoding.macRoman, .latin1] {
            let encURL = try file(encoding.rawValue + "-bytes.txt", all)
            let encDoc = try Document(contentsOf: encURL, encoding: encoding)
            XCTAssertEqual(encDoc.encoding, encoding)
            try encDoc.save()
            XCTAssertEqual(try bytes(encURL), all, encoding.rawValue)
        }
    }

    func testRepeatedByteOrderMarksAreKeptAsText() throws {
        let cases: [(String, Data, TextEncoding)] = [
            ("utf8", Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61, 0x0A]), .utf8BOM),
            ("utf16le", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x61, 0x00]), .utf16LE),
            ("utf16be", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x61]), .utf16BE),
        ]
        for (name, original, expected) in cases {
            let url = try file(name + ".txt", original)
            let doc = try Document(contentsOf: url)
            XCTAssertEqual(doc.encoding, expected, name)
            XCTAssertTrue((doc.string as String).hasPrefix("\u{FEFF}"), name)
            try doc.save()
            XCTAssertEqual(try bytes(url), original, name)
        }
    }

    func testUTF8PreferenceKeepsAByteOrderMark() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("marked\n".utf8)
        let url = try file("bom.txt", original)
        let reopened = try Document(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(reopened.encoding, .utf8BOM)
        XCTAssertEqual(reopened.string as String, "marked\n")
        try reopened.save()
        XCTAssertEqual(try bytes(url), original)

        // Another program adds a BOM to a file that was open as plain UTF-8.
        let plainURL = try file("plain.txt", Data("plain\n".utf8))
        let doc = try Document(contentsOf: plainURL)
        XCTAssertEqual(doc.encoding, .utf8)
        try original.write(to: plainURL)
        try doc.reload()
        XCTAssertEqual(doc.encoding, .utf8BOM)
        try doc.save()
        XCTAssertEqual(try bytes(plainURL), original)
    }

    func testMixedLineEndingsUseTheMostCommonConvention() throws {
        // The buffer stores one convention, so a mixed file is normalized to whichever ending most
        // lines use; a stray CR must not turn a Unix file into a classic Mac file.
        let cases: [(String, LineEnding, String)] = [
            ("one\ntwo\rthree\nfour\n", .lf, "one\ntwo\nthree\nfour\n"),
            ("one\r\ntwo\nthree\r\nfour\r\n", .crlf, "one\r\ntwo\r\nthree\r\nfour\r\n"),
            ("one\rtwo\rthree\nfour\r", .cr, "one\rtwo\rthree\rfour\r"),
            ("one\ntwo\nthree\r\n", .lf, "one\ntwo\nthree\n"),
        ]
        for (index, (source, ending, saved)) in cases.enumerated() {
            let url = try file("mixed-\(index).txt", Data(source.utf8))
            let doc = try Document(contentsOf: url)
            XCTAssertEqual(doc.lineEnding, ending, source.debugDescription)
            try doc.save()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), saved, source.debugDescription)
        }
    }

    // MARK: Editing and encoding failures

    func testEditedSaveKeepsTheChosenEncodingAndLineEnding() throws {
        for encoding in TextEncoding.allCases {
            for ending in LineEnding.allCases {
                let sample = try XCTUnwrap(Self.samples[encoding])
                let source = "head\(ending.string)\(sample)\(ending.string)"
                let url = try file("edit-\(encoding.rawValue)-\(ending.rawValue).txt", try XCTUnwrap(encoding.encode(source)))
                let doc = try Document(contentsOf: url, encoding: encoding)
                XCTAssertEqual(doc.lineEnding, ending)
                append("tail \(sample)\nlast", to: doc)
                XCTAssertTrue(doc.isDirty)
                try doc.save()
                XCTAssertFalse(doc.isDirty)
                let expected = source + "tail \(sample)\(ending.string)last"
                XCTAssertEqual(try bytes(url), encoding.encode(expected), "\(encoding.rawValue) \(ending.rawValue)")
            }
        }
    }

    func testUnrepresentableCharactersFailBeforeAnythingIsWritten() throws {
        let original = try XCTUnwrap(TextEncoding.latin1.encode("Café\n"))
        let url = try file("latin1.txt", original)
        let doc = try Document(contentsOf: url, encoding: .latin1)
        append("snowman ☃ and 😀\n", to: doc)
        XCTAssertThrowsError(try doc.save()) { error in
            guard case DocumentError.encodingFailed(.latin1) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try bytes(url), original)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.string as String, "Café\nsnowman ☃ and 😀\n")

        let fresh = directory.appendingPathComponent("never-created.txt")
        XCTAssertThrowsError(try doc.save(to: fresh))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(doc.url, url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["latin1.txt"],
                       "A failed save must not leave temporary files behind")
    }

    // MARK: File system metadata

    func testSavePreservesPermissionsExtendedAttributesAndCreationDate() throws {
        let fm = FileManager.default
        for mode: Int16 in [0o600, 0o640, 0o755] {
            let url = try file("mode-\(mode).sh", Data("echo hi\n".utf8))
            chmod(url.path, mode_t(mode))
            let value = Data("keep me".utf8)
            XCTAssertEqual(value.withUnsafeBytes { setxattr(url.path, "app.tovri.test", $0.baseAddress, value.count, 0, 0) }, 0)
            let created = Date(timeIntervalSince1970: 1_000_000_000)
            try fm.setAttributes([.creationDate: created], ofItemAtPath: url.path)
            let doc = try Document(contentsOf: url)
            append("echo bye\n", to: doc)
            try doc.save()
            let attrs = try fm.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, mode)
            XCTAssertEqual(attrs[.creationDate] as? Date, created)
            var buffer = [UInt8](repeating: 0, count: 64)
            let size = getxattr(url.path, "app.tovri.test", &buffer, buffer.count, 0, 0)
            XCTAssertEqual(size, value.count, "Extended attributes such as Finder tags must survive a save")
            if size > 0 { XCTAssertEqual(Data(buffer.prefix(size)), value) }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "echo hi\necho bye\n")
        }
    }

    func testNewFilesGetTheDefaultPermissions() throws {
        let mask = umask(0)
        umask(mask)
        let url = directory.appendingPathComponent("created.txt")
        let doc = Document(newFileAt: url)
        append("new\n", to: doc)
        try doc.save()
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode_t(mode.intValue), 0o666 & ~mask)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\n")
        XCTAssertFalse(doc.isNewFile)
    }

    func testSavingThroughSymlinksWritesTheTargetAndKeepsTheLinks() throws {
        let fm = FileManager.default
        let real = directory.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let target = try file("real/target.txt", Data("original\r\n".utf8))
        let absoluteLink = directory.appendingPathComponent("absolute.txt")
        try fm.createSymbolicLink(at: absoluteLink, withDestinationURL: target)
        let relativeLink = directory.appendingPathComponent("relative.txt")
        try fm.createSymbolicLink(atPath: relativeLink.path, withDestinationPath: "real/target.txt")

        for (index, link) in [absoluteLink, relativeLink].enumerated() {
            let doc = try Document(contentsOf: link)
            XCTAssertEqual(doc.lineEnding, .crlf)
            XCTAssertEqual(doc.checkDiskStatus(), .unchanged)
            append("edit \(index)\n", to: doc)
            try doc.save()
            XCTAssertEqual(try fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeSymbolicLink)
            XCTAssertEqual(doc.url, link)
            XCTAssertEqual(doc.checkDiskStatus(), .unchanged, "Our own save must not look like an external change")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original\r\nedit 0\r\nedit 1\r\n")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: real.path), ["target.txt"])
    }

    func testReadOnlyFileIsNeverReplaced() throws {
        let original = Data("protected\n".utf8)
        let url = try file("readonly.txt", original)
        chmod(url.path, 0o444)
        let doc = try Document(contentsOf: url)
        append("my edit\n", to: doc)
        XCTAssertThrowsError(try doc.save()) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission, "\(error)")
        }
        XCTAssertEqual(try bytes(url), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value, 0o444)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.string as String, "protected\nmy edit\n")

        // Save As to a writable location still works and keeps the edit.
        let copy = directory.appendingPathComponent("copy.txt")
        try doc.save(to: copy)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "protected\nmy edit\n")
        XCTAssertFalse(doc.isDirty)
    }

    func testFileInAReadOnlyDirectoryReportsAnErrorAndKeepsTheEdit() throws {
        let folder = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data("inside locked folder\n".utf8)
        let url = try file("locked/file.txt", original)
        chmod(folder.path, 0o555)
        let doc = try Document(contentsOf: url)
        append("edit\n", to: doc)
        XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try bytes(url), original)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.string as String, "inside locked folder\nedit\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["file.txt"])
    }

    // MARK: External changes

    func testSaveRefusesToOverwriteAFileChangedByAnotherApp() throws {
        let url = try file("shared.txt", Data("mine\n".utf8))
        let doc = try Document(contentsOf: url)
        append("my edit\n", to: doc)
        let external = Data("written by another app\n".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try doc.save()) { error in
            guard case DocumentError.modifiedOnDisk = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try bytes(url), external)
        XCTAssertTrue(doc.isDirty)

        try doc.save(replacingExternalChanges: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\nmy edit\n")
        XCTAssertFalse(doc.isDirty)
        append("again\n", to: doc)
        try doc.save()
    }

    func testSaveRefusesToReplaceAFileCreatedAtANewFilePath() throws {
        let url = directory.appendingPathComponent("planned.txt")
        let doc = Document(newFileAt: url)
        append("planned\n", to: doc)
        let external = Data("created meanwhile\n".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try bytes(url), external)
        try doc.save(replacingExternalChanges: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "planned\n")
    }

    func testChangesThatKeepOrRewindTheModificationDateAreDetected() throws {
        let url = try file("dated.txt", Data("version one\n".utf8))
        let doc = try Document(contentsOf: url)
        let loadedDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        // Restoring a backup or syncing a file can set an older timestamp.
        try Data("restored from backup\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: loadedDate.addingTimeInterval(-3600)], ofItemAtPath: url.path)
        XCTAssertEqual(doc.checkDiskStatus(), .modified)

        try doc.reload()
        XCTAssertEqual(doc.checkDiskStatus(), .unchanged)
        // Same timestamp, different size (coarse-timestamp file systems).
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try Data("restored from backup, then edited\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        XCTAssertEqual(doc.checkDiskStatus(), .modified)
    }

    func testExternalModificationReloadsCleanDocumentsAndNeverOverwritesDirtyOnes() throws {
        let cleanURL = try file("clean.txt", Data("before\n".utf8))
        let dirtyURL = try file("dirty.txt", Data("before\n".utf8))
        let controller = MainWindowController()
        defer {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let clean = try XCTUnwrap(controller.open(url: cleanURL))
        let dirty = try XCTUnwrap(controller.open(url: dirtyURL))
        append("unsaved\n", to: dirty)

        try Data("after\r\n".utf8).write(to: cleanURL)
        try Data("after\n".utf8).write(to: dirtyURL)
        controller.handleDiskChange(clean)
        XCTAssertEqual(clean.string as String, "after\n")
        XCTAssertEqual(clean.lineEnding, .crlf)
        XCTAssertFalse(clean.isDirty)

        controller.handleDiskChange(dirty)
        XCTAssertEqual(dirty.string as String, "before\nunsaved\n")
        XCTAssertTrue(dirty.isDirty)
        XCTAssertEqual(try String(contentsOf: dirtyURL, encoding: .utf8), "after\n")
    }

    func testDeletedFileKeepsItsTextAndStaysUnsavedAfterUndo() throws {
        let url = try file("doomed.txt", Data("keep this text\n".utf8))
        let doc = try Document(contentsOf: url)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(doc.checkDiskStatus(), .deleted)
        doc.markDeletedOnDisk()
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.string as String, "keep this text\n")

        editor.textView.setSelectedRange(NSRange(location: doc.length, length: 0))
        editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
        doc.undoManager.undo()
        spinRunLoop(0.1)
        XCTAssertEqual(doc.string as String, "keep this text\n")
        XCTAssertTrue(doc.isDirty, "Undoing back to the deleted file's text must not make the buffer discardable")

        try doc.save()
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep this text\n")
    }

    func testUndoBackToTheSavedTextClearsDirtyAndRestoredBuffersCompareWithDisk() throws {
        let url = try file("undo.txt", Data("saved\n".utf8))
        let doc = try Document(contentsOf: url)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.setSelectedRange(NSRange(location: doc.length, length: 0))
        editor.textView.insertText("typed", replacementRange: editor.textView.selectedRange())
        XCTAssertTrue(doc.isDirty)
        doc.undoManager.undo()
        spinRunLoop(0.1)
        XCTAssertEqual(doc.string as String, "saved\n")
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.redo()
        spinRunLoop(0.1)
        XCTAssertTrue(doc.isDirty)

        doc.restoreBuffer("saved\n")
        XCTAssertFalse(doc.isDirty)
        doc.restoreBuffer("saved\nplus\n")
        XCTAssertTrue(doc.isDirty)
    }

    func testRenamingAnOpenFileFollowsItWithoutSavingUnsavedEdits() throws {
        let url = try file("before.txt", Data("on disk\n".utf8))
        let moved = directory.appendingPathComponent("after.md")
        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let doc = try XCTUnwrap(controller.open(url: url))
        append("not saved yet\n", to: doc)
        try FileManager.default.moveItem(at: url, to: moved)
        controller.sidebar(controller.sidebar, didMove: url, to: moved)

        XCTAssertEqual(doc.url, moved)
        XCTAssertEqual(doc.displayName, "after.md")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.string as String, "on disk\nnot saved yet\n")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "on disk\n")
        XCTAssertEqual(doc.checkDiskStatus(), .unchanged)
        XCTAssertTrue(DocumentRegistry.shared.existing(for: moved) === doc)
        try doc.save()
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "on disk\nnot saved yet\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Monitoring

    private func expectDiskNotification(_ doc: Document, _ description: String) -> XCTestExpectation {
        let e = XCTNSNotificationExpectation(name: .documentFileDidChangeOnDisk, object: doc)
        e.expectationDescription = description
        e.assertForOverFulfill = false
        return e
    }

    func testMonitoringSurvivesAtomicReplacementByAnotherApp() throws {
        let url = try file("watched.txt", Data("one\n".utf8))
        let doc = try Document(contentsOf: url)
        for round in 1...2 {
            let e = expectDiskNotification(doc, "replacement \(round)")
            let temp = directory.appendingPathComponent(".watched-\(round).tmp")
            try Data("replacement \(round)\n".utf8).write(to: temp)
            XCTAssertEqual(rename(temp.path, url.path), 0)
            wait(for: [e], timeout: 3)
            XCTAssertEqual(doc.checkDiskStatus(), .modified)
            try doc.reload()
            XCTAssertEqual(doc.string as String, "replacement \(round)\n")
            spinRunLoop(0.6) // let the re-armed watcher settle before the next change
        }
        let inPlace = expectDiskNotification(doc, "in-place write")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("appended\n".utf8))
        try handle.close()
        wait(for: [inPlace], timeout: 3)
    }

    func testMonitoringResumesWhenADeletedFileComesBack() throws {
        let url = try file("flaky.txt", Data("one\n".utf8))
        let doc = try Document(contentsOf: url)
        let deleted = expectDiskNotification(doc, "deletion")
        try FileManager.default.removeItem(at: url)
        wait(for: [deleted], timeout: 3)
        XCTAssertEqual(doc.checkDiskStatus(), .deleted)
        spinRunLoop(0.6)

        try Data("two\n".utf8).write(to: url)
        XCTAssertEqual(doc.checkDiskStatus(), .modified)
        doc.acknowledgeDiskVersion() // "Keep My Changes": no reload re-arms the watcher
        let changed = expectDiskNotification(doc, "write after the file returned")
        spinRunLoop(0.1)
        try Data("three\n".utf8).write(to: url)
        wait(for: [changed], timeout: 3)
    }
}
