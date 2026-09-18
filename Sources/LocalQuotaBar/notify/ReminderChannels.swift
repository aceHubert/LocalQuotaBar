import AppKit

// MARK: - 提醒投递通道

/// 一次待投递的提醒内容；headline / detail 已按源聚合好。
struct ReminderAlert {
    let source: ReminderBucket.Source
    let presentation: ReminderPresentation
    /// 主文案，如 "Codex 5小时 仅剩 8%" / "ZAI 周额度 20分钟后重置"。
    let headline: String
    /// 同源其他受影响桶的摘要，逗号分隔。
    let detail: String?
    /// Touch Bar 额度条视图需要完整快照；仅 Codex 源非 nil。
    let codexSnapshot: QuotaSnapshot?

    var emoji: String {
        presentation.emoji
    }
}

@MainActor
protocol ReminderAlertChannel: AnyObject {
    var isAvailable: Bool { get }
    /// 点击"不再提醒"时回调：让该提醒本轮不再出现，并按 evaluator 的 muteCurrent 逻辑
    /// 把所有活跃桶静音到各自重置时刻。
    var onMute: (() -> Void)? { get set }
    /// 点击卡片打开主面板。
    var onOpenPanel: (() -> Void)? { get set }
    func deliver(_ alert: ReminderAlert)
    func retract()
}

/// 提醒能力：设置区显示与通道选择共用的硬件判断。
enum ReminderCapability {
    static var hasAnyChannel: Bool {
        TouchBarCapability.hasTouchBar || NotchCapability.hasNotch
    }
}

// MARK: - System modal Touch Bar (private API, runtime-checked)

@MainActor
enum SystemModalTouchBar {
    private static let presentSelectorNames = [
        "presentSystemModalTouchBar:systemTrayItemIdentifier:",
        "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
    ]
    private static let dismissSelectorNames = [
        "dismissSystemModalTouchBar:",
        "dismissSystemModalFunctionBar:"
    ]

    static var isSupported: Bool {
        firstClassMethod(named: presentSelectorNames) != nil
            && firstClassMethod(named: dismissSelectorNames) != nil
    }

    static func present(_ touchBar: NSTouchBar) {
        guard let (selector, method) = firstClassMethod(named: presentSelectorNames) else { return }
        typealias PresentIMP = @convention(c) (AnyObject, Selector, NSTouchBar, AnyObject?) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: PresentIMP.self)
        imp(NSTouchBar.self, selector, touchBar, nil)
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let (selector, method) = firstClassMethod(named: dismissSelectorNames) else { return }
        typealias DismissIMP = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: DismissIMP.self)
        imp(NSTouchBar.self, selector, touchBar)
    }

    private static func firstClassMethod(named selectorNames: [String]) -> (Selector, Method)? {
        for name in selectorNames {
            let selector = NSSelectorFromString(name)
            if let method = class_getClassMethod(NSTouchBar.self, selector) {
                return (selector, method)
            }
        }
        return nil
    }
}

// MARK: - Touch Bar 通道

/// Touch Bar 弹出提醒：Codex 用额度条视图，ZAI 等其他源用文本视图。
@MainActor
final class TouchBarAlertChannel: NSObject, ReminderAlertChannel, NSTouchBarDelegate {
    static let displayDuration: TimeInterval = 12

    var onMute: (() -> Void)?
    /// Touch Bar 不支持点击打开主面板（无回调通道），保留协议位。
    var onOpenPanel: (() -> Void)?

