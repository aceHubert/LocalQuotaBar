import AppKit
import Foundation

// MARK: - 面板共享组件

/// provider 品牌 logo（内嵌 OpenDesign 原型同款 SVG，模板图渲染后由 contentTintColor 着色）。
enum PanelLogos {
    static let codex: NSImage? = makeLogo("""
    <svg fill="#000000" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path clip-rule="evenodd" d="M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"></path></svg>
    """)

    static let zai: NSImage? = makeLogo("""
    <svg fill="#000000" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M12.105 2L9.927 4.953H.653L2.83 2h9.276zM23.254 19.048L21.078 22h-9.242l2.174-2.952h9.244zM24 2L9.264 22H0L14.736 2H24z"></path></svg>
    """)

    private static func makeLogo(_ svg: String) -> NSImage? {
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 14, height: 14)
        return image
    }
}

/// borderless 胶囊按钮：layer 画底/描边，标题两侧留内边距。
class PillButton: NSButton {
    var horizontalPadding: CGFloat = 14 { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding
        return size
    }

    func applyStyle(foreground: NSColor, background: NSColor, border: NSColor, cornerRadius: CGFloat = 8) {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = border.cgColor
        contentTintColor = foreground
        let title = attributedTitle.string
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: foreground,
            .font: font ?? .systemFont(ofSize: 9.5, weight: .semibold)
        ])
    }
}

/// 小图标按钮（顶部栏刷新/齿轮、provider 刷新），SF Symbols。
final class PanelIconButton: NSButton {
    var onTap: (() -> Void)?

