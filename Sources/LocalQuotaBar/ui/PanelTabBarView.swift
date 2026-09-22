import AppKit
import Foundation

// MARK: - 面板横向 Tab 栏（tabs.html 定稿：logo 圆环弧长＝剩余额度，下方百分比）

/// Tab 标识；枚举顺序即展示顺序，默认 active 为 codex。
enum QuotaTabID: String, CaseIterable {
    case codex
    case zai
    case deepSeek
    case codeBuddy

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .zai: return "Z.AI"
        case .deepSeek: return "DeepSeek"
        case .codeBuddy: return "CodeBuddy"
        }
    }
}

/// 单个 tab 的状态摘要，由 QuotaViewController 在各 provider apply 链路里汇总。
struct PanelTabStatus {
    /// 进度环与百分比文字的口径。
    /// percent：环按剩余比例填充，下方显示百分比（Codex 周限 / Z.AI 周限 / CodeBuddy 积分）。
    /// text：无「剩余/总量」口径（DeepSeek 余额），空环 + 金额文字，不伪造百分比。
    /// unavailable：数据缺失 / 刷新失败，空轨 + "--"。
    enum RingValue {
        case percent(remaining: Double)
        case text(String)
        case unavailable
    }

    var ring: RingValue = .unavailable
    /// logo 右上角套餐 tag（DeepSeek 无）。
    var tagText: String? = nil
    /// 最近一次刷新失败（状态点变红）。
    var isFailed: Bool = false
    /// tooltip 第一行覆盖名称（如 BigModel）；nil 用 QuotaTabID.displayName。
    var titleOverride: String? = nil
    /// tooltip 第二行：额度 / 金额 / 账号摘要。
    var summary: String? = nil

    /// 环填充比例（0...1）；非 percent 口径返回 nil（空轨）。
    var ringFraction: Double? {
        if case .percent(let remaining) = ring {
            return max(0, min(1, remaining / 100))
        }
        return nil
    }

    var valueText: String {
        switch ring {
        case .percent(let remaining): return "\(Int(remaining.rounded()))%"
        case .text(let text): return text
        case .unavailable: return "--"
        }
    }

    var valueColor: NSColor {
        if case .percent(let remaining) = ring {
            return PanelTheme.levelColor(remainingPercent: remaining)
        }
        return PanelTheme.secondaryText
    }

    var ringColor: NSColor {
        if case .percent(let remaining) = ring {
            return PanelTheme.levelColor(remainingPercent: remaining)
        }
        return PanelTheme.trackColor
    }
}

/// tab 品牌外观：logo 圆底的渐变色与图标前景色（对齐 tabs.html .tab-logo 配色）。
struct PanelTabBrand {
    let gradientTop: NSColor
    let gradientBottom: NSColor
    let iconColor: NSColor
    let logo: NSImage?
}

enum PanelTabBrands {
    static func brand(for tab: QuotaTabID) -> PanelTabBrand {
        switch tab {
        case .codex:
            return PanelTabBrand(
                gradientTop: NSColor(hex: 0x3C3C42),
                gradientBottom: NSColor(hex: 0x232327),
                iconColor: NSColor(hex: 0xE8E8EC),
                logo: PanelLogos.codex
            )
        case .zai:
            return PanelTabBrand(
                gradientTop: NSColor(hex: 0x2C2C31),
                gradientBottom: NSColor(hex: 0x191A1E),
                iconColor: .white,
                logo: PanelLogos.zai
            )
        case .deepSeek:
            return PanelTabBrand(
                gradientTop: NSColor(hex: 0x243B32),
                gradientBottom: NSColor(hex: 0x16241E),
                iconColor: NSColor(hex: 0x7DD8A8),
                logo: PanelLogos.deepSeek
            )
        case .codeBuddy:
            return PanelTabBrand(
                gradientTop: NSColor(hex: 0x2F4A6E),
                gradientBottom: NSColor(hex: 0x1C2C44),
                iconColor: NSColor(hex: 0x7FB3FF),
                logo: PanelLogos.codeBuddy
            )
        }
    }
}

