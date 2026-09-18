import AppKit
import DynamicNotchKit
import SwiftUI

// MARK: - DynamicNotchKit 通道
//
// 真正的灵动岛投递：复用第三方 SDK (MrKai77/DynamicNotchKit, MIT) 提供的
// DynamicNotchInfo，其内部在 NSScreen.hasNotch=true 时用 .notch 样式贴合刘海，
// 否则用 .floating 样式退化为顶部悬浮胶囊。我们仅在带刘海的屏上 isAvailable=true，
// 非刘海屏的兜底仍由 NotchAlertChannel（自画胶囊）负责。

@MainActor
final class DynamicNotchKitAlertChannel: ReminderAlertChannel {
    static let displayDuration: TimeInterval = 12

    /// 点击卡片时打开主面板。
    var onOpenPanel: (() -> Void)?
    /// 点击"不再提醒"时回调。
    var onMute: (() -> Void)?

    private var currentNotch: DynamicNotch<NotchAlertContent, AnyView, EmptyView>?
    private var dismissTask: Task<Void, Never>?
    private(set) var isPresenting = false

    var isAvailable: Bool {
        NotchCapability.hasNotch
    }

    func deliver(_ alert: ReminderAlert) {
        guard let screen = NotchCapability.notchScreen else { return }

        // 收起上一次通知，避免两条并存。
        if isPresenting { retract() }

        // 通用抽象：channel 不关心具体 provider / 窗口名是什么，
        // 顶部放 provider 标题（避免每行重复），下面遍历 hits 数组。
        let providerName = providerDisplayName(for: alert)
        let iconName = levelIconName(for: alert)
        let iconColor = levelIconColor(for: alert)
        let onMute = self.onMute
        let onClose = { [weak self] in
            NSLog("[DynamicNotch] close button tapped")
            // 只收起卡片，不写静音，额度继续下降时还会再提醒。
            self?.retract()
        }
        let content = NotchAlertContent(
            iconName: iconName,
            iconColor: iconColor,
            providerName: providerName,
            hits: alert.presentation.hits,
            onMute: {
                NSLog("[DynamicNotch] mute button tapped, onMute is \(onMute != nil ? "set" : "nil")")
                onMute?()
            },
            onClose: onClose
        )
        // hoverBehavior 必须去掉 .keepVisible：SDK 的 hide() 在 keepVisible 且鼠标
        // 仍悬停时会无限推迟收起（每 0.1s 重试），导致点完"不再提醒"卡片不消失，
        // 要等鼠标移开才收起。保留触感反馈与悬停阴影。
        let notch = DynamicNotch(hoverBehavior: [.hapticFeedback, .increaseShadow], style: .auto) {
            content
        } compactLeading: {
            AnyView(
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .padding(6)
            )
        } compactTrailing: {
            EmptyView()
        }
        currentNotch = notch

        Task { @MainActor in
            await notch.expand(on: screen)
        }

        isPresenting = true
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retract()
        }
    }

    func retract() {
        dismissTask?.cancel()
        dismissTask = nil
        guard isPresenting, let notch = currentNotch else { return }
        currentNotch = nil
        isPresenting = false
        Task { @MainActor in
            await notch.hide()
        }
    }

    // MARK: - 视觉映射

    /// 灵动岛顶部展示的 provider 名。
    private func providerDisplayName(for alert: ReminderAlert) -> String {
        switch alert.source {
        case .codex: "Codex"
        case .zai: "ZAI"
        }
    }

    /// 紧凑（贴刘海）状态下左侧显示的级别图标。
    private func levelIconName(for alert: ReminderAlert) -> String {
        switch alert.presentation.level ?? .warning {
        case .critical: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .resetSoon: "clock.arrow.circlepath"
        }
    }

    private func levelIconColor(for alert: ReminderAlert) -> Color {
        switch alert.presentation.level ?? .warning {
        case .critical: .red
        case .warning: .orange
        case .resetSoon: .yellow
        }
    }
}