    init(symbolName: String, toolTipText: String, side: CGFloat = 22) {
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = side >= 22 ? 7 : 6
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairline.cgColor

        let config = NSImage.SymbolConfiguration(pointSize: side >= 22 ? 11 : 10, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        contentTintColor = PanelTheme.secondaryText
        toolTip = toolTipText

        target = self
        action = #selector(tapped)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }
}

/// 套餐 tag 胶囊（蓝色 Pro/Lite；API Key 用中性灰）。
final class PlanTagView: NSView {
    enum Style {
        case plan
        case neutral
    }

    private let label = NSTextField(labelWithString: "")
    private var style: Style = .plan

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 8.5, weight: .bold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String?, style: Style = .plan) {
        self.style = style
        label.stringValue = text ?? ""
        isHidden = text?.isEmpty != false

        switch style {
        case .plan:
            label.textColor = NSColor(hex: 0x6DB8FF)
            layer?.backgroundColor = NSColor(hex: 0x428DE1, alpha: 0.15).cgColor
            layer?.borderColor = NSColor(hex: 0x5AA0FF, alpha: 0.25).cgColor
        case .neutral:
            label.textColor = PanelTheme.secondaryText
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
    }
}

/// provider 头部：logo 徽标（含状态点）+ 名称 + 副标题 + 套餐 tag + 状态文字 + 刷新按钮。
final class ProviderHeaderView: NSView {
    enum StatusKind {
        case ok
        case bad
        case idle
    }

    struct State {
        var title: String
        var monogram: String
        var logoImage: NSImage? = nil
        var subtitle: String?
        var tagText: String?
        var tagStyle: PlanTagView.Style
        var statusText: String
        var statusKind: StatusKind
    }

    var onRefresh: (() -> Void)?

    private let logoContainer = NSView()
    private let monogramLabel = NSTextField(labelWithString: "")
    private let logoImageView = NSImageView()
    private let statusDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let planTag = PlanTagView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDotMini = NSView()
    private let refreshButton = PanelIconButton(
        symbolName: "arrow.clockwise",
        toolTipText: "手动刷新",
        side: 20
    )
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // logo 徽标 24x24
        logoContainer.wantsLayer = true
        logoContainer.layer?.cornerRadius = 7
        logoContainer.layer?.backgroundColor = NSColor(hex: 0x2C2C31).cgColor
        logoContainer.layer?.borderWidth = 1
        logoContainer.layer?.borderColor = PanelTheme.hairline.cgColor
        logoContainer.translatesAutoresizingMaskIntoConstraints = false

        monogramLabel.font = .systemFont(ofSize: 10, weight: .bold)
        monogramLabel.textColor = .white
        monogramLabel.alignment = .center
        monogramLabel.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(monogramLabel)

        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.contentTintColor = .white
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoImageView)

        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = PanelTheme.green.cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.borderWidth = 1.5
        statusDot.layer?.borderColor = PanelTheme.panelBackground.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            logoContainer.widthAnchor.constraint(equalToConstant: 24),
            logoContainer.heightAnchor.constraint(equalToConstant: 24),
            monogramLabel.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            monogramLabel.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor, constant: 0.5),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 14),
            logoImageView.heightAnchor.constraint(equalToConstant: 14)
        ])

        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = PanelTheme.primaryText

        subtitleLabel.font = .systemFont(ofSize: 9, weight: .regular)
        subtitleLabel.textColor = PanelTheme.tertiaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.cell?.truncatesLastVisibleLine = true
        subtitleLabel.cell?.wraps = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        statusLabel.textColor = PanelTheme.tertiaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.init(751), for: .horizontal)

        statusDotMini.wantsLayer = true
        statusDotMini.layer?.backgroundColor = PanelTheme.green.cgColor
        statusDotMini.layer?.cornerRadius = 2.5
        statusDotMini.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.onTap = { [weak self] in self?.onRefresh?() }

        let titleLine = NSStackView(views: [titleLabel, subtitleLabel, planTag])
        titleLine.orientation = .horizontal
        titleLine.alignment = .lastBaseline
        titleLine.spacing = 6
        titleLine.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSStackView(views: [statusDotMini, statusLabel])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 4

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [logoContainer, titleLine, spacer, statusLine, refreshButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // 状态点独立叠在徽标右下方，避免被徽标边界裁成一小段圆弧。
        addSubview(statusDot)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusDot.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: 2.5),
            statusDot.bottomAnchor.constraint(equalTo: logoContainer.bottomAnchor, constant: 2.5),
            statusDotMini.widthAnchor.constraint(equalToConstant: 5),
            statusDotMini.heightAnchor.constraint(equalToConstant: 5),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 88),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ state: State) {
        monogramLabel.stringValue = state.monogram
        if let logoImage = state.logoImage {
            logoImageView.image = logoImage
            logoImageView.isHidden = false
            monogramLabel.isHidden = true
        } else {
            logoImageView.isHidden = true
            monogramLabel.isHidden = false
        }
        titleLabel.stringValue = state.title
        subtitleLabel.stringValue = Self.compactAccountLabel(state.subtitle ?? "")
        subtitleLabel.isHidden = state.subtitle?.isEmpty != false
        subtitleLabel.toolTip = state.subtitle ?? ""
        planTag.configure(text: state.tagText, style: state.tagStyle)

        statusLabel.stringValue = state.statusText
        statusLabel.toolTip = state.statusText
        statusDotMini.isHidden = state.statusText.isEmpty
        switch state.statusKind {
        case .ok:
            statusLabel.textColor = PanelTheme.tertiaryText
            statusDotMini.layer?.backgroundColor = PanelTheme.green.cgColor
            statusDot.layer?.backgroundColor = PanelTheme.green.cgColor
        case .bad:
            statusLabel.textColor = NSColor(hex: 0xFF8D84)
            statusDotMini.layer?.backgroundColor = PanelTheme.red.cgColor
            statusDot.layer?.backgroundColor = PanelTheme.red.cgColor
        case .idle:
            statusLabel.textColor = PanelTheme.tertiaryText
            statusDotMini.layer?.backgroundColor = PanelTheme.tertiaryText.cgColor
            statusDot.layer?.backgroundColor = PanelTheme.tertiaryText.cgColor
        }
    }

    /// 邮箱只保留用户名前三位，域名用于区分账号；完整内容由 tooltip 提供。
    static func compactAccountLabel(_ value: String) -> String {
        guard let separator = value.lastIndex(of: "@") else { return value }
        let username = value[..<separator]
        guard username.count > 3 else { return value }
        return "\(username.prefix(3))…\(value[separator...])"
    }

    private var refreshAvailable = true
    private var isRefreshing = false
    private var refreshAllowedAt: Date?
    var onRefreshAvailabilityChange: (() -> Void)?

    var canRequestRefresh: Bool { !isRefreshing && !isInRefreshCooldown }

    /// 错误横幅重试入口：失败后立即重试是明确意图，只做并发防重，不看冷却。
    var canRetryRefresh: Bool { refreshAvailable && !isRefreshing }

    func setRefreshAvailable(_ available: Bool) {
        refreshAvailable = available
        updateRefreshButton()
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
        updateRefreshButton()
    }

    private var isInRefreshCooldown: Bool {
        refreshAllowedAt.map { now() < $0 } ?? false
    }

    private func updateRefreshButton() {
        refreshButton.isEnabled = refreshAvailable && canRequestRefresh
        refreshButton.alphaValue = refreshButton.isEnabled ? 1 : 0.35
        if !refreshAvailable {
            refreshButton.toolTip = "API Key 模式不支持余额刷新"
        } else if isRefreshing {
            refreshButton.toolTip = "刷新中，请稍候"
        } else if isInRefreshCooldown {
            refreshButton.toolTip = "刷新冷却中，请稍后重试"
        } else {
            refreshButton.toolTip = "手动刷新"
        }
        onRefreshAvailabilityChange?()
    }

    /// 所有手动入口共用 60 秒防重；跳过请求不延长冷却。API Key 可仅刷新每日用量。
    @discardableResult
    func beginRefreshCooldown(allowUsageOnly: Bool = false) -> Bool {
        guard refreshAvailable || allowUsageOnly, !isRefreshing, !isInRefreshCooldown else { return false }
        refreshAllowedAt = now().addingTimeInterval(60)
        updateRefreshButton()
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cooldownTimer = nil
                self.updateRefreshButton()
            }
        }
        return true
    }

    private var cooldownTimer: Timer?
}

