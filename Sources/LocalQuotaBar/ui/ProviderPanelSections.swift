import AppKit
import Foundation

// MARK: - Provider 区块（Codex / Z.AI）

/// 单个 provider 的完整区块：头部 + 额度胶囊网格 + 重置卡 + 用量图 + 错误横幅。
/// 各 section 只做展示，数据填充语义与旧版 apply/applyZAI 保持一致。
final class ProviderPanelSection: NSView {
    var onRefresh: (() -> Void)?
    /// 内容高度变化（重置卡展开/收起），宿主刷新 popover contentSize。
    var onContentHeightChange: (() -> Void)?

    let header = ProviderHeaderView()
    let modeHintLabel = NSTextField(labelWithString: "")
    let grid = NSStackView()
    let resetCards = ResetCardsRow()
    let usageChart = DailyUsageChartView()
    let errorBanner = ErrorBannerView()

    init(monogram: String, name: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        header.configure(.init(
            title: name,
            monogram: monogram,
            subtitle: nil,
            tagText: nil,
            tagStyle: .plan,
            statusText: "等待刷新",
            statusKind: .idle
        ))
        header.onRefresh = { [weak self] in
            self?.requestRefresh()
        }

        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.distribution = .fillEqually

        resetCards.onContentHeightChange = { [weak self] in self?.onContentHeightChange?() }
        errorBanner.onRetry = { [weak self] in
            self?.retryFromError()
        }

        modeHintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        modeHintLabel.textColor = PanelTheme.tertiaryText
        modeHintLabel.isHidden = true

        let stack = NSStackView(views: [header, modeHintLabel, grid, resetCards, usageChart, errorBanner])
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
            resetCards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            usageChart.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorBanner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // 宽度钉常量：面板固定 322、内容 322-24。若只靠子视图互约束，
            // 宽度链自引用会产出歧义解（Codex 全宽 / ZAI 塌成 228pt 的随机表现）。
            stack.widthAnchor.constraint(equalToConstant: PanelTheme.contentWidth)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 单独刷新与全局刷新共用 60 秒冷却防重。
    func requestRefresh(allowUsageOnly: Bool = false) {
        guard let onRefresh, header.beginRefreshCooldown(allowUsageOnly: allowUsageOnly) else { return }
        onRefresh()
    }

    /// 错误横幅重试：就是再触发一次刷新，不受冷却限制；刷新开始后横幅清空、
    /// 头部进入"刷新中…"（store 同步回调），按钮随之隐藏不可连点。
    func retryFromError() {
        guard let onRefresh, header.canRetryRefresh else { return }
        onRefresh()
    }

    func setCells(_ cells: [NSView]) {
        grid.arrangedSubviews.forEach { grid.removeView($0) }
        guard !cells.isEmpty else { return }
        // 等分铺满：fillEqually 会扣除间距后均分，不可再叠 width×1/N 约束（会与间距冲突导致列重叠）
        cells.forEach { grid.addArrangedSubview($0) }
    }

    func setModeHint(_ text: String?) {
        modeHintLabel.stringValue = text ?? ""
        modeHintLabel.isHidden = text?.isEmpty != false
    }
}

/// Codex 区块：3 列（5小时 | 周限额 | 余额）。
final class CodexPanelSection: NSView {
    var onRefresh: (() -> Void)?
    var onResetCredit: ((String) -> Void)?
    var onContentHeightChange: (() -> Void)?
    var onRefreshAvailabilityChange: (() -> Void)?
    var canRequestRefresh: Bool { section.header.canRequestRefresh }

    func requestRefresh() { section.requestRefresh() }

    private let section = ProviderPanelSection(monogram: "Cx", name: "Codex")
    private let fiveHourCell = QuotaCellView()
    private let weeklyCell = QuotaCellView()
    private let creditsCell = QuotaCellView()
    private var transientStatus: String?
    private var resetActions: [String: ResetCardsRow.ResetAction] = [:]

