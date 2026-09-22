import AppKit
import Foundation

// MARK: - DeepSeek 面板（tabs.html 定稿：两指标卡 + 近 30 天消费图）

/// DeepSeek 区块：slim 头部 + 指标卡（充值 / 累计消费）+ 每日消费柱状图。
/// 余额无「剩余/总量」口径，不显示百分比，tab 进度环为空环 + 金额文字。
final class DeepSeekPanelSection: NSView {
    var onRefresh: (() -> Void)?
    var onRefreshAvailabilityChange: (() -> Void)?
    var onContentHeightChange: (() -> Void)?

    var canRequestRefresh: Bool { header.canRequestRefresh }
    func requestRefresh() {
        guard let onRefresh, header.beginRefreshCooldown() else { return }
        onRefresh()
    }

    let header = ProviderHeaderView()
    private let profileHint = NSTextField(labelWithString: "")
    private let metricsRow = NSStackView()
    private let rechargeCard = MetricCardView()
    private let totalCostCard = MetricCardView()
    private let costChart = DeepSeekCostChartView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        header.configure(.init(statusText: "等待刷新", statusKind: .idle))
        header.onRefreshAvailabilityChange = { [weak self] in self?.onRefreshAvailabilityChange?() }

        profileHint.font = .systemFont(ofSize: 9, weight: .regular)
        profileHint.textColor = PanelTheme.tertiaryText
        profileHint.isHidden = true

        metricsRow.orientation = .horizontal
        metricsRow.alignment = .top
        metricsRow.spacing = 7
        metricsRow.distribution = .fillEqually
        metricsRow.translatesAutoresizingMaskIntoConstraints = false
        metricsRow.addArrangedSubview(rechargeCard)
        metricsRow.addArrangedSubview(totalCostCard)

        costChart.onContentHeightChange = { [weak self] in self?.onContentHeightChange?() }

