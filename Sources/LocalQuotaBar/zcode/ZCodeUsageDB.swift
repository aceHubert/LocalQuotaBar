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
        // Zcode 数据库处于 WAL 模式；READONLY 连接在 wal/shm 伴文件被清理后，
        // prepare 可能因无法重建共享内存返回 SQLITE_CANTOPEN。这里以 READWRITE
        // 打开并立即启用 query_only，保持应用侧不写入数据库的只读语义。
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 400)
        sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)

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

    // MARK: - 配速图 / 叠加图查询（精确时间窗 + 渠道过滤）

    /// 周限窗口内逐日聚合（配速图历史点位）。毫秒边界精确切窗，providerIDs 过滤
    /// 当前渠道 coding plan（含 builtin/account 两种前缀形态），与周限 usedPercent
    /// 同口径；无行的日期不出现（由推导层按天补 0）。
    static func dailyUsage(since: Date, until: Date, providerIDs: [String]) -> [DayUsage]? {
        guard !providerIDs.isEmpty else { return [] }
        let placeholders = Self.placeholders(providerIDs.count)
        return query(
            sql: """
            SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
                   SUM(computed_total_tokens) AS tokens
            FROM model_usage
            WHERE started_at >= ? AND started_at <= ? AND provider_id IN (\(placeholders))
            GROUP BY day
            """,
            binds: [.double(since.timeIntervalSince1970 * 1000),
                    .double(until.timeIntervalSince1970 * 1000)]
                + providerIDs.map { .text($0) }
        )?
        .compactMap { row -> DayUsage? in
            guard case .text(let key) = row[0], let day = dayKeyFormatter().date(from: key),
                  case .double(let tokens) = row[1] else { return nil }
            return DayUsage(date: day, tokens: tokens)
        }
    }

    /// 周限窗口内总量（预算估算用），同上查询去掉 GROUP BY；读库失败返回 nil（按降级处理）。
    static func totalTokens(since: Date, until: Date, providerIDs: [String]) -> Double? {
        guard !providerIDs.isEmpty else { return 0 }
        let placeholders = Self.placeholders(providerIDs.count)
        let rows = query(
            sql: """
            SELECT SUM(computed_total_tokens) AS tokens
            FROM model_usage
            WHERE started_at >= ? AND started_at <= ? AND provider_id IN (\(placeholders))
            """,
            binds: [.double(since.timeIntervalSince1970 * 1000),
                    .double(until.timeIntervalSince1970 * 1000)]
                + providerIDs.map { .text($0) }
        )
        guard case .double(let total)? = rows?.first?[0] else { return 0 }
        return total
    }

    /// 近 30 天按渠道拆分的日聚合（叠加柱状图）：totalTokens 全渠道，channelTokens 仅当前渠道。
    /// 现有 last30Days() 的全渠道口径保持不动，本查询只服务叠加渲染。
    /// 注意：SQL 里 IN 占位符（SELECT 子句）在 WHERE 的 ? 之前出现，
    /// SQLite 匿名参数按文本出现顺序编号，绑定必须 ids 在前、时间戳在后。
    static func last30DaysSplit(channelProviderIDs: [String]) -> [ChannelSplitDayUsage]? {
        guard !channelProviderIDs.isEmpty else { return nil }
        let placeholders = Self.placeholders(channelProviderIDs.count)
        let rows = query(
            sql: """
            SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
                   SUM(computed_total_tokens) AS total,
                   SUM(CASE WHEN provider_id IN (\(placeholders)) THEN computed_total_tokens ELSE 0 END) AS channel
            FROM model_usage
            WHERE started_at >= ?
            GROUP BY day
            """,
            binds: channelProviderIDs.map { .text($0) } + [.double(thirtyDaysAgoMs())]
        )?
        .compactMap { row -> ChannelSplitDayUsage? in
            guard case .text(let key) = row[0], let day = dayKeyFormatter().date(from: key),
                  case .double(let total) = row[1],
                  case .double(let channel) = row[2] else { return nil }
            return ChannelSplitDayUsage(date: day, totalTokens: total, channelTokens: channel)
        }
        guard let rows else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let row = rows.first { calendar.isDate($0.date, inSameDayAs: day) }
            return ChannelSplitDayUsage(date: day, totalTokens: row?.totalTokens ?? 0, channelTokens: row?.channelTokens ?? 0)
        }
    }

    /// 近 30 天"排除套餐渠道"的日聚合（本机非套餐 = 自定义 UUID provider、
    /// API Key 模式与 start-plan 等本机渠道；本机套餐部分已含在服务端口径，
    /// 排除以避免双计）。排除集合用域内宽松匹配 `provider_id LIKE '%coding-plan'`
    /// （覆盖 builtin:/account: 双前缀形态，且不误伤 `-start-plan`）。
    static func last30DaysExcludingCodingPlan() -> [DayUsage]? {
        let rows = query(
            sql: """
            SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
                   SUM(computed_total_tokens) AS tokens
            FROM model_usage
            WHERE started_at >= ? AND provider_id NOT LIKE '%coding-plan'
            GROUP BY day
            """,
            binds: [.double(thirtyDaysAgoMs())]
        )?
        .compactMap { row -> (String, Double)? in
            guard case .text(let key) = row[0], case .double(let tokens) = row[1] else { return nil }
            return (key, tokens)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = dayKeyFormatter()
        return (0..<30).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = formatter.string(from: day)
            let tokens = rows?.first { $0.0 == key }?.1 ?? 0
            return DayUsage(date: day, tokens: tokens)
        }
    }

    private static func placeholders(_ count: Int) -> String {
        (0..<count).map { _ in "?" }.joined(separator: ", ")
    }

    // MARK: - 只读查询基建

    /// 列值：TEXT / 数值 / NULL 三态（day 列是 "yyyy-MM-dd" 文本）。
    private enum Column {
        case text(String)
        case double(Double)
        case null
    }

    private enum BindValue {
        case double(Double)
        case text(String)
    }

    /// open/prepare 失败返回 nil（调用方按降级阶梯处理）。
    private static func query(sql: String, binds: [BindValue]) -> [[Column]]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        var handle: OpaquePointer?
        // 同上：WAL 数据库需要可写连接来恢复共享内存；query_only 防止业务查询写入。
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 400)
        sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (index, bind) in binds.enumerated() {
            switch bind {
            case .double(let value): sqlite3_bind_double(statement, Int32(index + 1), value)
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            }
        }

        var rows: [[Column]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            let row = (0..<columnCount).map { column -> Column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT:
                    guard let cString = sqlite3_column_text(statement, column) else { return .null }
                    return .text(String(cString: cString))
                case SQLITE_NULL:
                    return .null
                default:
                    return .double(sqlite3_column_double(statement, column))
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func dayKeyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func thirtyDaysAgoMs() -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        return since.timeIntervalSince1970 * 1000
    }
}

