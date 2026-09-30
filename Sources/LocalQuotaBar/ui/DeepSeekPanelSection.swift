import AppKit
import Foundation

// MARK: - DeepSeek 面板（tabs.html 定稿 + 平台页三卡口径：充值余额 / 累计消费金额 / 赠送余额）

/// DeepSeek 区块：slim 头部 + 指标卡（充值余额 / 累计消费金额 / 赠送余额）+ 每日消费柱状图。
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
    let profileHint = NSTextField(labelWithString: "")
    let metricsRow = NSStackView()
    let rechargeCard = MetricCardView()
    let totalCostCard = MetricCardView()
    let bonusCard = MetricCardView()
    let costChart = DeepSeekCostChartView()

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
        // 顺序对齐平台页：充值余额 | 累计消费金额 | 赠送余额
        metricsRow.addArrangedSubview(rechargeCard)
        metricsRow.addArrangedSubview(totalCostCard)
        metricsRow.addArrangedSubview(bonusCard)

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

        // 首次成功前（含首刷中 / 首刷失败）没有任何历史数据：只显示头部状态，不渲染内容区占位
        guard let snapshot else {
            metricsRow.isHidden = true
            costChart.isHidden = true
            profileHint.isHidden = true
            return
        }
        metricsRow.isHidden = false
        costChart.isHidden = false
        configureCards(snapshot)
        costChart.configure(days: snapshot.usage.days, currency: snapshot.usage.currency)
        if profileCount > 1 {
            profileHint.stringValue = "已使用 Chrome Profile「\(snapshot.profileName)」（检测到 \(profileCount) 个登录态）"
            profileHint.isHidden = false
        } else {
            profileHint.isHidden = true
        }
    }

    private func configureCards(_ snapshot: DeepSeekSnapshot) {
        // 充值 / 赠送分开成两张卡（对齐平台页）：合计只在 tooltip 里给，不再顶替充值余额
        if let balance = snapshot.primaryBalance {
            let currency = balance.currency
            let symbol = DeepSeekSnapshot.currencySymbol(currency)
            let normal = snapshot.balance(kind: .normal, currency: currency)
            let bonus = snapshot.balance(kind: .bonus, currency: currency)
            let estimation = snapshot.wallets
                .filter { $0.currency == currency }
                .compactMap(\.tokenEstimation)
                .reduce(0.0, +)

            var rechargeTooltip = "充值余额（\(currency)）：\(symbol)\(Self.amountText(normal))"
            rechargeTooltip += otherCurrenciesText(snapshot, kind: .normal, primary: currency)
            rechargeTooltip += "\n可用余额（充值 + 赠送）：\(symbol)\(Self.amountText(balance.amount))"
            if estimation > 0 {
                rechargeTooltip += "\n平台估算可用 \(PanelTheme.formatTokenCount(estimation)) tokens"
            }
            rechargeCard.configure(
                label: "充值余额",
                valueText: "\(symbol)\(Self.amountText(normal))",
                tooltip: rechargeTooltip
            )

            var bonusTooltip = "赠送余额（\(currency)）：\(symbol)\(Self.amountText(bonus))"
            bonusTooltip += otherCurrenciesText(snapshot, kind: .bonus, primary: currency)
            bonusCard.configure(
                label: "赠送余额",
                valueText: "\(symbol)\(Self.amountText(bonus))",
                tooltip: bonusTooltip
            )
        } else {
            rechargeCard.configure(label: "充值余额", valueText: nil, tooltip: nil)
            bonusCard.configure(label: "赠送余额", valueText: nil, tooltip: nil)
        }

        let costsByCurrency = Dictionary(uniqueKeysWithValues: snapshot.totalCosts.map { ($0.currency, $0.amount) })
        let costCurrency = costsByCurrency[snapshot.usage.currency] != nil
            ? snapshot.usage.currency
            : (DeepSeekSnapshot.pickCurrency(costsByCurrency.filter { $0.value > 0 }) ?? snapshot.usage.currency)
        if let amount = costsByCurrency[costCurrency] {
            let costSymbol = DeepSeekSnapshot.currencySymbol(costCurrency)
            var tooltip = "累计消费（\(costCurrency)）：\(costSymbol)\(Self.amountText(amount))"
            for cost in snapshot.totalCosts.sorted(by: { $0.currency < $1.currency })
            where cost.currency != costCurrency {
                tooltip += "\n\(cost.currency)：\(DeepSeekSnapshot.currencySymbol(cost.currency))\(Self.amountText(cost.amount))"
            }
            totalCostCard.configure(
                label: "累计消费金额",
                valueText: "\(costSymbol)\(Self.amountText(amount))",
                tooltip: tooltip
            )
        } else {
            totalCostCard.configure(label: "累计消费金额", valueText: nil, tooltip: nil)
        }
    }

    /// 非主币种的同类钱包余额（逐条列出，避免主币种口径把其他币种的钱藏起来）。
    private func otherCurrenciesText(
        _ snapshot: DeepSeekSnapshot,
        kind: DeepSeekWallet.Kind,
        primary: String
    ) -> String {
        var text = ""
        let others = snapshot.wallets
            .filter { $0.kind == kind && $0.currency != primary && $0.balance > 0 }
            .sorted { $0.currency < $1.currency }
        for wallet in others {
            text += "\n\(wallet.currency)：\(DeepSeekSnapshot.currencySymbol(wallet.currency))\(Self.amountText(wallet.balance))"
        }
        return text
    }

    /// 金额文案统一两位小数。
    private static func amountText(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}

