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
        XCTAssertEqual(balance.valueColor, PanelTheme.primaryText)

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

        // logo 圆底：纯渐变背景填充，无边框
        let logoContainer = try XCTUnwrap(item.subviews.first { $0 !== item && $0.layer?.cornerRadius == 12.5 })
        XCTAssertEqual(logoContainer.layer?.borderWidth, 0)

        // tag 徽章：有 tag 时可见且带胶囊底色；状态点带同色光晕
        XCTAssertFalse(item.tagBadge.isHidden)
        XCTAssertEqual(item.tagBadge.layer?.backgroundColor, NSColor(hex: 0x232936).cgColor)
        XCTAssertEqual(item.statusDot.dotColor, PanelTheme.green)

        // 失败态 + 无 tag：徽章隐藏、光晕变红、环转为空轨 + "--"
        item.configure(PanelTabStatus(ring: .unavailable, tagText: nil, isFailed: true))
        XCTAssertTrue(item.tagBadge.isHidden)
        XCTAssertEqual(item.statusDot.dotColor, PanelTheme.red)
        XCTAssertEqual(item.ringFillLayer.strokeEnd, 0, accuracy: 0.001)
        XCTAssertEqual(item.ringFillLayer.strokeColor, PanelTheme.trackColor.cgColor)

        // idle 态（无快照无错误，首次刷新未完成）：点体置灰且不做呼吸
        item.configure(PanelTabStatus(ring: .unavailable, tagText: nil, isIdle: true))
        XCTAssertEqual(item.statusDot.dotColor, PanelTheme.tertiaryText)
        XCTAssertTrue(item.statusDot.isIdle)
        XCTAssertFalse(item.statusDot.isBreathing)
    }

    @MainActor
    func testBarSelectsActiveAndHidesInvisibleTabs() throws {
        _ = NSApplication.shared
        let bar = PanelTabBarView()
        var selected: [QuotaTabID] = []
        bar.onSelectionChange = { selected.append($0) }

        bar.configure(statuses: [:], visible: [.codex, .zai, .codeBuddy, .codeBuddyCN])
        let codex = try tabItem(.codex, in: bar)
        let zai = try tabItem(.zai, in: bar)
        let deepSeek = try tabItem(.deepSeek, in: bar)
        let codeBuddy = try tabItem(.codeBuddy, in: bar)
        let codeBuddyCN = try tabItem(.codeBuddyCN, in: bar)
        XCTAssertFalse(codex.isHidden)
        XCTAssertFalse(zai.isHidden)
        XCTAssertTrue(deepSeek.isHidden)
        // CodeBuddy 国内外为两个独立 tab，同名同 logo，靠 INTL / CN 角标区分。
        XCTAssertFalse(codeBuddy.isHidden)
        XCTAssertFalse(codeBuddyCN.isHidden)
        XCTAssertEqual(codeBuddy.tab.displayName, codeBuddyCN.tab.displayName)

        zai.performClick(nil)
        XCTAssertEqual(selected, [.zai])
        XCTAssertEqual(bar.active, .zai)
        bar.select(.codex, notify: false)
        XCTAssertEqual(bar.active, .codex)
        XCTAssertEqual(selected, [.zai])
    }

    @MainActor
    func testCodeBuddyTabsCarryRegionBadgeAndIndependentRings() throws {
        _ = NSApplication.shared
        let bar = PanelTabBarView()
        var intl = PanelTabStatus(ring: .percent(remaining: 83.05))
        intl.tagText = "INTL"
        intl.summary = "体验版"
        var cn = PanelTabStatus(ring: .percent(remaining: 40))
        cn.tagText = "CN"
        cn.summary = "体验版"
        bar.configure(
            statuses: [.codeBuddy: intl, .codeBuddyCN: cn],
            visible: [.codeBuddy, .codeBuddyCN]
        )

        let intlItem = try tabItem(.codeBuddy, in: bar)
        let cnItem = try tabItem(.codeBuddyCN, in: bar)
        // 区域角标取代套餐名，作为两个同名 tab 的唯一区分。
        XCTAssertEqual(intlItem.tagBadge.isHidden, false)
        XCTAssertEqual(cnItem.tagBadge.isHidden, false)
        XCTAssertTrue(intlItem.toolTip?.contains("INTL") == true)
        XCTAssertTrue(cnItem.toolTip?.contains("CN") == true)
        // 两站环各自独立取套餐基础积分剩余比例。
        XCTAssertEqual(intlItem.ringFillLayer.strokeEnd, 0.8305, accuracy: 0.001)
        XCTAssertEqual(cnItem.ringFillLayer.strokeEnd, 0.40, accuracy: 0.001)
        XCTAssertEqual(cnItem.ringFillLayer.strokeColor, PanelTheme.green.cgColor)
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
