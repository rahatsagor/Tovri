import XCTest
@testable import Tovri

/// Pins the feature counts the docs advertise to the code, so adding a language, a theme or a
/// file extension can't leave README or CONTRIBUTING stale.
final class DocumentationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // Tests/TovriTests/DocumentationTests.swift
            .deletingLastPathComponent() // TovriTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    private func document(_ name: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(name), encoding: .utf8)
    }

    /// The first capture group of `pattern` as a number.
    private func number(_ pattern: String, in text: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let re = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                  "no match for \(pattern)", file: file, line: line)
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text), file: file, line: line)
        return try XCTUnwrap(Int(text[range]), file: file, line: line)
    }

    func testDocumentedCountsMatchTheCode() throws {
        let readme = try document("README.md")
        let contributing = try document("CONTRIBUTING.md")
        XCTAssertEqual(try number(#"Colors for (\d+) languages"#, in: readme), Languages.all.count)
        XCTAssertEqual(try number(#"(\d+) language definitions"#, in: contributing), Languages.all.count)
        XCTAssertEqual(try number(#"(\d+) themes that can follow"#, in: readme), Themes.all.count)

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist")),
                                                   format: nil) as? [String: Any])
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let extensions = documentTypes.reduce(0) { $0 + (($1["CFBundleTypeExtensions"] as? [String]) ?? []).count }
        XCTAssertEqual(try number(#"\((\d+)\s+extensions\)"#, in: readme), extensions)
    }
}
