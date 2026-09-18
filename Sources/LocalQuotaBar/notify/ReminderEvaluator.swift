import Foundation

// MARK: - 提醒状态存储（静音 / 冷却）

/// 按桶 id 记录的提醒状态，整体存一个 UserDefaults key，"恢复提醒"可一次清空。
/// v2 的 id 不含渠道；v3 起 id 形如 "codex.<账号>.fiveHour"，渠道间互不干扰，故换 key 重新开始。
enum ReminderStateStore {
    private static let key = "local.codex.touchbar.quota.reminder.state.v3"

    struct BucketState: Codable {
        var lastAlertAt: TimeInterval = 0
        var mutedUntil: TimeInterval = 0
        /// 上次提醒时的剩余百分比；可选是为了兼容没有该字段的旧 v2 数据。
        var lastAlertedRemainingPercent: Double?
    }

    static func load() -> [String: BucketState] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let states = try? JSONDecoder().decode([String: BucketState].self, from: data)
        else { return [:] }
        return states
    }

    static func save(_ states: [String: BucketState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 提醒评估引擎

/// 只判断"该不该提醒、什么级别"，不关心用什么通道展示；
/// 通道能力（Touch Bar / 刘海屏）由 ReminderCenter 层决定。
final class ReminderEvaluator {
    private(set) var configuration: ReminderConfiguration
    private var states: [String: ReminderStateStore.BucketState]
    /// 最近一次各源的评估结果；muteCurrent 按它静音当前活跃桶。
    private(set) var lastPresentations: [ReminderBucket.Source: ReminderPresentation] = [:]

    init(configuration: ReminderConfiguration = ReminderSettings.load()) {
        self.configuration = configuration
        states = ReminderStateStore.load()
    }

    func presentation(for source: ReminderBucket.Source) -> ReminderPresentation {
        lastPresentations[source] ?? .inactive
    }

    /// 注册一次不经评估的展示（如手动测试卡片），
    /// 让它上面的「不再提醒」也能真正落到静音状态、可被"恢复提醒"撤销。
    func registerPresentation(for source: ReminderBucket.Source, presentation: ReminderPresentation) {
        guard presentation.isActive else { return }
        lastPresentations[source] = presentation
    }

    /// recordAlert = false 时只预演结果、不写冷却时间（改配置后立即生效用）。
    @discardableResult
    func evaluate(
        _ buckets: [ReminderBucket],
        source: ReminderBucket.Source,
        now: Date = Date(),
        recordAlert: Bool = true
    ) -> ReminderPresentation {
        guard configuration.isEnabled else {
            return store(source: source, presentation: .inactive)
        }

        var hits: [ReminderHit] = []
        let nowInterval = now.timeIntervalSince1970

        for bucket in buckets {
            guard let level = triggerLevel(for: bucket, now: now) else { continue }
            let state = states[bucket.id] ?? ReminderStateStore.BucketState()
            if state.mutedUntil > nowInterval { continue }
            let isResetCard = bucket.kind == .resetCard
            if !isResetCard {
                // 额度没动（一直没用或已为 0）时数字与上次相同，不重复打扰；
                // 数字变化、点"恢复提醒"或重置后才会重新放行。
                // 重置卡桶的剩余百分比恒为 100，跳过该去重，按固定间隔重复提醒。
                if let lastPercent = state.lastAlertedRemainingPercent,
                   lastPercent == bucket.remainingPercent {
                    continue
                }
            }
            let repeatInterval = isResetCard
                ? ReminderConfiguration.resetCardRepeatInterval
                : configuration.cooldown
            if state.lastAlertAt > 0, nowInterval - state.lastAlertAt < repeatInterval { continue }
            hits.append(ReminderHit(bucket: bucket, level: level))
        }

        guard let level = hits.map(\.level).max(), !hits.isEmpty else {
            return store(source: source, presentation: .inactive)
        }

        if recordAlert {
            for hit in hits {
                var state = states[hit.bucket.id, default: ReminderStateStore.BucketState()]
                state.lastAlertAt = nowInterval
                state.lastAlertedRemainingPercent = hit.bucket.remainingPercent
                states[hit.bucket.id] = state
            }
            ReminderStateStore.save(states)
        }

        return store(source: source, presentation: ReminderPresentation(level: level, hits: hits))
    }

    /// 静音当前所有活跃桶（跨源）到各自重置时刻；无重置时刻的桶静音 24 小时。
    func muteCurrent(now: Date = Date()) {
        let buckets = lastPresentations.values.flatMap { $0.affectedBuckets }
        guard !buckets.isEmpty else { return }

        let nowInterval = now.timeIntervalSince1970
        for bucket in buckets {
            let until = bucket.resetsAt.map { max($0.timeIntervalSince1970, nowInterval + 60) }
                ?? (nowInterval + 24 * 3600)
            states[bucket.id, default: ReminderStateStore.BucketState()].mutedUntil = until
        }
        ReminderStateStore.save(states)
        lastPresentations = [:]
    }

    /// 仅统计"静默中"（用户点过不再提醒）的桶；普通冷却不算。
    var canRestore: Bool {
        let now = Date().timeIntervalSince1970
        return states.values.contains { $0.mutedUntil > now }
    }

    /// 撤销所有静默并清除冷却状态。
    func unmuteAll() {
        states = [:]
        ReminderStateStore.save(states)
    }

    func updateConfiguration(_ configuration: ReminderConfiguration) {
        self.configuration = configuration
        ReminderSettings.save(configuration)
    }

    private func store(source: ReminderBucket.Source, presentation: ReminderPresentation) -> ReminderPresentation {
        lastPresentations[source] = presentation
        return presentation
    }

    private func triggerLevel(for bucket: ReminderBucket, now: Date) -> ReminderLevel? {
        // 重置卡只看到期时间：进入固定窗口就提醒，不受"重置还剩"等设置影响。
        if bucket.kind == .resetCard {
            guard let expiresAt = bucket.resetsAt else { return nil }
            let timeToExpiry = expiresAt.timeIntervalSince(now)
            guard timeToExpiry > 0, timeToExpiry <= ReminderConfiguration.resetCardExpiryWindow else {
                return nil
            }
            return .resetSoon
        }

        if bucket.remainingPercent <= configuration.criticalRemainingPercent {
            return .critical
        }

        if bucket.remainingPercent <= configuration.warningRemainingPercent {
            return .warning
        }

        if configuration.resetSoonMinutes > 0, let resetsAt = bucket.resetsAt {
            let minutesToReset = resetsAt.timeIntervalSince(now) / 60
            if minutesToReset >= 0 && minutesToReset <= configuration.resetSoonMinutes {
                return .resetSoon
            }
        }

        return nil
    }
}
