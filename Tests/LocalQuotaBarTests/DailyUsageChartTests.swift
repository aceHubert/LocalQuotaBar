import AppKit
import XCTest
@testable import LocalQuotaBar

@MainActor
final class DailyUsageChartTests: XCTestCase {

    // MARK: - 布局

    func testBarLayoutSplitsAvailableWidthEvenly() {
        let layout = ChartBarLayout(count: 30, availableWidth: 282, gap: 2)
        XCTAssertEqual(layout.count, 30)
        // (282 - 2*29) / 30 ≈ 7.47
        XCTAssertEqual(layout.barWidth, 7.4666, accuracy: 0.01)
        XCTAssertEqual(layout.pitch, layout.barWidth + 2)
    }

    func testBarLayoutUsesMinimumBarWidthWhenCramped() {
        let layout = ChartBarLayout(count: 30, availableWidth: 10, gap: 2)
        XCTAssertEqual(layout.barWidth, 1.5)
        XCTAssertEqual(layout.pitch, 3.5)
    }

    func testBarLayoutIndexAtBoundaries() {
        let layout = ChartBarLayout(count: 30, availableWidth: 282, gap: 2)
        XCTAssertEqual(layout.index(at: 0), 0)
        XCTAssertEqual(layout.index(at: layout.pitch), 1)
        XCTAssertEqual(layout.index(at: layout.pitch * 29 + layout.barWidth / 2), 29)
        // 最后一根柱子右侧的空白不归属任何柱子
        XCTAssertNil(layout.index(at: layout.pitch * 30))
        XCTAssertNil(layout.index(at: -1))
    }

    func testEmptyLayoutHasNoBars() {
        let layout = ChartBarLayout(count: 0, availableWidth: 282, gap: 2)
        XCTAssertEqual(layout.count, 0)
        XCTAssertNil(layout.index(at: 0))
    }

    // MARK: - 命中与文案

    /// 图表实际宽度下每根柱子只有约 7pt，验证悬停能稳定命中相邻柱子。
    func testHoveredBarIndexAcrossFullWidth() {
        let chart = DailyUsageChartView()
        chart.frame = NSRect(x: 0, y: 0, width: 298, height: 63)
        chart.configure(days: makeDays(count: 30))

        let rect = chart.barsRect
        let layout = ChartBarLayout(count: 30, availableWidth: rect.width, gap: 2)

        // 每根柱子中心都能命中自己
        for index in 0..<30 {
            let center = rect.minX + CGFloat(index) * layout.pitch + layout.barWidth / 2
            let hit = chart.hoveredBarIndex(at: NSPoint(x: center, y: rect.midY))
            XCTAssertEqual(hit, index, "柱子 \(index) 的中心未命中")
        }

        // 相邻柱子的命中区域不重叠
        let first = chart.hoveredBarIndex(at: NSPoint(x: rect.minX + 1, y: rect.midY))
        let secondCenter = rect.minX + layout.pitch + layout.barWidth / 2
        let second = chart.hoveredBarIndex(at: NSPoint(x: secondCenter, y: rect.midY))
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)

        // 柱子区域之外（标题行）不命中
        XCTAssertNil(chart.hoveredBarIndex(at: NSPoint(x: rect.midX, y: rect.maxY + 8)))
    }

    func testHoveredBarIndexIsNilWithoutData() {
        let chart = DailyUsageChartView()
        chart.frame = NSRect(x: 0, y: 0, width: 298, height: 63)
        chart.configure(days: nil)
        XCTAssertNil(chart.hoveredBarIndex(at: NSPoint(x: chart.barsRect.midX, y: chart.barsRect.midY)))
    }

    func testTooltipTextForPastDayAndToday() {
        let chart = DailyUsageChartView()
        chart.configure(days: makeDays(count: 30))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        // 最早的一天不带"今天"标记
        let past = chart.tooltipText(for: 0)
        XCTAssertEqual(past, "\(formatter.string(from: oldestDay())) · 1.0K tokens")

        // 最后一列是今天
        let today = chart.tooltipText(for: 29)
        XCTAssertEqual(today, "\(formatter.string(from: Date()))（今天） · 30.0K tokens")
    }

    // MARK: - 辅助

    /// 升序 30 天，最后一列为今天；tokens 与序号一致便于断言。
    private func makeDays(count: Int) -> [DayUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: -(count - 1 - offset), to: today) ?? today
            return DayUsage(date: date, tokens: Double(offset + 1) * 1000)
        }
    }

    private func oldestDay() -> Date {
        Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    }
}
