import AppKit
import Foundation

// MARK: - 设置页（settings-lite 原型）

/// 面板内设置页：通用（自动刷新）+ 低量提醒（开关、三项阈值下拉、恢复提醒、恢复默认）。
/// 写入走 QuotaViewController 既有回调链，与右键菜单共用一套持久化。
final class SettingsPageView: NSView {
    var onBack: (() -> Void)?
    var onReminderEnabledChange: ((Bool) -> Void)?
    var onWarningPercentChange: ((Int) -> Void)?
    var onResetSoonChange: ((Int) -> Void)?
    var onCooldownChange: ((Int) -> Void)?
    var onRefreshIntervalChange: ((Int) -> Void)?
    var onRestoreDefaults: (() -> Void)?
    var onUnmuteAll: (() -> Void)?

    private let refreshPopup = DarkPopUpButton()
    private let warningPopup = DarkPopUpButton()
    private let resetSoonPopup = DarkPopUpButton()
    private let cooldownPopup = DarkPopUpButton()
    private let reminderSwitch = PanelReminderSwitch()
    private let mutedLabel = NSTextField(labelWithString: "")
    private let restoreButton = PillButton(title: "恢复提醒", target: nil, action: nil)
    private let resetButton = PillButton(title: "重置", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // 顶部：返回 + 标题 + 版本
        let backButton = PanelIconButton(symbolName: "chevron.left", toolTipText: "返回额度面板", side: 22)
        backButton.onTap = { [weak self] in self?.onBack?() }

        let titleLabel = NSTextField(labelWithString: "设置")
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = PanelTheme.primaryText

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: "LocalQuotaBar \(version ?? "")")
        versionLabel.font = .systemFont(ofSize: 9, weight: .regular)
        versionLabel.textColor = PanelTheme.tertiaryText

        let versionSpacer = NSView()
        versionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topLine = NSStackView(views: [backButton, titleLabel, versionSpacer, versionLabel])
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 8

        // 通用
        refreshPopup.configure(
            options: RefreshSettings.availableMinutes.map { (title: "\($0) 分钟", value: $0) },
            onSelect: { [weak self] minutes in
                self?.onRefreshIntervalChange?(minutes)
            }
        )
        let generalSection = makeSection(
            icon: "slider.horizontal.3",
            title: "通用",
            rows: [makeRow(label: "自动刷新", tooltip: "后台自动刷新频率（Codex 与 Z.AI 共用）", control: refreshPopup)]
        )

        // 低量提醒
        PanelTheme.configureReminderSwitch(reminderSwitch)
        reminderSwitch.target = self
        reminderSwitch.action = #selector(switchChanged)

        warningPopup.configure(
            options: [50, 40, 30, 20, 10].map { (title: "\($0)%", value: $0) },
            onSelect: { [weak self] value in self?.onWarningPercentChange?(value) }
        )
        resetSoonPopup.configure(
            options: [50, 40, 30, 20, 10, 0].map { value in
                value == 0 ? (title: "关闭", value: 0) : (title: "\(value) 分钟", value: value)
            },
            onSelect: { [weak self] value in self?.onResetSoonChange?(value) }
        )
        cooldownPopup.configure(
            options: [5, 10, 15, 30, 60].map { (title: "\($0) 分钟", value: $0) },
            onSelect: { [weak self] value in self?.onCooldownChange?(value) }
        )

        let enabledRow = makeTitleRow(
            title: "主动提醒",
            subtitle: "任一额度触发提醒条件时通知（静音期内不重复）",
            control: reminderSwitch
        )
        let warningRow = makeRow(
            label: "额度低于",
            tooltip: "任一额度剩余低于该百分比时提醒",
            control: warningPopup
        )
        let resetSoonRow = makeRow(
            label: "重置还剩",
            tooltip: "重置倒计时短于该时间时提前提醒",
            control: resetSoonPopup
        )
        let cooldownRow = makeRow(
            label: "提醒间隔",
            tooltip: "两次提醒之间的最小间隔",
            control: cooldownPopup
        )

