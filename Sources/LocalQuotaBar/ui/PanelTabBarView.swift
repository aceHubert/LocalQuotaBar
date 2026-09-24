import AppKit
import Foundation

// MARK: - 面板横向 Tab 栏（tabs.html 定稿：logo 圆环弧长＝剩余额度，下方百分比）

/// Tab 标识；枚举顺序即展示顺序，默认 active 为 codex。
enum QuotaTabID: String, CaseIterable {
    case codex
    case zai
    case deepSeek
    case codeBuddy
    /// CodeBuddy 国内版（www.codebuddy.cn），与国际版为不同登录态。
    case codeBuddyCN

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .zai: return "Z.AI"
        case .deepSeek: return "DeepSeek"
        case .codeBuddy: return "CodeBuddy"
        case .codeBuddyCN: return "CodeBuddy"
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
    /// 无快照且无错误（首次刷新未完成）：状态点置灰、不呼吸（与头部 mini 点口径一致）。
    var isIdle: Bool = false
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
        // 非百分比口径（DeepSeek 余额金额）：白色主文字
        return PanelTheme.primaryText
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
        case .codeBuddyCN:
            // 同品牌 logo；靠角标 CN 区分
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
    private let brandGradient = CAGradientLayer()
    private let logoImageView = NSImageView()
    /// 套餐 tag 胶囊徽章（.tab-tag：蓝字 + 深蓝底 + 描边），internal 供测试。
    let tagBadge = NSView()
    private let tagLabel = NSTextField(labelWithString: "")
    /// 状态点（绿/红 + 同色光晕），internal 供测试。
    let statusDot = PanelStatusDotView()
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

        // logo 圆底：品牌渐变背景填充，无边框（.tab-logo）
        let brand = PanelTabBrands.brand(for: tab)
        logoContainer.wantsLayer = true
        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        brandGradient.colors = [brand.gradientTop.cgColor, brand.gradientBottom.cgColor]
        brandGradient.startPoint = CGPoint(x: 0.15, y: 1)
        brandGradient.endPoint = CGPoint(x: 0.85, y: 0)
        logoContainer.layer?.addSublayer(brandGradient)
        logoContainer.layer?.cornerRadius = 12.5
        logoContainer.layer?.masksToBounds = true