/// 胶囊条：连续填充 + 居中文字。支持百分比分级、余额、无限制空槽、待生效、占位。
final class CapsuleBarView: NSView {
    enum Content {
        case percent(remaining: Double)
        case credits(text: String)
        case unlimited
        case pending(text: String)
        case placeholder
    }

    private var content: Content = .placeholder
    private var showsDashedBorder = false
    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        textLabel.textColor = .white
        textLabel.alignment = .center
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ content: Content) {
        self.content = content
        showsDashedBorder = false
        textLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        needsDisplay = true

        switch content {
        case .percent(let remaining):
            layer?.backgroundColor = PanelTheme.trackColor.cgColor
            layer?.borderWidth = 0
            textLabel.stringValue = "\(Int(remaining.rounded()))%"
            textLabel.textColor = .white
        case .credits(let text):
            layer?.backgroundColor = NSColor(hex: 0x5B3FD6).cgColor
            layer?.borderWidth = 0
            textLabel.stringValue = text
            textLabel.textColor = .white
        case .unlimited:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            showsDashedBorder = true
            textLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            textLabel.stringValue = "无限制"
            textLabel.textColor = PanelTheme.secondaryText
        case .pending(let text):
            layer?.backgroundColor = PanelTheme.trackColor.cgColor
            layer?.borderWidth = 0
            textLabel.stringValue = text
            textLabel.textColor = PanelTheme.secondaryText
        case .placeholder:
            layer?.backgroundColor = PanelTheme.trackColor.cgColor
            layer?.borderWidth = 0
            textLabel.stringValue = "--"
            textLabel.textColor = PanelTheme.tertiaryText
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsDashedBorder {
            // CALayer border 不支持虚线，这里手绘可见的虚线胶囊描边
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            path.setLineDash([3.5, 2.5], count: 2, phase: 0)
            path.lineWidth = 1.2
            NSColor.white.withAlphaComponent(0.32).setStroke()
            path.stroke()
        }
        guard case .percent(let remaining) = content else { return }

        let fillWidth = bounds.width * max(0, min(100, remaining)) / 100
        guard fillWidth > 1 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        let color = PanelTheme.levelColor(remainingPercent: remaining)
        let path = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color.setFill()
        path.fill()
        // 顶部提亮，贴近原型渐变
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.height / 2, width: fillWidth, height: bounds.height / 2),
                     xRadius: bounds.height / 4, yRadius: bounds.height / 4).fill()
    }
}

