import XCTest
@testable import LocalQuotaBar

final class ZAIServerUsageTests: XCTestCase {
    private var calendar: Calendar { .current }

    private func dayKey(_ date: Date) -> String {
        ZAIServerUsageCacheLogic.dayKey(date)
    }

    private func day(_ offset: Int, from now: Date, hour: Int = 12) -> Date {
        let base = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    // MARK: - 请求构造

    func testModelUsageRequestPersonal() throws {
        let start = day(-1, from: Date())
        let end = day(0, from: Date())
        let request = ZAIServerUsageEndpoint.makeModelUsageRequest(
            domain: "zai", authorization: "Bearer oauth-token",
            startTime: start, endTime: end, teamContext: nil
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.z.ai")
        XCTAssertEqual(url.path, "/api/monitor/usage/model-usage")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["startTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: start))
        XCTAssertEqual(items["endTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: end))
        XCTAssertNil(items["type"], "个人套餐不带 type=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "bigmodel-organization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "bigmodel-project"))
    }

    func testModelUsageRequestTeamUsesBigModelScope() throws {
        let context = ZAITeamContext(productId: "product-test", organizationId: "org-test", projectId: "proj-test")
        let start = day(-1, from: Date())
        let end = day(0, from: Date())
        let request = ZAIServerUsageEndpoint.makeModelUsageRequest(
            domain: "bigmodel", authorization: "api-key.secret",
            startTime: start, endTime: end, teamContext: context
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://open.bigmodel.cn/api/monitor/usage/model-usage?"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "2")
        XCTAssertEqual(items["startTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: start))
        XCTAssertEqual(items["endTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: end))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "api-key.secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-organization"), "org-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-project"), "proj-test")
    }

    // MARK: - 响应解析

    func testParseHourlyResponseAggregatesDayBuckets() throws {
        let response = try XCTUnwrap(ZAIModelUsageResponse.parse([
            "data": [
                "granularity": "hourly",
                "x_time": ["2026-09-18 13:00", "2026-09-18 14:00", "2026-09-19 09:00"],
                "tokensUsage": [100, 20.5, 7],
            ]
        ]))
        XCTAssertEqual(response.granularity, .hourly)
        XCTAssertEqual(response.dayBuckets["2026-09-18"], 120.5)
        XCTAssertEqual(response.dayBuckets["2026-09-19"], 7)
        let hourly = try XCTUnwrap(response.hourlyByDay)
        XCTAssertEqual(hourly["2026-09-18"]?.count, 2)
        XCTAssertEqual(hourly["2026-09-18"]?.first?.hourStart, "2026-09-18 13:00")
    }

    func testParseDailyResponseHasNoHourlyDetail() throws {
        let response = try XCTUnwrap(ZAIModelUsageResponse.parse([
            "data": [
                "granularity": "daily",
                "x_time": ["2026-09-18", "2026-09-19"],
                "tokensUsage": [110699552, 44678517],
            ]
        ]))
        XCTAssertEqual(response.granularity, .daily)
        XCTAssertEqual(response.dayBuckets["2026-09-18"], 110699552)
        XCTAssertNil(response.hourlyByDay)
    }

    func testParseRejectsMalformedPayloads() {
        XCTAssertNil(ZAIModelUsageResponse.parse(["msg": "no data"]))
        XCTAssertNil(ZAIModelUsageResponse.parse(["data": ["x_time": ["2026-09-18"]]]))
        XCTAssertNil(ZAIModelUsageResponse.parse([
            "data": ["x_time": ["2026-09-18"], "tokensUsage": [1, 2]]
        ]))
    }

    // MARK: - 增量同步规划

    func testPlanSyncFirstRunQueriesFullWindowAndHourlyWindow() {
        let now = day(0, from: Date())
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: nil, calendar: calendar)
        XCTAssertEqual(plan.fetches.count, 2)
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertFalse(plan.fetches[0].servesHourly)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: day(-29, from: now)))
        XCTAssertFalse(plan.fetches[1].servesDaily)
        XCTAssertTrue(plan.fetches[1].servesHourly)
        XCTAssertEqual(plan.fetches[1].start, calendar.startOfDay(for: day(-7, from: now)))
    }

    func testPlanSyncSteadyStateMergesIntoSingleFetch() {
        let now = day(0, from: Date())
        let yesterday = day(-1, from: now)
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: yesterday,
            lastHourlyFetchedAt: yesterday,
            daily: [
                .init(date: dayKey(yesterday), usage: 10,
                      hourly: [.init(hourStart: "\(dayKey(yesterday)) 08:00", tokens: 10)]),
            ]
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        XCTAssertEqual(plan.fetches.count, 1)
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertTrue(plan.fetches[0].servesHourly)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: yesterday))
    }

    func testPlanSyncSyncedTodayQueriesTodayOnly() {
        let now = day(0, from: Date())
        let today = dayKey(now)
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: now,
            lastHourlyFetchedAt: now,
            daily: [
                .init(date: today, usage: 10, hourly: [.init(hourStart: "\(today) 08:00", tokens: 10)]),
            ]
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        XCTAssertEqual(plan.fetches.count, 1)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: now))
    }

    func testPlanSyncLongDailyGapSplitsIntoTwoFetches() {
        let now = day(0, from: Date())
        let oldDaily = day(-10, from: now)
        let today = dayKey(now)
        // hourly 先行创建了今天的日条目（usage = sum(hourly)），daily 覆盖进度
        // 必须以 lastDailyFetchedAt 为准，否则 T-9/T-8 的缺口永远不会补。
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: oldDaily,
            lastHourlyFetchedAt: now,
            daily: [
                .init(date: dayKey(oldDaily), usage: 10, hourly: nil),
                .init(date: today, usage: 5, hourly: [.init(hourStart: "\(today) 08:00", tokens: 5)]),
            ]
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        // daily 停在 T-10，与 hourly（今天）的并集 < T-7，不能合并（响应会是 daily 粒度）。
        XCTAssertEqual(plan.fetches.count, 2)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: oldDaily))
        XCTAssertEqual(plan.fetches[1].start, calendar.startOfDay(for: now))
    }