    func applyResetActions(_ actions: [String: ResetCardsRow.ResetAction]) {
        resetActions = actions
        section.resetCards.updateCardResetActions(actions)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        section.onRefresh = { [weak self] in self?.onRefresh?() }
        section.onContentHeightChange = { [weak self] in self?.onContentHeightChange?() }
        section.setCells([fiveHourCell, weeklyCell, creditsCell])
        section.resetCards.onReset = { [weak self] id in self?.onResetCredit?(id) }
        section.header.onRefreshAvailabilityChange = { [weak self] in self?.onRefreshAvailabilityChange?() }
        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(snapshot: QuotaSnapshot?, isRefreshing: Bool, error: String?, accountLabel: String?) {
        section.header.setRefreshing(isRefreshing)
        // 成功拿到新快照后清除临时状态（如"已切换账号，正在刷新…"）
        if !isRefreshing, error == nil, snapshot != nil {
            transientStatus = nil
        }

        // 额度格
        // 数据驱动的展示：RPC 返回哪个窗口就显示哪个；没有值的窗口一律 "--" 占位
        // （Codex plus 的 5h 由 chooseFiveHourWindow 从 rate_limits 里选，Z.AI 周限缺失同样走 "--"）
        if let bucket = snapshot?.fiveHour {
            fiveHourCell.configure(
                title: bucket.title,
                countdown: PanelTheme.formatCountdown(until: bucket.resetsAt),
                countdownSoon: isResetSoon(bucket.resetsAt),
                content: .percent(remaining: bucket.remainingPercent),
                tooltip: "\(bucket.title) · 剩余 \(bucket.roundedRemainingPercent)%"
            )
        } else {
            fiveHourCell.configure(
                title: QuotaKind.fiveHour.displayFallbackTitle,
                countdown: nil,
                content: .placeholder
            )
        }

        if let bucket = snapshot?.weekly {
            weeklyCell.configure(
                title: bucket.title,
                countdown: PanelTheme.formatCountdown(until: bucket.resetsAt),
                countdownSoon: isResetSoon(bucket.resetsAt),
                content: .percent(remaining: bucket.remainingPercent),
                tooltip: "\(bucket.title) · 剩余 \(bucket.roundedRemainingPercent)%"
            )
        } else {
            weeklyCell.configure(
                title: QuotaBucket.displayTitles(forDurationMins: 7 * 24 * 60).full,
                countdown: nil,
                content: .placeholder
            )
        }

        if let balance = snapshot?.creditBalance {
            creditsCell.configure(
                title: "余额",
                countdown: nil,
                content: .credits(text: String(format: "$%.2f", balance / 25)),
                tooltip: "额度余额 \(Int(balance.rounded())) 积分（$100 = 2500 积分），不参与低量提醒"
            )
        } else {
            creditsCell.configure(title: "余额", countdown: nil, content: .placeholder)
        }

        // 重置卡
        let cards = snapshot?.resetCreditCards ?? []
        let availableCount = snapshot?.resetCreditCount ?? cards.count
        if cards.isEmpty {
            section.resetCards.configure(chips: [])
        } else {
            let earliest = cards.compactMap(\.expiresAt).min()
            let soon = earliest.map { Date().distance(to: $0) < PanelTheme.cardExpiryWarningInterval } ?? false
            let chipTitle: String
            if let earliest {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M/d"
                chipTitle = "重置卡 ×\(availableCount) · 最早 \(formatter.string(from: earliest))"
            } else {
                chipTitle = "重置卡 ×\(availableCount)"
            }
            section.resetCards.configure(chips: [
                .init(
                    id: "codex",
                    title: chipTitle,
                    soon: soon,
                    cards: cards.enumerated().map { index, card in
                        let id = card.id ?? "codex-missing-id-\(index)"
                        return .init(
                            kindTitle: "重置卡", expiresAt: card.expiresAt, id: id,
                            resetAction: resetActions[id] ?? .init(
                                title: "重置", isEnabled: false, toolTip: "刷新当前账号额度后可用"
                            )
                        )
                    }
                )
            ])
        }

        // 头部状态
        var state = ProviderHeaderView.State(
            title: "Codex",
            monogram: "Cx",
            logoImage: PanelLogos.codex,
            subtitle: accountLabel,
            tagText: snapshot?.planType?.isEmpty == false ? snapshot?.planType : nil,
            tagStyle: .plan,
            statusText: "",
            statusKind: .idle
        )
        if let transientStatus {
            state.statusText = transientStatus
            state.statusKind = .idle
        } else if isRefreshing {
            state.statusText = snapshot != nil ? "刷新中…" : "正在读取…"
            state.statusKind = .idle
        } else if error != nil {
            state.statusText = "刷新失败"
            state.statusKind = .bad
        } else if let snapshot {
            state.statusText = PanelTheme.formatRefreshTime(snapshot.fetchedAt)
            state.statusKind = .ok
        } else {
            state.statusText = "暂无数据"
            state.statusKind = .idle
        }
        section.header.configure(state)

        // 错误横幅
        if let error, !isRefreshing {
            if let fetchedAt = snapshot?.fetchedAt {
                section.errorBanner.configure(
                    title: "刷新失败，显示 \(PanelTheme.formatFetchedAt(fetchedAt)) 数据",
                    detail: error
                )
            } else {
                section.errorBanner.configure(title: "刷新失败", detail: error)
            }
        } else {
            section.errorBanner.hide()
        }
    }

    func applyUsage(days: [DayUsage]?) {
        section.usageChart.configure(days: days)
    }

    /// 临时状态（如"已切换账号，正在刷新…"），下一次 apply 成功后自然清除。
    func showTransientStatus(_ text: String) {
        transientStatus = text
    }

    private func isResetSoon(_ resetsAt: Date?) -> Bool {
        guard let resetsAt else { return false }
        return Date().distance(to: resetsAt) < PanelTheme.resetSoonThreshold
    }

}

/// Z.AI / BigModel 区块：coding-plan 2 列（5小时 | 周限额）；start-plan 按余额/待生效渲染。
final class ZAIPanelSection: NSView {
    var onRefresh: (() -> Void)?
    var onUseResetCard: ((ZAIResetCreditCard.Kind) -> Void)?
    var onContentHeightChange: (() -> Void)?
    var onRefreshAvailabilityChange: (() -> Void)?
    var canRequestRefresh: Bool { section.header.canRequestRefresh }