/// 额度格：标题 + 重置倒计时（粉/黄）+ 胶囊。
final class QuotaCellView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let capsule = CapsuleBarView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = PanelTheme.secondaryText

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        countdownLabel.textColor = PanelTheme.pink

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleLine = NSStackView(views: [titleLabel, spacer, countdownLabel])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 3

        let stack = NSStackView(views: [titleLine, capsule])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            capsule.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 通用配置。countdown 为 nil 时隐藏倒计时。
    func configure(
        title: String,
        countdown: String?,
        countdownSoon: Bool = false,
        content: CapsuleBarView.Content,
        tooltip: String? = nil
    ) {
        titleLabel.stringValue = title
        countdownLabel.stringValue = countdown ?? ""
        countdownLabel.isHidden = countdown == nil
        countdownLabel.textColor = countdownSoon ? PanelTheme.yellow : PanelTheme.pink
        capsule.configure(content)
        toolTip = tooltip
    }
}

/// Start Plan 多套餐卡片列表：每个套餐一张卡，卡片内保留现有额度格样式。
final class StartPlanListView: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(plans: [ZAIPlanItem]) {
        stack.arrangedSubviews.forEach { stack.removeView($0) }
        for plan in plans {
            let card = StartPlanCardView(plan: plan)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// 单个 Start Plan 卡片。
private final class StartPlanCardView: NSView {
    init(plan: ZAIPlanItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairlineSubtle.cgColor

        let title = NSTextField(labelWithString: plan.name)
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = PanelTheme.primaryText
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail

        let status = NSTextField(labelWithString: Self.statusText(plan))
        status.font = .systemFont(ofSize: 9.5, weight: .medium)
        status.textColor = Self.statusColor(plan)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail

        let cells = plan.balances.map { balance -> QuotaCellView in
            let cell = QuotaCellView()
            cell.configure(
                title: balance.title,
                countdown: PanelTheme.formatCountdown(until: balance.expiresAt),
                countdownSoon: Self.isSoon(balance.expiresAt),
                content: .percent(remaining: balance.remainingFraction * 100),
                tooltip: Self.balanceTooltip(balance, plan: plan)
            )
            return cell
        }
        let pendingCells = plan.status == .upcoming
            ? plan.pendingEntitlements.prefix(2).map { entitlement -> QuotaCellView in
                let cell = QuotaCellView()
                cell.configure(
                    title: entitlement.title,
                    countdown: PanelTheme.formatCountdown(until: entitlement.expiresAt),
                    countdownSoon: false,
                    content: .pending(text: PanelTheme.formatTokenCount(entitlement.grantUnits)),
                    tooltip: Self.pendingTooltip(entitlement)
                )
                return cell
            }
            : []
        let visibleCells = Array((cells.isEmpty ? pendingCells : cells).prefix(2))

        let grid = NSStackView(views: visibleCells)
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 7
        grid.distribution = .fillEqually

        let rows = NSStackView(views: [title, status, grid])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        rows.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func statusText(_ plan: ZAIPlanItem) -> String {
        switch plan.status {
        case .upcoming:
            let effectiveAt = plan.pendingEntitlements.compactMap(\.effectiveAt).filter { $0 > Date() }.min()
            let start = effectiveAt ?? plan.startsAt
            return "待生效 \(formatDateTime(start)) · 过期时间 \(formatDateTime(plan.endsAt))"
        case .ended:
            return "已结束 \(formatDateTime(plan.endsAt))"
        case .active:
            return "过期时间 \(formatDateTime(plan.endsAt))"
        case .unknown:
            return "状态未知"
        }
    }

    private static func statusColor(_ plan: ZAIPlanItem) -> NSColor {
        switch plan.status {
        case .upcoming: return PanelTheme.orange
        case .ended: return PanelTheme.tertiaryText
        case .active: return PanelTheme.secondaryText
        case .unknown: return PanelTheme.tertiaryText
        }
    }

    private static func isSoon(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().distance(to: date) < PanelTheme.resetSoonThreshold
    }

    private static func balanceTooltip(_ balance: ZAIBalance, plan: ZAIPlanItem) -> String {
        let used = PanelTheme.formatTokenCount(max(balance.totalUnits - balance.remainingUnits, 0))
        let periodText = balance.isDaily ? "每日额度" : "一次性额度"
        return "\(plan.name) · \(balance.title) · \(periodText)，剩余 \(PanelTheme.formatTokenCount(balance.remainingUnits))/\(PanelTheme.formatTokenCount(balance.totalUnits))（已用 \(used)）"
    }

    private static func pendingTooltip(_ entitlement: ZAIPendingEntitlement) -> String {
        "\(entitlement.title) · 待生效，\(PanelTheme.formatCountdown(until: entitlement.effectiveAt) ?? "--") 后可用"
    }

    private static func formatDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

/// 重置卡 chip + 展开卡列表。支持多枚 chip（ZAI 的 5h/周各一枚）。
final class ResetCardsRow: NSView {
    private static let controlHeight: CGFloat = 18
    private static let controlCornerRadius: CGFloat = 6

    struct ResetAction {
        let title: String
        let isEnabled: Bool
        var toolTip: String? = nil
    }

    struct CardItem {
        let kindTitle: String
        let expiresAt: Date?
        var id: String? = nil
        var resetAction: ResetAction? = nil
    }

    struct Chip {
        let id: String
        let title: String      // 如 "重置卡 ×3 · 最早 9/20"
        let soon: Bool
        var cards: [CardItem]
        var resetAction: ResetAction? = nil
    }

    /// 展开状态变化会引起高度变化，宿主据此刷新 popover contentSize。
    var onContentHeightChange: (() -> Void)?
    var onReset: ((String) -> Void)?

    private var chips: [Chip] = []
    private var expandedIDs: Set<String> = []
    private var detailViews: [String: NSView] = [:]
    private var expandButtons: [String: NSButton] = [:]
    private var resetButtons: [String: PillButton] = [:]
    private var cardResetButtons: [String: PillButton] = [:]
    private var chipStackFullWidth: NSLayoutConstraint?
    private let chipStack = NSStackView()
    private let listStack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chipStack.orientation = .horizontal
        chipStack.alignment = .centerY
        chipStack.spacing = 4
        chipStack.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [chipStack, listStack])
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
            chipStack.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            listStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(chips: [Chip]) {
        self.chips = chips
        expandedIDs.formIntersection(chips.map(\.id))
        rebuild()
    }

    /// 请求中、失败和恢复可用只更新操作按钮，保留展开内容与视图实例。
    func updateResetActions(_ actions: [String: ResetAction]) {
        for index in chips.indices {
            let id = chips[index].id
            guard let action = actions[id], let button = resetButtons[id] else { continue }
            chips[index].resetAction = action
            updateResetButton(button, action: action)
        }
    }

    /// 按卡 ID 更新明细操作，不重建列表，保留展开状态和当前点击的按钮。
    func updateCardResetActions(_ actions: [String: ResetAction]) {
        for chipIndex in chips.indices {
            for cardIndex in chips[chipIndex].cards.indices {
                guard let id = chips[chipIndex].cards[cardIndex].id,
                      let action = actions[id], let button = cardResetButtons[id] else { continue }
                chips[chipIndex].cards[cardIndex].resetAction = action
                updateResetButton(button, action: action)
            }
        }
    }

    private func rebuild() {
        chipStack.arrangedSubviews.forEach { chipStack.removeView($0) }
        detailViews.values.forEach { listStack.removeView($0) }
        detailViews.removeAll()
        expandButtons.removeAll()
        resetButtons.removeAll()
        cardResetButtons.removeAll()

        isHidden = chips.isEmpty
        let hasResetActions = chips.contains { $0.resetAction != nil }
        chipStack.orientation = hasResetActions ? .vertical : .horizontal
        chipStack.alignment = hasResetActions ? .leading : .centerY
        chipStackFullWidth?.isActive = false
        chipStackFullWidth = hasResetActions
            ? chipStack.widthAnchor.constraint(equalTo: widthAnchor) : nil
        chipStackFullWidth?.isActive = true

        for chip in chips {
            let expanded = expandedIDs.contains(chip.id)
            let chipButton = makeChipButton(chip)
            let expandButton = makeExpandButton(chip, expanded: expanded)
            if hasResetActions {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.init(1), for: .horizontal)
                spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let group = NSStackView(views: [chipButton, expandButton, spacer])
                group.orientation = .horizontal
                group.alignment = .centerY
                group.spacing = 4
                group.translatesAutoresizingMaskIntoConstraints = false
                if let action = chip.resetAction {
                    let button = makeResetButton(chip.id, action: action)
                    group.addArrangedSubview(button)
                    resetButtons[chip.id] = button
                }
                chipStack.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: chipStack.widthAnchor).isActive = true
            } else {
                chipStack.addArrangedSubview(chipButton)
                chipStack.addArrangedSubview(expandButton)
            }
            expandButtons[chip.id] = expandButton

            let card = makeCardList(chip)
            listStack.addArrangedSubview(card)
            // 跨视图约束必须在挂载后启用，否则 AppKit 会因没有共同祖先抛出异常。
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            detailViews[chip.id] = card
            card.isHidden = !expanded
        }
        listStack.isHidden = expandedIDs.isEmpty

        onContentHeightChange?()
    }

    private func makeResetButton(_ id: String, action: ResetAction) -> PillButton {
        let button = PillButton(title: action.title, target: self, action: #selector(resetTapped(_:)))
        button.font = .systemFont(ofSize: 9.5, weight: .semibold)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.horizontalPadding = 14
        button.identifier = NSUserInterfaceItemIdentifier("reset-use.\(id)")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        updateResetButton(button, action: action)
        return button
    }

    private func updateResetButton(_ button: PillButton, action: ResetAction) {
        button.title = action.title
        button.isEnabled = action.isEnabled
        button.toolTip = action.toolTip
        button.applyStyle(
            foreground: action.isEnabled ? PanelTheme.panelBackground : PanelTheme.tertiaryText,
            background: action.isEnabled ? PanelTheme.green : NSColor.white.withAlphaComponent(0.06),
            border: action.isEnabled ? PanelTheme.green : NSColor.white.withAlphaComponent(0.12)
        )
        button.layer?.cornerRadius = Self.controlCornerRadius
    }

    @objc private func resetTapped(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        if let chip = chips.first(where: { resetButtons[$0.id] === sender }),
           chip.resetAction?.isEnabled == true {
            onReset?(chip.id)
        } else if let card = chips.flatMap(\.cards).first(where: {
            guard let id = $0.id else { return false }
            return cardResetButtons[id] === sender
        }), let id = card.id, card.resetAction?.isEnabled == true {
            onReset?(id)
        }
    }

    private func makeChipButton(_ chip: Chip) -> PillButton {
        let button = PillButton(title: chip.title, target: self, action: #selector(chipTapped(_:)))
        button.font = .systemFont(ofSize: 9.5, weight: .semibold)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.horizontalPadding = 14
        if chip.soon {
            button.applyStyle(
                foreground: PanelTheme.orange,
                background: PanelTheme.orange.withAlphaComponent(0.08),
                border: PanelTheme.orange.withAlphaComponent(0.35)
            )
        } else {
            button.applyStyle(
                foreground: PanelTheme.secondaryText,
                background: NSColor.white.withAlphaComponent(0.05),
                border: NSColor.white.withAlphaComponent(0.09)
            )
        }
        button.toolTip = "展开查看每张重置卡到期时间"
        button.layer?.cornerRadius = Self.controlCornerRadius
        button.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        button.identifier = NSUserInterfaceItemIdentifier(chip.id)
        return button
    }

    private func makeExpandButton(_ chip: Chip, expanded: Bool) -> NSButton {
        let button = NSButton(image: NSImage(), target: self, action: #selector(chipTapped(_:)))
        updateExpandButton(button, expanded: expanded)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.controlCornerRadius
        button.layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = PanelTheme.hairline.cgColor
        button.contentTintColor = PanelTheme.tertiaryText
        button.identifier = NSUserInterfaceItemIdentifier(chip.id)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.controlHeight),
            button.heightAnchor.constraint(equalToConstant: Self.controlHeight)
        ])
        return button
    }

    private func updateExpandButton(_ button: NSButton, expanded: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        let symbol = expanded ? "chevron.up" : "chevron.down"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.toolTip = expanded ? "收起重置卡列表" : "展开重置卡列表"
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let detail = detailViews[id], let expandButton = expandButtons[id] else { return }
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
        // 点击只更新对应卡片的可见性，保留按钮和明细实例，避免整组移除重建造成闪屏。
        let expanded = expandedIDs.contains(id)
        detail.isHidden = !expanded
        listStack.isHidden = expandedIDs.isEmpty
        updateExpandButton(expandButton, expanded: expanded)
        onContentHeightChange?()
    }

    private func makeCardList(_ chip: Chip) -> NSView {
        let card = PanelCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4)
        ])

        for (index, item) in chip.cards.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.alphaValue = 0.3
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let row = makeCardRow(index: index, item: item)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return card
    }

    private func makeCardRow(index: Int, item: CardItem) -> NSView {
        let indexLabel = NSTextField(labelWithString: "#\(index + 1)")
        indexLabel.font = .systemFont(ofSize: 9.5, weight: .bold)
        indexLabel.textColor = PanelTheme.tertiaryText

        let kindLabel = NSTextField(labelWithString: item.kindTitle)
        kindLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        kindLabel.textColor = PanelTheme.tertiaryText

        let timeLabel = NSTextField(labelWithString: PanelTheme.formatCardExpiry(item.expiresAt))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        timeLabel.textColor = PanelTheme.primaryText

        let badge = PanelBadgeLabel()
        let (text, soon) = PanelTheme.cardExpiryBadge(item.expiresAt)
        badge.configure(text: text, soon: soon)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // 明细新增操作后省去重复的卡类型，给完整到期时间和按钮留足空间。
        let rowViews: [NSView] = item.resetAction == nil
            ? [indexLabel, kindLabel, timeLabel, spacer, badge]
            : [indexLabel, timeLabel, spacer, badge]
        let row = NSStackView(views: rowViews)
        if let id = item.id, let action = item.resetAction {
            let button = makeResetButton("card.\(id)", action: action)
            button.horizontalPadding = 10
            row.addArrangedSubview(button)
            cardResetButtons[id] = button
        }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = item.resetAction == nil ? 7 : 4
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return row
    }
}

