import Foundation

// MARK: - Reminder models（Codex / ZAI 统一多源提醒）

enum ReminderLevel: Int, Comparable {
    case resetSoon = 1
    case warning = 2
    case critical = 3

    static func < (lhs: ReminderLevel, rhs: ReminderLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var emoji: String {
        switch self {
        case .critical: return "🚨"
        case .warning: return "⚠️"
        case .resetSoon: return "⏳"
        }
    }
}

/// 统一额度桶：Codex 与 ZAI 的阈值判断都归一到这个结构。
struct ReminderBucket: Equatable {
    enum Source: String {
        case codex
        case zai
    }

    let source: Source
    /// 稳定 id，同时是静音/冷却状态的 key：codex.fiveHour / zai.limit.hourly / zai.balance.<标题>
    let id: String
    /// 长标题，含来源前缀，如 "Codex 5小时" / "ZAI 周额度"。
    let title: String
    /// 短标题，不含来源前缀，如 "5小时" / "周额度" / "GLM-4.6"。
    /// 灵动岛每行展示用 shortTitle，避免每行重复 provider 名。
    let shortTitle: String
    let remainingPercent: Double
    let resetsAt: Date?

    var roundedRemainingPercent: Int {
        Int(remainingPercent.rounded())
    }

    /// 把渠道身份并入稳定 id：静音、冷却、"额度未变化去重"都按渠道隔离，
    /// 避免 Codex 多账号 / ZAI 多套餐共用一条状态而互相抑制或重复提醒。
    func namespacedByChannel(_ channel: String) -> ReminderBucket {
        let sanitized = channel.isEmpty ? "default" : channel
        let sourcePrefix = "\(source.rawValue)."
        let bareId = id.hasPrefix(sourcePrefix) ? String(id.dropFirst(sourcePrefix.count)) : id
        return ReminderBucket(
            source: source,
            id: "\(sourcePrefix)\(sanitized).\(bareId)",
            title: title,
            shortTitle: shortTitle,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt
        )
    }
}

/// 单个触发阈值的桶及其级别。
struct ReminderHit: Equatable {
    let bucket: ReminderBucket
    let level: ReminderLevel
}

struct ReminderPresentation: Equatable {
    let level: ReminderLevel?
    let hits: [ReminderHit]

    static let inactive = ReminderPresentation(level: nil, hits: [])

    var isActive: Bool {
        level != nil && !hits.isEmpty
    }

    var affectedBuckets: [ReminderBucket] {
        hits.map(\.bucket)
    }

    var emoji: String {
        level?.emoji ?? ""
    }
}

struct ReminderConfiguration {
    var isEnabled: Bool
    var warningRemainingPercent: Double
    var criticalRemainingPercent: Double
    var resetSoonMinutes: TimeInterval
    var cooldown: TimeInterval

    static let `default` = ReminderConfiguration(
        isEnabled: true,
        warningRemainingPercent: 20,
        criticalRemainingPercent: 10,
        resetSoonMinutes: 30,
        cooldown: 10 * 60
    )
}

enum ReminderSettings {
    static let enabledKey = "local.codex.touchbar.quota.reminder.enabled"
    static let warningPercentKey = "local.codex.touchbar.quota.reminder.warningPercent"
    static let resetSoonMinutesKey = "local.codex.touchbar.quota.reminder.resetSoonMinutes"
    static let cooldownMinutesKey = "local.codex.touchbar.quota.reminder.cooldownMinutes"

    static func registerDefaults() {
        let defaults = ReminderConfiguration.default
        UserDefaults.standard.register(defaults: [
            enabledKey: defaults.isEnabled,
            warningPercentKey: defaults.warningRemainingPercent,
            resetSoonMinutesKey: defaults.resetSoonMinutes,
            cooldownMinutesKey: defaults.cooldown / 60
        ])
    }

    static func load() -> ReminderConfiguration {
        registerDefaults()
        return ReminderConfiguration(
            isEnabled: UserDefaults.standard.bool(forKey: enabledKey),
            warningRemainingPercent: UserDefaults.standard.double(forKey: warningPercentKey),
            criticalRemainingPercent: ReminderConfiguration.default.criticalRemainingPercent,
            resetSoonMinutes: UserDefaults.standard.double(forKey: resetSoonMinutesKey),
            cooldown: UserDefaults.standard.double(forKey: cooldownMinutesKey) * 60
        )
    }

    static func save(_ configuration: ReminderConfiguration) {
        UserDefaults.standard.set(configuration.isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(configuration.warningRemainingPercent, forKey: warningPercentKey)
        UserDefaults.standard.set(configuration.resetSoonMinutes, forKey: resetSoonMinutesKey)
        UserDefaults.standard.set(configuration.cooldown / 60, forKey: cooldownMinutesKey)
    }
}
