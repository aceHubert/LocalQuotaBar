import AppKit

// MARK: - 提醒中心（评估 + 通道编排）

/// 额度数据每次刷新后 ingest 一个源；内部完成阈值评估并按
/// Touch Bar > 刘海屏 > 不弹出 的优先级取第一个可用通道投递。
@MainActor
final class ReminderCenter {
    let evaluator: ReminderEvaluator
    private let touchBarChannel: TouchBarAlertChannel
    private let dynamicNotchChannel: DynamicNotchKitAlertChannel
    private let notchChannel: NotchAlertChannel

    /// ingest 缓存的各源数据，改配置后立即按新阈值预演。
    private var cachedInputs: [ReminderBucket.Source: (buckets: [ReminderBucket], codexSnapshot: QuotaSnapshot?)] = [:]

    var configuration: ReminderConfiguration {
        evaluator.configuration
    }

    var canRestore: Bool {
        evaluator.canRestore
    }

    init() {
        evaluator = ReminderEvaluator()
        touchBarChannel = TouchBarAlertChannel()
        dynamicNotchChannel = DynamicNotchKitAlertChannel()
        notchChannel = NotchAlertChannel()
    }

    /// 接线通道回调：所有 channel 的"不再提醒"统一走 muteCurrent；刘海屏点击打开主面板。
    func start(onOpenPanel: @escaping () -> Void) {
        touchBarChannel.onMute = { [weak self] in
            self?.muteCurrent()
        }
        notchChannel.onOpenPanel = onOpenPanel
        notchChannel.onMute = { [weak self] in
            self?.muteCurrent()
        }
        dynamicNotchChannel.onOpenPanel = onOpenPanel
        dynamicNotchChannel.onMute = { [weak self] in
            self?.muteCurrent()
        }
    }

    func presentation(for source: ReminderBucket.Source) -> ReminderPresentation {
        evaluator.presentation(for: source)
    }

    /// 评估并投递一个数据源的额度桶；返回该源当前提醒表现（供 UI 展示 emoji 等）。
    @discardableResult
    func ingest(
        source: ReminderBucket.Source,
        buckets: [ReminderBucket],
        codexSnapshot: QuotaSnapshot? = nil
    ) -> ReminderPresentation {
        cachedInputs[source] = (buckets, codexSnapshot)

        let presentation = evaluator.evaluate(buckets, source: source)
        if presentation.isActive {
            deliver(makeAlert(source: source, presentation: presentation, codexSnapshot: codexSnapshot))
        }
        return presentation
    }

    /// 静音当前所有活跃桶并收起已弹出的提醒。
    func muteCurrent() {
        evaluator.muteCurrent()
        retractAll()
    }

    func unmuteAll() {
        evaluator.unmuteAll()
    }

    func updateConfiguration(_ configuration: ReminderConfiguration) {
        evaluator.updateConfiguration(configuration)
        // 立即按新配置预演当前数据（不记冷却），开关/阈值改动马上生效。
        for (source, input) in cachedInputs {
            let presentation = evaluator.evaluate(input.buckets, source: source, recordAlert: false)
            if presentation.isActive {
                deliver(makeAlert(source: source, presentation: presentation, codexSnapshot: input.codexSnapshot))
            }
        }
    }

    func retractAll() {
        touchBarChannel.retract()
        notchChannel.retract()
        dynamicNotchChannel.retract()
    }

    /// 右键菜单“测试提醒”用：手动走一遍投递链（Touch Bar > 刘海卡片）。
    /// 用 Codex 当前真实数据构建（真实百分比、真实重置时间），只投递、不写评估状态，
    /// 不受提醒开关、阈值、静音与冷却限制。返回 false 表示当前没有可用通道。
    @discardableResult
    func deliverTestAlert(codexSnapshot: QuotaSnapshot? = nil) -> Bool {
        guard channels.contains(where: { $0.isAvailable }) else { return false }

        if let snapshot = codexSnapshot, !snapshot.reminderBuckets.isEmpty {
            let hits = snapshot.reminderBuckets.map { bucket in
                ReminderHit(bucket: bucket, level: testLevel(for: bucket))
            }
            let presentation = ReminderPresentation(level: hits.map(\.level).max(), hits: hits)
            // 注册进评估器的最近展示，测试卡片上的「不再提醒」才能生效并出现"恢复提醒"。
            evaluator.registerPresentation(for: .codex, presentation: presentation)
            deliver(makeAlert(source: .codex, presentation: presentation, codexSnapshot: snapshot))
            return true
        }

        // 没有 Codex 数据时的兜底样例。
        let hit = ReminderHit(
            bucket: ReminderBucket(
                source: .codex,
                id: "test",
                title: "测试提醒",
                shortTitle: "测试提醒",
                remainingPercent: 8,
                resetsAt: nil
            ),
            level: .critical
        )
        let presentation = ReminderPresentation(level: .critical, hits: [hit])
        evaluator.registerPresentation(for: .codex, presentation: presentation)
        let alert = ReminderAlert(
            source: .codex,
            presentation: presentation,
            headline: "测试提醒 · 暂无 Codex 数据",
            detail: "手动触发，不影响冷却与阈值评估",
            codexSnapshot: nil
        )
        deliver(alert)
        return true
    }

    /// 测试展示用的级别：按真实百分比套用阈值，未触发阈值的桶以 ⚠️ 展示。
    private func testLevel(for bucket: ReminderBucket) -> ReminderLevel {
        let config = evaluator.configuration
        if bucket.remainingPercent <= config.criticalRemainingPercent {
            return .critical
        }
        if bucket.remainingPercent <= config.warningRemainingPercent {
            return .warning
        }
        if let resetsAt = bucket.resetsAt,
           resetsAt.timeIntervalSince(Date()) / 60 <= config.resetSoonMinutes {
            return .resetSoon
        }
        return .warning
    }

    private var channels: [ReminderAlertChannel] {
        // 优先级：Touch Bar > DynamicNotchKit（真正的灵动岛）> 自画刘海卡片（兜底）。
        // 在带刘海的 Mac 上，DynamicNotchKit 与 NotchAlertChannel 互斥可用
        // （isAvailable 条件相同），但 DynamicNotchKit 排在前，会先被选中。
        [touchBarChannel, dynamicNotchChannel, notchChannel]
    }

    private func deliver(_ alert: ReminderAlert) {
        for channel in channels where channel.isAvailable {
            channel.deliver(alert)
            return
        }
    }

    private func makeAlert(
        source: ReminderBucket.Source,
        presentation: ReminderPresentation,
        codexSnapshot: QuotaSnapshot?
    ) -> ReminderAlert {
        let now = Date()
        let sortedHits = presentation.hits.sorted { $0.level > $1.level }
        let headline = sortedHits.first.map { Self.describe(hit: $0, now: now) } ?? ""
        let detail = sortedHits.dropFirst()
            .map { Self.describe(hit: $0, now: now) }
            .joined(separator: "，")
        return ReminderAlert(
            source: source,
            presentation: presentation,
            headline: headline,
            detail: detail.isEmpty ? nil : detail,
            codexSnapshot: codexSnapshot
        )
    }

    private static func describe(hit: ReminderHit, now: Date) -> String {
        switch hit.level {
        case .critical, .warning:
            return "\(hit.bucket.title) 仅剩 \(hit.bucket.roundedRemainingPercent)%"
        case .resetSoon:
            guard let resetsAt = hit.bucket.resetsAt else { return hit.bucket.title }
            let minutes = Int(max(0, resetsAt.timeIntervalSince(now) / 60).rounded())
            return "\(hit.bucket.title) \(minutes)分钟后重置"
        }
    }
}