        logoImageView.image = brand.logo
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.contentTintColor = brand.iconColor
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoImageView)

        // 套餐 tag：胶囊徽章叠在 logo 右上角（对齐 .tab-tag 底色与描边）
        tagBadge.wantsLayer = true
        tagBadge.translatesAutoresizingMaskIntoConstraints = false
        tagBadge.layer?.cornerRadius = 6
        tagBadge.layer?.backgroundColor = NSColor(hex: 0x232936).cgColor
        tagBadge.layer?.borderWidth = 1
        tagBadge.layer?.borderColor = NSColor(hex: 0x5AA0FF, alpha: 0.32).cgColor

        tagLabel.font = .systemFont(ofSize: 7, weight: .bold)
        tagLabel.textColor = NSColor(hex: 0x6DB8FF)
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagBadge.addSubview(tagLabel)

        // 状态点：logo 右下角，绿=正常 / 红=失败；光晕在 PanelStatusDotView.draw 里自绘
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        valueLabel.textColor = PanelTheme.secondaryText
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(ringView)
        addSubview(logoContainer)
        addSubview(tagBadge)
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
            // 设计稿 .tab-tag（top:-5px / right:-13px）：徽章叠在 logo 右上角上
            tagBadge.topAnchor.constraint(equalTo: logoContainer.topAnchor, constant: -5),
            tagBadge.leadingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: -8),
            tagBadge.heightAnchor.constraint(equalTo: tagLabel.heightAnchor, constant: 2),
            tagLabel.leadingAnchor.constraint(equalTo: tagBadge.leadingAnchor, constant: 3.5),
            tagLabel.trailingAnchor.constraint(equalTo: tagBadge.trailingAnchor, constant: -3.5),
            tagLabel.centerYAnchor.constraint(equalTo: tagBadge.centerYAnchor),
            // 画布 12pt 给光晕留绘制空间；点本体 6.5pt 居中，中心位置与原 6.5pt 视图一致
            statusDot.widthAnchor.constraint(equalToConstant: 12),
            statusDot.heightAnchor.constraint(equalToConstant: 12),
            statusDot.centerXAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: -0.75),
            statusDot.centerYAnchor.constraint(equalTo: logoContainer.bottomAnchor, constant: 0.75)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 渐变层不是视图管理的 layer，需在布局时手动铺满圆底
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        brandGradient.frame = logoContainer.bounds
        CATransaction.commit()
    }

    func setActive(_ active: Bool) {
        isActive = active
        needsDisplay = true
        // 液态玻璃外投影（0 4px 14px rgba(0,0,0,0.35)）：走 layer shadow，仅 active 时可见
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = active ? 0.35 : 0
        layer?.shadowRadius = 7
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        layer?.masksToBounds = false
    }

    func configure(_ status: PanelTabStatus) {
        ringFillLayer.strokeEnd = CGFloat(status.ringFraction ?? 0)
        ringFillLayer.strokeColor = status.ringColor.cgColor
        valueLabel.stringValue = status.valueText
        valueLabel.textColor = status.valueColor
        tagLabel.stringValue = status.tagText ?? ""
        tagBadge.isHidden = status.tagText?.isEmpty != false
        statusDot.isIdle = status.isIdle
        statusDot.dotColor = status.isIdle
            ? PanelTheme.tertiaryText
            : (status.isFailed ? PanelTheme.red : PanelTheme.green)
        statusDot.isHidden = false

        var tooltip = status.titleOverride ?? tab.displayName
        // 角标文本已包含在名称末尾时（如 CodeBuddy CN · CN）不重复拼接
        if let tagText = status.tagText, !tagText.isEmpty, !tooltip.hasSuffix(tagText) {
            tooltip += " · \(tagText)"
        }
        if let summary = status.summary, !summary.isEmpty {
            tooltip += "\n\(summary)"
        }
        toolTip = tooltip
    }

    override func draw(_ dirtyRect: NSRect) {
        // layer 因投影而 masksToBounds=false：光晕/渐变必须显式裁剪在 bounds 内，
        // 否则会溢出到整个弹窗（外投影不受影响，它由 layer shadow 独立渲染）
        NSBezierPath(rect: bounds).addClip()
        let insetRect = bounds.insetBy(dx: 1, dy: 1)
        if isActive {
            drawLiquidGlassSelection(in: insetRect)
        } else if isHovered {
            NSColor.white.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: insetRect, xRadius: 11, yRadius: 11).fill()
        }
    }

    // MARK: 液态玻璃选中态（设计稿 .tab-item.active：炭黑底座 · 对角冷白光影 · 对角渐变描边）

    /// 对角（135°）炭黑渐变底座 + 角部对角微光（左上/右下）+ 顶部内高光 + 描边；
    /// 全部绘制先 clip 在圆角底内：高光条不刺出圆角，角部光晕不越界（外投影由 layer shadow 承担）。
    private func drawLiquidGlassSelection(in rect: NSRect) {
        let basePath = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSGraphicsContext.current?.saveGraphicsState()
        basePath.addClip()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        // ① 底：linear-gradient(135deg,#2a2a2f,#1a1a1c 48%,#141416)——左上亮、右下暗
        let base = NSGradient(colors: [
            NSColor(hex: 0x2A2A2F),
            NSColor(hex: 0x1A1A1C),
            NSColor(hex: 0x141416)
        ])
        base?.draw(in: basePath, angle: -45)

        // ② 对角冷白微光：只放在左上 / 右下两个角部（低峰值 + 60% 处衰减归零）
        let diagonal = hypot(bounds.width, bounds.height)
        drawCornerGlow(center: NSPoint(x: rect.minX, y: rect.maxY),
                       color: NSColor(hex: 0xE9F7FF), peakAlpha: 0.07, radius: diagonal * 0.4)
        drawCornerGlow(center: NSPoint(x: rect.maxX, y: rect.minY),
                       color: NSColor(hex: 0xC5E9FF), peakAlpha: 0.05, radius: diagonal * 0.4)

        // 顶部 1px 内高光（clip 内沿圆角，不刺出）
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()

        // ③ 描边：均匀低透明度（clip 内只显示内半，圆角处干净）
        NSColor(hex: 0xF4FCFF).withAlphaComponent(0.16).setStroke()
        basePath.lineWidth = 1
        basePath.stroke()
    }

    /// 角部径向微光：peak 在圆心，60% 处即衰减归零（避免小面积上形成可见亮斑）。
    private func drawCornerGlow(center: NSPoint, color: NSColor, peakAlpha: CGFloat, radius: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let glow = NSGradient(colors: [
            color.withAlphaComponent(peakAlpha),
            color.withAlphaComponent(peakAlpha * 0.12),
            color.withAlphaComponent(0)
        ])
        glow?.draw(in: path, relativeCenterPosition: CGPoint(x: 0.5, y: 0.5))
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


/// 状态点：实心圆 + 同色光晕（设计稿 .status-dot 的 box-shadow: 0 0 5px 70%）。
/// 光晕用径向渐变环带实现：NSShadow 观感偏弱且易被描边/裁剪吃掉，径向渐变浓度可控。
/// 画布 20pt、点本体 6.5pt 居中，视图禁用边界裁剪。
final class PanelStatusDotView: NSView {
    var dotColor: NSColor = PanelTheme.green {
        didSet { needsDisplay = true }
    }

    /// idle（无快照无错误）：点体置灰且不做呼吸光晕，timer 停跑。
    var isIdle: Bool = false {
        didSet {
            needsDisplay = true
            syncPulse()
        }
    }

    private let dotDiameter: CGFloat
    private let glowRadius: CGFloat

    /// 呼吸相位（0...2π）；光晕强度随余弦在 0.3...1 间缓慢往返（周期 3.2s）。
    private var phase: CGFloat = 0
    private var pulseTimer: Timer?
    private static let pulseInterval: TimeInterval = 1.0 / 30
    private static let phaseStep = CGFloat(2 * Double.pi) * CGFloat(1.0 / 30) / 3.2

    /// - Parameters:
    ///   - dotDiameter: 点本体直径。
    ///   - glowRadius: 光晕衰减半径。
    init(dotDiameter: CGFloat = 6.5, glowRadius: CGFloat = 5) {
        self.dotDiameter = dotDiameter
        self.glowRadius = glowRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // AppKit layer 默认裁剪绘制内容，会把越出画布边界的光晕切掉
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 呼吸只在挂窗且可见时运行，避免后台空转。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPulse()
    }

    override var isHidden: Bool {
        didSet { syncPulse() }
    }

    /// 呼吸是否在跑（internal：测试断言 idle 停表）。
    var isBreathing: Bool { pulseTimer != nil }

    private func syncPulse() {
        let shouldRun = window != nil && !isHiddenOrHasHiddenAncestor && !isIdle
        if shouldRun, pulseTimer == nil {
            let timer = Timer(timeInterval: Self.pulseInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !shouldRun, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
        }
    }

    private func tick() {
        phase += Self.phaseStep
        if phase > 2 * .pi { phase -= 2 * .pi }
        needsDisplay = true
    }

    private var glowStrength: CGFloat {
        0.3 + 0.7 * (0.5 - 0.5 * cos(phase))
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius = dotDiameter / 2

        // 光晕：径向渐变，点缘向画布边缘衰减；强度随呼吸相位脉动（idle 不画）
        let strength: CGFloat = isIdle ? 0 : glowStrength
        let glowPath = NSBezierPath(ovalIn: NSRect(
            x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2))
        let glow = NSGradient(colors: [
            dotColor.withAlphaComponent(0.45 * strength),
            dotColor.withAlphaComponent(0.30 * strength),
            dotColor.withAlphaComponent(0.0)
        ])
        glow?.draw(in: glowPath, relativeCenterPosition: CGPoint(x: 0.5, y: 0.5))

        // 点本体 + 细分界描边
        let dotRect = NSRect(
            x: center.x - dotRadius, y: center.y - dotRadius, width: dotDiameter, height: dotDiameter)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        PanelTheme.panelBackground.setStroke()
        let borderPath = NSBezierPath(ovalIn: dotRect)
        borderPath.lineWidth = 1
        borderPath.stroke()
    }
}
