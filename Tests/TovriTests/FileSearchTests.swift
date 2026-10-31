import XCTest
@testable import Tovri

final class FileSearchTests: XCTestCase {
    private func shell(_ command: String, in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    private func search(_ root: URL) throws -> FileSearcher.Result {
        let options = FileSearcher.Options(query: "needle", regex: false, caseSensitive: false,
                                          wholeWord: false, root: root, include: [], exclude: [])
        return try XCTUnwrap(FileSearcher().run(options))
    }

    func testSearchSkipsFilesGitIgnores() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TovriSearch-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try shell("""
        git init -q .
        printf 'ignored.txt\\nlogs/\\n' > .gitignore
        mkdir -p logs src && echo needle > logs/run.log && echo needle > ignored.txt
        echo needle > src/tracked.txt && git add src && echo needle > src/new.txt
        """, in: root)
        let all = try search(root)
        XCTAssertEqual(all.files, 2)
        XCTAssertTrue(all.text.contains("src/tracked.txt:"))
        XCTAssertTrue(all.text.contains("src/new.txt:"))
        XCTAssertFalse(all.text.contains("ignored.txt:"))
        XCTAssertFalse(all.text.contains("run.log:"))
        let sub = try search(root.appendingPathComponent("src"))
        XCTAssertEqual(sub.files, 2)
        XCTAssertEqual(sub.scanned, 2)
    }

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
