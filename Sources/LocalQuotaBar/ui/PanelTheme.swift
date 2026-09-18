import AppKit
import Foundation

// MARK: - 面板设计 token（对齐原型 quota-popup-redesign-9319 的 CSS 变量）

/// 弹窗整体固定深色外观（原型即深色），文本/分隔线用固定色保证与设计稿一致。
enum PanelTheme {
    static let appearance = NSAppearance(named: .vibrantDark)

    /// 两处提醒开关共享外观与控件尺寸，轨道颜色由组件固定绘制。
    @MainActor
    static func configureReminderSwitch(_ control: PanelReminderSwitch) {
        control.appearance = NSAppearance(named: .darkAqua)
        control.controlSize = .mini
    }

    // 尺寸
    static let panelWidth: CGFloat = 322
    static let contentInset: CGFloat = 12
    static var contentWidth: CGFloat { panelWidth - contentInset * 2 }

    // 背景层级
    static let panelBackground = NSColor(hex: 0x1A1A1C)
    static let cardBackground = NSColor(hex: 0x212024)
    static let trackColor = NSColor(hex: 0x2C2C30)
    static let dividerColor = NSColor(hex: 0x26262A)

    // 状态色
    static let green = NSColor(hex: 0x32D583)
    static let orange = NSColor(hex: 0xFF9F0A)
    static let red = NSColor(hex: 0xFF453A)
    static let yellow = NSColor(hex: 0xFFD60A)
    static let pink = NSColor(hex: 0xFF85B0)
    static let purple = NSColor(hex: 0xA78BFA)

    // 文本层级
    static let primaryText = NSColor(hex: 0xF5F5F7)
    static let secondaryText = NSColor(hex: 0x98989F)
    static let tertiaryText = NSColor(hex: 0x6F6F75)

    // 描边（白底低透明度）
    static let hairline = NSColor.white.withAlphaComponent(0.09)
    static let hairlineSubtle = NSColor.white.withAlphaComponent(0.055)

    /// 胶囊配色按剩余百分比分级（与提醒阈值一致：≤10% 严重、≤20% 预警）。
    static func levelColor(remainingPercent: Double) -> NSColor {
        if remainingPercent <= 10 { return red }
        if remainingPercent <= 20 { return orange }
        return green
    }

    /// 距重置 ≤30 分钟视为"即将重置"（黄色）。
    static let resetSoonThreshold: TimeInterval = 30 * 60

    // MARK: 格式化

    static func formatRefreshTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 顶部更新时间：刚刚、分钟数或小时数前。「刚刚」覆盖前两分钟，分钟档从 2 起。
    static func relativeTime(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let interval = now.timeIntervalSince(date)
        if interval < 120 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        return "\(Int(interval / 3600)) 小时前"
    }

    /// 重置倒计时（粉色小字）："3天4时" / "2时48分" / "12分"。
    static func formatCountdown(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "即将重置" }
        let totalMinutes = Int(remaining / 60)
        if totalMinutes < 60 { return "\(max(1, totalMinutes))分" }
        let hours = remaining / 3600
        if hours < 24 {
            let h = Int(hours)
            let m = totalMinutes % 60
            return m > 0 ? "\(h)时\(m)分" : "\(h)时"
        }
        let days = Int(hours / 24)
        let h = Int(hours.truncatingRemainder(dividingBy: 24))
        return h > 0 ? "\(days)天\(h)时" : "\(days)天"
    }

    /// 重置卡到期文案与"7 天内到期"判断。
    static let cardExpiryWarningInterval: TimeInterval = 7 * 24 * 60 * 60

    static func formatCardExpiry(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func cardExpiryBadge(_ date: Date?, now: Date = Date()) -> (text: String, soon: Bool) {
        guard let date else { return ("无到期时间", false) }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return ("已过期", true) }
        let soon = remaining < cardExpiryWarningInterval
        if remaining < 86400 {
            // 一天内细化到分钟，向上取整避免尚未到期却显示零分钟。
            let totalMinutes = Int(ceil(remaining / 60))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            let duration = hours > 0 ? "\(hours)小时\(minutes)分钟" : "\(minutes)分钟"
            return ("\(duration)后到期", soon)
        }
        return ("\(Int(ceil(remaining / 86400)))天后到期", soon)
    }

    /// token 数格式化：1404311393 → "1.4B"。
    static func formatTokenCount(_ value: Double) -> String {
        switch value {
        case 1e9...: return String(format: "%.1fB", value / 1e9)
        case 1e6...: return String(format: "%.1fM", value / 1e6)
        case 1e3...: return String(format: "%.1fK", value / 1e3)
        default: return String(format: "%.0f", value)
        }

    }

    /// 缓存快照的获取时间（错误横幅标题用）：今天 HH:mm:ss，跨天 MM-dd HH:mm。
    static func formatFetchedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 深色卡片容器：圆角 + 细描边 + 固定底色。
final class PanelCardView: NSView {
    init(fill: NSColor = PanelTheme.cardBackground,
         borderColor: NSColor = PanelTheme.hairlineSubtle,
         radius: CGFloat = 9) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
