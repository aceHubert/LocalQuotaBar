import Foundation

// MARK: - Z.AI 套餐用量服务端口径（model-usage 接口 + 按账号增量缓存）

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

/// GET {api.z.ai | open.bigmodel.cn}/api/monitor/usage/model-usage。
/// 与 quota/limit 同源认证（ZCode host 以 `/quota/limit` 后缀替换派生本端点），
/// 参数 startTime/endTime 为本地时区 "yyyy-MM-dd HH:mm:ss" 字符串；
/// 窗口 ≤ 8 个自然日返回 hourly 点，≥ 10 个自然日返回 daily 点，> 30 天被拒。
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

// MARK: - 响应解析

/// model-usage 响应的防御式解析结果：x_time 与 tokensUsage 逐点对齐。
/// hourly 点形如 "2026-09-18 13:00"，daily 点形如 "2026-09-18"。
struct ZAIModelUsageResponse {
    enum Granularity: String {
        case hourly, daily
    }

    struct Point: Equatable {
        let timeKey: String
        let tokens: Double
    }

    let points: [Point]
    let granularity: Granularity?

    /// 按 "yyyy-MM-dd" 前缀聚合成日桶（粒度无关，hourly/daily 通用）。
    var dayBuckets: [String: Double] {
        var buckets: [String: Double] = [:]
        for point in points {
            guard point.timeKey.count >= 10 else { continue }
            let day = String(point.timeKey.prefix(10))
            buckets[day, default: 0] += point.tokens
        }
        return buckets
    }

    /// 小时明细按日分组；响应不是 hourly 点（无 " HH:00" 段）时返回 nil。
    var hourlyByDay: [String: [ZAIServerUsageCache.HourPoint]]? {
        var byDay: [String: [ZAIServerUsageCache.HourPoint]] = [:]
        for point in points {
            // hourly key: "yyyy-MM-dd HH:00"（长度 16）；daily key 长度 10。
            guard point.timeKey.count == 16 else { return nil }
            let day = String(point.timeKey.prefix(10))
            byDay[day, default: []].append(
                .init(hourStart: point.timeKey, tokens: point.tokens)
            )
        }
        return byDay
    }

    /// 缺 data / x_time / tokensUsage 或两序列长度不齐时返回 nil（按同步失败处理）。
    static func parse(_ object: [String: Any]) -> ZAIModelUsageResponse? {
        guard let dataPayload = object["data"] as? [String: Any],
              let rawTimes = dataPayload["x_time"] as? [String],
              let rawTokens = dataPayload["tokensUsage"] as? [Any]
        else { return nil }
        guard rawTimes.count == rawTokens.count else { return nil }
        let points = zip(rawTimes, rawTokens).compactMap { time, token -> Point? in
            guard time.count >= 10 else { return nil }
            let value: Double
            if let number = token as? NSNumber {
                value = number.doubleValue
            } else if let string = token as? String, let parsed = Double(string) {
                value = parsed
            } else {
                return nil
            }
            return Point(timeKey: time, tokens: value)
        }
        guard points.count == rawTimes.count else { return nil }
        let granularity = (dataPayload["granularity"] as? String).flatMap(Granularity.init(rawValue:))
        return ZAIModelUsageResponse(points: points, granularity: granularity)
    }
}

// MARK: - 缓存模型

/// 按日组织的账号分桶缓存：日总量与小时明细同层，小时明细仅最近 ~8 天非空。
/// `{ lastDailyFetchedAt, lastHourlyFetchedAt, daily: [{ date, usage, hourly[] }] }`
struct ZAIServerUsageCache: Codable, Equatable {
    struct HourPoint: Codable, Equatable {
        /// "yyyy-MM-dd HH:00"
        let hourStart: String
        let tokens: Double
    }

    struct DayEntry: Codable, Equatable {
        /// "yyyy-MM-dd"
        let date: String
        var usage: Double
        var hourly: [HourPoint]?
    }

    var lastDailyFetchedAt: Date?
    var lastHourlyFetchedAt: Date?
    var daily: [DayEntry] = []
}

// MARK: - 纯逻辑（同步规划 / 合并 / 淘汰 / 切窗，可单测）

enum ZAIServerUsageCacheLogic {
    /// 一次同步的请求计划：daily 与 hourly 是两次逻辑同步（独立窗口、独立时间戳），
    /// 两窗口一致或并集 ≤ 8 个自然日（必返回 hourly）时合并为一次 GET。
    struct SyncPlan: Equatable {
        struct Fetch: Equatable {
            /// 起始日 00:00（含边界日重查，吸收其他设备延迟上报）
            let start: Date
            let servesDaily: Bool
            let servesHourly: Bool
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
    /// T-7（8 个自然日必 hourly，且覆盖周窗口起点落在 T-7 当天的边界）。
    static func planSync(now: Date, cache: ZAIServerUsageCache?,
                         calendar: Calendar = .current) -> SyncPlan {
        let today = calendar.startOfDay(for: now)
        let dailyClamp = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let hourlyClamp = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        let dailyLastSyncDay = cache?.lastDailyFetchedAt.map { calendar.startOfDay(for: $0) }
        let hourlyLastSyncDay = cache?.lastHourlyFetchedAt.map { calendar.startOfDay(for: $0) }

        let dailyStart = dailyLastSyncDay.map { max($0, dailyClamp) } ?? dailyClamp
        let hourlyStart = hourlyLastSyncDay.map { max($0, hourlyClamp) } ?? hourlyClamp

        if dailyStart == hourlyStart {
            return SyncPlan(fetches: [.init(start: dailyStart, servesDaily: true, servesHourly: true)])
        }
        let unionStart = min(dailyStart, hourlyStart)
        if unionStart >= hourlyClamp {
            // 并集窗口 ≤ 8 个自然日：单次 GET（hourly 响应）同时喂两部分。
            return SyncPlan(fetches: [.init(start: unionStart, servesDaily: true, servesHourly: true)])
        }
        let fetches: [SyncPlan.Fetch] = [
            .init(start: dailyStart, servesDaily: true, servesHourly: false),
            // hourly 即使窗口被 daily 覆盖也需单独短窗查询：daily 响应可能是 daily 粒度。
            .init(start: hourlyStart, servesDaily: false, servesHourly: true),
        ]
        return SyncPlan(fetches: fetches)
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
/// 按 SyncPlan 增量拉取并写入账号分桶缓存；失败不动缓存，下次自动补齐。
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
    func preload(bucket: String) {
        guard bucket != currentBucket else { return }
        currentBucket = bucket
        if let data = defaults.data(forKey: Self.storageKey(bucket: bucket)),
           let loaded = try? JSONDecoder().decode(ZAIServerUsageCache.self, from: data) {
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
        var mutated = false
        // endTime 取当天 23:59:59（与实测验证的请求形态一致；服务端不会返回未来点）。
        let calendar = Calendar.current
        let endTime = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))?
            .addingTimeInterval(-1) ?? now

        for fetch in plan.fetches {
            let request = ZAIServerUsageEndpoint.makeModelUsageRequest(
                domain: context.domain,
                authorization: context.authorization,
                startTime: fetch.start,
                endTime: endTime,
                teamContext: context.teamContext
            )
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let parsed = ZAIModelUsageResponse.parse(object)
                else { continue }
                if fetch.servesDaily {
                    ZAIServerUsageCacheLogic.applyDaily(&working, dayBuckets: parsed.dayBuckets,
                                                        fetchedAt: now, now: now)
                    mutated = true
                }
                if fetch.servesHourly, let hourly = parsed.hourlyByDay {
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
