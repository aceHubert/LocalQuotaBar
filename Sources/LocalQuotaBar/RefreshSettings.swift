import Foundation

/// 后台自动刷新频率设置。Codex 与 ZAI 两个 store 共用一个值，
/// 在状态栏右键菜单里以固定档位切换，面板上只读展示。
enum RefreshSettings {
    static let intervalMinutesKey = "local.codex.touchbar.quota.refresh.intervalMinutes"

    static let defaultIntervalMinutes = 5
    static let availableMinutes: [Int] = [5, 10, 15, 30, 60]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            intervalMinutesKey: defaultIntervalMinutes
        ])
    }

    /// 返回以秒为单位的刷新间隔；持久化值不在档位内时回退默认值。
    static func load() -> TimeInterval {
        registerDefaults()
        let minutes = UserDefaults.standard.integer(forKey: intervalMinutesKey)
        guard availableMinutes.contains(minutes) else {
            return TimeInterval(defaultIntervalMinutes) * 60
        }
        return TimeInterval(minutes) * 60
    }

    static func loadMinutes() -> Int {
        Int(load() / 60)
    }

    static func save(minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: intervalMinutesKey)
    }
}

// MARK: - 后台刷新错峰

/// 5 个持定时器的 store（Codex / ZAI / DeepSeek / CodeBuddy 国际 / CodeBuddy 国内）
/// 各占一个固定相位偏移，避免在同一瞬间形成对齐的 CPU/网络突发。
/// 偏移表按 5 分钟档位定义（基准周期 300s），更短档位按 interval 等比例缩小。
enum RefreshPhasePlanner {
    /// 偏移表的设计基准周期（秒）。
    static let baseInterval: TimeInterval = 300

    /// 距下一次相位对齐触发点的秒数，恒落在 (0, interval]。
    /// anchor 为 store 自身的启动锚点：改档位重建定时器时传入同一锚点，
    /// 各 store 的相对相位保持不变，不会重新对齐到同一时刻。
    /// 注：启动当轮首个周期可能短于 interval（如偏移 45s 的 store 在启动后
    /// 45s 就迎来第一次周期触发）——start() 已立即刷过一次，多出的早触发
    /// 只发生在启动后第一个周期，属可接受的一次性开销。
    static func nextDelay(
        offset: TimeInterval,
        interval: TimeInterval,
        anchor: Date,
        now: Date = Date()
    ) -> TimeInterval {
        let safeInterval = max(interval, 1)
        let effective = offset * (safeInterval / baseInterval)
        let elapsed = now.timeIntervalSince(anchor)
        let periods = ceil((elapsed - effective) / safeInterval)
        var delay = periods * safeInterval + effective - elapsed
        if delay <= 0 { delay += safeInterval }
        return delay
    }

    /// 定时器容差：给系统合并唤醒留出空间（上限 10 秒）。
    static func tolerance(for interval: TimeInterval) -> TimeInterval {
        min(10, interval * 0.1)
    }
}
