import XCTest
@testable import Tovri

final class SecurityTests: XCTestCase {
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

    func testGitStatusDoesNotRunCommandsConfiguredByTheRepository() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-git-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pwned")
        try shell("""
        git init -q . && git config user.email t@example.com && git config user.name t
        printf '#!/bin/sh\\ntouch "%s"\\ncat\\n' '\(marker.path)' > hook.sh && chmod +x hook.sh
        echo 'a.txt filter=evil' > .gitattributes && echo one > a.txt
        git add -A && git -c core.hooksPath=/dev/null commit -qm init
        git config core.fsmonitor "$PWD/hook.sh"
        git config filter.evil.clean "$PWD/hook.sh"
        echo two > a.txt
        """, in: dir)
        try? FileManager.default.removeItem(at: marker)
        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        let done = expectation(description: "status")
        var status: [String: GitFileStatus] = [:]
        repo.status { status = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status["a.txt"], .modified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran a program configured by the repository")
    }

    func testFilterOverridesCoverEveryConfiguredFilter() {
        let config = Data("filter.lfs.clean\ngit-lfs clean\u{0}filter.my.odd.name.smudge\nx\u{0}".utf8)
        let settings = (GitRepository.filterSettings(config) ?? []).map { "\($0.key)=\($0.value)" }
        XCTAssertTrue(settings.contains("filter.lfs.clean="))
        XCTAssertTrue(settings.contains("filter.my.odd.name.process="))
        XCTAssertTrue(settings.contains("filter.lfs.required=false"))
    }

    func testCommandLinePositionsAreClamped() {
        XCTAssertEqual(AppDelegate.clampedPosition("-9223372036854775808"), 1)
        XCTAssertEqual(AppDelegate.clampedPosition("99999999999999"), 100_000_000)
        XCTAssertEqual(AppDelegate.clampedPosition("42"), 42)
        XCTAssertNil(AppDelegate.clampedPosition("x"))
    }

    func testSudoCommandQuotesThePath() {
        XCTAssertEqual(Integration.shellQuoted("/Apps/It's $(x)`y`.app"), "'/Apps/It'\\''s $(x)`y`.app'")
    }
}
