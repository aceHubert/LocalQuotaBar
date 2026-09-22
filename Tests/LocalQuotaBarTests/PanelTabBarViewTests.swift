import AppKit
import XCTest
@testable import LocalQuotaBar

final class PanelTabBarViewTests: XCTestCase {
    @MainActor
    func testRingValueMapsFractionTextAndColor() {
        let percent = PanelTabStatus(ring: .percent(remaining: 64), tagText: "Pro")
        XCTAssertEqual(percent.ringFraction ?? 0, 0.64, accuracy: 0.001)
        XCTAssertEqual(percent.valueText, "64%")
        XCTAssertEqual(percent.valueColor, PanelTheme.green)

        let warn = PanelTabStatus(ring: .percent(remaining: 15))
        XCTAssertEqual(warn.valueColor, PanelTheme.orange)
        let critical = PanelTabStatus(ring: .percent(remaining: 6))
        XCTAssertEqual(critical.valueColor, PanelTheme.red)

        // DeepSeek：无「剩余/总量」口径 → 空环 + 金额文字，不伪造百分比
        let balance = PanelTabStatus(ring: .text("¥5.13"))
        XCTAssertNil(balance.ringFraction)
        XCTAssertEqual(balance.valueText, "¥5.13")
        XCTAssertEqual(balance.valueColor, PanelTheme.secondaryText)

        let unavailable = PanelTabStatus(ring: .unavailable)
        XCTAssertNil(unavailable.ringFraction)
        XCTAssertEqual(unavailable.valueText, "--")
    }

    @MainActor
    func testItemConfiguresRingTagDotAndTooltip() throws {
        _ = NSApplication.shared
        let item = PanelTabItemView(tab: .codex)
        item.configure(PanelTabStatus(
            ring: .percent(remaining: 64),
            tagText: "Pro",
            isFailed: false,
            summary: "周限额剩余 64% · 4天3时后重置"
        ))

        XCTAssertEqual(item.ringFillLayer.strokeEnd, 0.64, accuracy: 0.001)
        XCTAssertEqual(item.ringFillLayer.strokeColor, PanelTheme.green.cgColor)
        let value = try XCTUnwrap(descendants(of: item).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "64%" })
        XCTAssertFalse(value.isHidden)
        XCTAssertTrue(item.toolTip?.contains("Codex · Pro") == true)
        XCTAssertTrue(item.toolTip?.contains("周限额剩余 64%") == true)

        // 失败态：状态点变红、环转为空轨 + "--"
        item.configure(PanelTabStatus(ring: .unavailable, tagText: nil, isFailed: true))
        XCTAssertEqual(item.ringFillLayer.strokeEnd, 0, accuracy: 0.001)
        XCTAssertEqual(item.ringFillLayer.strokeColor, PanelTheme.trackColor.cgColor)
    }

    @MainActor
    func testBarSelectsActiveAndHidesInvisibleTabs() throws {
        _ = NSApplication.shared
        let bar = PanelTabBarView()
        var selected: [QuotaTabID] = []
        bar.onSelectionChange = { selected.append($0) }

        bar.configure(statuses: [:], visible: [.codex, .zai])
        let codex = try tabItem(.codex, in: bar)
        let zai = try tabItem(.zai, in: bar)
        let deepSeek = try tabItem(.deepSeek, in: bar)
        XCTAssertFalse(codex.isHidden)
        XCTAssertFalse(zai.isHidden)
        XCTAssertTrue(deepSeek.isHidden)

        zai.performClick(nil)
        XCTAssertEqual(selected, [.zai])
        XCTAssertEqual(bar.active, .zai)
        bar.select(.codex, notify: false)
        XCTAssertEqual(bar.active, .codex)
        XCTAssertEqual(selected, [.zai])
    }

    @MainActor
    private func tabItem(_ tab: QuotaTabID, in bar: PanelTabBarView) throws -> PanelTabItemView {
        try XCTUnwrap(descendants(of: bar).compactMap { $0 as? PanelTabItemView }
            .first { $0.identifier?.rawValue == "quota-tab.\(tab.rawValue)" })
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
