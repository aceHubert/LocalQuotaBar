import AppKit
import Foundation

// MARK: - 近 30 天每日用量图

/// 单日用量。date 为本地时区当天零点。
struct DayUsage: Equatable {
    let date: Date
    let tokens: Double
}

/// 30 根柱子的水平布局：等宽、等间距，按 x 坐标反查柱子序号。
struct ChartBarLayout: Equatable {
    let count: Int
    let barWidth: CGFloat
    let pitch: CGFloat

    init(count: Int, availableWidth: CGFloat, gap: CGFloat) {
        self.count = max(count, 0)
        let divisor = max(self.count, 1)
        barWidth = max(1.5, (availableWidth - gap * CGFloat(max(self.count - 1, 0))) / CGFloat(divisor))
        pitch = barWidth + gap
    }

    /// x 为相对绘制区左侧的偏移；落在柱子区域外（右侧空白）时返回 nil。
    func index(at x: CGFloat) -> Int? {
        guard count > 0, x >= 0 else { return nil }
        let index = Int(x / pitch)
        return (0..<count).contains(index) ? index : nil
    }
}

/// 30 根细柱 + 日均值 + 周刻度 + 今日高亮；hover 显示某天明细。
/// Z.AI 实例传入渠道拆分数据后支持「总量 / 叠加」两种显示：叠加模式下柱子
/// 下段为套餐（服务端 model-usage，全设备，绿），上段为本机非套餐渠道（橙），
/// 两段不重叠、总计即账号全部消耗；Codex 实例维持总量单色。
enum UsageDisplayMode: String {
    case total
    case stacked
}

final class DailyUsageChartView: NSView {
    /// 高度变化（图例行显隐、显示方式切换），宿主刷新 popover contentSize。
    var onContentHeightChange: (() -> Void)?

    private var days: [DayUsage] = []
    /// 与 days 按日期对齐的套餐（服务端）用量；nil = 不支持叠加（Codex 实例）。
    private var channelTokensByDay: [Date: Double]?
    private var hasData = false

    /// 偏好持久化入口；默认 .standard，单测可注入独立 suite。
    var storage: UserDefaults = .standard
    private(set) var displayMode: UsageDisplayMode
    private var hasLoadedDisplayMode = false

    private let titleHeight: CGFloat = 14
    private let barsHeight: CGFloat = 30
    private let legendHeight: CGFloat = 10
    private let ticksHeight: CGFloat = 11
    private let barGap: CGFloat = 2
    private let inset: CGFloat = 8
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        displayMode = .stacked
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        // 初始按无图例高度；configure 后按数据显示方式同步
        heightConstraint = heightAnchor.constraint(
            equalToConstant: 6 + titleHeight + 4 + barsHeight + 3 + ticksHeight + 5
        )
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let displayModeStorageKey = "local.codex.touchbar.quota.zaiUsageDisplayMode"

    /// days 需按日期升序、包含完整 30 天（无数据的天 tokens = 0）。
    /// channelDays 与 days 同日对齐；非 nil 即启用叠加显示与模式切换。
    func configure(days: [DayUsage]?, channelDays: [DayUsage]? = nil) {
        if !hasLoadedDisplayMode {
            hasLoadedDisplayMode = true
            if let raw = storage.string(forKey: Self.displayModeStorageKey),
               let mode = UsageDisplayMode(rawValue: raw) {
                displayMode = mode
            }
        }
        self.days = days ?? []
        channelTokensByDay = channelDays.map { entries in
            Dictionary(entries.map { ($0.date, $0.tokens) }, uniquingKeysWith: { _, last in last })
        }
        hasData = !(days ?? []).isEmpty
        syncLegendHeight()
        needsDisplay = true
        cancelPendingTooltip()
        tooltip.hide()
        hoveredIndex = nil
    }

    /// 切换显示方式并持久化；供图内切换点击与外部入口共用。
    func setDisplayMode(_ mode: UsageDisplayMode) {
        guard mode != displayMode else { return }
        displayMode = mode
        storage.set(mode.rawValue, forKey: Self.displayModeStorageKey)
        syncLegendHeight()
        needsDisplay = true
    }

