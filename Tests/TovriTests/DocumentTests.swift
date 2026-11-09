import XCTest
@testable import Tovri

final class DocumentTests: XCTestCase {
    func testCRLFNormalizationWithAndWithoutRawBytes() {
        let source = "first\r\nsecond\r\n"
        for data in [nil, Data(source.utf8)] {
            let (text, ending) = LineEnding.normalize(source, rawData: data)
            XCTAssertEqual(text, "first\nsecond\n")
            XCTAssertEqual(ending, .crlf)
        }
    }

    func testMixedAndClassicLineEndings() {
        let (mixed, mixedEnding) = LineEnding.normalize("a\r\nb\rc\n", rawData: nil)
        XCTAssertEqual(mixed, "a\nb\nc\n")
        XCTAssertEqual(mixedEnding, .crlf)
        let (classic, classicEnding) = LineEnding.normalize("a\rb\r", rawData: nil)
        XCTAssertEqual(classic, "a\nb\n")
        XCTAssertEqual(classicEnding, .cr)
    }

    func testWindowsFileEditPreservesLineEndingsOnSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("windows.txt")
        try Data("one\r\ntwo\r\n".utf8).write(to: url)
        let doc = try Document(contentsOf: url)
        XCTAssertEqual(doc.lineEnding, .crlf)
        XCTAssertEqual(doc.string as String, "one\ntwo\n")
        doc.textStorage.replaceCharacters(in: NSRange(location: doc.length, length: 0), with: "three\n")
        try doc.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\r\ntwo\r\nthree\r\n")
    }

    func testBinaryFileCannotBeOpenedAsEditableText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("binary.dat")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff, 0x0d, 0x0a])
        try bytes.write(to: url)
        XCTAssertThrowsError(try Document(contentsOf: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUTF16TextRemainsSupported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for encoding in [TextEncoding.utf16LE, .utf16BE, .utf8BOM] {
            let url = directory.appendingPathComponent(encoding.rawValue + ".txt")
            try XCTUnwrap(encoding.encode("Hello 🌏\r\n")).write(to: url)
            let doc = try Document(contentsOf: url)
            XCTAssertEqual(doc.encoding, encoding)
            XCTAssertEqual(doc.string as String, "Hello 🌏\n")
            XCTAssertEqual(doc.lineEnding, .crlf)
            try doc.save()
            XCTAssertEqual(try Data(contentsOf: url), encoding.encode("Hello 🌏\r\n"))
        }
    }

    func testPipedTextIsNormalizedLikeAFile() {
        let doc = Document(text: "one\r\ntwo\r\n", name: "Piped", language: LanguageRegistry.shared.plain)
        XCTAssertEqual(doc.string as String, "one\ntwo\n")
        XCTAssertEqual(doc.lineEnding, .crlf)
    }

    func testLargeLegacyEncodingsKeepCombiningCharactersAcrossChunkBoundaries() throws {
        let cases: [(TextEncoding, String)] = [
            (.windows1252, "e\u{301}"), (.latin1, "e\u{301}"), (.macRoman, "a\u{308}"),
            (.shiftJIS, "か\u{3099}"), (.eucKR, "か\u{3099}"),
        ]
        for (encoding, characters) in cases {
            let text = String(repeating: "a", count: 262_143) + characters + "\nend\n"
            for ending in LineEnding.allCases {
                let expected = try XCTUnwrap(encoding.encode(text.replacingOccurrences(of: "\n", with: ending.string)))
                XCTAssertEqual(Document.encode(text as NSString, encoding: encoding, lineEnding: ending), expected,
                               "\(encoding.rawValue), \(ending.rawValue)")
            }
        }
    }

    func testLargeGB18030SavePreservesBOMCharactersAtChunkBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for offset in [31, 262_143, 262_144, 262_145] {
            let text = String(repeating: "a", count: offset) + "\u{FEFF}\nend\n"
            // GB 18030 represents U+FEFF as 84 31 95 33; the remaining bytes are ASCII.
            let expected = Data(repeating: 0x61, count: offset) + Data([0x84, 0x31, 0x95, 0x33]) + Data("\nend\n".utf8)
            let url = directory.appendingPathComponent("gb18030-\(offset).txt")
            let doc = Document(text: text, name: "GB 18030", language: LanguageRegistry.shared.plain)
            doc.encoding = .gb18030
            try doc.checkBeforeSaving(to: url)
            try doc.save(to: url)
            XCTAssertEqual(try Data(contentsOf: url), expected)
            XCTAssertEqual(doc.string as String, text)
            XCTAssertEqual(try Document(contentsOf: url, encoding: .gb18030).string as String, text)
        }
    }

    func testGB18030KeepsLeadingTrailingAndRepeatedBOMCharacters() throws {
        let marker = Data([0x84, 0x31, 0x95, 0x33])
        for count in [0, 1, 262_144, 524_288] {
            let text = "\u{FEFF}" + String(repeating: "a", count: count) + "\u{FEFF}\u{FEFF}"
            let expected = marker + Data(repeating: 0x61, count: count) + marker + marker
            XCTAssertEqual(TextEncoding.decode(expected, preferred: .gb18030).text, text)
            for source in [text as NSString, NSMutableString(string: text)] {
                XCTAssertEqual(TextEncoding.gb18030.encode(source as String), expected)
                XCTAssertEqual(Document.encode(source, encoding: .gb18030, lineEnding: .lf), expected)
            }
        }
        XCTAssertEqual(TextEncoding.gb18030.encode(""), Data())
    }

    func testLargeUnicodeEncodingsPreserveSurrogatesBOMsAndLineEndings() throws {
        for encoding in [TextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            for offset in [262_143, 262_144] {
                let text = "\u{FEFF}" + String(repeating: "a", count: offset - 1) + "🎉e\u{301}\n\u{FEFF}end\n"
                for ending in LineEnding.allCases {
                    let expected = try XCTUnwrap(encoding.encode(text.replacingOccurrences(of: "\n", with: ending.string)))
                    XCTAssertEqual(Document.encode(text as NSString, encoding: encoding, lineEnding: ending), expected,
                                   "\(encoding.rawValue), \(ending.rawValue), \(offset)")
                }
            }
        }
    }

    func testLargeUnencodableDocumentLeavesDiskAndBufferIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("latin1.txt")
        try Data("original\n".utf8).write(to: url)
        let doc = try Document(contentsOf: url, encoding: .latin1)
        let text = String(repeating: "a", count: 262_143) + "🎉\n"
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.length), with: text)
        XCTAssertThrowsError(try doc.save()) { error in
            guard case DocumentError.encodingFailed(.latin1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("original\n".utf8))
        XCTAssertEqual(doc.string as String, text)
        XCTAssertTrue(doc.isDirty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TovriTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
