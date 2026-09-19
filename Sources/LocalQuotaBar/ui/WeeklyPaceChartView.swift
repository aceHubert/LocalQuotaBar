import AppKit
import Foundation

// MARK: - 周配速图推导（纯函数）

/// 燃尽式配速图数据：Y 轴剩余百分比（100 顶、0 底），对角线是理想剩余配速，
/// 每天一个评估点位。make(...) 只做几何与语义推导，视图只负责绘制；
/// 输入不全时按降级阶梯逐级退化（只有线 / 线+今日点 / 全量点位）。
struct WeeklyPaceSnapshot: Equatable {
    /// 横轴自然日格：窗口覆盖到的每个自然日，首尾可为部分天（W0 非零点时共 8 格）。
    struct DayCell: Equatable {
        let day: Date
        /// 该天在窗口时间轴上的覆盖区间（0–1，相对 W0 → 窗口结束）。
        let xStart: Double
        let xEnd: Double
        let isToday: Bool
    }

    /// 评估点位：x 为窗口时间占比，y 为剩余百分比（真实值可为负，绘制时 clamp）。
    struct PacePoint: Equatable {
        let day: Date
        let x: Double
        let remainingPercent: Double
        let idealPercent: Double
        let dayTokens: Double
        let isToday: Bool

        /// 点在线下方＝用多了；恰好压线算配速内。
        var isOverPace: Bool { remainingPercent < idealPercent }
        var drawPercent: Double { min(max(remainingPercent, 0), 100) }
    }

    struct Tick: Equatable {
        let cellIndex: Int
        let label: String
        let isToday: Bool
    }

    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let cells: [DayCell]
    let historyPoints: [PacePoint]
    /// 今日真实点：x = now，剩余百分比直接取服务端 usedPercent，不依赖估算。
    let todayPoint: PacePoint?
    /// 头部"第 d/N 天"；N 为窗口时长折算天数（7×number / windowDurationMins），非格子数。
    let dayIndex: Int
    let windowDays: Int
    let ticks: [Tick]
    let budgetEstimate: Double?

    var dailyAverage: Double? {
        guard let budgetEstimate, windowDays > 0 else { return nil }
        return budgetEstimate / Double(windowDays)
    }

    /// 时间戳 → 等宽日格轴占比（对角线锚点 / 今日点定位共用）。
    func xFraction(_ date: Date) -> Double {
        guard let axisStart = cells.first?.day else { return 0 }
        let axisSpan = Double(cells.count) * 86400
        guard axisSpan > 0 else { return 0 }
        return min(max(date.timeIntervalSince(axisStart) / axisSpan, 0), 1)
    }

    /// now 在等宽日格轴上的占比（对角线虚实分段用）。
    var nowFraction: Double { xFraction(now) }
    var windowStartFraction: Double { xFraction(windowStart) }
    var windowEndFraction: Double { xFraction(windowEnd) }

    /// 对角线在轴上任意占比处的理想剩余百分比（clamp 0–100）。
    func idealPercent(atFraction fraction: Double) -> Double {
        let start = windowStartFraction
        let end = windowEndFraction
        guard end > start else { return 0 }
        return min(max(100 * (end - fraction) / (end - start), 0), 100)
    }

    // MARK: 推导入口