        restoreButton.font = .systemFont(ofSize: 9.5, weight: .semibold)
        restoreButton.bezelStyle = .regularSquare
        restoreButton.isBordered = false
        restoreButton.horizontalPadding = 16
        restoreButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)

        mutedLabel.font = .systemFont(ofSize: 10, weight: .regular)
        mutedLabel.textColor = PanelTheme.tertiaryText

        let mutedRow = makeTitleRow(
            title: "已静音提醒",
            subtitle: "",
            subtitleLabel: mutedLabel,
            control: restoreButton
        )

        resetButton.font = .systemFont(ofSize: 9.5, weight: .semibold)
        resetButton.bezelStyle = .regularSquare
        resetButton.isBordered = false
        resetButton.horizontalPadding = 16
        resetButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        resetButton.target = self
        resetButton.action = #selector(resetDefaultsTapped)
        let resetDefaultsRow = makeTitleRow(
            title: "恢复默认",
            subtitle: "恢复为默认：额度低于 20% · 重置还剩 30 分钟 · 提醒间隔 10 分钟",
            control: resetButton
        )

        let reminderSection = makeSection(
            icon: "bell",
            title: "低量提醒",
            rows: [enabledRow, warningRow, resetSoonRow, cooldownRow, mutedRow, resetDefaultsRow]
        )

        let stack = NSStackView(views: [topLine, generalSection, reminderSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(8, after: topLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            generalSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reminderSection.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        configure(reminder: .default, refreshMinutes: RefreshSettings.defaultIntervalMinutes, canRestore: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reminder: ReminderConfiguration, refreshMinutes: Int, canRestore: Bool) {
        isConfiguring = true
        reminderSwitch.state = reminder.isEnabled ? .on : .off
        refreshPopup.select(value: refreshMinutes)
        warningPopup.select(nearest: Int(reminder.warningRemainingPercent))
        resetSoonPopup.select(nearest: Int(reminder.resetSoonMinutes))
        cooldownPopup.select(nearest: Int(reminder.cooldown / 60))
        mutedLabel.stringValue = canRestore ? "有额度处于静音期" : "无"
        configureActionButton(resetButton, enabled: reminder != .default)
        configureActionButton(restoreButton, enabled: canRestore)
        isConfiguring = false
    }

    private func configureActionButton(_ button: PillButton, enabled: Bool) {
        button.isEnabled = enabled
        button.applyStyle(
            foreground: enabled ? PanelTheme.panelBackground : PanelTheme.tertiaryText,
            background: enabled ? PanelTheme.green : NSColor.white.withAlphaComponent(0.06),
            border: enabled ? PanelTheme.green : NSColor.white.withAlphaComponent(0.12)
        )
        // 共用胶囊样式会重设圆角，动态着色后仍保持设置页的小圆角。
        button.layer?.cornerRadius = 4
    }

    private var isConfiguring = false

    @objc private func switchChanged() {
        guard !isConfiguring else { return }
        onReminderEnabledChange?(reminderSwitch.state == .on)
    }

    @objc private func restoreTapped() {
        guard !isConfiguring, restoreButton.isEnabled else { return }
        onUnmuteAll?()
    }

    @objc private func resetDefaultsTapped() {
        guard !isConfiguring, resetButton.isEnabled else { return }
        onRestoreDefaults?()
    }

    // MARK: 布局构件

    private func makeSection(icon: String, title: String, rows: [NSView]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        let divider = makeDivider(color: PanelTheme.dividerColor)
        section.addSubview(divider)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        iconView.contentTintColor = PanelTheme.tertiaryText
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = PanelTheme.tertiaryText

        let titleLine = NSStackView(views: [iconView, titleLabel])
        titleLine.orientation = .horizontal
        titleLine.spacing = 5

        // 设置页使用通栏分组线和轻量行分隔线，对齐 settings-lite 原型。
        let stack = NSStackView(views: [titleLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(4, after: titleLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(stack)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rowDivider = makeDivider(color: NSColor.white.withAlphaComponent(0.035))
                stack.addArrangedSubview(rowDivider)
                rowDivider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }

            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(row)
            stack.addArrangedSubview(rowContainer)
            NSLayoutConstraint.activate([
                rowContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
                rowContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
                row.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                row.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: 7),
                row.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: -7)
            ])
        }

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: -PanelTheme.contentInset),
            divider.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: PanelTheme.contentInset),
            divider.topAnchor.constraint(equalTo: section.topAnchor),
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: section.bottomAnchor, constant: -10)
        ])
        return section
    }

    private func makeDivider(color: NSColor) -> NSView {
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = color.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func makeRow(label: String, tooltip: String, control: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 10, weight: .medium)
        labelView.textColor = PanelTheme.primaryText
        labelView.toolTip = tooltip

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelView, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeTitleRow(title: String, subtitle: String, subtitleLabel: NSTextField? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = PanelTheme.primaryText

        let subLabel = subtitleLabel ?? {
            let label = NSTextField(labelWithString: subtitle)
            label.font = .systemFont(ofSize: 8.5, weight: .regular)
            label.textColor = PanelTheme.tertiaryText
            label.lineBreakMode = .byTruncatingTail
            return label
        }()

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }
}

/// 深色下拉框：NSPopUpButton 固定深色外观。
final class DarkPopUpButton: NSPopUpButton {
    private var options: [(title: String, value: Int)] = []
    private var onSelectHandler: ((Int) -> Void)?

    convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        controlSize = .small
        font = .systemFont(ofSize: 10, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = PanelTheme.trackColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelTheme.hairline.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(options: [(title: String, value: Int)], onSelect: @escaping (Int) -> Void) {
        self.options = options
        self.onSelectHandler = onSelect
        let optionsMenu = NSMenu()
        optionsMenu.autoenablesItems = false
        for option in options {
            // 菜单项直接绑定动作；仅设置按钮 action 不会补齐手动创建的菜单项。
            let item = NSMenuItem(title: option.title, action: #selector(selectionChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.value
            optionsMenu.addItem(item)
        }
        menu = optionsMenu
        if !options.isEmpty { selectItem(at: 0) }
    }

    func select(value: Int) {
        guard let index = options.firstIndex(where: { $0.value == value }) else { return }
        selectItem(at: index)
    }

    /// 持久化值不在档位内时选最接近的一项（与右键菜单口径一致）。
    func select(nearest value: Int) {
        guard let index = options.indices.min(by: {
            abs(options[$0].value - value) < abs(options[$1].value - value)
        }) else { return }
        selectItem(at: index)
    }

    @objc private func selectionChanged(_ item: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === item }) == true else { return }
        // 先更新选中状态，再通知配置层，避免回调读取到上一次选项。
        select(item)
        onSelectHandler?(item.tag)
    }
}