/// 小胶囊徽标（重置卡"N天后到期"）。
final class PanelBadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 8.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, soon: Bool) {
        label.stringValue = text
        label.textColor = soon ? NSColor(hex: 0xFF6B5E) : PanelTheme.tertiaryText
        layer?.backgroundColor = (soon
            ? PanelTheme.red.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.05)).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (soon
            ? PanelTheme.red.withAlphaComponent(0.30)
            : NSColor.white.withAlphaComponent(0.08)).cgColor
    }
}

/// 刷新失败横幅：图标 + 标题 + 详情（2 行截断）+ 重试按钮。
final class ErrorBannerView: NSView {
    var onRetry: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = PillButton(title: "重试", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelTheme.red.withAlphaComponent(0.07).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.red.withAlphaComponent(0.22).cgColor
        isHidden = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = PanelTheme.red
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = NSColor(hex: 0xFF8D84)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 9, weight: .regular)
        detailLabel.textColor = PanelTheme.tertiaryText
        detailLabel.maximumNumberOfLines = 2

        retryButton.font = .systemFont(ofSize: 9.5, weight: .bold)
        retryButton.bezelStyle = .regularSquare
        retryButton.isBordered = false
        retryButton.horizontalPadding = 18
        retryButton.applyStyle(
            foreground: NSColor(hex: 0xFF8D84),
            background: PanelTheme.red.withAlphaComponent(0.12),
            border: PanelTheme.red.withAlphaComponent(0.3),
            cornerRadius: 6
        )
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        // 面板定宽，预先确定换行上限，避免在 layout 中用标签自身宽度反复反馈。
        detailLabel.preferredMaxLayoutWidth = max(1, PanelTheme.contentWidth - 18 - 12 - 14
            - ceil(retryButton.intrinsicContentSize.width))

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(textStack)
        addSubview(retryButton)

