import Foundation
import SweetCookieKit
import XCTest
@testable import LocalQuotaBar

final class CodeBuddyCookieImporterTests: XCTestCase {
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
