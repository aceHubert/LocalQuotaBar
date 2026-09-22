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
        let controller = QuotaViewController()
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
