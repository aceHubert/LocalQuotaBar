import Foundation

// MARK: - Z.AI 套餐用量服务端口径（credit-usage 接口 + 按账号增量缓存）
// 2026-09 起 Zcode 改用 credit-usage/usage-detail?usageType=MODEL 拉取模型用量明细；
// 本文件保留旧 model-usage 端点与解析器作为受控回滚路径（source 开关切换）。

/// coding-plan 额度刷新成功后捕获的用量同步上下文：凭证与作用域在请求发起时
/// 固定，响应写回前按 bucket 校验，避免账号切换瞬间串桶。
struct ZAIUsageSyncContext {
    let domain: String
    let email: String?
    let teamContext: ZAITeamContext?
    /// 完整 Authorization 头值（个人 "Bearer <oauth>"；团队 "<apiKey>.<secret>"）。
    let authorization: String

    /// 与周预算 E 相同的分桶思路：domain + 套餐 + 账号邮箱，团队再叠加 org/project。
    var bucket: String {
        Self.bucket(domain: domain, email: email, teamContext: teamContext)
    }

    static func bucket(domain: String, email: String?, teamContext: ZAITeamContext?) -> String {
        var key = "\(domain)-coding-plan|\(email ?? "")"
        if let team = teamContext {
            key += "|\(team.organizationId)/\(team.projectId)"
        }
        return key
    }
}

/// 用量同步数据源：credit 为当前默认；model 保留为本地回滚开关
/// （UserDefaults "local.codex.touchbar.quota.serverPlanUsage.source" = "model"）。
enum ZAIServerUsageSource: String {
    case credit
    case model

    static let overrideKey = "local.codex.touchbar.quota.serverPlanUsage.source"

    static func resolve(defaults: UserDefaults = .standard) -> ZAIServerUsageSource {
        let raw = defaults.string(forKey: overrideKey)?.lowercased()
        return raw == "model" ? .model : .credit
    }
}

