import AppKit
import XCTest
@testable import LocalQuotaBar

final class ZAIUsagePresentationTests: XCTestCase {
    @MainActor
    func testAPIKeyModeShowsSeparateHintAndKeepsDailyUsageVisible() async throws {
        _ = NSApplication.shared
        let panel = ZAIPanelSection(resolveSelection: { nil })
        panel.applyUsage(days: [.init(date: Date(), tokens: 123_456)])
        apply(.apiKey, to: panel)

        let section = try providerSection(in: panel)
        let refresh = try refreshButton(in: section)
        XCTAssertEqual(section.modeHintLabel.stringValue, "API Key 模式，无余额功能")
        XCTAssertFalse(section.modeHintLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(section.modeHintLabel.isDescendant(of: section.header))
        let stack = try XCTUnwrap(section.modeHintLabel.superview as? NSStackView)
        let headerIndex = try XCTUnwrap(stack.arrangedSubviews.firstIndex(of: section.header))
        XCTAssertTrue(stack.arrangedSubviews[headerIndex + 1] === section.modeHintLabel)
        XCTAssertTrue(section.grid.isHidden)
        XCTAssertTrue(section.resetCards.isHidden)
        XCTAssertFalse(section.usageChart.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(refresh.isEnabled)

        // 额度状态再次刷新时仍须保留独立日用量区域。
        panel.applyUsage(days: [.init(date: Date(), tokens: 654_321)])
        apply(.apiKey, to: panel)
        XCTAssertFalse(section.usageChart.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(refresh.isEnabled)
    }

    @MainActor
    func testReturningToCodingPlanRestoresQuotaRefresh() async throws {
        _ = NSApplication.shared
        let panel = ZAIPanelSection(resolveSelection: { nil })
        apply(.apiKey, to: panel)
        let section = try providerSection(in: panel)
        XCTAssertFalse(try refreshButton(in: section).isEnabled)

        apply(.codingPlan, to: panel)
        XCTAssertTrue(section.modeHintLabel.isHidden)
        XCTAssertFalse(section.grid.isHidden)
        XCTAssertTrue(try refreshButton(in: section).isEnabled)
        XCTAssertFalse(section.usageChart.isHiddenOrHasHiddenAncestor)
    }

    @MainActor
    func testCurrentAPIKeySelectionOverridesCachedPlanSnapshot() async throws {
        _ = NSApplication.shared
        let panel = ZAIPanelSection(resolveSelection: {
            .init(domain: "zai", kind: .apiKey, selectedKey: nil)
        })
        apply(.codingPlan, to: panel)
        let section = try providerSection(in: panel)
        XCTAssertFalse(section.modeHintLabel.isHidden)
        XCTAssertTrue(section.grid.isHidden)
        XCTAssertFalse(try refreshButton(in: section).isEnabled)
        XCTAssertFalse(section.usageChart.isHiddenOrHasHiddenAncestor)
    }

    @MainActor
    private func apply(_ kind: ZAIPlanKind, to panel: ZAIPanelSection) {
        panel.apply(
            snapshot: .init(kind: kind, apiKeySuffix: "abcd"),
            account: nil, isRefreshing: false, error: nil, titleOverride: nil
        )
    }

    @MainActor
    private func providerSection(in panel: ZAIPanelSection) throws -> ProviderPanelSection {
        try XCTUnwrap(panel.subviews.compactMap { $0 as? ProviderPanelSection }.first)
    }

    @MainActor
    private func refreshButton(in section: ProviderPanelSection) throws -> PanelIconButton {
        try XCTUnwrap(descendants(of: section.header).compactMap { $0 as? PanelIconButton }.first)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