// MARK: - 灵动岛内容视图（通用 {label, percent, time} 抽象渲染）

/// 灵动岛展开态：通用渲染每个 reminder hit 一行。
/// 数据结构是 {provider, limits:[{label, percent, time}]}：
/// - provider 由 channel 层在 compactLeading 用级别图标表达（不在内容里重复）
/// - limits 直接遍历 hits 数组，每行三个槽位：bucket.title（label） / 进度条（percent） / 重置时间（time）
/// 不对 label 做任何格式化（5H / 5h / GLM-4.6 等原样显示），
/// 不显示数字百分比（进度条自身的填充就是 percent 表达）。
struct NotchAlertContent: View {
    let iconName: String
    let iconColor: Color
    let providerName: String
    let hits: [ReminderHit]
    let onMute: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 13, weight: .semibold))
                Text(providerName + "：")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                // 必须用 Button 而不是 onTapGesture：本 app 是 .accessory，刘海提醒弹出时
                // 几乎总是处于未激活状态，而 macOS 上 SwiftUI 手势（onTapGesture，底层
                // NSGestureRecognizer）只在 app 激活时才识别；Button 走控件级鼠标跟踪，
                // 未激活也响应（已用合成点击在 SDK 完整链路上验证）。
                Button {
                    onMute()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                        Text("不再提醒")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    onClose()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                        Text("关闭")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 触发原因：让"额度低了"和"快到重置时间了"两种弹出一眼可分。
            Text(triggerSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(hits, id: \.bucket.id) { hit in
                NotchAlertLimitRow(
                    label: hit.bucket.shortTitle,
                    percent: hit.bucket.remainingPercent,
                    resetsAt: hit.bucket.resetsAt
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minWidth: 380)
    }

    /// 多个触发原因用逗号连成一行，如 "5小时额度低了，周限额快到重置时间了"。
    private var triggerSummary: String {
        hits.map(triggerText(for:)).joined(separator: "，")
    }

    private func triggerText(for hit: ReminderHit) -> String {
        let name = hit.bucket.shortTitle
        // 重置卡桶的 resetsAt 是卡的到期时刻，不是额度重置。
        if hit.bucket.kind == .resetCard {
            return "\(name)快过期了"
        }
        // ZAI 的短标题自带"额度"，Codex 的"5小时/周限额"需要补量词才通顺。
        let noun = name.contains("额度") || name.contains("限额") ? "" : "额度"
        switch hit.level {
        case .critical, .warning:
            return "\(name)\(noun)低了"
        case .resetSoon:
            return "\(name)快到重置时间了"
        }
    }
}

/// 灵动岛内单行：label（左侧）+ 进度条（中间）+ 重置时间（右侧）。
/// 进度条颜色规则与 TouchBar SegmentedBatteryBarView 完全一致：
/// remainingPercent < 20 → 红；< 50 → 黄；其余 → 绿。
private struct NotchAlertLimitRow: View {
    let label: String
    let percent: Double
    let resetsAt: Date?

    private let segmentCount = 10
    private let labelWidth: CGFloat = 60
    private let timeWidth: CGFloat = 130
    private let barHeight: CGFloat = 8

    private var fillColor: Color {
        switch percent {
        case 0..<20: .red
        case 20..<50: .yellow
        default: .green
        }
    }

    private var roundedPercent: Int {
        Int(percent.rounded())
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 2) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let filled = Double(index) / Double(segmentCount) * 100 < percent
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(filled ? fillColor : Color.white.opacity(0.18))
                        .frame(height: barHeight)
                }
            }
            .frame(maxWidth: .infinity)

            if let resetsAt {
                HStack(spacing: 4) {
                    Text("\(roundedPercent)%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(fillColor)
                    Text("·")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(formatReset(resetsAt))
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(width: timeWidth, alignment: .trailing)
                .lineLimit(1)
            } else {
                Text("\(roundedPercent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(fillColor)
                    .frame(width: timeWidth, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }
}
