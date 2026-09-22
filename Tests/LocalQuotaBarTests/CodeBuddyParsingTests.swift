import AppKit
import XCTest
@testable import LocalQuotaBar

/// CodeBuddy 解析与面板口径单测（fixture 来自执行计划字段规格）。
final class CodeBuddyParsingTests: XCTestCase {
    private func summaryJSON(subscriptionCode: String = "FREE") -> [String: Any] {
        [
            "data": [
                "SubscriptionPackageCode": subscriptionCode,
                "IsProtectedPriceUser": false,
                "Packages": [
                    [
                        "PackageCode": subscriptionCode,
                        "CycleTotalCapacity": "500",
                        "CycleUsedCapacity": "1.62"
                    ],
                    [
                        "PackageCode": "OTHER",
                        "CycleTotalCapacity": 10,
                        "CycleUsedCapacity": 0
                    ]
                ]
            ]
        ]
    }

    private func packagesJSON(_ accounts: [[String: Any]]) -> [String: Any] {
        ["data": ["Accounts": accounts]]
    }

    func testParseSummaryPicksSubscriptionPackage() throws {
        let (plan, code) = try CodeBuddyParser.parseSummary(json: summaryJSON())
        XCTAssertEqual(code, "FREE")
        XCTAssertEqual(plan?.packageCode, "FREE")
        XCTAssertEqual(plan?.totalCapacity ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(plan?.usedCapacity ?? 0, 1.62, accuracy: 0.001)
        XCTAssertEqual(plan?.remainCapacity ?? 0, 498.38, accuracy: 0.001)
        XCTAssertEqual(plan?.remainingPercent ?? 0, 99.676, accuracy: 0.01)
        // 套餐代码 → 展示名映射（体验版）
        XCTAssertEqual(CodeBuddySnapshot.planName(for: code), "体验版")
    }

    func testParseSummaryRequiresPackages() {
        XCTAssertThrowsError(try CodeBuddyParser.parseSummary(json: ["data": ["Packages": []]]))
        XCTAssertThrowsError(try CodeBuddyParser.parseSummary(json: [:]))
    }

    func testParsePackagesSortsByExpiryAndKeepsUnknownCodes() throws {
        let json = packagesJSON([
            [
                "PackageCode": "REWARD", "ResourceId": "r-2", "Status": 1, "InUsage": true,
                "CycleCapacitySizePrecise": "300", "CycleCapacityRemainPrecise": "300",
                "ExpiredTime": "2026-10-20 00:00:00"
            ],
            [
                "PackageCode": "UNKNOWN_GROUP", "ResourceId": "r-1", "Status": 1, "InUsage": false,
                "CycleCapacitySizePrecise": "100", "CycleCapacityRemainPrecise": "100",
                "ExpiredTime": "2026-10-20 00:00:00"
            ],
            [
                "PackageCode": "REWARD", "ResourceId": "r-3", "Status": 1, "InUsage": false,
                "CycleCapacitySizePrecise": "5", "CycleCapacityRemainPrecise": "2.5",
                "ExpiredTime": "2026-09-25 00:00:00"
            ]
        ])
        let packages = try CodeBuddyParser.parsePackages(json: json, group: .free)
        // 到期升序：09-25 < 10-20；同到期按 ResourceId
        XCTAssertEqual(packages.count, 3)
        XCTAssertEqual(packages[0].resourceID, "r-3")
        XCTAssertEqual(packages[0].remainCapacity, 2.5, accuracy: 0.001)
        XCTAssertEqual(packages[1].resourceID, "r-1")
        XCTAssertEqual(packages[2].resourceID, "r-2")
        // 未知 PackageCode 保留（归入调用侧组别），不丢弃
        XCTAssertEqual(packages[1].packageCode, "UNKNOWN_GROUP")
    }

    func testDateParsingAcceptsSecondsAndStrings() {
        let seconds = CodeBuddyParser.date(1_790_000_000)
        XCTAssertEqual(seconds?.timeIntervalSince1970 ?? 0, 1_790_000_000, accuracy: 0.001)
        let milliseconds = CodeBuddyParser.date(1_790_000_000_000)
        XCTAssertEqual(milliseconds?.timeIntervalSince1970 ?? 0, 1_790_000_000, accuracy: 0.001)
        XCTAssertNil(CodeBuddyParser.date(0))
        XCTAssertNil(CodeBuddyParser.date("not-a-date"))
        let text = CodeBuddyParser.date("2026-09-30 12:30:00")
        XCTAssertNotNil(text)
    }

    func testCreditsFormatTrimsTrailingZeros() {
        XCTAssertEqual(CodeBuddyFormat.credits(1.62), "1.62")
        XCTAssertEqual(CodeBuddyFormat.credits(500), "500")
        XCTAssertEqual(CodeBuddyFormat.credits(498.38), "498.38")
        XCTAssertEqual(CodeBuddyFormat.credits(2.50), "2.5")
        XCTAssertEqual(CodeBuddyFormat.credits(0), "0")
    }

    // MARK: - 面板口径

    @MainActor
    func testPanelRendersPlanBarAndPackageChips() async throws {
        _ = NSApplication.shared
        let section = CodeBuddyPanelSection()
        let plan = CodeBuddyPackage(
            group: .subscription, packageCode: "FREE", resourceID: nil,
            totalCapacity: 500, remainCapacity: 498.38, inUsage: true,
            cycleEndTime: CodeBuddyParser.date("2026-09-30 00:00:00"), expiredTime: nil
        )
        let free = CodeBuddyPackage(
            group: .free, packageCode: "REWARD", resourceID: "r-2",
            totalCapacity: 300, remainCapacity: 300, inUsage: false,
            cycleEndTime: nil, expiredTime: CodeBuddyParser.date("2026-10-20 00:00:00")
        )
        let snapshot = CodeBuddySnapshot(
            fetchedAt: Date(), region: "international",
            profileID: "Default", profileName: "Default",
            planName: "体验版", planPackage: plan,
            paidPackages: [], freePackages: [free]
        )
        section.apply(snapshot: snapshot, isRefreshing: false, error: nil)

        let fields = descendants(of: section).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue.contains("已用 1.62 / 500") })
        XCTAssertTrue(fields.contains { $0.stringValue.contains("剩 498.38") })
        XCTAssertTrue(fields.contains { $0.stringValue.contains("国际版") })
        // 购买积分空态 chip + 奖励包 chip
        XCTAssertTrue(fields.contains { $0.stringValue == "购买积分 · 无资源包" } || descendants(of: section)
            .compactMap { $0 as? NSButton }
            .contains { $0.title == "购买积分 · 无资源包" })
        XCTAssertTrue(descendants(of: section).compactMap { $0 as? NSButton }
            .contains { $0.title.contains("奖励包 ×1 · 共 300") })

        // 失败态：保留旧快照、头部报错
        section.apply(snapshot: snapshot, isRefreshing: false, error: "Keychain 拒绝访问")
        XCTAssertTrue(fields.contains { $0.stringValue == "刷新失败" })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