/// 近 30 天单日"全渠道 + 指定渠道"双口径用量（叠加柱状图）。
struct ChannelSplitDayUsage: Equatable {
    let date: Date
    let totalTokens: Double
    let channelTokens: Double

    var otherChannelTokens: Double { max(totalTokens - channelTokens, 0) }
}

/// Z.AI 用量 Store：本地 SQLite 快查，每次额度刷新后重查。
/// coding-plan 模式只查"排除套餐渠道"的本机非套餐日用量（本机套餐部分已含在
/// 服务端套餐口径里，避免双计）；其余模式查询本机全渠道。
@MainActor
final class ZAIUsageStore {
    /// 全渠道 30 天日桶（非 coding-plan 模式使用）。
    private(set) var days: [DayUsage]?
    private(set) var splitDays: [ChannelSplitDayUsage]?
    /// coding-plan 模式的本机非套餐日用量（30 天对齐、缺日补 0；读库失败为 nil）。
    private(set) var thirdPartyDays: [DayUsage]?
    private var isRefreshing = false
    private var isPaceRefreshing = false

    var onChange: (([DayUsage]?, [ChannelSplitDayUsage]?) -> Void)?
    /// 配速图窗口查询结果（逐日桶 + 窗口总量；nil 表示读库失败，走降级）。
    var onPaceChange: (([DayUsage]?, Double?) -> Void)?

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let isCodingPlan = ZAISettings.resolveProviderSelection()?.kind == .codingPlan

        Task.detached(priority: .utility) { [weak self] in
            let thirdParty = isCodingPlan ? ZCodeUsageDB.last30DaysExcludingCodingPlan() : nil
            let allChannels = isCodingPlan ? nil : ZCodeUsageDB.last30Days()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.thirdPartyDays = thirdParty
                self.days = allChannels
                self.splitDays = nil
                self.onChange?(allChannels, nil)
            }
        }
    }

    /// 配速图窗口聚合：额度快照解析出窗口锚点后触发，读库结果经 onPaceChange 回调。
    func refreshPace(windowStart: Date, windowEnd: Date, providerIDs: [String]) {
        guard !isPaceRefreshing else { return }
        isPaceRefreshing = true
        let now = Date()

        Task.detached(priority: .utility) { [weak self] in
            let daily = ZCodeUsageDB.dailyUsage(since: windowStart, until: now, providerIDs: providerIDs)
            let total = ZCodeUsageDB.totalTokens(since: windowStart, until: now, providerIDs: providerIDs)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isPaceRefreshing = false
                self.onPaceChange?(daily, total)
            }
        }
    }

}
