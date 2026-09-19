import XCTest
@testable import LocalQuotaBar

final class WeeklyPaceChartTests: XCTestCase {

    // MARK: - 窗口切分

    /// W0 非零点：首尾都是部分天格，共 8 格；起点落在首日格内的真实位置。
    func testWindowSplitEightCellsWhenWindowStartsMidDay() {
        let start = date(2026, 9, 8, 13, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 14, 16, 0)

        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now)

        XCTAssertEqual(snapshot?.cells.count, 8)
        // 等宽日格轴：首格 = 9/8 全天，W0 13:00 落在首格 13/24 处，即轴上 13/192
        let first = snapshot?.cells.first
        XCTAssertEqual(first?.xStart ?? 0, 13.0 / 192.0, accuracy: 1e-9)
        XCTAssertEqual(first?.xEnd ?? 0, 24.0 / 192.0, accuracy: 1e-9)
        // 末格为部分天：窗口结束 9/15 13:00 落在末格 13/24 处，不到右缘
        XCTAssertEqual(snapshot?.cells.last?.xEnd ?? 0, 181.0 / 192.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot?.windowEndFraction ?? 0, 181.0 / 192.0, accuracy: 1e-9)
        // 周二 13:00 起点，今天 9/14：已过 6 天 3 小时 → 第 7/7 天
        XCTAssertEqual(snapshot?.dayIndex, 7)
        XCTAssertEqual(snapshot?.windowDays, 7)
        // 第 7 格（index 6）是今天
        XCTAssertEqual(snapshot?.cells.firstIndex(where: { $0.isToday }), 6)
    }

    /// W0 恰在零点：首日为整天，窗口结束日不占格，共 7 格。
    func testWindowSplitSevenCellsWhenWindowStartsAtMidnight() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 10, 9, 30)

        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now)

        XCTAssertEqual(snapshot?.cells.count, 7)
        XCTAssertEqual(snapshot?.cells.first?.xStart ?? -1, 0, accuracy: 1e-9)
        // 零点对齐时时间轴恰好覆盖窗口：末格（最后一日）xEnd = 1
        XCTAssertEqual(snapshot?.cells.last?.xEnd ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(snapshot?.dayIndex, 3)
    }

    /// 窗口非法（时长 ≤ 0 / now 越界）时返回 nil，由调用方隐藏整图。
    func testMakeReturnsNilForInvalidWindow() {
        let start = date(2026, 9, 8, 0, 0)
        XCTAssertNil(makeSnapshot(windowStart: start, windowEnd: start))
        XCTAssertNil(makeSnapshot(windowStart: start, windowEnd: start.addingTimeInterval(-100)))
        XCTAssertNil(makeSnapshot(windowStart: start, windowEnd: start.addingTimeInterval(7 * 86400), now: start.addingTimeInterval(8 * 86400)))
    }

    /// 刻度：≤7 天窗口用星期几，今日格显示"今"；紧邻"今"的刻度避让。
    func testTicksUseWeekdayAndHighlightToday() {
        let start = date(2026, 9, 8, 13, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 14, 16, 0)

        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now)!

        let todayTick = snapshot.ticks.first(where: \.isToday)
        XCTAssertEqual(todayTick?.label, "今")
        XCTAssertEqual(todayTick?.cellIndex, 6)
        // ≤9 格时格距足够，紧邻"今"的格子不再避让
        XCTAssertTrue(snapshot.ticks.contains { $0.cellIndex == 5 && !$0.isToday })
        XCTAssertEqual(snapshot.ticks.filter { !$0.isToday }.count, 7)
    }

    /// 长于一周（ZAI number > 1）：改用 M/d 且每 2 天一个刻度。
    func testTicksUseShortDateForLongWindows() {
        let start = date(2026, 9, 1, 0, 0)
        let end = start.addingTimeInterval(14 * 86400)
        let now = date(2026, 9, 8, 10, 0)

        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now)!

        XCTAssertEqual(snapshot.windowDays, 14)
        XCTAssertEqual(snapshot.cells.count, 14)
        let labels = snapshot.ticks.filter { !$0.isToday }.map(\.label)
        XCTAssertEqual(labels.first, "9/1")
        // stride = 2：偶数格 + 今
        XCTAssertFalse(snapshot.ticks.contains { $0.cellIndex == 1 && !$0.isToday })
    }

    // MARK: - Codex 首日折算

    /// 官方只有自然日整桶：首日按 (首日 24 点 − W0)/24h 折算，窗口外整天剔除，今日不折算。
    func testCodexFirstDayProRataScaling() {
        let calendar = Calendar.current
        let windowStart = date(2026, 9, 8, 13, 0)
        let now = date(2026, 9, 10, 9, 0)
        let day = { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: windowStart))! }

        let naturalDays = [
            DayUsage(date: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: windowStart))!, tokens: 999_999),
            DayUsage(date: day(0), tokens: 2400),
            DayUsage(date: day(1), tokens: 1000),
            DayUsage(date: day(2), tokens: 600),
            DayUsage(date: day(3), tokens: 777),
        ]

        let window = WeeklyPaceCodexBridge.windowDailyUsage(naturalDays: naturalDays, windowStart: windowStart, now: now)

        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window[0].tokens, 2400 * 11.0 / 24.0, accuracy: 0.001)
        XCTAssertEqual(window[1].tokens, 1000)
        XCTAssertEqual(window[2].tokens, 600)
    }

    /// W0 恰在零点时折算系数为 1（整天桶原样保留）。
    func testCodexFirstDayProRataIsOneAtMidnight() {
        let windowStart = date(2026, 9, 8, 0, 0)
        let now = date(2026, 9, 9, 8, 0)
        let naturalDays = [DayUsage(date: windowStart, tokens: 1200)]

        let window = WeeklyPaceCodexBridge.windowDailyUsage(naturalDays: naturalDays, windowStart: windowStart, now: now)

        XCTAssertEqual(window, [DayUsage(date: windowStart, tokens: 1200)])
    }

    // MARK: - 预算估算器

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WeeklyPaceChartTests")
        defaults.removePersistentDomain(forName: "WeeklyPaceChartTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "WeeklyPaceChartTests")
        defaults = nil
        super.tearDown()
    }

    func testEstimatorInvertsUsedPercent() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        let budget = estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 1_000_000, usedPercent: 40)
        XCTAssertEqual(budget ?? 0, 2_500_000, accuracy: 0.01)
    }

    /// usedPercent ≥ 100%：剩余为 0 无法反推，直接取 windowTokens。
    func testEstimatorSaturatesAtWindowTokens() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        let budget = estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 800_000, usedPercent: 120)
        XCTAssertEqual(budget ?? 0, 800_000, accuracy: 0.01)
    }

    /// usedPercent < 5%：不更新估算，沿用持久化旧值；无旧值返回 nil（降级到"线 + 今日点"）。
    func testEstimatorKeepsOldValueBelowTrustThreshold() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        XCTAssertNil(estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 100_000, usedPercent: 3))

        let first = estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 1_000_000, usedPercent: 50)
        XCTAssertEqual(first ?? 0, 2_000_000, accuracy: 0.01)

        // < 5% 观测不更新，沿用 2M
        XCTAssertEqual(estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 900_000, usedPercent: 2) ?? 0,
                       2_000_000, accuracy: 0.01)
        // 后续可信观测仍以 2M 为 EMA 基准（未被 2% 观测污染）
        let after = estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 1_000_000, usedPercent: 40)
        XCTAssertEqual(after ?? 0, 2_000_000 + 0.5 * (2_500_000 - 2_000_000), accuracy: 0.01)
    }

    /// 本机无该渠道记录（windowTokens ≤ 0）同样不更新。
    func testEstimatorIgnoresEmptyWindowTokens() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        XCTAssertNil(estimator.update(windowEnd: date(2026, 9, 15), windowTokens: 0, usedPercent: 60))
    }

    /// 同一窗口内多次观测 EMA（α = 0.5）。
    func testEstimatorSmoothsSameWindowWithEMA() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        let windowEnd = date(2026, 9, 15)
        _ = estimator.update(windowEnd: windowEnd, windowTokens: 1_000_000, usedPercent: 50)
        let smoothed = estimator.update(windowEnd: windowEnd, windowTokens: 1_500_000, usedPercent: 50)
        // raw = 3M，EMA = 2M + 0.5 × (3M − 2M)
        XCTAssertEqual(smoothed ?? 0, 2_500_000, accuracy: 0.01)
    }

    /// 新窗口首个可信观测直接采用，不与旧窗口混合（吸收换账号跳变）。
    func testEstimatorAdoptsFirstObservationInNewWindow() {
        let estimator = WeeklyPaceEstimator(bucket: "test", defaults: defaults)
        let firstWindow = date(2026, 9, 15)
        _ = estimator.update(windowEnd: firstWindow, windowTokens: 1_000_000, usedPercent: 50)

        let nextWindow = firstWindow.addingTimeInterval(7 * 86400)
        let adopted = estimator.update(windowEnd: nextWindow, windowTokens: 600_000, usedPercent: 30)
        // raw = 2M 直接采用，而非与旧窗口 2M 做平均
        XCTAssertEqual(adopted ?? 0, 2_000_000, accuracy: 0.01)
    }

    /// 持久化按渠道 + 账号分桶：换渠道/换账号不串值。
    func testEstimatorBucketsAreIsolated() {
        let zai = WeeklyPaceEstimator(bucket: "builtin:zai-coding-plan|a@z.ai", defaults: defaults)
        let bigmodel = WeeklyPaceEstimator(bucket: "builtin:bigmodel-coding-plan|a@z.ai", defaults: defaults)
        let otherAccount = WeeklyPaceEstimator(bucket: "builtin:zai-coding-plan|b@z.ai", defaults: defaults)

        let windowEnd = date(2026, 9, 15)
        _ = zai.update(windowEnd: windowEnd, windowTokens: 1_000_000, usedPercent: 50)

        XCTAssertNil(bigmodel.currentEstimate())
        XCTAssertNil(otherAccount.currentEstimate())
        XCTAssertEqual(zai.currentEstimate() ?? 0, 2_000_000, accuracy: 0.01)
    }

    // MARK: - 点位

    /// 恰好压线算配速内（绿）；线下方才红。
    func testPointOnLineCountsAsWithinPace() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 11, 12, 0)
        // E = 700，第 1 天结束 x = 1/7：cum = E × x = 100 → 剩余 = 理想，恰好压线
        let calendar = Calendar.current
        let day1 = calendar.date(byAdding: .day, value: 1, to: start)!
        let usage = [DayUsage(date: start, tokens: 100), DayUsage(date: day1, tokens: 150)]
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now,
                                    dailyUsage: usage, budget: 700, usedPercent: 40)!

        XCTAssertEqual(snapshot.historyPoints.count, 3)
        XCTAssertEqual(snapshot.historyPoints[0].remainingPercent,
                       snapshot.historyPoints[0].idealPercent, accuracy: 1e-9)
        XCTAssertFalse(snapshot.historyPoints[0].isOverPace)
        // 第 2 天累计 250 > E × 2/7 = 200 → 线下方
        XCTAssertTrue(snapshot.historyPoints[1].isOverPace)
    }

    /// cum > E 时绘制 clamp 在 0%，tooltip 保留真实负值。
    func testCumulativeOverBudgetClampsAtZero() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 10, 12, 0)
        let usage = [DayUsage(date: start, tokens: 150)]
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now,
                                    dailyUsage: usage, budget: 100, usedPercent: 80)!

        let first = snapshot.historyPoints[0]
        XCTAssertEqual(first.remainingPercent, -50, accuracy: 1e-9)
        XCTAssertEqual(first.drawPercent, 0)
        XCTAssertTrue(first.isOverPace)
        XCTAssertTrue(snapshot.tooltip(for: first).lines.joined().contains("剩余 ≈-50%"))
    }

    /// 今日点用服务端真实百分比，锚定 now 位置。
    func testTodayPointUsesServerPercent() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 11, 12, 0)
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now,
                                    dailyUsage: [], budget: 700, usedPercent: 30)!

        let today = snapshot.todayPoint
        XCTAssertEqual(today?.remainingPercent ?? -1, 70, accuracy: 1e-9)
        XCTAssertEqual(today?.x ?? -1, 3.5 / 7.0, accuracy: 1e-9)
        // 理想剩余此刻 = 50%，真实 70% 在线上方 → 配速内
        XCTAssertFalse(today?.isOverPace ?? true)
    }

    // MARK: - 渠道 id 解析

    func testCodingPlanProviderIDsContainSelectedKeyAndFallbacks() {
        let selection = ZAIProviderSelection(domain: "zai", kind: .codingPlan,
                                             selectedKey: "coding-plan:builtin:zai-coding-plan")
        let ids = ZAIPaceChannel.codingPlanProviderIDs(selection: selection)!
        XCTAssertTrue(ids.contains("builtin:zai-coding-plan"))
        // ZCode 3.12.3+ 的 account: 前缀新形态（实测与 builtin 并存迁移）
        XCTAssertTrue(ids.contains("account:zai-individual-coding-plan"))
        XCTAssertTrue(ids.contains("account:zai-team-coding-plan"))

        let bigmodel = ZAIProviderSelection(domain: "bigmodel", kind: .codingPlan,
                                            selectedKey: "coding-plan:builtin:bigmodel-coding-plan")
        XCTAssertEqual(ZAIPaceChannel.codingPlanProviderIDs(selection: bigmodel)!.first,
                       "builtin:bigmodel-coding-plan")
    }

    /// selectedKey 缺失（team 连接）或冻结在旧套餐值：兜底 domain 拼接仍可用。
    func testCodingPlanProviderIDsFallBackWithoutSelectedKey() {
        let noKey = ZAIProviderSelection(domain: "zai", kind: .codingPlan, selectedKey: nil)
        XCTAssertEqual(ZAIPaceChannel.codingPlanProviderIDs(selection: noKey)!.first, "builtin:zai-coding-plan")

        let frozenKey = ZAIProviderSelection(domain: "bigmodel", kind: .codingPlan,
                                             selectedKey: "start-plan:builtin:bigmodel-start-plan")
        // 冻结的 start-plan 后段不混入，仍以 builtin 兜底为主
        XCTAssertEqual(ZAIPaceChannel.codingPlanProviderIDs(selection: frozenKey)!.first,
                       "builtin:bigmodel-coding-plan")
        XCTAssertFalse(ZAIPaceChannel.codingPlanProviderIDs(selection: frozenKey)!
            .contains("builtin:bigmodel-start-plan"))
    }

    /// 非 coding-plan（apiKey / startPlan）→ nil，整图隐藏。
    func testCodingPlanProviderIDsRejectNonCodingPlanKinds() {
        XCTAssertNil(ZAIPaceChannel.codingPlanProviderIDs(selection: nil))
        let apiKey = ZAIProviderSelection(domain: "zai", kind: .apiKey, selectedKey: "api-key:builtin:zai")
        XCTAssertNil(ZAIPaceChannel.codingPlanProviderIDs(selection: apiKey))
        let startPlan = ZAIProviderSelection(domain: "zai", kind: .startPlan, selectedKey: "start-plan:builtin:zai-start-plan")
        XCTAssertNil(ZAIPaceChannel.codingPlanProviderIDs(selection: startPlan))
    }

    // MARK: - 降级阶梯

    /// 第 1 级：只有对角线（无 usedPercent、无 E）。
    func testLadderLineOnly() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: date(2026, 9, 10, 0, 0),
                                    dailyUsage: [], budget: nil, usedPercent: nil)!

        XCTAssertFalse(snapshot.cells.isEmpty)
        XCTAssertTrue(snapshot.historyPoints.isEmpty)
        XCTAssertNil(snapshot.todayPoint)
        XCTAssertNil(snapshot.dailyAverage)
    }

    /// 第 2 级：线 + 今日真实点（无 E）。
    func testLadderLineAndTodayPointOnly() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: date(2026, 9, 10, 0, 0),
                                    dailyUsage: [], budget: nil, usedPercent: 44)!

        XCTAssertTrue(snapshot.historyPoints.isEmpty)
        XCTAssertEqual(snapshot.todayPoint?.remainingPercent ?? -1, 56, accuracy: 1e-9)
        XCTAssertNil(snapshot.dailyAverage)
    }

    /// 第 3 级：E 可估 → 补全历史点位与"日均可"。
    func testLadderFullPoints() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let usage = [DayUsage(date: start, tokens: 300)]
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: date(2026, 9, 10, 0, 0),
                                    dailyUsage: usage, budget: 2100, usedPercent: 44)!

        XCTAssertEqual(snapshot.historyPoints.count, 2)
        XCTAssertEqual(snapshot.dailyAverage ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(snapshot.historyPoints[0].remainingPercent,
                       100 * (1 - 300.0 / 2100.0), accuracy: 1e-9)
    }

    /// tooltip 文案（超过 2 段 → 日期单独一行，数值合并第二行）+ 估算口径尾注。
    func testTooltipFormatForHistoryPoint() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let usage = [DayUsage(date: start, tokens: 1_900_000)]
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: date(2026, 9, 11, 12, 0),
                                    dailyUsage: usage, budget: 10_000_000, usedPercent: 30)!

        let content = snapshot.tooltip(for: snapshot.historyPoints[0])
        // 剩余 = 100 × (1 − 1.9M/10M) = 81%，理想 = 100 × 6/7 ≈ 86% → 超配速 5%
        XCTAssertEqual(content.lines, ["9月8日", "当日 +1.9M · 剩余 ≈81%（理想 86%） · 超配速 5%"])
        XCTAssertEqual(content.footnote, "预算为按用量与百分比的估算值")
    }

    /// 今日点 tooltip：追加"（今天）"并显示真实百分比。
    func testTooltipFormatForTodayPoint() {
        let start = date(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(7 * 86400)
        let now = date(2026, 9, 10, 12, 0)
        let usage = [DayUsage(date: Calendar.current.startOfDay(for: now), tokens: 800_000)]
        let snapshot = makeSnapshot(windowStart: start, windowEnd: end, now: now,
                                    dailyUsage: usage, budget: 10_000_000, usedPercent: 10)!

        let content = snapshot.tooltip(for: snapshot.todayPoint!)
        // 真实剩余 90%，此刻理想 100×(1−2.5/7) ≈ 64% → 配速内
        XCTAssertEqual(content.lines, ["9月10日（今天）", "今日 +800.0K · 真实剩余 90%（此刻理想 64%） · 配速内"])
    }

    // MARK: - 辅助

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeSnapshot(
        windowStart: Date,
        windowEnd: Date,
        now: Date? = nil,
        dailyUsage: [DayUsage] = [],
        budget: Double? = nil,
        usedPercent: Double? = nil
    ) -> WeeklyPaceSnapshot? {
        WeeklyPaceSnapshot.make(
            windowStart: windowStart,
            windowEnd: windowEnd,
            now: now ?? Date(),
            dailyUsage: dailyUsage,
            budgetEstimate: budget,
            usedPercent: usedPercent
        )
    }
}