        // 手动横排：文本区吃掉富余宽度，重试按钮按内容宽度钉在右缘，避免被拉伸。
        let retryWidth = ceil(retryButton.intrinsicContentSize.width)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -7),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: retryWidth),
            retryButton.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

/// 底部：阈值图例行 + 低量提醒开关（+ 恢复提醒按钮）。
final class PanelFooterView: NSView {
    var onToggleReminder: ((Bool) -> Void)?
    var onRestoreReminders: (() -> Void)?

    private let reminderSwitch = PanelReminderSwitch()
    private let restoreButton = PillButton(title: "恢复提醒", target: nil, action: nil)
    private let reminderLine = NSStackView()
    private let warningLegendLabel = NSTextField(labelWithString: "")
    private let criticalLegendLabel = NSTextField(labelWithString: "")
    private let resetLegendLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        func legendDot(_ color: NSColor) -> NSView {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7)
            ])
            return dot
        }

        func legendItem(_ color: NSColor, _ label: NSTextField) -> NSStackView {
            label.font = .systemFont(ofSize: 9.5, weight: .semibold)
            label.textColor = PanelTheme.secondaryText
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let item = NSStackView(views: [legendDot(color), label])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 4
            item.setContentHuggingPriority(.required, for: .horizontal)
            return item
        }

        // 图例项保持内容宽度，所有剩余空间集中到末尾，避免“正常”后出现大空隙。
        let legendSpacer = NSView()
        legendSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        legendSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let legendLine = NSStackView(views: [
            legendItem(PanelTheme.green, NSTextField(labelWithString: "正常")),
            legendItem(PanelTheme.orange, warningLegendLabel),
            legendItem(PanelTheme.red, criticalLegendLabel),
            legendItem(PanelTheme.yellow, resetLegendLabel),
            legendSpacer
        ])
        legendLine.orientation = .horizontal
        legendLine.spacing = 9
        legendLine.alignment = .centerY

        let reminderLabel = NSTextField(labelWithString: "低量提醒 · 阈值可在设置中调整")
        reminderLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        reminderLabel.textColor = PanelTheme.tertiaryText

        PanelTheme.configureReminderSwitch(reminderSwitch)
        reminderSwitch.target = self
        reminderSwitch.action = #selector(switchChanged)

        restoreButton.font = .systemFont(ofSize: 9.5, weight: .semibold)
        restoreButton.bezelStyle = .regularSquare
        restoreButton.isBordered = false
        restoreButton.horizontalPadding = 16
        restoreButton.applyStyle(
            foreground: PanelTheme.secondaryText,
            background: NSColor.white.withAlphaComponent(0.06),
            border: NSColor.white.withAlphaComponent(0.12)
        )
        restoreButton.toolTip = "撤销“不再提醒”并清除冷却，本周期内重新允许提醒"
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        restoreButton.isHidden = true

        let spacer = NSView()
        // 显式最低拥抱/抗压优先级：让 spacer 独占所有剩余宽度，开关稳定右对齐
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // 初始化与后续显隐更新必须使用同一个容器，避免同名局部变量遮蔽属性。
        for item in [reminderLabel, spacer, restoreButton, reminderSwitch] {
            reminderLine.addArrangedSubview(item)
        }
        reminderLine.orientation = .horizontal
        reminderLine.alignment = .centerY
        reminderLine.spacing = 8
        reminderLine.translatesAutoresizingMaskIntoConstraints = false
        // 隐藏的"恢复提醒"不再占位（否则开关右侧会留出按钮宽度的空隙）
        reminderLine.setVisibilityPriority(.notVisible, for: restoreButton)

        let stack = NSStackView(views: [legendLine, reminderLine])
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
            reminderLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            legendLine.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        configure(reminder: .default, canRestore: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reminder: ReminderConfiguration, canRestore: Bool) {
        reminderSwitch.state = reminder.isEnabled ? .on : .off
        warningLegendLabel.stringValue = "预警 ≤\(String(format: "%g", reminder.warningRemainingPercent))%"
        criticalLegendLabel.stringValue = "严重 ≤\(String(format: "%g", reminder.criticalRemainingPercent))%"
        resetLegendLabel.stringValue = reminder.resetSoonMinutes > 0
            ? "即将重置 ≤\(String(format: "%g", reminder.resetSoonMinutes))分"
            : "重置提醒关闭"
        reminderLine.setVisibilityPriority(canRestore ? .init(999) : .notVisible, for: restoreButton)
        restoreButton.isHidden = !canRestore
    }

    @objc private func switchChanged() {
        onToggleReminder?(reminderSwitch.state == .on)
    }

    @objc private func restoreTapped() {
        onRestoreReminders?()
    }
}