/// 单个 tab：36pt 进度环 + 内嵌 logo（tag / 状态点叠加）+ 下方百分比文字。
/// 以 NSButton 承载点击，背景按 active / hover 状态在 draw(_:) 里手绘。
final class PanelTabItemView: NSButton {
    let tab: QuotaTabID
    var onSelection: ((QuotaTabID) -> Void)?

    private let ringView = NSView()
    private let ringTrackLayer = CAShapeLayer()
    /// 环填充层（internal：测试读取 strokeEnd 校验口径）。
    let ringFillLayer = CAShapeLayer()
    private let logoContainer = NSView()
    private let logoImageView = NSImageView()
    private let tagLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let valueLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isActive = false

    init(tab: QuotaTabID) {
        self.tab = tab
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("quota-tab.\(tab.rawValue)")
        target = self
        action = #selector(tapped)

        // 进度环：track 固定满圆，fill 用 strokeEnd 表示剩余比例，起点在正上方。
        ringView.wantsLayer = true
        ringView.translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = 1.25
        let side: CGFloat = 36
        let radius = (side - inset * 2 - 2.5) / 2 + inset
        let path = CGPath(
            ellipseIn: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
            transform: nil
        )
        // 以中心为圆心重新构造半径路径，避免 stroke 出界
        let center = CGPoint(x: side / 2, y: side / 2)
        let ringPath = CGPath(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
        ringTrackLayer.path = ringPath
        ringTrackLayer.fillColor = nil
        ringTrackLayer.strokeColor = PanelTheme.trackColor.cgColor
        ringTrackLayer.lineWidth = 2.5
        ringView.layer?.addSublayer(ringTrackLayer)

        ringFillLayer.path = ringPath
        ringFillLayer.fillColor = nil
        ringFillLayer.strokeColor = PanelTheme.green.cgColor
        ringFillLayer.lineWidth = 2.5
        ringFillLayer.lineCap = .round
        ringFillLayer.strokeEnd = 0
        ringFillLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        ringFillLayer.transform = CATransform3DMakeRotation(-Double.pi / 2, 0, 0, 1)
        ringView.layer?.addSublayer(ringFillLayer)
        ringView.layer?.masksToBounds = false

        // logo 圆底（品牌渐变）+ 图标
        let brand = PanelTabBrands.brand(for: tab)
        logoContainer.wantsLayer = true
        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        let gradient = CAGradientLayer()
        gradient.colors = [brand.gradientTop.cgColor, brand.gradientBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.15, y: 1)
        gradient.endPoint = CGPoint(x: 0.85, y: 0)
        logoContainer.layer?.addSublayer(gradient)
        logoContainer.layer?.cornerRadius = 12.5
        logoContainer.layer?.borderWidth = 1
        logoContainer.layer?.borderColor = PanelTheme.hairline.cgColor

        logoImageView.image = brand.logo
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.contentTintColor = brand.iconColor
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoImageView)

        // 套餐 tag：叠在 logo 右上角
        tagLabel.font = .systemFont(ofSize: 7, weight: .bold)
        tagLabel.textColor = NSColor(hex: 0x6DB8FF)
        tagLabel.translatesAutoresizingMaskIntoConstraints = false

        // 状态点：logo 右下角，绿=正常 / 红=失败，外圈描面板底色避免与环境混色
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = PanelTheme.green.cgColor
        statusDot.layer?.cornerRadius = 3.25
        statusDot.layer?.borderWidth = 1.5
        statusDot.layer?.borderColor = PanelTheme.panelBackground.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        valueLabel.textColor = PanelTheme.secondaryText
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(ringView)
        addSubview(logoContainer)
        addSubview(tagLabel)
        addSubview(statusDot)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            ringView.widthAnchor.constraint(equalToConstant: side),
            ringView.heightAnchor.constraint(equalToConstant: side),
            ringView.centerXAnchor.constraint(equalTo: centerXAnchor),
            ringView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            logoContainer.widthAnchor.constraint(equalToConstant: 25),
            logoContainer.heightAnchor.constraint(equalToConstant: 25),
            logoContainer.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
            logoContainer.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 13.5),
            logoImageView.heightAnchor.constraint(equalToConstant: 13.5),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 3),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        // tag 与状态点允许越出环的边界（z 轴叠在上面），只锚定 logo 容器。
        NSLayoutConstraint.activate([
            tagLabel.bottomAnchor.constraint(equalTo: logoContainer.topAnchor, constant: 4),
            tagLabel.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: 7),
            statusDot.widthAnchor.constraint(equalToConstant: 6.5),
            statusDot.heightAnchor.constraint(equalToConstant: 6.5),
            statusDot.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: 2.5),
            statusDot.bottomAnchor.constraint(equalTo: logoContainer.bottomAnchor, constant: 2.5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        isActive = active
        needsDisplay = true
    }

    func configure(_ status: PanelTabStatus) {
        ringFillLayer.strokeEnd = CGFloat(status.ringFraction ?? 0)
        ringFillLayer.strokeColor = status.ringColor.cgColor
        valueLabel.stringValue = status.valueText
        valueLabel.textColor = status.valueColor
        tagLabel.stringValue = status.tagText ?? ""
        tagLabel.isHidden = status.tagText?.isEmpty != false
        statusDot.layer?.backgroundColor = (status.isFailed ? PanelTheme.red : PanelTheme.green).cgColor
        statusDot.isHidden = false

        var tooltip = status.titleOverride ?? tab.displayName
        if let tagText = status.tagText, !tagText.isEmpty {
            tooltip += " · \(tagText)"
        }
        if let summary = status.summary, !summary.isEmpty {
            tooltip += "\n\(summary)"
        }
        toolTip = tooltip
    }

    override func draw(_ dirtyRect: NSRect) {
        // active / hover 背景：圆角浅白填充（对齐 .tab-item.active / :hover）
        if isActive || isHovered {
            let alpha: CGFloat = isActive ? 0.08 : 0.04
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self
            ))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    @objc private func tapped() {
        onSelection?(tab)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 52, height: 36 + 3 + 12 + 9)
    }
}