    /// 窗口非法（时长 ≤ 0、now 越界）时返回 nil，由调用方隐藏整图。
    /// 横轴为等宽自然日格（首尾可为部分天），时间戳在格内按当日比例定位——
    /// 对角线起点因此落在首日格内的真实位置（如 W0 = 周二 13:00 → 13/24 处）。
    static func make(
        windowStart: Date,
        windowEnd: Date,
        now: Date = Date(),
        dailyUsage: [DayUsage],
        budgetEstimate: Double?,
        usedPercent: Double?,
        calendar: Calendar = .current
    ) -> WeeklyPaceSnapshot? {
        let duration = windowEnd.timeIntervalSince(windowStart)
        guard duration > 0, now >= windowStart, now < windowEnd else { return nil }

        // 先收集窗口覆盖的自然日（含真实起止时刻），再映射到等宽日格时间轴
        let today = calendar.startOfDay(for: now)
        var spans: [(day: Date, start: Date, end: Date, isToday: Bool)] = []
        var cursor = calendar.startOfDay(for: windowStart)
        while cursor < windowEnd {
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: cursor) ?? windowEnd
            spans.append((day: cursor, start: max(cursor, windowStart),
                          end: min(nextMidnight, windowEnd), isToday: cursor == today))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        guard !spans.isEmpty else { return nil }

        // 等宽日格时间轴：首格零点 → N 格 × 24h；时间戳线性映射到 [0, 1]
        let axisStart = spans[0].day
        let axisSpan = Double(spans.count) * 86400
        func x(_ date: Date) -> Double {
            min(max(date.timeIntervalSince(axisStart) / axisSpan, 0), 1)
        }
        func ideal(_ date: Date) -> Double {
            100 * (1 - date.timeIntervalSince(windowStart) / duration)
        }
        let cells = spans.map {
            DayCell(day: $0.day, xStart: x($0.start), xEnd: x($0.end), isToday: $0.isToday)
        }

        let tokensByDay = Dictionary(dailyUsage.map { ($0.date, $0.tokens) }, uniquingKeysWith: { _, last in last })

        // 历史点位：E 可估时，每个已结束的自然日在其结束时刻落一个剩余百分比
        var historyPoints: [PacePoint] = []
        if let budget = budgetEstimate, budget > 0 {
            var cumulative = 0.0
            for span in spans {
                guard span.end <= now else { break }
                let tokens = tokensByDay[span.day] ?? 0
                cumulative += tokens
                historyPoints.append(PacePoint(
                    day: span.day,
                    x: x(span.end),
                    remainingPercent: 100 * (1 - cumulative / budget),
                    idealPercent: ideal(span.end),
                    dayTokens: tokens,
                    isToday: false
                ))
            }
        }

        // 今日点：真实剩余百分比锚定 now
        var todayPoint: PacePoint?
        if let usedPercent, let todayCell = cells.first(where: \.isToday) {
            todayPoint = PacePoint(
                day: todayCell.day,
                x: x(now),
                remainingPercent: 100 - usedPercent,
                idealPercent: ideal(now),
                dayTokens: tokensByDay[todayCell.day] ?? 0,
                isToday: true
            )
        }

        let windowDays = max(1, Int((duration / 86400).rounded()))
        let elapsedDays = Int(now.timeIntervalSince(windowStart) / 86400) + 1

        return WeeklyPaceSnapshot(
            windowStart: windowStart,
            windowEnd: windowEnd,
            now: now,
            cells: cells,
            historyPoints: historyPoints,
            todayPoint: todayPoint,
            dayIndex: min(max(elapsedDays, 1), windowDays),
            windowDays: windowDays,
            ticks: makeTicks(cells: cells, windowDays: windowDays, calendar: calendar),
            budgetEstimate: budgetEstimate
        )
    }

    /// 横轴刻度：窗口 ≤ 7 天逐格显示星期几（今日绿色"今"）；更长窗口改用 M/d
    /// 并每 1–2 天一个，避免文字互相压盖。
    private static func makeTicks(cells: [DayCell], windowDays: Int, calendar: Calendar) -> [Tick] {
        let todayIndex = cells.firstIndex(where: \.isToday)
        let stride = cells.count >= 14 ? 2 : 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"

        var ticks: [Tick] = []
        for (index, cell) in cells.enumerated() {
            if cell.isToday {
                ticks.append(Tick(cellIndex: index, label: "今", isToday: true))
            } else if index % stride == 0 {
                // 窄格距（长窗口 M/d 标签）时才避让紧邻"今"的刻度，避免文字压盖；
                // ≤9 格的星期单字格距足够，不再跳格（否则会出现明显的刻度空洞）
                if let todayIndex, index == todayIndex - 1, cells.count >= 10 { continue }
                let label = windowDays > 7 ? formatter.string(from: cell.day) : weekdaySymbol(for: cell.day, calendar: calendar)
                ticks.append(Tick(cellIndex: index, label: label, isToday: false))
            }
        }
        return ticks
    }

