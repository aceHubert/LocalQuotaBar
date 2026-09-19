import Foundation

// MARK: - 周预算估算器（纯逻辑，可单测）

/// 周限百分比与本地 tokens 不是同一计费口径，"周预算"只能是由 (窗口用量, usedPercent)
/// 持续修正的估算值：E = windowTokens ÷ p。规则（详见 exec-plan weekly-pace-chart）：
/// - usedPercent < 5% 不更新（整数百分比粒度方差大），沿用持久化旧值；
/// - usedPercent ≥ 100% 时 E = windowTokens（剩余为 0，无法再反推）；
/// - 同一窗口内多次观测 EMA 平滑（α = 0.5）；新窗口首个可信观测直接采用，
///   吸收网关/渠道换账号导致的 usedPercent 跳变；
/// - 持久化按渠道 + 账号分桶，账号/套餐/渠道切换自然失效。
struct WeeklyPaceEstimator {
    /// 分桶标识：调用方组合渠道与账号（Codex 用账号 ID，Z.AI 用 provider id + 邮箱）。
    let bucket: String
    let defaults: UserDefaults

    init(bucket: String, defaults: UserDefaults = .standard) {
        self.bucket = bucket
        self.defaults = defaults
    }

    private struct Stored: Codable {
        let windowEnd: Date
        let budget: Double
    }

    private var storageKey: String { "local.codex.touchbar.quota.weeklyPace.budget.\(bucket)" }

    /// 用本次观测更新并返回预算估算（tokens）；不可信或无历史时可能返回 nil。
    /// windowTokens ≤ 0（本机无该渠道记录）同样不更新。
    func update(windowEnd: Date, windowTokens: Double, usedPercent: Double) -> Double? {
        let stored = load()
        let fraction = usedPercent / 100
        guard windowTokens > 0, fraction >= 0.05 else { return stored?.budget }

        let raw = fraction >= 1 ? windowTokens : windowTokens / fraction
        let next: Double
        if let stored, stored.windowEnd == windowEnd {
            // 同窗口 EMA（α = 0.5）
            next = stored.budget + 0.5 * (raw - stored.budget)
        } else {
            // 新窗口（或无历史）：首个可信观测直接采用
            next = raw
        }
        save(Stored(windowEnd: windowEnd, budget: next))
        return next
    }

    /// 只读当前估算，不更新状态（今日点不依赖 E，暂无调用方以外用途保留对称入口）。
    func currentEstimate() -> Double? {
        load()?.budget
    }

    private func load() -> Stored? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func save(_ stored: Stored) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Z.AI coding-plan 渠道 id 解析

/// 配速图窗口用量只统计当前渠道 coding plan（与周限 usedPercent 同口径）。
/// 渠道 id 不硬编码：优先取 setting.json 已解析 selectedKey 的冒号后段
/// （"coding-plan:builtin:zai-coding-plan"），并兼容 ZCode 3.12.3+ 改写的
/// `account:<domain>-<connection>-coding-plan` 新前缀（同 start-plan 日志的
/// 双前缀迁移，实测两形态在 model_usage 中并存）；解析不到时兜底
/// `builtin:<domain>-coding-plan` 拼接；非 coding-plan 模式返回 nil（整图隐藏）。
enum ZAIPaceChannel {
    static func codingPlanProviderIDs(selection: ZAIProviderSelection?) -> [String]? {
        guard let selection, selection.kind == .codingPlan else { return nil }
        var ids = [
            "builtin:\(selection.domain)-coding-plan",
            "account:\(selection.domain)-individual-coding-plan",
            "account:\(selection.domain)-team-coding-plan",
        ]
        if let selectedKey = selection.selectedKey {
            let parts = selectedKey.split(separator: ":")
            if parts.count >= 2 {
                let id = parts.dropFirst().joined(separator: ":")
                if id.contains("coding-plan"), !ids.contains(id) {
                    ids.append(id)
                }
            }
        }
        return ids
    }
}

// MARK: - Codex 官方日桶 → 周窗口用量（首日时间比例折算）

/// Codex 官方 dailyUsageBuckets 只有自然日整桶，重置时刻不在零点时首日混入上一周期用量。
/// 按时间比例折算首日：`首日桶 × (首日 24 点 − W0) / 24h`，其余整天桶原样取用；
/// 今日桶天然只含已发生用量，不再折算。Z.AI 侧毫秒明细精确切窗，无需此折算。
enum WeeklyPaceCodexBridge {
    static func windowDailyUsage(
        naturalDays: [DayUsage],
        windowStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [DayUsage] {
        let windowDay = calendar.startOfDay(for: windowStart)
        let today = calendar.startOfDay(for: now)
        // 首日折算系数：(首日 24 点 − W0) / 24h；W0 恰在零点时 = 1（整天桶）。
        let firstDayEnd = calendar.date(byAdding: .day, value: 1, to: windowDay) ?? windowStart
        let firstDayFactor = min(max(firstDayEnd.timeIntervalSince(windowStart) / 86400, 0), 1)

        return naturalDays.compactMap { day in
            guard day.date >= windowDay, day.date <= today else { return nil }
            let tokens = day.date == windowDay ? day.tokens * firstDayFactor : day.tokens
            return DayUsage(date: day.date, tokens: tokens)
        }
    }
}
