import Foundation
import SQLite3

// MARK: - zcode 本地日用量（~/.zcode/cli/db/db.sqlite 只读聚合）

/// ZCode 官方"使用统计"页同款数据源：model_usage 表不分渠道、按天聚合 computed_total_tokens。
/// 只读连接 + 短 busy_timeout，zcode 运行中也可安全并行读；失败返回 nil（面板显示空图）。
/// zcode.cjs 对齐的只读用量查询；SQLITE_TRANSIENT 让 SQLite 拷贝绑定字符串。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ZCodeUsageDB {
    static func last30Days() -> [DayUsage]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 400)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let sinceDate = calendar.date(byAdding: .day, value: -29, to: today) else { return nil }
        let sinceMs = sinceDate.timeIntervalSince1970 * 1000

        // 官方统计页按全渠道合计：自定义渠道（UUID provider）与 builtin:zai
        // 同样计入每日总量，仅按时间过滤，否则每日用量会少算几百至上亿 tokens。
        let sql = """
        SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
               SUM(computed_total_tokens) AS tokens
        FROM model_usage
        WHERE started_at >= ?1
        GROUP BY day
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, sinceMs)

        var tokensByDay: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dayCString = sqlite3_column_text(statement, 0) else { continue }
            let day = String(cString: dayCString)
            tokensByDay[day] = sqlite3_column_double(statement, 1)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return (0..<30).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = formatter.string(from: day)
            return DayUsage(date: day, tokens: tokensByDay[key] ?? 0)
        }
    }
}

/// Z.AI 用量 Store：本机 SQLite 快查，每次额度刷新后按需重查。
@MainActor
final class ZAIUsageStore {
    private(set) var days: [DayUsage]?
    private var isRefreshing = false

    var onChange: (([DayUsage]?) -> Void)?

    /// 本机记录独立于当前套餐，API Key 模式同样展示全渠道日用量。
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            let result = ZCodeUsageDB.last30Days()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.days = result
                self.onChange?(result)
            }
        }
    }

}
