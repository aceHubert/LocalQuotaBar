import AppKit
import XCTest
@testable import LocalQuotaBar

/// 顶栏刷新语义（tabs 版）：只刷新当前 active tab；各 provider 60 秒冷却互相独立。
final class ManualRefreshTests: XCTestCase {
    @MainActor
    func testCooldownExpiresAtSixtySecondsWithoutExtendingSkippedRequests() async throws {
        _ = NSApplication.shared
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var now = startedAt
        let header = ProviderHeaderView(now: { now })

        XCTAssertTrue(header.beginRefreshCooldown())
        XCTAssertFalse(header.canRequestRefresh)
        now = startedAt.addingTimeInterval(30)
        XCTAssertFalse(header.beginRefreshCooldown())
        now = startedAt.addingTimeInterval(59.999)
        XCTAssertFalse(header.beginRefreshCooldown())
        now = startedAt.addingTimeInterval(60)
        XCTAssertTrue(header.canRequestRefresh)
        XCTAssertTrue(header.beginRefreshCooldown())
        XCTAssertFalse(header.canRequestRefresh)
    }

    @MainActor
    func testBusyRequestDoesNotStartCooldownAndRemainsBlockedAfterCooldownExpires() async throws {
        _ = NSApplication.shared
        var now = Date(timeIntervalSince1970: 1_000)
        let header = ProviderHeaderView(now: { now })
        header.setRefreshing(true)
        XCTAssertFalse(header.canRequestRefresh)
        XCTAssertFalse(header.beginRefreshCooldown())

        header.setRefreshing(false)
        XCTAssertTrue(header.canRequestRefresh)
        XCTAssertTrue(header.beginRefreshCooldown())
        header.setRefreshing(true)
        now = now.addingTimeInterval(61)
        XCTAssertFalse(header.canRequestRefresh)
        XCTAssertFalse(header.beginRefreshCooldown())

        header.setRefreshing(false)
        XCTAssertTrue(header.canRequestRefresh)
    }

    @MainActor
    func testTopRefreshOnlyRefreshesActiveTab() async throws {
        let controller = makeController()
        var codexRequests = 0
        var zaiRequests = 0
        controller.onRefresh = { codexRequests += 1 }
        controller.onZAIRefresh = { zaiRequests += 1 }
        let top = try activeRefreshButton(in: controller)

        // 默认 active = Codex：顶栏刷新只触发 Codex。
        top.performClick(nil)
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 0)
        // 冷却期按钮禁用，直接触发回调也不能绕过禁用状态。
        XCTAssertFalse(top.isEnabled)
        top.onTap?()
        XCTAssertEqual(codexRequests, 1)

        // 切到 Z.AI tab：Z.AI 可独立刷新，Codex 保持冷却。
        try tabItem(.zai, in: controller).performClick(nil)
        XCTAssertTrue(top.isEnabled)
        top.performClick(nil)
        XCTAssertEqual(zaiRequests, 1)
        XCTAssertEqual(codexRequests, 1)