    private let quotaView = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 370, height: 30))
    private let textAlertView = TouchBarTextAlertView(frame: NSRect(x: 0, y: 0, width: 370, height: 30))
    private lazy var containerView: NSView = {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 30))
        return view
    }()
    private lazy var touchBar: NSTouchBar = {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.quotaPanel]
        return bar
    }()
    private var dismissTimer: Timer?
    private(set) var isPresenting = false

    override init() {
        super.init()
        quotaView.onMuteReminder = { [weak self] in
            self?.onMute?()
        }
        textAlertView.onMuteReminder = { [weak self] in
            self?.onMute?()
        }
        textAlertView.onClose = { [weak self] in
            self?.retract()
        }
    }

    var isAvailable: Bool {
        TouchBarCapability.hasTouchBar && SystemModalTouchBar.isSupported
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .quotaPanel else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.customizationLabel = "Codex 余额"
        item.view = containerView
        return item
    }

    func deliver(_ alert: ReminderAlert) {
        let content: NSView
        if let snapshot = alert.codexSnapshot {
            quotaView.update(snapshot: snapshot, reminder: alert.presentation)
            content = quotaView
        } else {
            textAlertView.update(alert: alert)
            content = textAlertView
        }

        if content.superview !== containerView {
            containerView.subviews.forEach { $0.removeFromSuperview() }
            content.frame = containerView.bounds
            content.autoresizingMask = [.width, .height]
            containerView.addSubview(content)
        }

        if !isPresenting {
            SystemModalTouchBar.present(touchBar)
            isPresenting = true
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retract()
            }
        }
    }

    func retract() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard isPresenting else { return }
        isPresenting = false
        SystemModalTouchBar.dismiss(touchBar)
    }
}

/// Touch Bar 上的通用文本提醒视图（ZAI 等没有额度条数据的源）。
final class TouchBarTextAlertView: NSView {
    var onMuteReminder: (() -> Void)?
    /// 只收起提醒条，不静音。
    var onClose: (() -> Void)?

    private let emojiLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton(title: "不再提醒", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        update(alert: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(alert: ReminderAlert?) {
        emojiLabel.stringValue = alert?.emoji ?? ""
        textLabel.stringValue = alert?.headline ?? ""
        let detail = (alert?.detail ?? "").isEmpty ? nil : alert?.detail
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        muteButton.isEnabled = alert != nil
        closeButton.isEnabled = alert != nil
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        emojiLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emojiLabel.alignment = .center
        emojiLabel.lineBreakMode = .byClipping
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        muteButton.bezelStyle = .rounded
        muteButton.font = .systemFont(ofSize: 10, weight: .medium)
        muteButton.target = self
        muteButton.action = #selector(muteReminderTapped)
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .rounded
        closeButton.font = .systemFont(ofSize: 10, weight: .medium)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [emojiLabel, textLabel, detailLabel, muteButton, closeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            emojiLabel.widthAnchor.constraint(equalToConstant: 22),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 60),
            muteButton.widthAnchor.constraint(equalToConstant: 66),
            closeButton.widthAnchor.constraint(equalToConstant: 46)
        ])
    }

    @objc private func muteReminderTapped() {
        onMuteReminder?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

// MARK: - 刘海屏能力与通道

enum NotchCapability {
    /// 内置刘海屏：有左右辅助区（菜单栏被刘海分开）即视为刘海屏。
    static var notchScreen: NSScreen? {
        NSScreen.screens.first { screen in
            screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        }
    }

    static var hasNotch: Bool {
        notchScreen != nil
    }

    /// 刘海矩形（全局屏幕坐标，动画起点）。
    /// 注：macOS 26 的系统灵动岛（iPhone 镜像 Live Activities）覆盖刘海区域且第三方无法在其上层显示
    /// （ActivityKit 对 macOS 全量 unavailable），所以提醒卡片挂在菜单栏下方。
    static func notchRect(on screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.height > 0, right.minX > left.maxX
        else { return nil }
        return NSRect(
            x: left.maxX,
            y: screen.frame.maxY - left.height,
            width: right.minX - left.maxX,
            height: left.height
        )
    }

    /// 提醒卡片矩形：以刘海为中心向左右加宽、紧贴菜单栏下沿，视觉上是灵动岛向下展开。
    static func cardRect(on screen: NSScreen) -> NSRect? {
        guard let notch = notchRect(on: screen) else { return nil }
        let width = notch.width + 132
        let height: CGFloat = 78
        let centerX = notch.midX
        return NSRect(
            x: centerX - width / 2,
            y: screen.frame.maxY - notch.height - height,
            width: width,
            height: height
        )
    }
}

/// 岛式提醒卡片窗口：黑色圆角矩形，贴刘海下沿弹出。
@MainActor
final class NotchAlertPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 317, height: 78),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
}