    private static func weekdaySymbol(for day: Date, calendar: Calendar) -> String {
        switch calendar.component(.weekday, from: day) {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        default: return "六"
        }
    }

    // MARK: tooltip 文案

    /// 悬停明细（超过 2 段，日期单独一行，数值合并在第二行）：
    /// 日期（今日带"（今天）"）/ 当日 +X · 剩余 ≈Y%（理想 Z%）· 超配速 Δ 或 配速内；
    /// 今日点显示服务端真实百分比；尾注说明估算口径。
    func tooltip(for point: PacePoint) -> (lines: [String], footnote: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let delta = point.idealPercent - point.remainingPercent
        let pace = delta > 0.5 ? "超配速 \(Int(delta.rounded()))%" : "配速内"

        let date = point.isToday
            ? "\(formatter.string(from: point.day))（今天）"
            : formatter.string(from: point.day)
        let values: String
        if point.isToday {
            values = "今日 +\(PanelTheme.formatTokenCount(point.dayTokens)) · "
                + "真实剩余 \(Int(point.remainingPercent.rounded()))%"
                + "（此刻理想 \(Int(point.idealPercent.rounded()))%） · \(pace)"
        } else {
            values = "当日 +\(PanelTheme.formatTokenCount(point.dayTokens)) · "
                + "剩余 ≈\(Int(point.remainingPercent.rounded()))%"
                + "（理想 \(Int(point.idealPercent.rounded()))%） · \(pace)"
        }
        return ([date, values], "预算为按用量与百分比的估算值")
    }
}

// MARK: - 周配速图视图

/// 卡片样式对齐 DailyUsageChartView（圆角 9、hairline 边框、inset 8）；柱区高 44，整卡约 86pt。
/// 对角线锚定真实重置时刻（起点落在首日格内的真实位置），已过段实线、未来段虚线。
final class WeeklyPaceChartView: NSView {
    private var snapshot: WeeklyPaceSnapshot?

