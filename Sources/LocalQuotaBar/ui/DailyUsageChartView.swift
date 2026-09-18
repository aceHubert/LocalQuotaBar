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
final class DailyUsageChartView: NSView {
    private var days: [DayUsage] = []
    private var hasData = false

    private let titleHeight: CGFloat = 14
    private let barsHeight: CGFloat = 30
    private let ticksHeight: CGFloat = 11
    private let barGap: CGFloat = 2
    private let inset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 6 + titleHeight + 4 + barsHeight + 3 + ticksHeight + 5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// days 需按日期升序、包含完整 30 天（无数据的天 tokens = 0）。
    func configure(days: [DayUsage]?) {
        self.days = days ?? []
        hasData = !(days ?? []).isEmpty
        needsDisplay = true
        cancelPendingTooltip()
        tooltip.hide()
        hoveredIndex = nil
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
            // 宽度不够容纳"标题 + 日均"时跳过日均，避免文字互相压盖
            guard title.size().width + size.width + 10 <= bounds.width - inset * 2 else { return }
            avg.draw(at: NSPoint(x: bounds.width - inset - 1 - size.width, y: bounds.height - 6 - titleHeight + 2))
        }
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

    private func drawBars() {
        let rect = barsRect
        let layout = barLayout
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        let today = Calendar.current.startOfDay(for: Date())

        for (index, day) in days.enumerated() {
            let x = rect.minX + CGFloat(index) * layout.pitch
            let ratio = day.tokens / maxTokens
            let barHeight = max(day.tokens > 0 ? 2 : 1, rect.height * CGFloat(ratio))
            let barRect = NSRect(x: x, y: rect.minY, width: layout.barWidth, height: barHeight)
            let path = NSBezierPath(
                roundedRect: barRect,
                xRadius: min(2, layout.barWidth / 2),
                yRadius: min(2, layout.barWidth / 2)
            )

            let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
            if index == hoveredIndex {
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
                text: tooltipText(for: index),
                anchor: screenAnchor(for: index),
                hostWindow: window
            )
            return
        }
        cancelPendingTooltip()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.tooltip.present(
                text: self.tooltipText(for: index),
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

    /// 悬停浮层上显示的明细文案。
    func tooltipText(for index: Int) -> String {
        let day = days[index]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let suffix = Calendar.current.isDateInToday(day.date) ? "（今天）" : ""
        return "\(formatter.string(from: day.date))\(suffix) · \(PanelTheme.formatTokenCount(day.tokens)) tokens"
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
private final class ChartTooltipWindow {
    private let panel: NSPanel
    private let label: NSTextField
    private(set) var isShown = false

    init() {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white

        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        container.addSubview(label)

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

    func present(text: String, anchor: NSPoint, hostWindow: NSWindow?) {
        label.stringValue = text
        label.sizeToFit()
        let textSize = label.bounds.size
        let size = NSSize(
            width: ceil(textSize.width) + 16,
            height: ceil(textSize.height) + 10
        )
        label.frame = NSRect(
            x: 8,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

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
