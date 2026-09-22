import AppKit
import Foundation

// MARK: - CodeBuddy 面板（tabs.html 定稿：Credits 口径，无 Tokens / 无用量图）

/// CodeBuddy 区块（国际版）：slim 头部 + 套餐基础积分细进度条 + 购买积分 / 奖励包 chips。
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
    private let planRow = NSStackView()
    private let planUsageLabel = NSTextField(labelWithString: "")
    private let planRemainLabel = NSTextField(labelWithString: "")
    private let planBar = CodeBuddySlimBarView()
    private let resetCards = ResetCardsRow()

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

        guard let snapshot else {
            planUsageLabel.stringValue = "--"
            planRemainLabel.stringValue = ""
            planBar.configure(percent: nil)
            resetCards.configure(chips: [])
            return
        }

        // 套餐基础积分：细进度条，不显示百分比文字（设计稿 .capsule.slim）
        if let plan = snapshot.planPackage {
            planUsageLabel.stringValue = "已用 \(CodeBuddyFormat.credits(plan.usedCapacity)) / \(CodeBuddyFormat.credits(plan.totalCapacity))"
                + "（套餐基础积分 · \(snapshot.region == "international" ? "国际版" : "国内版")）"
            planRemainLabel.stringValue = "剩 \(CodeBuddyFormat.credits(plan.remainCapacity))"
                + (plan.cycleEndTime.map { " · \(Self.formatUpdateDate($0)) 更新" } ?? "")
            planBar.configure(percent: plan.remainingPercent)
            planBar.toolTip = "剩余 \(CodeBuddyFormat.credits(plan.remainCapacity)) / \(CodeBuddyFormat.credits(plan.totalCapacity)) 积分"
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
        let earliest = packages.compactMap { $0.expiredTime ?? $0.cycleEndTime }.min()
        let soon = earliest.map { Date().distance(to: $0) < PanelTheme.cardExpiryWarningInterval } ?? false
        var title = "\(label) ×\(packages.count) · 共 \(CodeBuddyFormat.credits(total))"
        if let earliest {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "MM-dd"
            title += " · \(formatter.string(from: earliest)) 到期"
        }
        return ResetCardsRow.Chip(
            id: id,
            title: title,
            soon: soon,
            cards: packages.enumerated().map { index, package in
                ResetCardsRow.CardItem(
                    kindTitle: label,
                    expiresAt: package.expiredTime ?? package.cycleEndTime,
                    id: "\(id).\(index)",
                    detailText: "\(CodeBuddyFormat.credits(package.totalCapacity)) 积分 · 剩 \(CodeBuddyFormat.credits(package.remainCapacity))"
                        + (package.inUsage ? " · 使用中" : "")
                )
            }
        )
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
