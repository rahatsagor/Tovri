import XCTest
@testable import Tovri

final class FileSearchTests: XCTestCase {
    func testSearchingAnEmptyFolderReturnsNoResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TovriSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = FileSearcher.Options(query: "test", regex: false, caseSensitive: false,
                                          wholeWord: false, root: root, include: [], exclude: [])
        let result = try XCTUnwrap(FileSearcher().run(options))
        XCTAssertEqual(result.matches, 0)
        XCTAssertEqual(result.scanned, 0)
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.text, "")
    }
}
