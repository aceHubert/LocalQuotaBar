import Foundation

/// 后台自动刷新频率设置。Codex 与 ZAI 两个 store 共用一个值，
/// 在状态栏右键菜单里以固定档位切换，面板上只读展示。
enum RefreshSettings {
    static let intervalMinutesKey = "local.codex.touchbar.quota.refresh.intervalMinutes"

    static let defaultIntervalMinutes = 5
    static let availableMinutes: [Int] = [1, 2, 5, 10, 15, 30, 60]

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