    // 全局刷新保留 API Key 模式的每日用量读取，单独余额按钮仍不可用。
    func requestRefresh() { section.requestRefresh(allowUsageOnly: true) }

    private let section = ProviderPanelSection(monogram: "Z", name: "Z.AI")
    private let firstCell = QuotaCellView()
    private let secondCell = QuotaCellView()
    private let resolveSelection: () -> ZAIProviderSelection?
    private var resetStates: [ZAIResetCreditCard.Kind: ZAIResetState] = [:]
    private var resetCards: [ZAIResetCreditCard] = []
    private var renderedResetIDs: Set<String> = []
    private var showsResetActions = false
    private var canUseResetCards = false
    private var canRetryReset = false
    private var resetUnavailableReason: String?
    private var quotaIsRefreshing = false

    init(resolveSelection: @escaping () -> ZAIProviderSelection? = ZAISettings.resolveProviderSelection) {
        self.resolveSelection = resolveSelection
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        section.onRefresh = { [weak self] in self?.onRefresh?() }
        section.onContentHeightChange = { [weak self] in self?.onContentHeightChange?() }
        section.setCells([firstCell, secondCell])
        section.resetCards.onReset = { [weak self] id in
            guard let self, let kind = Self.resetKind(for: id), self.resetAction(for: kind).isEnabled else { return }
            self.onUseResetCard?(kind)
        }
        section.header.onRefreshAvailabilityChange = { [weak self] in self?.onRefreshAvailabilityChange?() }
        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        snapshot: ZAIQuotaSnapshot?,
        account: ZAIAccount?,
        isRefreshing: Bool,
        error: String?,
        titleOverride: String?
    ) {
        // setting.json 是当前事实；快照可能还是切换账号/套餐前的旧缓存。
        quotaIsRefreshing = isRefreshing
        updateResetBusyState()
        let selection = resolveSelection()
        let kind = selection?.kind ?? snapshot?.kind ?? .codingPlan

        var tagStyle = PlanTagView.Style.plan
        var tagText: String?
        var cells: [QuotaCellView] = []
        var showsResetCards = false

        switch kind {
        case .apiKey:
            let suffix = snapshot?.apiKeySuffix.map { " ····\($0)" } ?? ""
            tagText = "API Key\(suffix)"
            tagStyle = .neutral
            showsResetCards = false

        case .startPlan:
            let planName = snapshot?.planName.flatMap { $0.isEmpty ? nil : $0 } ?? "体验套餐"
            tagText = planName
            let tooltipBase = snapshot?.planDescription.flatMap { $0.isEmpty ? nil : $0 }
                ?? snapshot?.planName.flatMap { $0.isEmpty ? nil : $0 }

            // 权益生效前 balances 为空、只返回 entitlements，从 pendingEntitlements 展示待生效额度
            let balances = Array((snapshot?.balances ?? []).prefix(2))
            let entitlements = snapshot?.pendingEntitlements ?? []
            for (index, cell) in [firstCell, secondCell].enumerated() {
                if index < balances.count {
                    let balance = balances[index]
                    cell.configure(
                        title: balance.title,
                        countdown: PanelTheme.formatCountdown(until: balance.expiresAt),
                        countdownSoon: isResetSoon(balance.expiresAt),
                        content: .percent(remaining: balance.remainingFraction * 100),
                        tooltip: startPlanBalanceTooltip(balance, planTooltip: tooltipBase)
                    )
                    cells.append(cell)
                } else if balances.isEmpty, index < entitlements.count {
                    let entitlement = entitlements[index]
                    cell.configure(
                        title: entitlement.title,
                        countdown: PanelTheme.formatCountdown(until: entitlement.expiresAt),
                        countdownSoon: false,
                        content: .pending(text: PanelTheme.formatTokenCount(entitlement.grantUnits)),
                        tooltip: startPlanPendingTooltip(entitlement)
                    )
                    cells.append(cell)
                }
            }
            showsResetCards = false

        case .codingPlan:
            tagText = snapshot?.level
            let limits = snapshot?.limits ?? []
            let units: [ZAILimit.WindowUnit] = [.hourly, .weekly]
            for (unit, cell) in zip(units, [firstCell, secondCell]) {
                if let limit = limits.first(where: { $0.unit == unit }) {
                    cell.configure(
                        title: limit.title,
                        countdown: PanelTheme.formatCountdown(until: limit.nextResetTime),
                        countdownSoon: isResetSoon(limit.nextResetTime),
                        content: .percent(remaining: limit.remainingPercent),
                        tooltip: "\(limit.title) · 剩余 \(limit.roundedRemainingPercent)%"
                    )
                } else {
                    cell.configure(
                        title: unit == .hourly ? "5小时" : "周限额",
                        countdown: nil,
                        content: .placeholder
                    )
                }
                cells.append(cell)
            }
            showsResetCards = true
        }

        section.grid.isHidden = cells.isEmpty
        for cell in [firstCell, secondCell] where !cells.contains(cell) {
            cell.isHidden = true
        }
        for cell in cells {
            cell.isHidden = false
        }

        showsResetActions = showsResetCards
        resetCards = snapshot?.resetCreditCards ?? []
        renderResetCards(rebuild: true)

        // 本机日用量是全渠道统计，不受 API Key 是否支持余额查询限制。
        section.usageChart.isHidden = false
        section.setModeHint(kind == .apiKey ? "API Key 模式，无余额功能" : nil)
        section.header.setRefreshAvailable(kind != .apiKey)

        // 头部状态
        let email = account?.email ?? snapshot?.email ?? ""
        var statusText = ""
        var statusKind = ProviderHeaderView.StatusKind.idle

        if kind == .apiKey {
            statusText = ""
        } else if isRefreshing {
            statusText = snapshot != nil ? "刷新中…" : "正在读取…"
        } else if error != nil {
            statusText = "刷新失败"
            statusKind = .bad
        } else if let snapshot, let pendingText = Self.startPlanPendingText(snapshot) {
            statusText = pendingText
        } else if let snapshot {
            statusText = PanelTheme.formatRefreshTime(snapshot.fetchedAt)
            statusKind = .ok
        } else {
            statusText = "暂无数据"
        }

        section.header.configure(.init(
            title: titleOverride ?? "Z.AI",
            monogram: "Z",
            logoImage: PanelLogos.zai,
            subtitle: email.isEmpty ? nil : email,
            tagText: tagText,
            tagStyle: tagStyle,
            statusText: statusText,
            statusKind: statusKind
        ))

        // 错误横幅
        if let error, !isRefreshing, kind != .apiKey {
            if let fetchedAt = snapshot?.fetchedAt {
                section.errorBanner.configure(
                    title: "刷新失败，显示 \(PanelTheme.formatFetchedAt(fetchedAt)) 数据",
                    detail: error
                )
            } else {
                section.errorBanner.configure(title: "刷新失败", detail: error)
            }
        } else {
            section.errorBanner.hide()
        }
    }

