import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexAuthStampTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuthStampTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileStampIsStableAndDistinct() throws {
        let missingPath = directory.appendingPathComponent("absent.json").path

        XCTAssertEqual(CodexAuthStamp(path: missingPath), .missing)
        XCTAssertEqual(CodexAuthStamp(path: missingPath), CodexAuthStamp(path: missingPath))

        let existing = directory.appendingPathComponent("auth.json")
        try Data(#"{"a":1}"#.utf8).write(to: existing)
        XCTAssertNotEqual(CodexAuthStamp(path: missingPath), CodexAuthStamp(path: existing.path))
    }

    func testUnchangedFileKeepsEqualStamp() throws {
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"account_id":"a"}"#.utf8).write(to: file)

        XCTAssertEqual(CodexAuthStamp(path: file.path), CodexAuthStamp(path: file.path))
    }

    func testContentChangeAltersStamp() throws {
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"account_id":"a"}"#.utf8).write(to: file)
        let before = CodexAuthStamp(path: file.path)

        try Data(#"{"account_id":"a","extra":"padding-to-change-size"}"#.utf8).write(to: file)

        XCTAssertNotEqual(before, CodexAuthStamp(path: file.path))
    }

    func testAtomicReplaceAltersStamp() throws {
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"account_id":"a"}"#.utf8).write(to: file)
        let before = CodexAuthStamp(path: file.path)

        // 与 CodexAuthManager.switchAccount 同款原子替换：临时文件 rename 覆盖
        let replacement = directory.appendingPathComponent("auth-tmp-\(UUID().uuidString).json")
        try Data(#"{"account_id":"a"}"#.utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)

        XCTAssertNotEqual(before, CodexAuthStamp(path: file.path))
    }
}
