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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TovriTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
