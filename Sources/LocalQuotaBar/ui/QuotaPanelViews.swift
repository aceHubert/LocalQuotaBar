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

    static let deepSeek: NSImage? = makeLogo("""
    <svg fill="#000000" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M23.748 4.482c-.254-.124-.364.113-.512.234-.051.039-.094.09-.137.136-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.156-.708-.311-.955-.65-.172-.241-.219-.51-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.093.172.187.129.323-.082.28-.18.552-.266.833-.055.179-.137.217-.329.14a5.526 5.526 0 01-1.736-1.18c-.857-.828-1.631-1.742-2.597-2.458a11.365 11.365 0 00-.689-.471c-.985-.957.13-1.743.388-1.836.27-.098.093-.432-.779-.428-.872.004-1.67.295-2.687.684a3.055 3.055 0 01-.465.137 9.597 9.597 0 00-2.883-.102c-1.885.21-3.39 1.102-4.497 2.623C.082 8.606-.231 10.684.152 12.85c.403 2.284 1.569 4.175 3.36 5.653 1.858 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.133-.284 4.994-1.86.47.234.962.327 1.78.397.63.059 1.236-.03 1.705-.128.735-.156.684-.837.419-.961-2.155-1.004-1.682-.595-2.113-.926 1.096-1.296 2.746-2.642 3.392-7.003.05-.347.007-.565 0-.845-.004-.17.035-.237.23-.256a4.173 4.173 0 001.545-.475c1.396-.763 1.96-2.015 2.093-3.517.02-.23-.004-.467-.247-.588zM11.581 18c-2.089-1.642-3.102-2.183-3.52-2.16-.392.024-.321.471-.235.763.09.288.207.486.371.739.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.167-1.361-.802-2.5-1.86-3.301-3.307-.774-1.393-1.224-2.887-1.298-4.482-.02-.386.093-.522.477-.592a4.696 4.696 0 011.529-.039c2.132.312 3.946 1.265 5.468 2.774.868.86 1.525 1.887 2.202 2.891.72 1.066 1.494 2.082 2.48 2.914.348.292.625.514.891.677-.802.09-2.14.11-3.054-.614zm1-6.44a.306.306 0 01.415-.287.302.302 0 01.2.288.306.306 0 01-.31.307.303.303 0 01-.304-.308zm3.11 1.596c-.2.081-.399.151-.59.16a1.245 1.245 0 01-.798-.254c-.274-.23-.47-.358-.552-.758a1.73 1.73 0 01.016-.588c.07-.327-.008-.537-.239-.727-.187-.156-.426-.199-.688-.199a.559.559 0 01-.254-.078c-.11-.054-.2-.19-.114-.358.028-.054.16-.186.192-.21.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.391.451.462.576.685.914.176.265.336.537.445.848.067.195-.019.354-.25.452z"></path></svg>
    """)

    static let codeBuddy: NSImage? = makeLogo("""
    <svg fill="#000000" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M18.777 1.647c.28-.02.536.114.972.51 1.018.926 2.437 2.828 3.318 4.452l.34.631.482.24.11.06v3.638a5.206 5.206 0 00-5.32-1.23c-.491.166-1.021.471-2.08 1.082l-6.09 3.516c-1.057.61-1.586.916-1.975 1.259a5.208 5.208 0 00-1.493 5.572c.165.49.471 1.02 1.082 2.08l.315.543h-3.26c-.685 0-1.34-.135-1.939-.377-.169-.956-.009-1.789.469-2.335.158-.18.164-.189.13-.493a11.846 11.846 0 01-.057-1.711l.02-.444-.667-1.18C2.1 15.622 1.445 14.078 1.192 12.9c-.133-.647-.125-.934.04-1.146.1-.128.427-.261.822-.334.994-.175 3.162-.017 5.575.41l.25.043.551-.487c.915-.81 1.522-1.264 2.641-1.962 1.167-.73 2.484-1.331 3.967-1.807l.476-.152.261-.688c.937-2.471 1.896-4.293 2.58-4.9.235-.21.25-.22.422-.23z"></path><path d="M12.139 18.2a1.203 1.203 0 011.642.44l1.296 2.243a1.204 1.204 0 01-2.083 1.203l-1.296-2.243a1.203 1.203 0 01.44-1.644zM18.629 14.452a1.203 1.203 0 011.642.44l1.295 2.244a1.204 1.204 0 11-2.083 1.203l-1.295-2.243a1.203 1.203 0 01.44-1.644z"></path></svg>
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

/// provider 面板头部（slim 版，tabs.html 定稿）：provider 身份（logo / 名称 / tag / 刷新按钮）
/// 已上移到 Tab 栏，这里只保留右侧刷新状态与失败时的错误文案；冷却状态也在此承载。
final class ProviderHeaderView: NSView {
    enum StatusKind {
        case ok
        case bad
        case idle
    }

    struct State {
        var statusText: String
        var statusKind: StatusKind
        /// 失败时的错误文案（单行省略，tooltip 给全文）。
        var errorText: String? = nil
        var errorTooltip: String? = nil
    }

    private let errorLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDotMini = NSView()
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 9, weight: .regular)
        errorLabel.textColor = PanelTheme.tertiaryText
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.maximumNumberOfLines = 1
        errorLabel.cell?.truncatesLastVisibleLine = true
        errorLabel.cell?.wraps = false
        errorLabel.isHidden = true
        // 主拉伸位：错误文案吃掉富余宽度，把状态时间推到右侧（.p-errmsg flex:1）
        errorLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        statusLabel.textColor = PanelTheme.tertiaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.wraps = false
        statusLabel.setContentHuggingPriority(.init(751), for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.init(751), for: .horizontal)

        statusDotMini.wantsLayer = true
        statusDotMini.layer?.backgroundColor = PanelTheme.green.cgColor
        statusDotMini.layer?.cornerRadius = 2.5
        statusDotMini.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSStackView(views: [statusDotMini, statusLabel])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 4

        // 兜底拉伸位：错误文案隐藏（正常态）时由它吃掉富余宽度，时间保持靠右
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(2), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let content = NSStackView(views: [errorLabel, spacer, statusLine])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            statusDotMini.widthAnchor.constraint(equalToConstant: 5),
            statusDotMini.heightAnchor.constraint(equalToConstant: 5),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ state: State) {
        let hasError = !(state.errorText ?? "").isEmpty
        errorLabel.stringValue = state.errorText ?? ""
        errorLabel.isHidden = !hasError
        errorLabel.toolTip = state.errorTooltip ?? state.errorText

        statusLabel.stringValue = state.statusText
        statusLabel.toolTip = state.statusText
        statusDotMini.isHidden = state.statusText.isEmpty
        switch state.statusKind {
        case .ok:
            statusLabel.textColor = PanelTheme.tertiaryText
            statusDotMini.layer?.backgroundColor = PanelTheme.green.cgColor
        case .bad:
            statusLabel.textColor = NSColor(hex: 0xFF8D84)
            statusDotMini.layer?.backgroundColor = PanelTheme.red.cgColor
        case .idle:
            statusLabel.textColor = PanelTheme.tertiaryText
            statusDotMini.layer?.backgroundColor = PanelTheme.tertiaryText.cgColor
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

    /// 余额刷新是否可用（API Key 模式为 false；测试与外部状态读取用）。
    var isRefreshAvailable: Bool { refreshAvailable }

    func setRefreshAvailable(_ available: Bool) {
        refreshAvailable = available
        notifyAvailabilityChange()
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
        notifyAvailabilityChange()
    }

    private var isInRefreshCooldown: Bool {
        refreshAllowedAt.map { now() < $0 } ?? false
    }

    private func notifyAvailabilityChange() {
        onRefreshAvailabilityChange?()
    }

    /// 所有手动入口共用 60 秒防重；跳过请求不延长冷却。API Key 可仅刷新每日用量。
    @discardableResult
    func beginRefreshCooldown(allowUsageOnly: Bool = false) -> Bool {
        guard refreshAvailable || allowUsageOnly, !isRefreshing, !isInRefreshCooldown else { return false }
        refreshAllowedAt = now().addingTimeInterval(60)
        notifyAvailabilityChange()
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cooldownTimer = nil
                self.notifyAvailabilityChange()
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
        /// 明细行主文案（CodeBuddy 积分包："100 积分 · 剩 100"）；nil 时沿用到期时间文案。
        var detailText: String? = nil
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

        let timeLabel = NSTextField(labelWithString: item.detailText ?? PanelTheme.formatCardExpiry(item.expiresAt))
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
