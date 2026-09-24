import AppKit
import XCTest
@testable import LocalQuotaBar

/// CodeBuddy 解析与面板口径单测（fixture 来自执行计划字段规格）。
final class CodeBuddyParsingTests: XCTestCase {
    private func resourceJSON(_ accounts: [[String: Any]]) -> [String: Any] {
        [
            "code": 0,
            "msg": "OK",
            "data": [
                "Response": [
                    "Data": [
                        "TotalCount": accounts.count,
                        "TotalDosage": accounts.reduce(0.0) {
                            $0 + (DeepSeekJSON.number($1["CycleCapacitySizePrecise"]) ?? 0)
                        },
                        "Accounts": accounts
                    ],
                    "RequestId": "test-request"
                ],
                "ProTrialStatus": 0
            ]
        ]
    }

    func testParseResourceGroupsAccountsAndUsesPreciseCapacity() throws {
        let json = resourceJSON([
            [
                "PackageCode": "TCACA_code_035_ArVxJcGDsm",
                "PackageName": "Free Plan Subscription",
                "CapacityType": 4,
                "CycleCapacitySizePrecise": "100",
                "CycleCapacityRemainPrecise": "83.05",
                "CycleCapacityUsedPrecise": "16.95",
                "CycleEndTime": "2026-09-30 23:59:59"
            ],
            [
                "PackageCode": "TCACA_code_007_nzdH5h4Nl0",
                "PackageName": "Bonus Pack",
                "SubProductCode": "sp_tcaca_codebuddyide_bonus_pack",
                "CycleCapacitySizePrecise": "1000",
                "CycleCapacityRemainPrecise": "1000",
                "CycleCapacityUsedPrecise": "0",
                "ExpiredTime": "2027-03-26 21:59:14"
            ],
            [
                "PackageCode": "PURCHASE_1",
                "PackageName": "Purchased Credits",
                "SubProductCode": "purchase_credits",
                "CycleCapacitySizePrecise": "50",
                "CycleCapacityRemainPrecise": "12.5",
                "CycleCapacityUsedPrecise": "37.5",
                "ExpiredTime": "2026-10-01 00:00:00"
            ],
            [
                "PackageCode": "UNKNOWN_GROUP",
                "PackageName": "Unclassified Resource",
                "CycleCapacitySizePrecise": "10",
                "CycleCapacityRemainPrecise": "9"
            ]
        ])

        let parsed = try CodeBuddyParser.parseResource(json: json)
        XCTAssertEqual(parsed.planName, "体验版")
        XCTAssertEqual(parsed.planPackage?.totalCapacity ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(parsed.planPackage?.usedCapacity ?? 0, 16.95, accuracy: 0.001)
        XCTAssertEqual(parsed.planPackage?.remainCapacity ?? 0, 83.05, accuracy: 0.001)
        XCTAssertEqual(parsed.planPackage?.remainingPercent ?? 0, 83.05, accuracy: 0.01)
        XCTAssertEqual(parsed.paidPackages.map(\.packageCode), ["PURCHASE_1"])
        XCTAssertEqual(parsed.freePackages.map(\.packageCode), ["TCACA_code_007_nzdH5h4Nl0"])
        XCTAssertEqual(parsed.otherPackages.map(\.packageCode), ["UNKNOWN_GROUP"])
    }

    func testParseResourceRequiresCurrentEnvelope() {
        XCTAssertThrowsError(try CodeBuddyParser.parseResource(json: ["data": ["Packages": []]]))
        XCTAssertThrowsError(try CodeBuddyParser.parseResource(json: ["code": 0, "data": ["Response": [:]]]))
        XCTAssertThrowsError(try CodeBuddyParser.parseResource(json: [:]))
    }

    func testParseResourceSortsByExpiry() throws {
        let json = resourceJSON([
            [
                "PackageCode": "REWARD", "PackageName": "Bonus Pack", "ResourceId": "r-2", "Status": 1, "InUsage": true,
                "CycleCapacitySizePrecise": "300", "CycleCapacityRemainPrecise": "300",
                "ExpiredTime": "2026-10-20 00:00:00"
            ],
            [
                "PackageCode": "UNKNOWN_GROUP", "PackageName": "Bonus Pack", "ResourceId": "r-1", "Status": 1, "InUsage": false,
                "CycleCapacitySizePrecise": "100", "CycleCapacityRemainPrecise": "100",
                "ExpiredTime": "2026-10-20 00:00:00"
            ],
            [
                "PackageCode": "REWARD", "PackageName": "Bonus Pack", "ResourceId": "r-3", "Status": 1, "InUsage": false,
                "CycleCapacitySizePrecise": "5", "CycleCapacityRemainPrecise": "2.5",
                "ExpiredTime": "2026-09-25 00:00:00"
            ]
        ])
        let packages = try CodeBuddyParser.parseResource(json: json).freePackages
        // 到期升序：09-25 < 10-20；同到期按 ResourceId
        XCTAssertEqual(packages.count, 3)
        XCTAssertEqual(packages[0].resourceID, "r-3")
        XCTAssertEqual(packages[0].remainCapacity, 2.5, accuracy: 0.001)
        XCTAssertEqual(packages[1].resourceID, "r-1")
        XCTAssertEqual(packages[2].resourceID, "r-2")
        // 未知 PackageCode 仍按字段分类为奖励包，不因代码未知而丢弃
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
        XCTAssertTrue(fields.contains { $0.stringValue.contains("498.38/500 积分") })
        XCTAssertFalse(fields.contains { $0.stringValue.contains("已用") }, "统一口径后不再显示已用")
        // 基础积分行显示当前套餐名（非区域标识）
        XCTAssertTrue(fields.contains { $0.stringValue.contains("体验版") })
        // 购买积分空态 chip + 奖励包 chip
        XCTAssertTrue(fields.contains { $0.stringValue == "购买积分 · 无资源包" } || descendants(of: section)
            .compactMap { $0 as? NSButton }
            .contains { $0.title == "购买积分 · 无资源包" })
        XCTAssertTrue(descendants(of: section).compactMap { $0 as? NSButton }
            .contains { $0.title.contains("奖励包 ×1 · 300/300") })

        // 到期时间逐项显示在明细行（MM-dd HH:mm 结尾，不带"到期"字样）；按进程时区换算期望值
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        let expectedExpiry = formatter.string(from: CodeBuddyParser.date("2026-10-20 00:00:00")!)
        XCTAssertTrue(descendants(of: section).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.hasPrefix("300/300 积分 · ") && $0.stringValue.hasSuffix(expectedExpiry) })

        // 失败态：保留旧快照、头部报错
        section.apply(snapshot: snapshot, isRefreshing: false, error: "Keychain 拒绝访问")
        XCTAssertTrue(fields.contains { $0.stringValue == "刷新失败" })
    }