    func applyUsage(days: [DayUsage]?) {
        section.usageChart.configure(days: days)
    }

    private func isResetSoon(_ resetsAt: Date?) -> Bool {
        guard let resetsAt else { return false }
        return Date().distance(to: resetsAt) < PanelTheme.resetSoonThreshold
    }

    func applyResetState(
        _ states: [ZAIResetCreditCard.Kind: ZAIResetState],
        canUseCards: Bool,
        canRetry: Bool,
        unavailableReason: String?
    ) {
        resetStates = states
        canUseResetCards = canUseCards
        canRetryReset = canRetry
        resetUnavailableReason = unavailableReason
        updateResetBusyState()
        renderResetCards(rebuild: false)
    }

    private var resetIsSubmitting: Bool { resetStates.values.contains(.submitting) }

    private func updateResetBusyState() {
        section.header.setRefreshing(quotaIsRefreshing || resetIsSubmitting)
    }

    private static func resetKind(for id: String) -> ZAIResetCreditCard.Kind? {
        switch id {
        case "zai.fiveHour": return .fiveHour
        case "zai.week": return .week
        default: return nil
        }
    }

    private func resetAction(for kind: ZAIResetCreditCard.Kind) -> ResetCardsRow.ResetAction {
        let state = resetStates[kind] ?? .idle
        let blocked = quotaIsRefreshing || resetIsSubmitting
        switch state {
        case .submitting:
            return .init(title: "重置中…", isEnabled: false, toolTip: "正在确认重置结果")
        case .succeeded:
            return .init(title: "已重置", isEnabled: false, toolTip: "重置成功，等待新的额度和重置卡状态")
        case .failed(let message):
            return .init(title: "重试", isEnabled: canRetryReset && !blocked, toolTip: message)
        case .idle:
            let hasAvailableCard = resetCards.contains { $0.kind == kind && ($0.expiresAt.map { $0 > Date() } ?? false) }
            let enabled = canUseResetCards && hasAvailableCard && !blocked
            return .init(title: "重置", isEnabled: enabled,
                         toolTip: enabled ? "使用一张\(kind.title)重置卡" : (resetUnavailableReason ?? "暂无可用重置卡或正在刷新"))
        }
    }

