import Foundation
import SQLite3
import SweetCookieKit
import XCTest
@testable import LocalQuotaBar

final class CodeBuddyCookieImporterTests: XCTestCase {
    func testSnapshotReadsCommittedCookieFromRollbackJournalDatabase() throws {
        try assertSnapshotReadsNewSession(journalMode: "DELETE")
    }

    func testSnapshotReadsCommittedCookieFromWAL() throws {
        try assertSnapshotReadsNewSession(journalMode: "WAL")
    }

    private func assertSnapshotReadsNewSession(journalMode: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Cookies")
        var writer: OpaquePointer?
        defer { sqlite3_close(writer) }
        guard sqlite3_open(source.path, &writer) == SQLITE_OK else {
            return XCTFail("无法创建临时 SQLite 数据库")
        }
        let store = BrowserCookieStore(
            browser: .chrome,
            profile: BrowserProfile(id: "Default", name: "Default"),
            kind: .primary,
            label: "Chrome Default",
            databaseURL: source
        )
        let prepare = """
            PRAGMA journal_mode=\(journalMode);
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE cookies (name TEXT PRIMARY KEY, value TEXT);
            INSERT INTO cookies VALUES ('session', 'old');
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN;
            UPDATE cookies SET value = 'new' WHERE name = 'session';
            """
        XCTAssertEqual(sqlite3_exec(writer, prepare, nil, nil, nil), SQLITE_OK)

        // Chrome 仍持有数据库连接。提交前保持旧值，提交后立即读到新值。
        XCTAssertEqual(try readSessionFromSnapshot(of: store), "old")
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try readSessionFromSnapshot(of: store), "new")
    }

    private func readSessionFromSnapshot(of store: BrowserCookieStore) throws -> String {
        try CodeBuddyCookieImporter.withCookieStoreSnapshot(of: store) { readableStore in
            let snapshot = try XCTUnwrap(readableStore.databaseURL)
            XCTAssertNotEqual(snapshot, store.databaseURL)
            XCTAssertEqual(readableStore.profile, store.profile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))

            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT value FROM cookies WHERE name = 'session'"
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                XCTFail("快照缺少会话 Cookie")
                return ""
            }
            return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
        }
    }

    func testCookieHeaderKeepsTargetCookiesAndDeduplicatesBySpecificity() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let records = [
            BrowserCookieRecord(
                domain: "codebuddy.ai", name: "session", path: "/", value: "domain-session",
                expires: now.addingTimeInterval(3600), isSecure: false, isHTTPOnly: true,
                scope: .domain
            ),
            BrowserCookieRecord(
                domain: "www.codebuddy.ai", name: "session", path: "/", value: "host-session",
                expires: now.addingTimeInterval(1800), isSecure: false, isHTTPOnly: true,
                scope: .hostOnly
            ),
            BrowserCookieRecord(
                domain: "www.codebuddy.ai", name: "session_2", path: "/", value: "session-two",
                expires: now.addingTimeInterval(1800), isSecure: false, isHTTPOnly: true,
                scope: .hostOnly
            ),
            BrowserCookieRecord(
                domain: "codebuddy.ai", name: "qcloud_visitId", path: "/", value: "visit",
                expires: nil, isSecure: true, isHTTPOnly: false, scope: .domain
            ),
            BrowserCookieRecord(
                domain: "www.codebuddy.ai", name: "login-only", path: "/login", value: "excluded",
                expires: nil, isSecure: false, isHTTPOnly: false, scope: .hostOnly
            ),
            BrowserCookieRecord(
                domain: "www.codebuddy.ai", name: "expired", path: "/", value: "excluded",
                expires: now.addingTimeInterval(-1), isSecure: false, isHTTPOnly: false, scope: .hostOnly
            )
        ]

        let header = CodeBuddyCookieImporter.cookieHeader(
            from: records,
            host: "www.codebuddy.ai",
            path: "/billing/meter/get-user-resource",
            now: now
        )

        XCTAssertTrue(header.contains("session=host-session"))
        XCTAssertFalse(header.contains("domain-session"))
        XCTAssertTrue(header.contains("session_2=session-two"))
        XCTAssertTrue(header.contains("qcloud_visitId=visit"))
        XCTAssertFalse(header.contains("login-only="))
        XCTAssertFalse(header.contains("expired="))
        XCTAssertEqual(header.split(separator: ";").filter { $0.contains("session=") }.count, 1)
    }

    /// 导入失败文案必须指向本次导入的目标站点，避免国内版提示去 .ai 登录。
    func testImportErrorMessagesCarryTargetHost() {
        let domestic = CodeBuddyCookieImporter.ImportError.cookieNotFound(host: "www.codebuddy.cn")
        XCTAssertTrue(domestic.errorDescription?.contains("www.codebuddy.cn") == true)
        XCTAssertFalse(domestic.errorDescription?.contains("codebuddy.ai") == true)

        let international = CodeBuddyCookieImporter.ImportError.cookieNotFound(host: "www.codebuddy.ai")
        XCTAssertTrue(international.errorDescription?.contains("www.codebuddy.ai") == true)

        let chrome = CodeBuddyCookieImporter.ImportError.chromeNotFound(host: "www.codebuddy.cn")
        XCTAssertTrue(chrome.errorDescription?.contains("www.codebuddy.cn") == true)
    }
}