    @MainActor
    func testPanelHidesContentWithoutSnapshot() async throws {
        _ = NSApplication.shared
        let section = CodeBuddyPanelSection()
        section.apply(snapshot: nil, isRefreshing: false, error: "CodeBuddy 会话已失效（HTTP 401）")

        // 首刷失败无历史数据：只留头部状态行，内容区全部隐藏
        XCTAssertTrue(section.planUsageLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(section.planBar.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(section.resetCards.isHiddenOrHasHiddenAncestor)
        let failure = try XCTUnwrap(descendants(of: section).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "刷新失败" })
        XCTAssertFalse(failure.isHiddenOrHasHiddenAncestor)
    }

    @MainActor
    func testChipsLayoutForEmptyAndFilledGroups() {
        let free = CodeBuddyPackage(
            group: .free, packageCode: "REWARD", resourceID: "r-1",
            totalCapacity: 300, remainCapacity: 295.5, inUsage: false,
            cycleEndTime: nil, expiredTime: CodeBuddyParser.date("2026-10-20 18:30:00")
        )
        let chips = CodeBuddyPanelSection.chips(paid: [], free: [free])
        XCTAssertEqual(chips.count, 2)
        // 无资源包：空态 chip 无明细 → 不渲染展开按钮
        XCTAssertEqual(chips[0].title, "购买积分 · 无资源包")
        XCTAssertTrue(chips[0].cards.isEmpty)
        // 有包 chip：标题 = ×N · 剩余/总量，无到期时间
        XCTAssertEqual(chips[1].title, "奖励包 ×1 · 295.5/300")
        XCTAssertFalse(chips[1].title.contains("到期"))
        // 明细行带 MM-dd HH:mm 到期
        let detail = chips[1].cards[0].detailText ?? ""
        XCTAssertTrue(detail.hasPrefix("295.5/300 积分 · "), "detail=\(detail)")
        XCTAssertFalse(detail.contains("奖励包"))
        XCTAssertFalse(detail.contains("到期"))
        // 展示层按本地时区渲染：期望文本用进程本地时区换算（与断言时区无关）
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        let expected = formatter.string(from: CodeBuddyParser.date("2026-10-20 18:30:00")!)
        XCTAssertTrue(detail.hasSuffix(expected), "detail=\(detail)")
        XCTAssertFalse(chips[1].cards[0].kindTitle.isEmpty == false)
    }

    @MainActor
    func testEmptyChipHasNoExpandButton() throws {
        _ = NSApplication.shared
        let row = ResetCardsRow()
        row.configure(chips: [ResetCardsRow.Chip(id: "empty", title: "购买积分 · 无资源包", soon: false, cards: [])])
        row.layoutSubtreeIfNeeded()
        // 空 chip：只有 chip 按钮本身，没有展开按钮
        let buttons = descendants(of: row).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons[0].title, "购买积分 · 无资源包")
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