    private func renderResetCards(rebuild: Bool) {
        let chips: [ResetCardsRow.Chip] = showsResetActions ? [
            ("zai.fiveHour", ZAIResetCreditCard.Kind.fiveHour, "5h 重置"),
            ("zai.week", ZAIResetCreditCard.Kind.week, "周重置")
        ].compactMap { id, kind, label in
            let cards = resetCards.filter { $0.kind == kind }
            // 网络结果不明确时，即使可用卡列表已变化，也保留同一请求的重试入口。
            guard !cards.isEmpty || (resetStates[kind] ?? .idle) != .idle else { return nil }
            let earliest = cards.compactMap(\.expiresAt).min()
            let soon = earliest.map { Date().distance(to: $0) < PanelTheme.cardExpiryWarningInterval } ?? false
            var title = "\(label) ×\(cards.count)"
            if let earliest {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M/d"
                title += " · \(formatter.string(from: earliest))"
            }
            return ResetCardsRow.Chip(id: id, title: title, soon: soon,
                                     cards: cards.map { .init(kindTitle: $0.kind.title, expiresAt: $0.expiresAt) },
                                     resetAction: resetAction(for: kind))
        } : []
        let ids = Set(chips.map(\.id))
        if rebuild || ids != renderedResetIDs {
            renderedResetIDs = ids
            section.resetCards.configure(chips: chips)
        } else {
            section.resetCards.updateResetActions(Dictionary(uniqueKeysWithValues: chips.compactMap { chip in
                chip.resetAction.map { (chip.id, $0) }
            }))
        }
    }

    private func startPlanBalanceTooltip(_ balance: ZAIBalance, planTooltip: String?) -> String {
        let used = PanelTheme.formatTokenCount(max(balance.totalUnits - balance.remainingUnits, 0))
        let periodText = balance.isDaily ? "每日额度" : "一次性额度"
        var tooltip = "\(balance.title) · \(periodText)，剩余 \(PanelTheme.formatTokenCount(balance.remainingUnits))/\(PanelTheme.formatTokenCount(balance.totalUnits))（已用 \(used)）"
        if let planTooltip, !planTooltip.isEmpty {
            tooltip += " · \(planTooltip)"
        }
        return tooltip
    }

    private func startPlanPendingTooltip(_ entitlement: ZAIPendingEntitlement) -> String {
        "\(entitlement.title) · 待生效，\(PanelTheme.formatCountdown(until: entitlement.effectiveAt) ?? "--") 后可用"
    }

    /// start-plan 套餐待生效 / 已结束时的状态文案（与旧版口径一致）。
    private static func startPlanPendingText(_ snapshot: ZAIQuotaSnapshot) -> String? {
        guard snapshot.kind == .startPlan else { return nil }
        let now = Date()
        if let start = snapshot.planStartAt, start > now {
            return "套餐待生效 · \(formatCompactDateTime(start)) 开始"
        }
        if let end = snapshot.planEndAt, end < now {
            return "套餐已于 \(formatCompactDateTime(end)) 结束"
        }
        if let effectiveAt = snapshot.pendingEntitlements
            .compactMap(\.effectiveAt)
            .filter({ $0 > now })
            .min() {
            return "套餐待生效 · \(formatCompactDateTime(effectiveAt)) 生效"
        }
        return nil
    }

    private static func formatCompactDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

extension QuotaKind {
    /// 无快照时 5 小时格的兜底标题。
    var displayFallbackTitle: String {
        switch self {
        case .fiveHour: return "5小时"
        case .weekly: return "周限额"
        }
    }
}
