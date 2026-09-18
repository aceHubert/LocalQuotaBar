import XCTest
@testable import LocalQuotaBar

final class PanelThemeTests: XCTestCase {
    func testRelativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 「刚刚」覆盖前两分钟，分钟档从 2 起、小时档从 1 起。
        let cases: [(TimeInterval, String)] = [
            (0, "刚刚"),
            (119, "刚刚"),
            (120, "2 分钟前"),
            (3599, "59 分钟前"),
            (3600, "1 小时前"),
            (7199, "1 小时前"),
            (7200, "2 小时前")
        ]

        for (elapsed, expected) in cases {
            let fetchedAt = now.addingTimeInterval(-elapsed)
            XCTAssertEqual(
                PanelTheme.relativeTime(from: fetchedAt, now: now),
                expected,
                "间隔 \(elapsed) 秒时应显示「\(expected)」"
            )
        }
    }

    func testRelativeTimeReturnsPlaceholderForMissingDate() {
        XCTAssertEqual(PanelTheme.relativeTime(from: nil), "--")
    }
}
