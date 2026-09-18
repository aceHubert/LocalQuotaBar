import AppKit
import XCTest
@testable import LocalQuotaBar

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
        XCTAssertTrue(try refreshButton(in: header).isEnabled)
        XCTAssertTrue(header.beginRefreshCooldown())
    }

    @MainActor
    func testSingleRefreshDisablesGlobalWhileOtherProviderRemainsIndependent() async throws {
        let controller = makeController()
        var codexRequests = 0
        var zaiRequests = 0
        controller.onRefresh = { codexRequests += 1 }
        controller.onZAIRefresh = { zaiRequests += 1 }
        let codex = try providerSection(CodexPanelSection.self, in: controller)
        let zai = try providerSection(ZAIPanelSection.self, in: controller)
        let global = try globalButton(in: controller)

        try refreshButton(in: codex.header).performClick(nil)
        XCTAssertEqual(codexRequests, 1)
        XCTAssertFalse(global.isEnabled)
        global.performClick(nil)
        // 即使直接触发回调，也不能绕过禁用状态。
        global.onTap?()
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 0)

        try refreshButton(in: zai.header).performClick(nil)
        XCTAssertEqual(zaiRequests, 1)
        XCTAssertFalse(global.isEnabled)
    }

    @MainActor
    func testRefreshingDisablesGlobalAndCompletionRestoresIt() async throws {
        let controller = makeController()
        let global = try globalButton(in: controller)
        let zai = try providerSection(ZAIPanelSection.self, in: controller)
        XCTAssertTrue(global.isEnabled)

        controller.apply(snapshot: nil, isRefreshing: true, error: nil, reminder: .inactive)
        XCTAssertFalse(global.isEnabled)
        controller.apply(snapshot: nil, isRefreshing: false, error: nil, reminder: .inactive)
        XCTAssertTrue(global.isEnabled)

        zai.header.setRefreshing(true)
        XCTAssertFalse(global.isEnabled)
        zai.header.setRefreshing(false)
        XCTAssertTrue(global.isEnabled)
    }

    @MainActor
    func testGlobalRefreshStartsBothIdleProvidersOnce() async throws {
        let controller = makeController()
        var codexRequests = 0
        var zaiRequests = 0
        controller.onRefresh = { codexRequests += 1 }
        controller.onZAIRefresh = { zaiRequests += 1 }
        let global = try globalButton(in: controller)

        global.performClick(nil)
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 1)
        XCTAssertFalse(global.isEnabled)
        global.performClick(nil)
        global.onTap?()
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 1)
    }

    @MainActor
    func testFailedRefreshAndErrorRetryPreserveCooldown() async throws {
        let controller = makeController()
        var requests = 0
        controller.onRefresh = { requests += 1 }
        let section = try providerSection(CodexPanelSection.self, in: controller)
        try refreshButton(in: section.header).performClick(nil)
        controller.apply(snapshot: nil, isRefreshing: false, error: "测试失败", reminder: .inactive)
        XCTAssertFalse(try globalButton(in: controller).isEnabled)

        // 错误横幅重试按设计绕过 60 秒冷却：失败后立即重试是明确意图，
        // 只做并发防重。因此这里会真实再触发一次刷新。
        let retry = try XCTUnwrap(descendants(of: section.errorBanner)
            .compactMap { $0 as? NSButton }.first { $0.title == "重试" })
        retry.performClick(nil)
        XCTAssertEqual(requests, 2)
        // 重试不延长也不清除 header 的冷却，手动入口仍被挡住。
        XCTAssertFalse(section.header.canRequestRefresh)
    }

    @MainActor
    func testHiddenProviderDoesNotBlockGlobalOrReceiveRefresh() async throws {
        let controller = makeController()
        var codexRequests = 0
        var zaiRequests = 0
        controller.onRefresh = { codexRequests += 1 }
        controller.onZAIRefresh = { zaiRequests += 1 }
        let zai = try providerSection(ZAIPanelSection.self, in: controller)
        zai.header.setRefreshing(true)
        XCTAssertFalse(try globalButton(in: controller).isEnabled)

        controller.setZAISectionVisible(false)
        let global = try globalButton(in: controller)
        XCTAssertTrue(global.isEnabled)
        global.performClick(nil)
        XCTAssertEqual(codexRequests, 1)
        XCTAssertEqual(zaiRequests, 0)
    }

    @MainActor
    func testAPIKeyGlobalEntryRefreshesUsageOnceWhileQuotaButtonStaysDisabled() async throws {
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
        XCTAssertFalse(try refreshButton(in: section.header).isEnabled)

        section.requestRefresh()
        XCTAssertEqual(usageRequests, 0)
        // Z.AI 的全局入口允许只刷新本机日用量，仍须遵守同一冷却。
        panel.requestRefresh()
        panel.requestRefresh()
        XCTAssertEqual(usageRequests, 1)
        XCTAssertFalse(panel.canRequestRefresh)
        XCTAssertFalse(try refreshButton(in: section.header).isEnabled)
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
    private func globalButton(in controller: QuotaViewController) throws -> PanelIconButton {
        try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? PanelIconButton }
            .first { $0.identifier?.rawValue == "global-refresh" })
    }

    @MainActor
    private func providerSection<T: NSView>(_ type: T.Type, in controller: QuotaViewController) throws -> ProviderPanelSection {
        let panel = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? T }.first)
        return try XCTUnwrap(panel.subviews.compactMap { $0 as? ProviderPanelSection }.first)
    }

    @MainActor
    private func refreshButton(in header: ProviderHeaderView) throws -> PanelIconButton {
        try XCTUnwrap(descendants(of: header).compactMap { $0 as? PanelIconButton }.first)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