        // 再切回 Codex：仍在冷却中。
        try tabItem(.codex, in: controller).performClick(nil)
        XCTAssertFalse(top.isEnabled)
    }

    @MainActor
    func testRefreshingDisablesTopRefreshAndCompletionRestoresIt() async throws {
        let controller = makeController()
        let top = try activeRefreshButton(in: controller)
        XCTAssertTrue(top.isEnabled)

        controller.apply(snapshot: nil, isRefreshing: true, error: nil, reminder: .inactive)
        XCTAssertFalse(top.isEnabled)
        controller.apply(snapshot: nil, isRefreshing: false, error: nil, reminder: .inactive)
        XCTAssertTrue(top.isEnabled)

        // 另一个 tab 的刷新状态不影响当前 active tab 的按钮。
        try tabItem(.zai, in: controller).performClick(nil)
        XCTAssertTrue(top.isEnabled)
    }

    @MainActor
    func testHiddenProviderFallsBackToCodexAndDoesNotReceiveRefresh() async throws {
        let controller = makeController()
        var codexRequests = 0
        var zaiRequests = 0
        controller.onRefresh = { codexRequests += 1 }
        controller.onZAIRefresh = { zaiRequests += 1 }

        try tabItem(.zai, in: controller).performClick(nil)
        controller.setZAISectionVisible(false)
        // Z.AI 隐藏后当前 tab 应回退到 Codex，且 tab 随之隐藏。
        XCTAssertTrue(try tabItem(.zai, in: controller).isHidden)

        let top = try activeRefreshButton(in: controller)
        top.performClick(nil)
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 0)
    }

    @MainActor
    func testFailedRefreshKeepsCooldownForTopRefresh() async throws {
        let controller = makeController()
        var requests = 0
        controller.onRefresh = { requests += 1 }

        let top = try activeRefreshButton(in: controller)
        top.performClick(nil)
        controller.apply(snapshot: nil, isRefreshing: false, error: "测试失败", reminder: .inactive)
        // tabs 版没有独立错误横幅：失败后的重试入口就是顶栏刷新，遵守同一 60 秒冷却。
        XCTAssertFalse(top.isEnabled)
        top.performClick(nil)
        top.onTap?()
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testTabRingPrefersFiveHourOverWeeklyWindow() async throws {
        let controller = makeController()
        let now = Date()
        let fiveHourRemaining = 70.0
        let weeklyRemaining = 30.0
        controller.apply(
            snapshot: QuotaSnapshot(
                fiveHour: .init(kind: .fiveHour, usedPercent: 100 - fiveHourRemaining,
                                windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600)),
                weekly: .init(kind: .weekly, usedPercent: 100 - weeklyRemaining,
                              windowDurationMins: 7 * 24 * 60, resetsAt: now.addingTimeInterval(86400)),
                resetCreditCount: nil, resetCreditCards: [], creditBalance: nil,
                planType: nil, fetchedAt: now
            ),
            isRefreshing: false, error: nil, reminder: .inactive
        )
        let codexTab = try tabItem(.codex, in: controller)
        XCTAssertEqual(codexTab.ringFillLayer.strokeEnd, fiveHourRemaining / 100, accuracy: 0.001)
    }

    /// CodeBuddy 国内外是两个独立 tab：顶栏刷新只作用于当前 active 的那一个。
    @MainActor
    func testCodeBuddyDomesticTabRefreshesIndependentlyFromInternational() async throws {
        let controller = makeController()
        var intlRequests = 0
        var cnRequests = 0
        controller.onCodeBuddyRefresh = { intlRequests += 1 }
        controller.onCodeBuddyCNRefresh = { cnRequests += 1 }

        // 默认 active 仍是 Codex，两个 CodeBuddy tab 均不应被触发。
        let top = try activeRefreshButton(in: controller)
        top.performClick(nil)
        XCTAssertEqual(intlRequests, 0)
        XCTAssertEqual(cnRequests, 0)

        try tabItem(.codeBuddy, in: controller).performClick(nil)
        top.performClick(nil)
        XCTAssertEqual(intlRequests, 1)
        XCTAssertEqual(cnRequests, 0)

        // 切到国内版：国际版仍在冷却，国内版可独立刷新。
        try tabItem(.codeBuddyCN, in: controller).performClick(nil)
        XCTAssertTrue(top.isEnabled)
        top.performClick(nil)
        XCTAssertEqual(intlRequests, 1)
        XCTAssertEqual(cnRequests, 1)
    }

    /// 上次选择的 tab 会被持久化，弹窗重开恢复；不可见时回退 Codex。
    @MainActor
    func testActiveTabSelectionIsRestoredAndFallsBackWhenHidden() async throws {
        let controller = QuotaViewController.makeForTesting()
        _ = controller.view
        controller.setZAISectionVisible(true)
        try tabItem(.codeBuddyCN, in: controller).performClick(nil)
        XCTAssertEqual(
            controller.tabStorage.string(forKey: QuotaViewController.activeTabStorageKey),
            QuotaTabID.codeBuddyCN.rawValue
        )

        // 重新打开弹窗（viewDidAppear 读取持久化选择）：恢复上次 tab 而不是回到 Codex。
        let restored = QuotaViewController.makeForTesting(clearStoredTab: false)
        _ = restored.view
        restored.setZAISectionVisible(true)
        restored.viewDidAppear()
        // 收尾关闭：停掉 viewDidAppear 注册的相对时间定时器，避免影响其他用例。
        defer { restored.viewWillDisappear() }
        // INTL / CN 都是常驻 tab，恢复选择不改变彼此显隐；active 应回到 CN。
        XCTAssertFalse(try tabItem(.codeBuddyCN, in: restored).isHidden)
        XCTAssertFalse(try tabItem(.codeBuddy, in: restored).isHidden)
        let restoredBar = try XCTUnwrap(descendants(of: restored.view)
            .compactMap { $0 as? PanelTabBarView }.first)
        XCTAssertEqual(restoredBar.active, .codeBuddyCN)

        // Z.AI 隐藏时若正停留在该 tab，回退 Codex（既有语义不变）。
        try tabItem(.zai, in: restored).performClick(nil)
        restored.setZAISectionVisible(false)
        XCTAssertTrue(try tabItem(.zai, in: restored).isHidden)
        XCTAssertFalse(try tabItem(.codex, in: restored).isHidden)
    }

    @MainActor
    func testAPIKeyEntryRefreshesUsageOnceWhileQuotaRefreshStaysUnavailable() async throws {
        _ = NSApplication.shared
        let panel = ZAIPanelSection(resolveSelection: {
            .init(domain: "zai", kind: .apiKey, selectedKey: nil)
        })
        panel.apply(snapshot: .init(kind: .apiKey), account: nil,
                    isRefreshing: false, error: nil, titleOverride: nil)
        let section = try XCTUnwrap(panel.subviews.compactMap { $0 as? ProviderPanelSection }.first)
        var usageRequests = 0
        panel.onRefresh = { usageRequests += 1 }
        XCTAssertTrue(panel.canRequestRefresh)
        XCTAssertFalse(section.header.isRefreshAvailable)

        section.requestRefresh()
        XCTAssertEqual(usageRequests, 0)
        // Z.AI 的顶栏入口允许只刷新本机日用量，仍须遵守同一冷却。
        panel.requestRefresh()
        panel.requestRefresh()
        XCTAssertEqual(usageRequests, 1)
        XCTAssertFalse(panel.canRequestRefresh)
    }

    @MainActor
    private func makeController() -> QuotaViewController {
        _ = NSApplication.shared
        let controller = QuotaViewController.makeForTesting()
        _ = controller.view
        controller.setZAISectionVisible(true)
        return controller
    }

    @MainActor
    private func activeRefreshButton(in controller: QuotaViewController) throws -> PanelIconButton {
        try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? PanelIconButton }
            .first { $0.identifier?.rawValue == "refresh-active" })
    }

    @MainActor
    private func tabItem(_ tab: QuotaTabID, in controller: QuotaViewController) throws -> PanelTabItemView {
        try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? PanelTabItemView }
            .first { $0.identifier?.rawValue == "quota-tab.\(tab.rawValue)" })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