    private var supportsStacking: Bool { channelTokensByDay != nil }

    /// 图例只在叠加模式且有数据时占一行高度。
    private var showsLegend: Bool { supportsStacking && displayMode == .stacked && hasData }

    private func syncLegendHeight() {
        let constant: CGFloat = 6 + titleHeight + 4 + barsHeight + 3 + ticksHeight + 5 + (showsLegend ? legendHeight : 0)
        guard heightConstraint.constant != constant else { return }
        heightConstraint.constant = constant
        onContentHeightChange?()
    }

    var barsRect: NSRect {
        NSRect(
            x: inset,
            y: bounds.height - 6 - titleHeight - 4 - barsHeight,
            width: bounds.width - inset * 2,
            height: barsHeight
        )
    }

    private var averageTokens: Double {
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.tokens } / Double(days.count)
    }

    private var barLayout: ChartBarLayout {
        ChartBarLayout(count: days.count, availableWidth: barsRect.width, gap: barGap)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawHeader()
        guard hasData else {
            drawEmptyState()
            return
        }
        drawBars()
        drawAverageLine()
        drawLegend()
        drawTicks()
    }

    private func drawHeader() {
        let title = NSAttributedString(string: "近 30 天用量", attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: PanelTheme.tertiaryText
        ])
        title.draw(at: NSPoint(x: inset + 1, y: bounds.height - 6 - titleHeight + 2))

        if hasData {
            let avg = NSAttributedString(
                string: "日均 \(PanelTheme.formatTokenCount(averageTokens))",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: PanelTheme.green
                ]
            )
            let size = avg.size()
            // 宽度不够容纳"标题 + 切换 + 日均"时跳过日均，避免文字互相压盖
            let fits = title.size().width + size.width + 10 <= bounds.width - inset * 2
            let avgX: CGFloat
            if fits {
                avgX = bounds.width - inset - 1 - size.width
                avg.draw(at: NSPoint(x: avgX, y: bounds.height - 6 - titleHeight + 2))
            } else {
                avgX = bounds.width - inset - 1
            }
            if supportsStacking {
                drawModeChips(rightX: avgX - 6)
            }
        }
    }

    // MARK: 显示方式切换（总量 / 叠加）

    private var chipRects: [(rect: NSRect, mode: UsageDisplayMode)] = []

    /// 图卡头部的模式切换胶囊（对齐原型 mode-chips）；rect 供 mouseDown 命中。
    private func drawModeChips(rightX: CGFloat) {
        chipRects = []
        let y = bounds.height - 6 - titleHeight + 1
        var cursor = rightX
        for mode in [UsageDisplayMode.total, .stacked].reversed() {
            let text = NSAttributedString(string: mode == .total ? "总量" : "叠加", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: mode == displayMode ? PanelTheme.primaryText : PanelTheme.tertiaryText
            ])
            let textSize = text.size()
            let width = textSize.width + 12
            cursor -= width
            let rect = NSRect(x: cursor, y: y, width: width, height: 11)
            chipRects.append((rect, mode))

            let active = mode == displayMode
            let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            if active {
                NSColor.white.withAlphaComponent(0.08).setFill()
                pill.fill()
            }
            pill.lineWidth = 1
            NSColor.white.withAlphaComponent(active ? 0.24 : 0.10).setStroke()
            pill.stroke()
            text.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + (rect.height - textSize.height) / 2))

            cursor -= 3
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard supportsStacking else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        for chip in chipRects where chip.rect.contains(location) {
            setDisplayMode(chip.mode)
            return
        }
        super.mouseDown(with: event)
    }

    private func drawEmptyState() {
        let text = NSAttributedString(string: "暂无用量记录", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: PanelTheme.tertiaryText
        ])
        let size = text.size()
        text.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: barsRect.midY - size.height / 2
        ))
    }

    private var showsStackedBars: Bool {
        supportsStacking && displayMode == .stacked && hasData
    }

    private func drawBars() {
        let rect = barsRect
        let layout = barLayout
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        let today = Calendar.current.startOfDay(for: Date())

        for (index, day) in days.enumerated() {
            let x = rect.minX + CGFloat(index) * layout.pitch
            let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
            let hovered = index == hoveredIndex

            guard showsStackedBars, day.tokens > 0 else {
                drawSingleBar(x: x, day: day, layout: layout, rect: rect,
                              maxTokens: maxTokens, isToday: isToday, hovered: hovered)
                continue
            }

            // 叠加：下段套餐（服务端、全设备，绿），上段本机非套餐渠道（橙）。
            // 两段不重叠，柱高 = 总计（账号全部消耗），总量/叠加模式可直观对照。
            let channelTokens = min(channelTokensByDay?[day.date] ?? 0, day.tokens)
            let totalHeight = max(2, rect.height * CGFloat(day.tokens / maxTokens))
            let channelHeight = max(channelTokens > 0 ? 1.5 : 0, rect.height * CGFloat(channelTokens / maxTokens))
            let otherHeight = totalHeight - channelHeight

            let channelColor = segmentColor(base: PanelTheme.green, isToday: isToday, hovered: hovered)
            let otherColor = segmentColor(base: PanelTheme.orange, isToday: isToday, hovered: hovered)

            // 整柱一个圆角胶囊，按上下区域裁剪出两段配色（原型 bar / bar-third 的观感）
            let fullBar = NSRect(x: x, y: rect.minY, width: layout.barWidth, height: totalHeight)
            let pill = NSBezierPath(
                roundedRect: fullBar,
                xRadius: min(2, layout.barWidth / 2),
                yRadius: min(2, layout.barWidth / 2)
            )
            if otherHeight >= 1 {
                fillPill(pill, color: otherColor, clip: NSRect(
                    x: x - 1, y: fullBar.minY + channelHeight - 0.5,
                    width: layout.barWidth + 2, height: otherHeight + 1
                ))
                fillPill(pill, color: channelColor, clip: NSRect(
                    x: x - 1, y: fullBar.minY - 1,
                    width: layout.barWidth + 2, height: channelHeight + 0.5 + 1
                ))
            } else {
                fillPill(pill, color: channelColor, clip: fullBar.insetBy(dx: -1, dy: -1))
            }
        }
    }

    /// 在指定裁剪区域内填充胶囊路径（叠加柱的两段着色）。
    private func fillPill(_ pill: NSBezierPath, color: NSColor, clip: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        color.setFill()
        pill.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// 总量模式（或无数据天）的单段柱，维持原有配色行为。
    private func drawSingleBar(x: CGFloat, day: DayUsage, layout: ChartBarLayout, rect: NSRect,
                               maxTokens: Double, isToday: Bool, hovered: Bool) {
        let barHeight = max(day.tokens > 0 ? 2 : 1, rect.height * CGFloat(day.tokens / maxTokens))
        let barRect = NSRect(x: x, y: rect.minY, width: layout.barWidth, height: barHeight)
        let path = NSBezierPath(
            roundedRect: barRect,
            xRadius: min(2, layout.barWidth / 2),
            yRadius: min(2, layout.barWidth / 2)
        )

        if hovered {
            // 悬停的柱子更亮，与即时浮层提示对应
            (PanelTheme.green.highlight(withLevel: 0.4) ?? PanelTheme.green).setFill()
        } else if isToday {
            // 今日高亮（更亮 + 轻微光晕感）
            (PanelTheme.green.highlight(withLevel: 0.25) ?? PanelTheme.green).setFill()
        } else if day.tokens > 0 {
            // 有数据的天数用不透明绿，深底上保证清晰可读
            PanelTheme.green.setFill()
        } else {
            NSColor.white.withAlphaComponent(0.06).setFill()
        }
        path.fill()
    }

    private func segmentColor(base: NSColor, isToday: Bool, hovered: Bool) -> NSColor {
        if hovered { return base.highlight(withLevel: 0.4) ?? base }
        if isToday { return base.highlight(withLevel: 0.25) ?? base }
        return base
    }

    /// 叠加模式图例行："■ 套餐（服务端） / ■ 第三方（本机）"；总量模式隐藏。
    /// 位于日期刻度行之下（卡片最后一行）。
    private func drawLegend() {
        guard showsLegend else { return }
        let y = barsRect.minY - ticksHeight + 1 - legendHeight - 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: PanelTheme.tertiaryText
        ]
        var x = inset + 1
        for (color, text) in [(PanelTheme.green, "套餐（服务端）"), (PanelTheme.orange, "第三方（本机）")] {
            let square = NSBezierPath(
                roundedRect: NSRect(x: x, y: y + 1.5, width: 4.5, height: 4.5),
                xRadius: 1.5, yRadius: 1.5
            )
            color.setFill()
            square.fill()
            x += 7
            let attributed = NSAttributedString(string: text, attributes: attributes)
            attributed.draw(at: NSPoint(x: x, y: y))
            x += attributed.size().width + 12
        }
    }

    private func drawAverageLine() {
        let rect = barsRect
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        let y = rect.minY + rect.height * CGFloat(min(1, averageTokens / maxTokens))
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX, y: y))
        line.line(to: NSPoint(x: rect.maxX, y: y))
        line.lineWidth = 1
        line.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        line.stroke()
    }

    private func drawTicks() {
        let rect = barsRect
        let layout = barLayout
        let today = Calendar.current.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"

        for (index, day) in days.enumerated() {
            let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
            // 每 7 列一个日期刻度；最后一列若是今天则单独标"今"
            let isTick = index % 7 == 0
            guard isTick || isToday else { continue }
            // 倒数第二列的刻度会与末尾"今"字重叠，跳过
            if isTick && !isToday && index >= layout.count - 2 { continue }

            let text = isToday ? "今" : formatter.string(from: day.date)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: isToday ? PanelTheme.green : NSColor(hex: 0x56565C)
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let size = attributed.size()
            let centerX = rect.minX + CGFloat(index) * layout.pitch + layout.barWidth / 2
            attributed.draw(at: NSPoint(
                x: min(max(centerX - size.width / 2, rect.minX), rect.maxX - size.width),
                y: rect.minY - ticksHeight + 1
            ))
        }
    }

    // MARK: hover 提示

    /// 系统 NSView.toolTip 有约 1 秒固定延迟且要求光标静止；柱状图每根柱子只有约
    /// 7pt 宽，轻微移动就重新计时，导致提示要好几秒才出现。这里改用自绘浮层即时显示。
    private var hoveredIndex: Int?
    private let tooltip = ChartTooltipWindow()
    private var showTooltipWork: DispatchWorkItem?
    private var windowWillCloseObserver: NSObjectProtocol?

    private static let tooltipDelay: TimeInterval = 0.18

    private var hoverRect: NSRect { barsRect.insetBy(dx: -4, dy: -4) }

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
        if hoveredIndex != nil {
            hoveredIndex = nil
            needsDisplay = true
        }
    }

    private func refreshHover(at location: NSPoint) {
        guard let index = hoveredBarIndex(at: location) else {
            cancelPendingTooltip()
            tooltip.hide()
            if hoveredIndex != nil {
                hoveredIndex = nil
                needsDisplay = true
            }
            return
        }
        if hoveredIndex != index {
            hoveredIndex = index
            needsDisplay = true
        }
        if tooltip.isShown {
            // 已显示时跟随柱子即时更新文字和位置，不再等待延迟
            tooltip.present(
                lines: tooltipLines(for: index),
                anchor: screenAnchor(for: index),
                hostWindow: window
            )
            return
        }
        cancelPendingTooltip()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.tooltip.present(
                lines: self.tooltipLines(for: index),
                anchor: self.screenAnchor(for: index),
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

    /// 命中的柱子序号；location 为视图内坐标，落在柱子区域外时返回 nil。
    func hoveredBarIndex(at location: NSPoint) -> Int? {
        guard hasData, !days.isEmpty else { return nil }
        let rect = barsRect
        guard rect.contains(location) else { return nil }
        return barLayout.index(at: location.x - rect.minX)
    }

    /// 悬停明细的分行规则：≤2 段保持单行；超过 2 段时日期单独一行、数值合并第二行。
    func tooltipLines(for index: Int) -> [String] {
        let day = days[index]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let date = formatter.string(from: day.date)
            + (Calendar.current.isDateInToday(day.date) ? "（今天）" : "")
        guard showsStackedBars, let channel = channelTokensByDay?[day.date] else {
            return ["\(date) · \(PanelTheme.formatTokenCount(day.tokens)) tokens"]
        }
        // 两段不重叠：总计 = 套餐（全设备）+ 本机非套餐渠道。
        let thirdParty = max(day.tokens - channel, 0)
        return [
            date,
            "套餐 \(PanelTheme.formatTokenCount(channel)) · 第三方 \(PanelTheme.formatTokenCount(thirdParty)) · 总计 \(PanelTheme.formatTokenCount(day.tokens))",
        ]
    }

    /// 单行形式（tooltipLines 以 " · " 连接），供测试断言。
    func tooltipText(for index: Int) -> String {
        tooltipLines(for: index).joined(separator: " · ")
    }

    /// 提示浮层的锚点：悬停柱子的顶部中心，换算到屏幕坐标。
    private func screenAnchor(for index: Int) -> NSPoint {
        let rect = barsRect
        let layout = barLayout
        let centerX = rect.minX + CGFloat(index) * layout.pitch + layout.barWidth / 2
        let point = convert(NSPoint(x: centerX, y: rect.maxY + 3), to: nil)
        guard let window else { return point }
        return window.convertToScreen(NSRect(origin: point, size: .zero)).origin
    }
}

// MARK: - 悬停浮层

/// 轻量提示窗口：不抢焦点、不拦截鼠标，层级高于 popover，悬停即时出现。
/// 主行 + 可选尾注行（配速图标注估算口径）。
final class ChartTooltipWindow {
    private let panel: NSPanel
    private let label: NSTextField
    private let detailLabel = NSTextField(labelWithString: "")
    private(set) var isShown = false

    init() {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white

        detailLabel.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        detailLabel.textColor = PanelTheme.secondaryText

        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        container.addSubview(label)
        container.addSubview(detailLabel)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.contentView = container
    }

    func present(text: String, detail: String? = nil, anchor: NSPoint, hostWindow: NSWindow?) {
        present(lines: [text], detail: detail, anchor: anchor, hostWindow: hostWindow)
    }

    /// 多行形式：主行逐行排布（日期/数值分行），detail 作为末尾的弱化尾注行。
    func present(lines: [String], detail: String? = nil, anchor: NSPoint, hostWindow: NSWindow?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let combined = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { combined.append(NSAttributedString(string: "\n", attributes: attributes)) }
            combined.append(NSAttributedString(string: line, attributes: attributes))
        }
        label.attributedStringValue = combined
        label.sizeToFit()

        let showsDetail = detail?.isEmpty == false
        detailLabel.isHidden = !showsDetail
        if let detail {
            detailLabel.stringValue = detail
            detailLabel.sizeToFit()
        }

        let textSize = label.bounds.size
        let detailSize = showsDetail ? detailLabel.bounds.size : .zero
        let size = NSSize(
            width: ceil(max(textSize.width, detailSize.width)) + 16,
            height: ceil(textSize.height) + (showsDetail ? ceil(detailSize.height) + 4 : 0) + 10
        )
        label.frame = NSRect(
            x: 8,
            y: size.height - 5 - textSize.height,
            width: textSize.width,
            height: textSize.height
        )
        if showsDetail {
            detailLabel.frame = NSRect(x: 8, y: 5, width: detailSize.width, height: detailSize.height)
        }

        // 始终盖在宿主窗口（NSPopover）之上
        panel.level = NSWindow.Level(rawValue: (hostWindow?.level.rawValue ?? NSWindow.Level.normal.rawValue) + 1)

        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let frame = hostWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            if origin.y + size.height > frame.maxY - 4 {
                origin.y = frame.maxY - size.height - 4
            }
        }

        isShown = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
    }
}