/// 岛式卡片的一行额度：标题 + 10 段电量条 + 百分比 + 重置时间（白字适配黑底）。
final class NotchCardQuotaRow: NSView {
    private let titleLabel: NSTextField
    private let barView = SegmentedBatteryBarView(segmentCount: 10)
    private let percentLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(bucket: QuotaBucket?) {
        guard let bucket else {
            barView.percent = 0
            percentLabel.stringValue = "--%"
            resetLabel.stringValue = "--"
            return
        }

        titleLabel.stringValue = bucket.shortTitle
        barView.percent = bucket.remainingPercent
        percentLabel.stringValue = "\(bucket.roundedRemainingPercent)%"
        resetLabel.stringValue = formatCompactReset(bucket.resetsAt)
    }

    private func setup() {
        titleLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentLabel.textColor = .white
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        resetLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        resetLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        resetLabel.alignment = .right
        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        barView.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [titleLabel, barView, percentLabel, resetLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 16),
            titleLabel.widthAnchor.constraint(equalToConstant: 26),
            percentLabel.widthAnchor.constraint(equalToConstant: 34),
            resetLabel.widthAnchor.constraint(equalToConstant: 46),
            barView.heightAnchor.constraint(equalToConstant: 7)
        ])
    }
}

/// 刘海下沿的岛式提醒卡片：emoji + 真实 headline + Codex 电量条，点击打开主面板。
@MainActor
final class NotchAlertContentView: NSView {
    var onClick: (() -> Void)?

    private let emojiLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let fiveHourRow = NotchCardQuotaRow(title: "5H")
    private let weeklyRow = NotchCardQuotaRow(title: "W")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 岛式大圆角矩形，不是全圆药丸。
        layer?.cornerRadius = 20
    }

    func update(alert: ReminderAlert) {
        emojiLabel.stringValue = alert.emoji
        textLabel.stringValue = alert.headline
        detailLabel.stringValue = alert.detail ?? ""
        detailLabel.isHidden = (alert.detail ?? "").isEmpty

        if let snapshot = alert.codexSnapshot {
            fiveHourRow.update(bucket: snapshot.fiveHour)
            weeklyRow.update(bucket: snapshot.weekly)
            fiveHourRow.isHidden = false
            weeklyRow.isHidden = false
        } else {
            fiveHourRow.isHidden = true
            weeklyRow.isHidden = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        emojiLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        emojiLabel.alignment = .center
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 12, weight: .bold)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [emojiLabel, textLabel, NSView(), detailLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [fiveHourRow, weeklyRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        rows.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, rows])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            emojiLabel.widthAnchor.constraint(equalToConstant: 19),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            fiveHourRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            weeklyRow.widthAnchor.constraint(equalTo: rows.widthAnchor)
        ])
    }
}

/// 刘海屏提醒通道：卡片从刘海展开、贴菜单栏下沿，12 秒自动收起，新提醒替换旧的。
@MainActor
final class NotchAlertChannel: ReminderAlertChannel {
    static let displayDuration: TimeInterval = 12

    /// 点击卡片时打开主面板。
    var onOpenPanel: (() -> Void)?
    /// 点击"不再提醒"时回调。
    var onMute: (() -> Void)?

    private let panel = NotchAlertPanel()
    private let contentView = NotchAlertContentView(frame: NSRect(x: 0, y: 0, width: 317, height: 78))
    private var dismissTimer: Timer?
    private(set) var isPresenting = false

    init() {
        panel.contentView = contentView
        contentView.onClick = { [weak self] in
            self?.onOpenPanel?()
        }
    }

    var isAvailable: Bool {
        NotchCapability.hasNotch
    }

    func deliver(_ alert: ReminderAlert) {
        guard let screen = NotchCapability.notchScreen,
              let rect = NotchCapability.cardRect(on: screen)
        else { return }

        contentView.update(alert: alert)
        contentView.frame = NSRect(origin: .zero, size: rect.size)

        // 从刘海矩形展开成卡片，模仿灵动岛展开动效。
        let startRect = NotchCapability.notchRect(on: screen) ?? rect
        panel.alphaValue = 0
        panel.setFrame(startRect, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rect, display: true)
            panel.animator().alphaValue = 1
        })
        isPresenting = true

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retract()
            }
        }
    }

    func retract() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard isPresenting else { return }
        isPresenting = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}