// MARK: - 指标卡（大数值 + 小标签）

/// 三格等分时单格内容区仅约 70pt：数值只带币种符号（与 Codex 余额格同款），
/// 币种代码放 tooltip，字号 13pt 保证「¥1234.56」这类长金额不溢出。
final class MetricCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

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

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        valueLabel.textColor = PanelTheme.primaryText
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        let stack = NSStackView(views: [titleLabel, valueLabel])
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

    func configure(label: String, valueText: String?, tooltip: String?) {
        titleLabel.stringValue = label
        valueLabel.stringValue = valueText ?? "--"
        valueLabel.textColor = valueText == nil ? PanelTheme.tertiaryText : PanelTheme.primaryText
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

/// 柱区：30 根金额柱 + 均值虚线 + 日期刻度行 + 今日高亮 + 悬浮气泡。
/// 视觉与刻度规则对齐 DailyUsageChartView（每 7 列一个 M/d 刻度，今天绿色"今"）。
private final class DeepSeekCostBarsView: NSView {
    private var days: [DeepSeekDailyUsage] = []
    private var hoveredIndex: Int?
    private var hoverCurrencySymbol = "¥"
    private let tooltip = ChartTooltipWindow()
    private let ticksHeight: CGFloat = 10

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

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let layout = barLayout
        let maxValue = max(days.map(\.amount).max() ?? 0, 0.01)
        // 顶部留均值数值、底部留日期刻度行
        let barsBottom = bounds.minY + 10
        let barsHeight = bounds.height - 10 - ticksHeight

        for (index, day) in days.enumerated() {
            guard day.amount > 0 else { continue }
            let fraction = CGFloat(day.amount / maxValue)
            let barHeight = max(2, fraction * barsHeight)
            let barRect = NSRect(
                x: CGFloat(index) * layout.pitch,
                y: barsBottom,
                width: layout.barWidth,
                height: barHeight
            )
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            let isToday = index == days.count - 1
            let hovered = index == hoveredIndex
            // 设计稿同款垂直渐变 + 顶部高光（平涂亮绿深底上显灰薄）
            DailyUsageChartView.fillBarPath(path, barRect: barRect, isToday: isToday, hovered: hovered)
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

            let text = String(format: "%.2f", average) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: PanelTheme.tertiaryText
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.width - textSize.width - 2, y: y + 1.5),
                      withAttributes: attributes)
        }

        drawTicks(barsBottom: barsBottom)
    }

    /// 日期刻度：每 7 列一个 M/d；今天单独标绿色"今"；倒数第二列刻度与"今"重叠时跳过。
    private func drawTicks(barsBottom: CGFloat) {
        let layout = barLayout
        let today = Calendar.current.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        let tickY = barsBottom - ticksHeight + 1

        for (index, day) in days.enumerated() {
            let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
            let isTick = index % 7 == 0
            guard isTick || isToday else { continue }
            if isTick && !isToday && index >= layout.count - 2 { continue }

            let text = isToday ? "今" : formatter.string(from: day.date)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: isToday ? PanelTheme.green : NSColor(hex: 0x56565C)
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let size = attributed.size()
            let centerX = CGFloat(index) * layout.pitch + layout.barWidth / 2
            attributed.draw(at: NSPoint(
                x: min(max(centerX - size.width / 2, 0), bounds.width - size.width),
                y: tickY
            ))
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
        let dateText = formatter.string(from: day.date) + (isToday ? "（今天）" : "")
        // 锚点 = 悬停柱顶部中心，换算到屏幕坐标（浮层窗口使用屏幕坐标系）
        let centerX = CGFloat(index) * barLayout.pitch + barLayout.barWidth / 2
        let pointInWindow = convert(NSPoint(x: centerX, y: bounds.maxY + 3), to: nil)
        let anchor = window.map {
            $0.convertToScreen(NSRect(origin: pointInWindow, size: .zero)).origin
        } ?? pointInWindow
        tooltip.present(
            lines: [dateText, "\(hoverCurrencySymbol)\(String(format: "%.2f", day.amount))"],
            detail: "Tokens \(PanelTheme.formatTokenCount(day.tokens)) · 请求 \(Int(day.requests)) 次",
            anchor: anchor,
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