        let stack = NSStackView(views: [header, profileHint, metricsRow, costChart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            metricsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            costChart.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // 宽度钉常量与 Codex/ZAI 区块同款，避免宽度链自引用产生歧义解。
            stack.widthAnchor.constraint(equalToConstant: PanelTheme.contentWidth)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 状态填充语义与其他 provider 一致：失败保留旧快照，只换头部状态。
    func apply(snapshot: DeepSeekSnapshot?, isRefreshing: Bool, error: String?, profileCount: Int) {
        header.setRefreshing(isRefreshing)

        var state = ProviderHeaderView.State(statusText: "", statusKind: .idle)
        if isRefreshing {
            state.statusText = snapshot != nil ? "刷新中…" : "正在读取…"
        } else if error != nil {
            state.statusText = "刷新失败"
            state.statusKind = .bad
        } else if let snapshot {
            state.statusText = PanelTheme.formatRefreshTime(snapshot.fetchedAt)
            state.statusKind = .ok
        } else {
            state.statusText = "暂无数据"
        }
        if let error, !isRefreshing {
            state.errorText = error
            state.errorTooltip = ProviderPanelSection.errorTooltip(error: error, fetchedAt: snapshot?.fetchedAt)
        }
        header.configure(state)

        if let snapshot {
            configureCards(snapshot)
            costChart.configure(days: snapshot.usage.days, currency: snapshot.usage.currency)
            if profileCount > 1 {
                profileHint.stringValue = "已使用 Chrome Profile「\(snapshot.profileName)」（检测到 \(profileCount) 个登录态）"
                profileHint.isHidden = false
            } else {
                profileHint.isHidden = true
            }
        } else {
            rechargeCard.configure(label: "充值金额", valueText: nil, tooltip: nil)
            totalCostCard.configure(label: "累计消费金额", valueText: nil, tooltip: nil)
            costChart.configure(days: nil, currency: nil)
            profileHint.isHidden = true
        }
    }

    private func configureCards(_ snapshot: DeepSeekSnapshot) {
        if let balance = snapshot.primaryBalance {
            let balanceSymbol = DeepSeekSnapshot.currencySymbol(balance.currency)
            let normal = snapshot.wallets.filter { $0.kind == .normal && $0.currency == balance.currency }
                .reduce(0.0) { $0 + $1.balance }
            let bonus = snapshot.wallets.filter { $0.kind == .bonus && $0.currency == balance.currency }
                .reduce(0.0) { $0 + $1.balance }
            let estimation = snapshot.wallets
                .filter { $0.currency == balance.currency }
                .compactMap(\.tokenEstimation)
                .reduce(0.0, +)
            var tooltip = "可用余额（充值 + 赠送）：\(balanceSymbol)\(String(format: "%.2f", balance.amount))"
            tooltip += "\n充值 \(balanceSymbol)\(String(format: "%.2f", normal)) · 赠送 \(balanceSymbol)\(String(format: "%.2f", bonus))"
            if estimation > 0 {
                tooltip += "\n平台估算可用 \(PanelTheme.formatTokenCount(estimation)) tokens"
            }
            rechargeCard.configure(
                label: "充值金额",
                valueText: "\(balanceSymbol)\(String(format: "%.2f", balance.amount))",
                unit: balance.currency,
                tooltip: tooltip
            )
        } else {
            rechargeCard.configure(label: "充值金额", valueText: nil, tooltip: nil)
        }

        let costsByCurrency = Dictionary(uniqueKeysWithValues: snapshot.totalCosts.map { ($0.currency, $0.amount) })
        let costCurrency = costsByCurrency[snapshot.usage.currency] != nil
            ? snapshot.usage.currency
            : (DeepSeekSnapshot.pickCurrency(costsByCurrency.filter { $0.value > 0 }) ?? snapshot.usage.currency)
        if let amount = costsByCurrency[costCurrency] {
            let costSymbol = DeepSeekSnapshot.currencySymbol(costCurrency)
            var tooltip = "累计消费（\(costCurrency)）：\(costSymbol)\(String(format: "%.2f", amount))"
            for cost in snapshot.totalCosts.sorted(by: { $0.currency < $1.currency })
            where cost.currency != costCurrency {
                tooltip += "\n\(cost.currency)：\(DeepSeekSnapshot.currencySymbol(cost.currency))\(String(format: "%.2f", cost.amount))"
            }
            totalCostCard.configure(
                label: "累计消费金额",
                valueText: "\(costSymbol)\(String(format: "%.2f", amount))",
                unit: costCurrency,
                tooltip: tooltip
            )
        } else {
            totalCostCard.configure(label: "累计消费金额", valueText: nil, tooltip: nil)
        }
    }
}

// MARK: - 指标卡（大数值 + 小标签 + 币种单位）

private final class MetricCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor

        titleLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        titleLabel.textColor = PanelTheme.secondaryText

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        valueLabel.textColor = PanelTheme.primaryText
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        unitLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        unitLabel.textColor = PanelTheme.tertiaryText

        let valueLine = NSStackView(views: [valueLabel, unitLabel])
        valueLine.orientation = .horizontal
        valueLine.alignment = .lastBaseline
        valueLine.spacing = 3

        let stack = NSStackView(views: [titleLabel, valueLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(label: String, valueText: String?, unit: String? = nil, tooltip: String?) {
        titleLabel.stringValue = label
        valueLabel.stringValue = valueText ?? "--"
        valueLabel.textColor = valueText == nil ? PanelTheme.tertiaryText : PanelTheme.primaryText
        unitLabel.stringValue = unit ?? ""
        unitLabel.isHidden = unit == nil || valueText == nil
        toolTip = tooltip
    }
}

// MARK: - 近 30 天消费柱状图（金额口径，视觉与 DailyUsageChartView 同语言）

final class DeepSeekCostChartView: NSView {
    var onContentHeightChange: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "近 30 天消费")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let barsView = DeepSeekCostBarsView()
    private let emptyLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 8.5, weight: .bold)
        titleLabel.textColor = PanelTheme.tertiaryText

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        summaryLabel.textColor = PanelTheme.green

        emptyLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        emptyLabel.textColor = PanelTheme.tertiaryText
        emptyLabel.stringValue = "暂无用量记录"
        emptyLabel.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let head = NSStackView(views: [titleLabel, spacer, summaryLabel])
        head.orientation = .horizontal
        head.alignment = .lastBaseline
        head.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [head, barsView, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barsView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: stack.centerXAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(days: [DeepSeekDailyUsage]?, currency: String?) {
        let hasData = (days?.contains { $0.amount > 0 || $0.tokens > 0 || $0.requests > 0 }) == true
        barsView.configure(days: days,
                           currencySymbol: DeepSeekSnapshot.currencySymbol(currency ?? "CNY"))
        emptyLabel.isHidden = hasData
        barsView.isHidden = !hasData

        if let days, let currency, hasData {
            let totalAmount = days.reduce(0.0) { $0 + $1.amount }
            let totalTokens = days.reduce(0.0) { $0 + $1.tokens }
            let symbol = DeepSeekSnapshot.currencySymbol(currency)
            summaryLabel.stringValue = "消费金额：\(symbol)\(String(format: "%.2f", totalAmount))"
                + " · Tokens：\(PanelTheme.formatTokenCount(totalTokens))"
        } else {
            summaryLabel.stringValue = ""
        }
    }
}

/// 柱区：30 根金额柱 + 均值虚线 + 周刻度 + 今日高亮 + 悬浮气泡。
private final class DeepSeekCostBarsView: NSView {
    private var days: [DeepSeekDailyUsage] = []
    private var hoveredIndex: Int?
    private var hoverCurrencySymbol = "¥"
    private let tooltip = ChartTooltipWindow()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(days: [DeepSeekDailyUsage]?, currencySymbol: String = "¥") {
        self.days = days ?? []
        hoverCurrencySymbol = currencySymbol
        hoveredIndex = nil
        needsDisplay = true
    }

    private var barLayout: ChartBarLayout {
        ChartBarLayout(count: days.count, availableWidth: bounds.width, gap: 2)
    }

    private func barRect(index: Int, barsBottom: CGFloat, heightPlaceholder: CGFloat) -> NSRect {
        NSRect(
            x: CGFloat(index) * barLayout.pitch,
            y: barsBottom,
            width: barLayout.barWidth,
            height: heightPlaceholder
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let layout = barLayout
        let maxValue = max(days.map(\.amount).max() ?? 0, 0.01)
        let barsHeight = bounds.height - 12
        let barsBottom = bounds.minY + 10

        for (index, day) in days.enumerated() {
            let barArea = barRect(index: index, barsBottom: barsBottom, heightPlaceholder: barsHeight)
            let fraction = CGFloat(day.amount / maxValue)
            let barHeight = max(day.amount > 0 ? 2 : 0, fraction * barsHeight)
            let barRect = NSRect(x: barArea.minX, y: barsBottom, width: barLayout.barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            let isToday = index == days.count - 1
            (isToday ? NSColor(hex: 0x6CF0AC) : PanelTheme.green).setFill()
            path.fill()
        }

        // 均值虚线 + 数值
        let nonZero = days.filter { $0.amount > 0 }
        if !nonZero.isEmpty {
            let average = nonZero.reduce(0.0) { $0 + $1.amount } / Double(nonZero.count)
            let y = barsBottom + CGFloat(average / maxValue) * barsHeight
            let dashes = NSBezierPath()
            dashes.move(to: NSPoint(x: 0, y: y))
            dashes.line(to: NSPoint(x: bounds.width, y: y))
            dashes.setLineDash([3, 2.5], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            dashes.lineWidth = 1
            dashes.stroke()

            let text = "\(String(format: "%.2f", average))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: PanelTheme.tertiaryText
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.width - textSize.width - 2, y: y + 1.5),
                      withAttributes: attributes)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !days.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = barLayout.index(at: point.x)
        hoveredIndex = index
        needsDisplay = true
        guard let index, index < days.count else {
            tooltip.hide()
            return
        }
        let day = days[index]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let isToday = index == days.count - 1
        let dateText = formatter.string(from: day.date) + (isToday ? " 今天" : "")
        let amountText = "\(hoverCurrencySymbol)\(String(format: "%.2f", day.amount))"
        tooltip.present(
            lines: [dateText, amountText],
            detail: "Tokens \(PanelTheme.formatTokenCount(day.tokens)) · 请求 \(Int(day.requests)) 次",
            anchor: NSPoint(x: point.x, y: convert(bounds, to: nil).maxY + 6),
            hostWindow: window
        )
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
        tooltip.hide()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                owner: self
            ))
        }
    }
}