    private let titleHeight: CGFloat = 14
    private let plotHeight: CGFloat = 44
    private let ticksHeight: CGFloat = 11
    private let inset: CGFloat = 8
    /// 左侧 100%/50%/0% 刻度留白
    private let yAxisWidth: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 6 + titleHeight + 4 + plotHeight + 3 + ticksHeight + 4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// nil = 无周限桶，由宿主隐藏整图（降级阶梯第 4 级）。
    func configure(_ snapshot: WeeklyPaceSnapshot?) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        needsDisplay = true
        cancelPendingTooltip()
        tooltip.hide()
    }

    var plotRect: NSRect {
        NSRect(
            x: inset + yAxisWidth,
            y: bounds.height - 6 - titleHeight - 4 - plotHeight,
            width: bounds.width - inset * 2 - yAxisWidth,
            height: plotHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawHeader()
        guard let snapshot else { return }
        drawGrid()
        drawDiagonal(snapshot)
        drawPoints(snapshot)
        drawTicks(snapshot)
    }

    private func drawHeader() {
        guard let snapshot else { return }
        let title = NSAttributedString(
            string: "本周配速 · 第\(snapshot.dayIndex)/\(snapshot.windowDays)天",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: PanelTheme.tertiaryText
            ]
        )
        title.draw(at: NSPoint(x: inset + 1, y: bounds.height - 6 - titleHeight + 2))

        guard let average = snapshot.dailyAverage else { return }
        let avg = NSAttributedString(
            string: "日均可 ≈\(PanelTheme.formatTokenCount(average))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: PanelTheme.green
            ]
        )
        let size = avg.size()
        // 宽度不够容纳"标题 + 日均可"时跳过（与 30 天图日均同退让规则）
        guard title.size().width + size.width + 10 <= bounds.width - inset * 2 else { return }
        avg.draw(at: NSPoint(x: bounds.width - inset - 1 - size.width, y: bounds.height - 6 - titleHeight + 2))
    }

    private func drawGrid() {
        let rect = plotRect

        let labels: [(text: String, y: CGFloat)] = [
            ("100%", rect.maxY), ("50%", rect.midY), ("0%", rect.minY)
        ]
        for label in labels {
            let attributed = NSAttributedString(string: label.text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: PanelTheme.tertiaryText
            ])
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: inset + yAxisWidth - 4 - size.width, y: label.y - size.height / 2))
        }

        // 50% 淡虚线 + 0% 基线
        let dashes: [(y: CGFloat, alpha: CGFloat, dashed: Bool)] = [
            (rect.midY, 0.08, true), (rect.minY, 0.10, false)
        ]
        for dash in dashes {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: dash.y))
            line.line(to: NSPoint(x: rect.maxX, y: dash.y))
            line.lineWidth = 1
            if dash.dashed { line.setLineDash([2, 2], count: 2, phase: 0) }
            NSColor.white.withAlphaComponent(dash.alpha).setStroke()
            line.stroke()
        }

        // 自然日分隔（零点竖线），首尾部分天也按真实位置分格
        guard let snapshot, snapshot.cells.count > 1 else { return }
        for cell in snapshot.cells.dropFirst() {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plotX(cell.xStart), y: rect.minY))
            line.line(to: NSPoint(x: plotX(cell.xStart), y: rect.maxY))
            line.lineWidth = 1
            NSColor.white.withAlphaComponent(0.045).setStroke()
            line.stroke()
        }
    }

    private func drawDiagonal(_ snapshot: WeeklyPaceSnapshot) {
        let rect = plotRect
        // 线锚定真实重置时刻：W0 非零点时起点落在首日格内、终点在末格中间（不到右缘）
        let start = NSPoint(x: plotX(snapshot.windowStartFraction), y: rect.maxY)
        let nowPoint = NSPoint(x: plotX(snapshot.nowFraction), y: plotY(snapshot.idealPercent(atFraction: snapshot.nowFraction)))
        let end = NSPoint(x: plotX(snapshot.windowEndFraction), y: rect.minY)

        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: nowPoint)
        line.lineWidth = 1.25
        NSColor.white.withAlphaComponent(0.45).setStroke()
        line.stroke()

        // 今天之后到窗口结束：虚线延伸
        let future = NSBezierPath()
        future.move(to: nowPoint)
        future.line(to: end)
        future.lineWidth = 1.25
        future.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.45).setStroke()
        future.stroke()

        // W0 起点：理想配速从 100% 出发
        let dot = NSBezierPath(ovalIn: NSRect(
            x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3
        ))
        NSColor.white.withAlphaComponent(0.8).setFill()
        dot.fill()
    }

    private func drawPoints(_ snapshot: WeeklyPaceSnapshot) {
        let points = snapshot.historyPoints
        guard !points.isEmpty else { return }

        // 相邻点低透明折线
        let polyline = NSBezierPath()
        polyline.move(to: NSPoint(x: plotX(points[0].x), y: plotY(points[0].drawPercent)))
        for point in points.dropFirst() {
            polyline.line(to: NSPoint(x: plotX(point.x), y: plotY(point.drawPercent)))
        }
        polyline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.25).setStroke()
        polyline.stroke()

        for point in points {
            let color = point.isOverPace ? PanelTheme.red : PanelTheme.green
            let dot = NSBezierPath(ovalIn: NSRect(
                x: plotX(point.x) - 1.5, y: plotY(point.drawPercent) - 1.5, width: 3, height: 3
            ))
            color.setFill()
            dot.fill()
        }

        // 今日点：空心加大，锚定服务端真实剩余
        guard let today = snapshot.todayPoint else { return }
        let color = today.isOverPace ? PanelTheme.red : PanelTheme.green
        let ring = NSBezierPath(ovalIn: NSRect(
            x: plotX(today.x) - 2.5, y: plotY(today.drawPercent) - 2.5, width: 5, height: 5
        ))
        PanelTheme.cardBackground.setFill()
        ring.fill()
        ring.lineWidth = 1.2
        color.setStroke()
        ring.stroke()
    }

    private func drawTicks(_ snapshot: WeeklyPaceSnapshot) {
        let rect = plotRect
        let cellCount = Double(snapshot.cells.count)
        for tick in snapshot.ticks {
            let attributed = NSAttributedString(string: tick.label, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: tick.isToday ? PanelTheme.green : NSColor(hex: 0x56565C)
            ])
            let size = attributed.size()
            // 刻度对齐整格中心（部分天格也按整格居中，与原型一致）
            let centerX = plotX((Double(tick.cellIndex) + 0.5) / cellCount)
            attributed.draw(at: NSPoint(
                x: min(max(centerX - size.width / 2, rect.minX), rect.maxX - size.width),
                y: rect.minY - ticksHeight + 1
            ))
        }
    }

    private func plotX(_ fraction: Double) -> CGFloat {
        plotRect.minX + CGFloat(fraction) * plotRect.width
    }

    /// 剩余百分比 → 视图 y：AppKit 坐标 y 向上，100% 在柱区顶部（maxY）、0% 在底部。
    private func plotY(_ percent: Double) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        return plotRect.minY + plotRect.height * CGFloat(clamped / 100)
    }

    // MARK: hover 提示

    private let tooltip = ChartTooltipWindow()
    private var showTooltipWork: DispatchWorkItem?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var hoveredDay: Date?

    private static let tooltipDelay: TimeInterval = 0.18

    private var hoverRect: NSRect { plotRect.insetBy(dx: -3, dy: -3) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: hoverRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowWillCloseObserver = nil
        }
        guard let window else { return }
        // popover 关闭时不会收到 mouseExited，浮层需要在这里收掉
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.cancelPendingTooltip()
            self?.tooltip.hide()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        refreshHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        refreshHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        cancelPendingTooltip()
        tooltip.hide()
        hoveredDay = nil
    }

    private func refreshHover(at location: NSPoint) {
        guard let point = pacePoint(at: location) else {
            cancelPendingTooltip()
            tooltip.hide()
            hoveredDay = nil
            return
        }
        if hoveredDay != point.day {
            hoveredDay = point.day
        }
        if tooltip.isShown {
            let content = snapshot?.tooltip(for: point)
            tooltip.present(
                lines: content?.lines ?? [],
                detail: content?.footnote,
                anchor: screenAnchor(for: point),
                hostWindow: window
            )
            return
        }
        cancelPendingTooltip()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true,
                  let content = self.snapshot?.tooltip(for: point) else { return }
            self.tooltip.present(
                lines: content.lines,
                detail: content.footnote,
                anchor: self.screenAnchor(for: point),
                hostWindow: self.window
            )
        }
        showTooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tooltipDelay, execute: work)
    }

    private func cancelPendingTooltip() {
        showTooltipWork?.cancel()
        showTooltipWork = nil
    }

    /// 命中某视图坐标下的点位（按自然日格命中）：今日格给真实点，已结束的天给历史点。
    func pacePoint(at location: NSPoint) -> WeeklyPaceSnapshot.PacePoint? {
        guard let snapshot else { return nil }
        let rect = plotRect
        guard rect.contains(location) else { return nil }
        let fraction = Double((location.x - rect.minX) / rect.width)
        guard let cell = snapshot.cells.first(where: { fraction >= $0.xStart && fraction < $0.xEnd })
            ?? snapshot.cells.last else { return nil }
        if cell.isToday, let todayPoint = snapshot.todayPoint {
            return todayPoint
        }
        return snapshot.historyPoints.first { $0.day == cell.day }
    }

    /// 提示浮层的锚点：点位上方，换算到屏幕坐标。
    private func screenAnchor(for point: WeeklyPaceSnapshot.PacePoint) -> NSPoint {
        let anchor = NSPoint(x: plotX(point.x), y: plotY(point.drawPercent) + 4)
        let converted = convert(anchor, to: nil)
        guard let window else { return converted }
        return window.convertToScreen(NSRect(origin: converted, size: .zero)).origin
    }
}
