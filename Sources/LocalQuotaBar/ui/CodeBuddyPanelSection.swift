import AppKit
import Foundation

// MARK: - CodeBuddy 面板（tabs.html 定稿：Credits 口径，无 Tokens / 无用量图）

/// CodeBuddy 区块（国际版 / 国内版共用）：slim 头部 + 套餐基础积分细进度条 + 购买积分 / 奖励包 chips。
final class CodeBuddyPanelSection: NSView {
    var onRefresh: (() -> Void)?
    var onRefreshAvailabilityChange: (() -> Void)?
    var onContentHeightChange: (() -> Void)?

    var canRequestRefresh: Bool { header.canRequestRefresh }
    func requestRefresh() {
        guard let onRefresh, header.beginRefreshCooldown() else { return }
        onRefresh()
    }

    let header = ProviderHeaderView()
    let planUsageLabel = NSTextField(labelWithString: "")
    let planRemainLabel = NSTextField(labelWithString: "")
    let planBar = CodeBuddySlimBarView()
    let resetCards = ResetCardsRow()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        header.configure(.init(statusText: "等待刷新", statusKind: .idle))
        header.onRefreshAvailabilityChange = { [weak self] in self?.onRefreshAvailabilityChange?() }

        planUsageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        planUsageLabel.textColor = PanelTheme.primaryText

        planRemainLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        planRemainLabel.textColor = PanelTheme.tertiaryText

        let usageLine = NSStackView(views: [planUsageLabel, planRemainLabel])
        usageLine.orientation = .horizontal
        usageLine.alignment = .centerY
        usageLine.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        usageLine.insertArrangedSubview(spacer, at: 1)

        resetCards.onContentHeightChange = { [weak self] in self?.onContentHeightChange?() }

        let stack = NSStackView(views: [header, usageLine, planBar, resetCards])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            usageLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            planBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetCards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(equalToConstant: PanelTheme.contentWidth)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(snapshot: CodeBuddySnapshot?, isRefreshing: Bool, error: String?) {
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
            planUsageLabel.isHidden = true
            planRemainLabel.isHidden = true
            planBar.isHidden = true
            resetCards.isHidden = true
            return
        }
        planUsageLabel.isHidden = false
        planRemainLabel.isHidden = false
        planBar.isHidden = false
        resetCards.isHidden = false

        // 套餐基础积分：细进度条，不显示百分比文字（设计稿 .capsule.slim）
        if let plan = snapshot.planPackage {
            // 套餐名来自 SubscriptionPackageCode 映射（体验版/Pro/Max）；
            // 统一 <剩余>/<总量> 积分 口径，不做已用/剩余的文字区分（窄面板放不下）
            planUsageLabel.stringValue = "\(CodeBuddyFormat.credits(plan.remainCapacity))/\(CodeBuddyFormat.credits(plan.totalCapacity)) 积分"
                + "（\(snapshot.planName ?? "未知套餐")）"
            planRemainLabel.stringValue = plan.cycleEndTime.map { "\(Self.formatUpdateDate($0)) 更新" } ?? ""
            planBar.configure(percent: plan.remainingPercent)
            planBar.toolTip = "\(CodeBuddyFormat.credits(plan.remainCapacity))/\(CodeBuddyFormat.credits(plan.totalCapacity)) 积分"
        } else {
            planUsageLabel.stringValue = "套餐基础积分数据不完整"
            planRemainLabel.stringValue = ""
            planBar.configure(percent: nil)
        }

        resetCards.configure(chips: Self.chips(paid: snapshot.paidPackages, free: snapshot.freePackages))
    }

    /// 购买积分与奖励包 chips：空态显示“无资源包”；有包时计数 + 展开明细。
    static func chips(paid: [CodeBuddyPackage], free: [CodeBuddyPackage]) -> [ResetCardsRow.Chip] {
        var chips: [ResetCardsRow.Chip] = []

        if paid.isEmpty {
            chips.append(ResetCardsRow.Chip(
                id: "cb.paid",
                title: "购买积分 · 无资源包",
                soon: false,
                cards: []
            ))
        } else {
            chips.append(Self.packageChip(id: "cb.paid", label: "购买积分", packages: paid))
        }
        if !free.isEmpty {
            chips.append(Self.packageChip(id: "cb.free", label: "奖励包", packages: free))
        }
        return chips
    }

    private static func packageChip(id: String, label: String, packages: [CodeBuddyPackage]) -> ResetCardsRow.Chip {
        let total = packages.reduce(0.0) { $0 + $1.totalCapacity }
        let remain = packages.reduce(0.0) { $0 + $1.remainCapacity }
        let earliest = packages.compactMap { $0.expiredTime ?? $0.cycleEndTime }.min()
        let soon = earliest.map { Date().distance(to: $0) < PanelTheme.cardExpiryWarningInterval } ?? false
        // 到期时间不进总标题，逐项展示在明细行上
        return ResetCardsRow.Chip(
            id: id,
            title: "\(label) ×\(packages.count) · \(CodeBuddyFormat.credits(remain))/\(CodeBuddyFormat.credits(total))",
            soon: soon,
            cards: packages.enumerated().map { index, package in
                // 单项不重复分组名：<剩余>/<总量> 积分 · MM-dd HH:mm（对齐 Z.AI 重置单项样式）
                var detail = "\(CodeBuddyFormat.credits(package.remainCapacity))/\(CodeBuddyFormat.credits(package.totalCapacity)) 积分"
                if let expiry = package.expiredTime ?? package.cycleEndTime {
                    detail += " · \(formatExpiry(expiry))"
                }
                if package.inUsage {
                    detail += " · 使用中"
                }
                return ResetCardsRow.CardItem(
                    kindTitle: "",
                    expiresAt: package.expiredTime ?? package.cycleEndTime,
                    id: "\(id).\(index)",
                    detailText: detail
                )
            }
        )
    }

    /// 到期时间：MM-dd HH:mm。
    private static func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func formatUpdateDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

/// 细进度条（6pt，无百分比文字）：CodeBuddy 套餐基础积分专用。
final class CodeBuddySlimBarView: NSView {
    private var percent: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3
        heightAnchor.constraint(equalToConstant: 6).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// nil = 数据缺失（空槽）。
    func configure(percent: Double?) {
        self.percent = percent
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let percent else {
            let dashes = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            dashes.setLineDash([3, 2], count: 2, phase: 0)
            dashes.lineWidth = 1.2
            NSColor.white.withAlphaComponent(0.14).setStroke()
            dashes.stroke()
            return
        }
        PanelTheme.trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let fillWidth = bounds.width * max(0, min(100, percent)) / 100
        guard fillWidth > 0.5 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        PanelTheme.levelColor(remainingPercent: percent).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
    }
}