/// Tab 栏容器：横向排列所有 tab，底部 1px 分隔线；超出宽度时横向滚动。
final class PanelTabBarView: NSView {
    var onSelectionChange: ((QuotaTabID) -> Void)?

    private let items: [QuotaTabID: PanelTabItemView]
    private let stack = NSStackView()
    private var activeTab: QuotaTabID = .codex

    init() {
        var items: [QuotaTabID: PanelTabItemView] = [:]
        for id in QuotaTabID.allCases {
            items[id] = PanelTabItemView(tab: id)
        }
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for id in QuotaTabID.allCases {
            items[id]!.onSelection = { [weak self] tab in
                self?.select(tab, notify: true)
            }
        }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for id in QuotaTabID.allCases {
            stack.addArrangedSubview(items[id]!)
        }

        // 底部分隔线（tabs.html .tabbar border-bottom）
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = PanelTheme.dividerColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(divider)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])

        select(.codex, notify: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 汇总入口：更新各 tab 的环 / 文案 / 状态点与显隐。
    func configure(statuses: [QuotaTabID: PanelTabStatus], visible: Set<QuotaTabID>) {
        for (id, item) in items {
            let isVisible = visible.contains(id)
            item.isHidden = !isVisible
            if let status = statuses[id] {
                item.configure(status)
            } else {
                item.configure(PanelTabStatus())
            }
        }
    }

    var active: QuotaTabID { activeTab }

    /// 切换 active tab；外部调用同样生效（如隐藏当前 tab 后回退到 codex）。
    func select(_ tab: QuotaTabID, notify: Bool) {
        activeTab = tab
        for (id, item) in items {
            item.setActive(id == tab)
        }
        if notify {
            onSelectionChange?(tab)
        }
    }
}