    func testPlanSyncShortDailyGapMergesIntoSingleHourlyFetch() {
        let now = day(0, from: Date())
        let recent = day(-5, from: now)
        let today = dayKey(now)
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: recent,
            lastHourlyFetchedAt: now,
            daily: [
                .init(date: dayKey(recent), usage: 10, hourly: nil),
                .init(date: today, usage: 5, hourly: [.init(hourStart: "\(today) 08:00", tokens: 5)]),
            ]
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        // 并集 T-5 ≥ T-7：窗口 6 个自然日必为 hourly，单请求同时喂两部分。
        XCTAssertEqual(plan.fetches.count, 1)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: recent))
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertTrue(plan.fetches[0].servesHourly)
    }

    // MARK: - 缓存写入（覆盖写 / 淘汰）

    func testApplyDailyReplacesInsteadOfSumming() {
        let now = day(0, from: Date())
        let today = dayKey(now)
        var cache = ZAIServerUsageCache(daily: [
            .init(date: today, usage: 100, hourly: [.init(hourStart: "\(today) 08:00", tokens: 100)]),
        ])
        ZAIServerUsageCacheLogic.applyDaily(&cache, dayBuckets: [today: 120], fetchedAt: now, now: now)
        XCTAssertEqual(cache.daily.first?.usage, 120)
        // hourly 字段归 hourly 同步管，daily 覆盖写不动它
        XCTAssertEqual(cache.daily.first?.hourly?.count, 1)
    }

    func testApplyDailyEvictsEntriesBeyondThirtyDays() {
        let now = day(0, from: Date())
        var cache = ZAIServerUsageCache(daily: [
            .init(date: dayKey(day(-40, from: now)), usage: 1, hourly: nil),
            .init(date: dayKey(day(-29, from: now)), usage: 2, hourly: nil),
            .init(date: dayKey(day(-28, from: now)), usage: 3, hourly: nil),
        ])
        ZAIServerUsageCacheLogic.applyDaily(&cache, dayBuckets: [:], fetchedAt: now, now: now)
        XCTAssertEqual(cache.daily.map(\.date), [dayKey(day(-29, from: now)), dayKey(day(-28, from: now))])
        XCTAssertEqual(cache.lastDailyFetchedAt, now)
    }

    func testApplyHourlyCreatesMissingDayAndEvictsOldDetail() {
        let now = day(0, from: Date())
        let today = dayKey(now)
        let oldDay = dayKey(day(-8, from: now))
        var cache = ZAIServerUsageCache(daily: [
            .init(date: oldDay, usage: 5, hourly: [.init(hourStart: "\(oldDay) 08:00", tokens: 5)]),
        ])
        ZAIServerUsageCacheLogic.applyHourly(
            &cache,
            hourlyByDay: [today: [.init(hourStart: "\(today) 09:00", tokens: 3),
                                  .init(hourStart: "\(today) 10:00", tokens: 4)]],
            fetchedAt: now, now: now
        )
        XCTAssertEqual(cache.daily.count, 2)
        let oldEntry = cache.daily.first { $0.date == oldDay }
        XCTAssertNotNil(oldEntry)
        XCTAssertNil(oldEntry?.hourly, "超过 7 天的小时明细应被淘汰")
        XCTAssertEqual(oldEntry?.usage, 5, "淘汰小时明细不影响日条目本身")
        let newEntry = cache.daily.first { $0.date == today }
        XCTAssertEqual(newEntry?.usage, 7, "缺失日条目以 sum(hourly) 建立")
        XCTAssertEqual(newEntry?.hourly?.count, 2)
        XCTAssertEqual(cache.lastHourlyFetchedAt, now)
    }

    // MARK: - 周窗口切窗

    func testWindowUsageCutsAtHourBoundary() throws {
        let now = day(0, from: Date())
        let startDay = dayKey(day(-2, from: now))
        let midDay = dayKey(day(-1, from: now))
        let today = dayKey(now)
        let cache = ZAIServerUsageCache(daily: [
            .init(date: startDay, usage: 100, hourly: [
                .init(hourStart: "\(startDay) 06:00", tokens: 10),
                .init(hourStart: "\(startDay) 13:00", tokens: 20),
            ]),
            .init(date: midDay, usage: 60, hourly: [
                .init(hourStart: "\(midDay) 01:00", tokens: 60),
            ]),
            .init(date: today, usage: 9, hourly: [
                .init(hourStart: "\(today) 09:00", tokens: 9),
            ]),
        ])
        // 窗口起点在 startDay 12:30：所在小时（13:00 桶不含 12 点）按小时边界近似。
        let windowStart = calendar.date(byAdding: .minute, value: 30,
                                        to: calendar.date(bySettingHour: 12, minute: 0, second: 0,
                                                          of: day(-2, from: now))!)!
        let result = try XCTUnwrap(
            ZAIServerUsageCacheLogic.windowUsage(cache: cache, windowStart: windowStart, now: now)
        )
        // 06:00 桶在窗口前被切掉：20 + 60 + 9
        XCTAssertEqual(result.total, 89)
        XCTAssertEqual(result.daily.count, 3)
        XCTAssertEqual(result.daily.first?.tokens, 20)
        XCTAssertEqual(result.daily.last?.tokens, 9)
    }

    func testWindowUsageWithoutHourlyDetailReturnsNil() {
        let now = day(0, from: Date())
        let cache = ZAIServerUsageCache(daily: [
            .init(date: dayKey(now), usage: 100, hourly: nil),
        ])
        XCTAssertNil(ZAIServerUsageCacheLogic.windowUsage(cache: cache, windowStart: day(-2, from: now), now: now))
        XCTAssertNil(ZAIServerUsageCacheLogic.windowUsage(cache: nil, windowStart: day(-2, from: now), now: now))
    }

    // MARK: - 分桶标识

    func testSyncContextBucketIncludesTeamScope() {
        let personal = ZAIUsageSyncContext(domain: "zai", email: "a@b.c", teamContext: nil,
                                           authorization: "Bearer t")
        XCTAssertEqual(personal.bucket, "zai-coding-plan|a@b.c")
        let team = ZAIUsageSyncContext(
            domain: "bigmodel", email: "a@b.c",
            teamContext: ZAITeamContext(productId: nil, organizationId: "org", projectId: "proj"),
            authorization: "key.secret"
        )
        XCTAssertEqual(team.bucket, "bigmodel-coding-plan|a@b.c|org/proj")
    }
}