enum ZAIServerUsageEndpoint {
    private static func baseURL(domain: String) -> URL {
        URL(string: domain == "bigmodel" ? "https://open.bigmodel.cn" : "https://api.z.ai")!
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// GET {api.z.ai | open.bigmodel.cn}/api/monitor/credit-usage/usage-detail。
    /// Zcode 以 `/usage/quota/limit` 后缀替换派生本端点；作用域参数个人 type=1、
    /// 团队 type=3（团队再带 bigmodel-organization/bigmodel-project 头）。
    /// 窗口跨度决定粒度：≤ 6 个自然日返回 HOUR 点，≥ 7 个自然日返回 DAY 点（实测）。
    static func makeCreditUsageRequest(domain: String,
                                       authorization: String,
                                       startTime: Date,
                                       endTime: Date,
                                       teamContext: ZAITeamContext?) -> URLRequest {
        var components = URLComponents(url: baseURL(domain: domain)
            .appendingPathComponent("api/monitor/credit-usage/usage-detail"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: teamContext != nil ? "3" : "1"),
            URLQueryItem(name: "usageType", value: "MODEL"),
            URLQueryItem(name: "startTime", value: timeFormatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: timeFormatter.string(from: endTime)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "bigmodel-organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "bigmodel-project")
        }
        request.timeoutInterval = 15
        return request
    }

    /// 旧端点（回滚路径）：GET /api/monitor/usage/model-usage。
    /// 参数 startTime/endTime 为本地时区 "yyyy-MM-dd HH:mm:ss" 字符串；
    /// 窗口 ≤ 8 个自然日返回 hourly 点，≥ 10 个自然日返回 daily 点，> 30 天被拒。
    static func makeModelUsageRequest(domain: String,
                                      authorization: String,
                                      startTime: Date,
                                      endTime: Date,
                                      teamContext: ZAITeamContext?) -> URLRequest {
        var components = URLComponents(url: baseURL(domain: domain)
            .appendingPathComponent("api/monitor/usage/model-usage"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "startTime", value: timeFormatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: timeFormatter.string(from: endTime)),
        ]
        if teamContext != nil { items.append(URLQueryItem(name: "type", value: "2")) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "bigmodel-organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "bigmodel-project")
        }
        request.timeoutInterval = 15
        return request
    }
}

// MARK: - 归一化时间点与聚合（两种响应共用）

/// 归一化后的用量点：timeKey 为日键 "yyyy-MM-dd" 或小时键 "yyyy-MM-dd HH:mm[:ss]"。
struct ZAIServerUsagePoint: Equatable {
    let timeKey: String
    let tokens: Double
}

enum ZAIServerUsageSeriesMath {
    /// 按 "yyyy-MM-dd" 前缀聚合成日桶（粒度无关，hourly/daily 通用）。
    static func dayBuckets(_ points: [ZAIServerUsagePoint]) -> [String: Double] {
        var buckets: [String: Double] = [:]
        for point in points {
            guard point.timeKey.count >= 10 else { continue }
            let day = String(point.timeKey.prefix(10))
            buckets[day, default: 0] += point.tokens
        }
        return buckets
    }

    /// 小时明细按日分组；响应不是 hourly 点（键无 " HH:mm" 段）时返回 nil。
    /// 小时键统一截断为 "yyyy-MM-dd HH:mm"（credit 的带秒键与旧键在此归一）。
    static func hourlyByDay(_ points: [ZAIServerUsagePoint]) -> [String: [ZAIServerUsageCache.HourPoint]]? {
        var byDay: [String: [ZAIServerUsageCache.HourPoint]] = [:]
        for point in points {
            guard isHourlyKey(point.timeKey) else { return nil }
            let day = String(point.timeKey.prefix(10))
            byDay[day, default: []].append(
                .init(hourStart: String(point.timeKey.prefix(16)), tokens: point.tokens)
            )
        }
        return byDay
    }

    /// daily 键长 10；hourly 键 ≥ 16 且第 11 位是空格（"yyyy-MM-dd HH:mm[:ss]"）。
    static func isHourlyKey(_ timeKey: String) -> Bool {
        guard timeKey.count >= 16 else { return false }
        let spaceIndex = timeKey.index(timeKey.startIndex, offsetBy: 10)
        return timeKey[spaceIndex] == " "
    }
}

// MARK: - 响应解析

/// credit-usage usage-detail MODEL 明细的防御式解析。
/// 契约（2026-09 实测，个人 type=1 与团队 type=3 一致）：
/// `{code,msg,success,data:{granularity:"HOUR"|"DAY",timezone,modelUsage:{xTime,modelDataList}}}`；
/// xTime 小时键带秒 "yyyy-MM-dd HH:mm:ss"、日键 "yyyy-MM-dd"；
/// modelDataList 每项携带与 xTime 等长的分组序列（totalTokensUsage 优先，
/// 回退 tokensUsage，再回退 cached+uncached+output 逐点求和），
/// 逐模型求和得到 Token 总量点；creditsUsage 系列与本解析无关（不得混入 Token）。
struct ZAICreditUsageResponse {
    enum Granularity: Equatable {
        case hourly, daily
    }

    /// 汇总桶行（Zcode 的 isCreditUsageBreakdownBucket）：modelCode 命中
    /// 分组编码或 modelName 为 缓存/未缓存/输出。这些行是对模型的二次拆分，
    /// 逐模型求和时必须排除，否则 Token 双计。
    private static let breakdownModelCodes: Set<String> = [
        "cached_input", "cachedInput", "cache_input", "cacheInput",
        "uncached_input", "uncachedInput", "output", "output_tokens", "outputTokens",
    ]
    private static let breakdownModelNames: Set<String> = ["缓存", "未缓存", "输出"]

    let points: [ZAIServerUsagePoint]
    let granularity: Granularity?

    var dayBuckets: [String: Double] { ZAIServerUsageSeriesMath.dayBuckets(points) }

    var hourlyByDay: [String: [ZAIServerUsageCache.HourPoint]]? {
        ZAIServerUsageSeriesMath.hourlyByDay(points)
    }

    /// 缺 data / modelUsage / xTime 时返回 nil（按同步失败处理）。
    /// modelDataList 为空数组视为合法零用量（xTime 存在即对齐出全 0 点）。
    static func parse(_ object: [String: Any]) -> ZAICreditUsageResponse? {
        guard let dataPayload = object["data"] as? [String: Any],
              let usage = dataPayload["modelUsage"] as? [String: Any],
              let rawTimes = usage["xTime"] as? [String]
        else { return nil }
        let models = (usage["modelDataList"] as? [[String: Any]]) ?? []

        var totals = [Double](repeating: 0, count: rawTimes.count)
        for model in models where !isBreakdownBucket(model) {
            let series = tokenSeries(model, count: rawTimes.count)
            for (index, value) in series.enumerated() { totals[index] += value }
        }
        let points = zip(rawTimes, totals).map { ZAIServerUsagePoint(timeKey: $0, tokens: $1) }
        let granularity = (dataPayload["granularity"] as? String).flatMap(granularity(from:))
            ?? (rawTimes.first.map { ZAIServerUsageSeriesMath.isHourlyKey($0) ? Granularity.hourly : Granularity.daily })
        return ZAICreditUsageResponse(points: points, granularity: granularity)
    }

    private static func granularity(from raw: String) -> Granularity? {
        switch raw.uppercased() {
        case "HOUR", "HOURLY": return .hourly
        case "DAY", "DAILY": return .daily
        default: return nil
        }
    }

    private static func isBreakdownBucket(_ model: [String: Any]) -> Bool {
        if let code = (model["modelCode"] as? String)?.trimmingCharacters(in: .whitespaces),
           !code.isEmpty, breakdownModelCodes.contains(code) {
            return true
        }
        guard let name = (model["modelName"] as? String)?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return breakdownModelNames.contains(name)
    }

    /// 单模型 Token 序列：totalTokensUsage → tokensUsage → 分组三序列逐点求和；
    /// 序列比 xTime 短补 0，长则截断（对齐 Zcode alignUsageSeries 的容错语义）。
    private static func tokenSeries(_ model: [String: Any], count: Int) -> [Double] {
        if let series = numericSeries(model["totalTokensUsage"]) { return padded(series, count: count) }
        if let series = numericSeries(model["tokensUsage"]) { return padded(series, count: count) }
        var sum: [Double]? = nil
        for key in ["cachedInputTokensUsage", "uncachedInputTokensUsage", "outputTokensUsage"] {
            guard let series = numericSeries(model[key]) else { continue }
            if sum == nil { sum = [Double](repeating: 0, count: count) }
            for (index, value) in padded(series, count: count).enumerated() { sum![index] += value }
        }
        return sum ?? [Double](repeating: 0, count: count)
    }

    /// 数值数组：元素可为数字或数字字符串（credits 系列实测为字符串）。
    private static func numericSeries(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        return array.map { element -> Double in
            if let number = element as? NSNumber { return number.doubleValue }
            if let string = element as? String, let parsed = Double(string) { return parsed }
            return 0
        }
    }

    private static func padded(_ series: [Double], count: Int) -> [Double] {
        guard series.count != count else { return series }
        if series.count > count { return Array(series.prefix(count)) }
        return series + [Double](repeating: 0, count: count - series.count)
    }
}

/// 旧 model-usage 响应的防御式解析（回滚路径）：x_time 与 tokensUsage 逐点对齐。
/// hourly 点形如 "2026-09-18 13:00"，daily 点形如 "2026-09-18"。
struct ZAIModelUsageResponse {
    enum Granularity: String {
        case hourly, daily
    }

    let points: [ZAIServerUsagePoint]
    let granularity: Granularity?

    var dayBuckets: [String: Double] { ZAIServerUsageSeriesMath.dayBuckets(points) }

    var hourlyByDay: [String: [ZAIServerUsageCache.HourPoint]]? {
        ZAIServerUsageSeriesMath.hourlyByDay(points)
    }

    /// 缺 data / x_time / tokensUsage 或两序列长度不齐时返回 nil（按同步失败处理）。
    static func parse(_ object: [String: Any]) -> ZAIModelUsageResponse? {
        guard let dataPayload = object["data"] as? [String: Any],
              let rawTimes = dataPayload["x_time"] as? [String],
              let rawTokens = dataPayload["tokensUsage"] as? [Any]
        else { return nil }
        guard rawTimes.count == rawTokens.count else { return nil }
        let points = zip(rawTimes, rawTokens).compactMap { time, token -> ZAIServerUsagePoint? in
            guard time.count >= 10 else { return nil }
            let value: Double
            if let number = token as? NSNumber {
                value = number.doubleValue
            } else if let string = token as? String, let parsed = Double(string) {
                value = parsed
            } else {
                return nil
            }
            return ZAIServerUsagePoint(timeKey: time, tokens: value)
        }
        guard points.count == rawTimes.count else { return nil }
        let granularity = (dataPayload["granularity"] as? String).flatMap(Granularity.init(rawValue:))
        return ZAIModelUsageResponse(points: points, granularity: granularity)
    }
}

// MARK: - 缓存模型

/// 按日组织的账号分桶缓存：日总量与小时明细同层，小时明细仅最近 ~8 天非空。
/// `{ schema, lastDailyFetchedAt, lastHourlyFetchedAt, daily: [{ date, usage, hourly[] }] }`
struct ZAIServerUsageCache: Codable, Equatable {
    struct HourPoint: Codable, Equatable {
        /// "yyyy-MM-dd HH:mm"
        let hourStart: String
        let tokens: Double
    }

    struct DayEntry: Codable, Equatable {
        /// "yyyy-MM-dd"
        let date: String
        var usage: Double
        var hourly: [HourPoint]?
    }

    /// 当前缓存 schema：2 = credit-usage 时代；nil（解码缺省）= 旧 model-usage
    /// 写入的兼容格式（同为 Token 口径，保留）。仅当缓存 schema 高于当前版本
    /// （降级运行）时丢弃重同步。
    static let currentSchema = 2

    var schema: Int?
    var lastDailyFetchedAt: Date?
    var lastHourlyFetchedAt: Date?
    var daily: [DayEntry] = []
}

// MARK: - 纯逻辑（同步规划 / 合并 / 淘汰 / 切窗，可单测）

enum ZAIServerUsageCacheLogic {
    /// 一次同步的请求计划：daily 与 hourly 是两次逻辑同步（独立窗口、独立时间戳）。
    /// 请求窗口 ≤ 6 个自然日时合并为一次 GET（必返回 HOUR 点，同时喂两部分）。
    struct SyncPlan: Equatable {
        struct Fetch: Equatable {
            /// 起始日 00:00（含边界日重查，吸收其他设备延迟上报）
            let start: Date
            /// 结束日（startOfDay）；nil 表示今天。hourly 短窗请求按日边界切块，
            /// 实际请求的 endTime 取该日 23:59:59。
            let end: Date?
            let servesDaily: Bool
            let servesHourly: Bool

            init(start: Date, end: Date? = nil, servesDaily: Bool, servesHourly: Bool) {
                self.start = start
                self.end = end
                self.servesDaily = servesDaily
                self.servesHourly = servesHourly
            }
        }

        let fetches: [Fetch]
        var isEmpty: Bool { fetches.isEmpty }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// 统一增量规则：`queryStart = max(上次成功同步日 ?? clamp, clamp)`。
    /// 覆盖进度以 lastDailyFetchedAt / lastHourlyFetchedAt 时间戳为准——日条目
    /// 可能由 hourly 同步先行创建（usage = sum(hourly)），按最大条目日期推导
    /// 会把 daily 的历史缺口永久留下。daily 钳位 T-29（30 天图），hourly 钳位
    /// T-7（8 个自然日周窗，且覆盖周窗口起点落在 T-7 当天的边界）。
    ///
    /// credit-usage 的粒度阈值是窗口 ≤ 6 个自然日返回 HOUR、≥ 7 天返回 DAY
    /// （实测 6 天 = HOUR、7 天 = DAY，与旧 model-usage 的 8 天阈值不同）：
    /// - 并集窗口 ≤ 6 天（unionStart ≥ T-5）才允许 daily+hourly 合并为一次 GET；
    /// - hourly 窗口跨度 > 6 天时按日边界切成 ≤ 6 天的块（8 天周窗 = 两块），
    ///   块间无重叠，applyHourly 按日合并。
    static func planSync(now: Date, cache: ZAIServerUsageCache?,
                         calendar: Calendar = .current) -> SyncPlan {
        let today = calendar.startOfDay(for: now)
        let dailyClamp = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let hourlyClamp = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let hourlyMergeClamp = calendar.date(byAdding: .day, value: -5, to: today) ?? today

        let dailyLastSyncDay = cache?.lastDailyFetchedAt.map { calendar.startOfDay(for: $0) }
        let hourlyLastSyncDay = cache?.lastHourlyFetchedAt.map { calendar.startOfDay(for: $0) }

        let dailyStart = dailyLastSyncDay.map { max($0, dailyClamp) } ?? dailyClamp
        let hourlyStart = hourlyLastSyncDay.map { max($0, hourlyClamp) } ?? hourlyClamp

        let unionStart = min(dailyStart, hourlyStart)
        if unionStart >= hourlyMergeClamp {
            // 并集窗口 ≤ 6 个自然日：单次 GET（HOUR 响应）同时喂两部分。
            return SyncPlan(fetches: [.init(start: unionStart, servesDaily: true, servesHourly: true)])
        }
        // hourly 即使窗口被 daily 覆盖也需独立短窗请求：daily 请求是 30 天窗（DAY 粒度）。
        return SyncPlan(fetches: [.init(start: dailyStart, servesDaily: true, servesHourly: false)]
            + hourlyFetches(from: hourlyStart, to: today, calendar: calendar))
    }

    /// hourly 短窗切块：每块跨度 ≤ 6 个自然日（credit-usage 返回 HOUR 点的上限），
    /// 起止均落在日边界；首块起点 = 增量起点，末块终点 = 今天。
    static func hourlyFetches(from start: Date, to today: Date,
                              calendar: Calendar = .current) -> [SyncPlan.Fetch] {
        var fetches: [SyncPlan.Fetch] = []
        var cursor = start
        while cursor <= today {
            let chunkEnd = calendar.date(byAdding: .day, value: 5, to: cursor) ?? today
            let clampedEnd = min(chunkEnd, today)
            fetches.append(.init(start: cursor, end: clampedEnd,
                                 servesDaily: false, servesHourly: true))
            guard let next = calendar.date(byAdding: .day, value: 6, to: cursor), next <= today else { break }
            cursor = next
        }
        return fetches
    }

    /// 日桶覆盖写（replace，非 sum）：同一查询窗口重叠拉两次不双计；
    /// 淘汰日期 < T-29 的日条目；hourly 字段保留不动（归 hourly 同步管）。
    static func applyDaily(_ cache: inout ZAIServerUsageCache,
                           dayBuckets: [String: Double],
                           fetchedAt: Date,
                           now: Date,
                           calendar: Calendar = .current) {
        let evictionKey = dayKey(calendar.date(byAdding: .day, value: -29,
                                               to: calendar.startOfDay(for: now)) ?? now)
        var byDate: [String: ZAIServerUsageCache.DayEntry] = [:]
        for entry in cache.daily where entry.date >= evictionKey {
            byDate[entry.date] = entry
        }
        for (day, tokens) in dayBuckets where day >= evictionKey {
            if var entry = byDate[day] {
                entry.usage = tokens
                byDate[day] = entry
            } else {
                byDate[day] = ZAIServerUsageCache.DayEntry(date: day, usage: tokens, hourly: nil)
            }
        }
        cache.daily = byDate.values.sorted { $0.date < $1.date }
        cache.lastDailyFetchedAt = fetchedAt
    }

    /// 小时明细覆盖写：日条目缺失时以 sum(hourly) 建立 usage（daily 同步随后覆盖为权威值）；
    /// 淘汰日期 < T-7 的小时明细（保留日条目本身）。
    static func applyHourly(_ cache: inout ZAIServerUsageCache,
                            hourlyByDay: [String: [ZAIServerUsageCache.HourPoint]],
                            fetchedAt: Date,
                            now: Date,
                            calendar: Calendar = .current) {
        let evictionKey = dayKey(calendar.date(byAdding: .day, value: -7,
                                               to: calendar.startOfDay(for: now)) ?? now)
        var byDate: [String: ZAIServerUsageCache.DayEntry] = cache.daily.reduce(into: [:]) { $0[$1.date] = $1 }
        for (day, points) in hourlyByDay {
            guard day >= evictionKey else { continue }
            let dayTotal = points.reduce(0) { $0 + $1.tokens }
            if var existing = byDate[day] {
                existing.hourly = points
                byDate[day] = existing
            } else {
                byDate[day] = ZAIServerUsageCache.DayEntry(date: day, usage: dayTotal, hourly: points)
            }
        }
        cache.daily = byDate.values
            .map { entry in
                guard entry.date < evictionKey else { return entry }
                var stripped = entry
                stripped.hourly = nil
                return stripped
            }
            .sorted { $0.date < $1.date }
        cache.lastHourlyFetchedAt = fetchedAt
    }

    /// 周窗口切窗求和：起点按小时边界近似（含起点所在小时桶），逐日输出窗口内日桶。
    /// 无任何小时明细时返回 nil（配速图走空数据降级）。
    static func windowUsage(cache: ZAIServerUsageCache?,
                            windowStart: Date,
                            now: Date,
                            calendar: Calendar = .current) -> (daily: [DayUsage], total: Double)? {
        guard let cache else { return nil }
        let hourFormatter = DateFormatter()
        hourFormatter.locale = Locale(identifier: "en_US_POSIX")
        hourFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let hourFloor = calendar.dateInterval(of: .hour, for: windowStart)?.start ?? windowStart
        var byDay: [String: Double] = [:]
        var total: Double = 0
        for entry in cache.daily {
            guard let hourly = entry.hourly else { continue }
            for point in hourly {
                guard let hour = hourFormatter.date(from: point.hourStart),
                      hour >= hourFloor, hour <= now
                else { continue }
                byDay[entry.date, default: 0] += point.tokens
                total += point.tokens
            }
        }
        guard !byDay.isEmpty else { return nil }

        let today = calendar.startOfDay(for: now)
        var daily: [DayUsage] = []
        var cursor = calendar.startOfDay(for: hourFloor)
        while cursor <= today {
            let key = dayKey(cursor)
            let tokens = byDay[key] ?? 0
            if tokens > 0 { daily.append(DayUsage(date: cursor, tokens: tokens)) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (daily, total)
    }
}

// MARK: - 服务端用量 Store

/// 套餐用量的服务端同步器：挂在额度刷新成功后（复用同一凭证上下文），
/// 按 SyncPlan 增量拉取（默认 credit-usage MODEL 明细，可切回 model-usage）
/// 并写入账号分桶缓存；失败不动缓存，下次自动补齐。
@MainActor
final class ZAIServerUsageStore {
    private let session: URLSession
    private let defaults: UserDefaults

    private var currentBucket: String?
    private(set) var cache: ZAIServerUsageCache?
    private var isSyncing = false

    var onChange: ((ZAIServerUsageCache?) -> Void)?

    init(defaults: UserDefaults = .standard) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        self.defaults = defaults
    }

    private static func storageKey(bucket: String) -> String {
        "local.codex.touchbar.quota.serverPlanUsage.\(bucket)"
    }

    /// 启动回放：只按 bucket 载入已持久化的缓存，不发起请求。
    /// 首次网络同步到达前图表先有昨日读数，避免启动瞬间空白。
    /// schema 为 nil（旧 model-usage 写入）时保留——同为 Token 口径与键格式；
    /// 高于当前版本的缓存（降级运行）安全丢弃，待下次同步重建。
    func preload(bucket: String) {
        guard bucket != currentBucket else { return }
        currentBucket = bucket
        if let data = defaults.data(forKey: Self.storageKey(bucket: bucket)),
           let loaded = try? JSONDecoder().decode(ZAIServerUsageCache.self, from: data),
           (loaded.schema ?? ZAIServerUsageCache.currentSchema) <= ZAIServerUsageCache.currentSchema {
            cache = loaded
        } else {
            cache = nil
        }
        onChange?(cache)
    }

    /// 额度刷新成功后调用；context 携带发起时刻的凭证与作用域。
    func sync(context: ZAIUsageSyncContext) {
        guard !isSyncing else { return }
        isSyncing = true

        let bucket = context.bucket
        if bucket != currentBucket {
            preload(bucket: bucket)
        }

        let now = Date()
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache)
        guard !plan.isEmpty else {
            isSyncing = false
            return
        }

        Task { [weak self] in
            await self?.run(plan: plan, context: context, now: now)
        }
    }

    private func run(plan: ZAIServerUsageCacheLogic.SyncPlan,
                     context: ZAIUsageSyncContext,
                     now: Date) async {
        var working = cache ?? ZAIServerUsageCache()
        working.schema = ZAIServerUsageCache.currentSchema
        var mutated = false
        let calendar = Calendar.current
        // 请求 endTime 取结束日 23:59:59（与实测验证的请求形态一致；服务端不会返回未来点）。
        let source = ZAIServerUsageSource.resolve(defaults: defaults)

        for fetch in plan.fetches {
            let endDay = fetch.end ?? now
            let endTime = calendar.date(byAdding: .day, value: 1,
                                        to: calendar.startOfDay(for: endDay))?
                .addingTimeInterval(-1) ?? now
            let request: URLRequest
            switch source {
            case .credit:
                request = ZAIServerUsageEndpoint.makeCreditUsageRequest(
                    domain: context.domain,
                    authorization: context.authorization,
                    startTime: fetch.start,
                    endTime: endTime,
                    teamContext: context.teamContext
                )
            case .model:
                request = ZAIServerUsageEndpoint.makeModelUsageRequest(
                    domain: context.domain,
                    authorization: context.authorization,
                    startTime: fetch.start,
                    endTime: endTime,
                    teamContext: context.teamContext
                )
            }
            do {
                let (data, response) = try await session.data(for: request)
                let points: [ZAIServerUsagePoint]
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                switch source {
                case .credit:
                    guard let parsed = ZAICreditUsageResponse.parse(object) else { continue }
                    points = parsed.points
                case .model:
                    guard let parsed = ZAIModelUsageResponse.parse(object) else { continue }
                    points = parsed.points
                }
                if fetch.servesDaily {
                    ZAIServerUsageCacheLogic.applyDaily(&working, dayBuckets: ZAIServerUsageSeriesMath.dayBuckets(points),
                                                        fetchedAt: now, now: now)
                    mutated = true
                }
                if fetch.servesHourly, let hourly = ZAIServerUsageSeriesMath.hourlyByDay(points) {
                    ZAIServerUsageCacheLogic.applyHourly(&working, hourlyByDay: hourly,
                                                         fetchedAt: now, now: now)
                    mutated = true
                }
            } catch {
                // 单个 fetch 失败：该部分缓存不动，下个周期由增量规则自动补齐。
                continue
            }
        }

        let bucket = context.bucket
        if mutated {
            if let data = try? JSONEncoder().encode(working) {
                defaults.set(data, forKey: Self.storageKey(bucket: bucket))
            }
        }
        isSyncing = false
        // 分桶校验：账号已切换时只落盘旧账号缓存，不更新内存展示。
        guard bucket == currentBucket else { return }
        cache = mutated ? working : cache
        if mutated { onChange?(cache) }
    }

    // MARK: - 读取

    /// 近 30 天套餐日桶（与服务端窗口对齐、缺日补 0）；无缓存返回 nil。
    func last30DayUsage(now: Date = Date(), calendar: Calendar = .current) -> [DayUsage]? {
        guard let cache else { return nil }
        let today = calendar.startOfDay(for: now)
        var byDay: [String: Double] = [:]
        for entry in cache.daily { byDay[entry.date] = entry.usage }
        return (0..<30).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayUsage(date: day, tokens: byDay[ZAIServerUsageCacheLogic.dayKey(day)] ?? 0)
        }
    }

    /// 周窗口切窗（见 ZAIServerUsageCacheLogic.windowUsage）。
    func windowUsage(windowStart: Date, now: Date = Date()) -> (daily: [DayUsage], total: Double)? {
        ZAIServerUsageCacheLogic.windowUsage(cache: cache, windowStart: windowStart, now: now)
    }
}
