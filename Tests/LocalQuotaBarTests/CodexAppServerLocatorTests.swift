import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexAppServerLocatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeExecutable(named fileName: String) throws -> String {
        let url = temporaryDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testFirstExecutablePathPrefersEarlierCandidateWhenBothExist() throws {
        let first = try makeExecutable(named: "codex-new")
        let second = try makeExecutable(named: "codex-old")

        XCTAssertEqual(
            CodexAppServerLocator.firstExecutablePath(in: [first, second]),
            first
        )
        XCTAssertEqual(
            CodexAppServerLocator.firstExecutablePath(in: [second, first]),
            second
        )
    }

    func testFirstExecutablePathSkipsMissingCandidates() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing-codex").path
        let existing = try makeExecutable(named: "codex-old")

        XCTAssertEqual(
            CodexAppServerLocator.firstExecutablePath(in: [missing, existing]),
            existing
        )
        XCTAssertNil(CodexAppServerLocator.firstExecutablePath(in: [missing]))
    }

    func testFirstExecutablePathIgnoresNonExecutableFiles() throws {
        let plainURL = temporaryDirectory.appendingPathComponent("codex-plain")
        FileManager.default.createFile(atPath: plainURL.path, contents: Data())
        let executable = try makeExecutable(named: "codex-exec")

        XCTAssertEqual(
            CodexAppServerLocator.firstExecutablePath(in: [plainURL.path, executable]),
            executable
        )
    }

    func testCandidatePathsCoverNewAndLegacyLocations() {
        XCTAssertEqual(CodexAppServerLocator.candidatePaths.first, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertEqual(CodexAppServerLocator.candidatePaths.last, "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertEqual(
            Set(CodexAppServerLocator.candidatePaths).count,
            CodexAppServerLocator.candidatePaths.count
        )
    }
}
