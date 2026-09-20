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

    // MARK: - credit-usage 请求构造

    func testCreditUsageRequestPersonal() throws {
        let start = day(-1, from: Date())
        let end = day(0, from: Date())
        let request = ZAIServerUsageEndpoint.makeCreditUsageRequest(
            domain: "zai", authorization: "Bearer oauth-token",
            startTime: start, endTime: end, teamContext: nil
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.z.ai")
        XCTAssertEqual(url.path, "/api/monitor/credit-usage/usage-detail")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "1", "个人套餐 type=1")
        XCTAssertEqual(items["usageType"], "MODEL")
        XCTAssertEqual(items["startTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: start))
        XCTAssertEqual(items["endTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: end))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "bigmodel-organization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "bigmodel-project"))
    }

    func testCreditUsageRequestTeamUsesType3AndBigModelScope() throws {
        let context = ZAITeamContext(productId: "product-test", organizationId: "org-test", projectId: "proj-test")
        let start = day(-1, from: Date())
        let end = day(0, from: Date())
        let request = ZAIServerUsageEndpoint.makeCreditUsageRequest(
            domain: "bigmodel", authorization: "api-key.secret",
            startTime: start, endTime: end, teamContext: context
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://open.bigmodel.cn/api/monitor/credit-usage/usage-detail?"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "3", "团队套餐 type=3（非旧接口的 type=2）")
        XCTAssertEqual(items["usageType"], "MODEL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "api-key.secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-organization"), "org-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-project"), "proj-test")
    }

    // MARK: - 旧 model-usage 请求构造（回滚路径回归）

    func testModelUsageRequestPersonal() throws {
        let start = day(-1, from: Date())
        let end = day(0, from: Date())
        let request = ZAIServerUsageEndpoint.makeModelUsageRequest(
            domain: "zai", authorization: "Bearer oauth-token",
            startTime: start, endTime: end, teamContext: nil
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/monitor/usage/model-usage")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["startTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: start))
        XCTAssertEqual(items["endTime"], ZAIServerUsageEndpoint.timeFormatter.string(from: end))
        XCTAssertNil(items["type"], "旧接口个人套餐不带 type")
        XCTAssertNil(items["usageType"])
    }

    func testModelUsageRequestTeamUsesType2Scope() throws {
        let context = ZAITeamContext(productId: "product-test", organizationId: "org-test", projectId: "proj-test")
        let request = ZAIServerUsageEndpoint.makeModelUsageRequest(
            domain: "bigmodel", authorization: "api-key.secret",
            startTime: day(-1, from: Date()), endTime: day(0, from: Date()), teamContext: context
        )
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-organization"), "org-test")
    }

    // MARK: - credit-usage 响应解析

    func testParseCreditHourlyResponseSumsModelsAndNormalizesKeys() throws {
        let response = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": [
                "granularity": "HOUR",
                "modelUsage": [
                    "xTime": ["2026-09-18 13:00:00", "2026-09-18 14:00:00", "2026-09-19 09:00:00"],
                    "modelDataList": [
                        ["modelCode": "glm-5.3", "modelName": "GLM-5.3", "sortOrder": 1,
                         "totalTokensUsage": [100, 20, 7]],
                        ["modelCode": "glm-5.3-flash", "modelName": "GLM-5.3-Flash", "sortOrder": 2,
                         "totalTokensUsage": [0.5, 0, 1]],
                    ],
                ],
            ]
        ]))
        XCTAssertEqual(response.granularity, .hourly)
        XCTAssertEqual(response.points, [
            .init(timeKey: "2026-09-18 13:00:00", tokens: 100.5),
            .init(timeKey: "2026-09-18 14:00:00", tokens: 20),
            .init(timeKey: "2026-09-19 09:00:00", tokens: 8),
        ])
        XCTAssertEqual(response.dayBuckets["2026-09-18"], 120.5)
        XCTAssertEqual(response.dayBuckets["2026-09-19"], 8)
        // 带秒键归一为 "yyyy-MM-dd HH:mm"，与周配速切窗的解析格式一致。
        let hourly = try XCTUnwrap(response.hourlyByDay)
        XCTAssertEqual(hourly["2026-09-18"]?.count, 2)
        XCTAssertEqual(hourly["2026-09-18"]?.first?.hourStart, "2026-09-18 13:00")
    }

    func testParseCreditDailyResponse() throws {
        let response = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": [
                "granularity": "DAY",
                "modelUsage": [
                    "xTime": ["2026-09-18", "2026-09-19"],
                    "modelDataList": [
                        ["modelCode": "glm-5.3", "modelName": "GLM-5.3",
                         "totalTokensUsage": [110699552, 44678517]],
                    ],
                ],
            ]
        ]))
        XCTAssertEqual(response.granularity, .daily)
        XCTAssertEqual(response.dayBuckets["2026-09-18"], 110699552)
        XCTAssertEqual(response.dayBuckets["2026-09-19"], 44678517)
        XCTAssertNil(response.hourlyByDay)
    }

    func testParseCreditFiltersBreakdownBuckets() throws {
        let response = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": [
                "granularity": "DAY",
                "modelUsage": [
                    "xTime": ["2026-09-18"],
                    "modelDataList": [
                        ["modelCode": "glm-5.3", "modelName": "GLM-5.3", "totalTokensUsage": [100]],
                        // 汇总桶行：cachedInput / output_tokens / 名称为「缓存」的行都要排除
                        ["modelCode": "cachedInput", "modelName": "缓存", "totalTokensUsage": [60]],
                        ["modelCode": "uncached_input", "modelName": "未缓存", "totalTokensUsage": [10]],
                        ["modelCode": "output_tokens", "modelName": "输出", "totalTokensUsage": [30]],
                    ],
                ],
            ]
        ]))
        XCTAssertEqual(response.dayBuckets["2026-09-18"], 100, "汇总桶行是模型的二次拆分，混入会双计")
    }

    func testParseCreditSeriesFallbackChain() throws {
        // totalTokensUsage 缺失时回退 tokensUsage；两者都缺失时回退分组三序列求和。
        let viaTokensUsage = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["granularity": "DAY", "modelUsage": [
                "xTime": ["2026-09-18"],
                "modelDataList": [["modelCode": "m", "tokensUsage": [42]]],
            ]]
        ]))
        XCTAssertEqual(viaTokensUsage.dayBuckets["2026-09-18"], 42)

        let viaComponents = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["granularity": "DAY", "modelUsage": [
                "xTime": ["2026-09-18"],
                "modelDataList": [["modelCode": "m",
                                   "cachedInputTokensUsage": [10],
                                   "uncachedInputTokensUsage": [5],
                                   "outputTokensUsage": [2]]],
            ]]
        ]))
        XCTAssertEqual(viaComponents.dayBuckets["2026-09-18"], 17)

        // credits 序列与 Token 无关：只有 credits 数据的模型对 Token 无贡献。
        let creditsOnly = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["granularity": "DAY", "modelUsage": [
                "xTime": ["2026-09-18"],
                "modelDataList": [["modelCode": "m",
                                   "totalCreditsUsage": ["12.5"],
                                   "cachedInputCreditsUsage": ["10.0"],
                                   "uncachedInputCreditsUsage": ["0.5"],
                                   "outputCreditsUsage": ["2.0"]]],
            ]]
        ]))
        XCTAssertEqual(creditsOnly.dayBuckets["2026-09-18"], 0, "Credit 数值不得混入 Token 计算")
    }

    func testParseCreditPadsShortSeriesAndAcceptsStringNumbers() throws {
        // 序列比 xTime 短补 0；字符串数值（credits 系列实测形态）可解析。
        let response = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["granularity": "DAY", "modelUsage": [
                "xTime": ["2026-09-17", "2026-09-18", "2026-09-19"],
                "modelDataList": [["modelCode": "m", "totalTokensUsage": ["100", 20]]],
            ]]
        ]))
        XCTAssertEqual(response.points, [
            .init(timeKey: "2026-09-17", tokens: 100),
            .init(timeKey: "2026-09-18", tokens: 20),
            .init(timeKey: "2026-09-19", tokens: 0),
        ])
    }

    func testParseCreditEmptyModelListIsZeroUsage() throws {
        // 空模型列表是合法零用量（xTime 存在即可对齐），不算同步失败。
        let response = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["granularity": "HOUR", "modelUsage": [
                "xTime": ["2026-09-19 09:00:00"], "modelDataList": [],
            ]]
        ]))
        XCTAssertEqual(response.points.first?.tokens, 0)
        XCTAssertNotNil(response.hourlyByDay)
    }

    func testParseCreditInfersGranularityFromKeysWhenFieldMissing() throws {
        let hourly = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["modelUsage": ["xTime": ["2026-09-19 09:00:00"],
                                    "modelDataList": [["modelCode": "m", "totalTokensUsage": [1]]]]]
        ]))
        XCTAssertEqual(hourly.granularity, .hourly)
        let daily = try XCTUnwrap(ZAICreditUsageResponse.parse([
            "data": ["modelUsage": ["xTime": ["2026-09-19"],
                                    "modelDataList": [["modelCode": "m", "totalTokensUsage": [1]]]]]
        ]))
        XCTAssertEqual(daily.granularity, .daily)
    }

    func testParseCreditRejectsMalformedPayloads() {
        XCTAssertNil(ZAICreditUsageResponse.parse(["msg": "no data"]))
        XCTAssertNil(ZAICreditUsageResponse.parse(["data": ["granularity": "HOUR"]]))
        XCTAssertNil(ZAICreditUsageResponse.parse(["data": ["modelUsage": ["modelDataList": []]]]))
    }

    // MARK: - 旧 model-usage 响应解析（回滚路径回归）

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

    // MARK: - 数据源开关

    func testUsageSourceDefaultsToCreditAndSupportsModelOverride() throws {
        let defaults = UserDefaults(suiteName: "ZAIServerUsageSourceTests")!
        defaults.removePersistentDomain(forName: "ZAIServerUsageSourceTests")
        XCTAssertEqual(ZAIServerUsageSource.resolve(defaults: defaults), .credit)
        defaults.set("model", forKey: ZAIServerUsageSource.overrideKey)
        XCTAssertEqual(ZAIServerUsageSource.resolve(defaults: defaults), .model)
        defaults.set("credit", forKey: ZAIServerUsageSource.overrideKey)
        XCTAssertEqual(ZAIServerUsageSource.resolve(defaults: defaults), .credit)
        defaults.removePersistentDomain(forName: "ZAIServerUsageSourceTests")
    }

    // MARK: - 增量同步规划

    func testPlanSyncFirstRunQueriesDailyAndChunkedHourlyWindows() {
        let now = day(0, from: Date())
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: nil, calendar: calendar)
        // credit-usage 粒度阈值 ≤6 天：8 天周窗切成 [T-7..T-2] + [T-1..T] 两块。
        XCTAssertEqual(plan.fetches.count, 3)
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertFalse(plan.fetches[0].servesHourly)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: day(-29, from: now)))
        XCTAssertNil(plan.fetches[0].end)
        let chunk1 = plan.fetches[1]
        XCTAssertFalse(chunk1.servesDaily)
        XCTAssertTrue(chunk1.servesHourly)
        XCTAssertEqual(chunk1.start, calendar.startOfDay(for: day(-7, from: now)))
        XCTAssertEqual(chunk1.end, calendar.startOfDay(for: day(-2, from: now)))
        let chunk2 = plan.fetches[2]
        XCTAssertEqual(chunk2.start, calendar.startOfDay(for: day(-1, from: now)))
        XCTAssertEqual(chunk2.end, calendar.startOfDay(for: day(0, from: now)))
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
        // 并集 T-1 ≥ T-5：窗口 2 天必为 HOUR，单请求同时喂两部分。
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

    func testPlanSyncLongDailyGapKeepsHourlySingleChunk() {
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
        // daily 停在 T-10，hourly（今天）单日一块：2 个请求。
        XCTAssertEqual(plan.fetches.count, 2)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: oldDaily))
        XCTAssertEqual(plan.fetches[1].start, calendar.startOfDay(for: now))
        XCTAssertEqual(plan.fetches[1].end, calendar.startOfDay(for: now))
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
        // 并集 T-5 恰好 ≥ T-5：窗口 6 个自然日必为 HOUR，单请求同时喂两部分。
        XCTAssertEqual(plan.fetches.count, 1)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: recent))
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertTrue(plan.fetches[0].servesHourly)
    }

    func testPlanSyncStaleHourlySplitsIntoChunkedFetches() {
        // hourly 停在 T-7（8 个自然日窗）而 daily 是今天：并集 T-7 超出合并条件，
        // hourly 需要切两块（credit-usage 的 HOUR 阈值 ≤6 天）。
        let now = day(0, from: Date())
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: now,
            lastHourlyFetchedAt: day(-7, from: now),
            daily: []
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        XCTAssertEqual(plan.fetches.count, 3)
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertFalse(plan.fetches[0].servesHourly)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: now))
        let chunk1 = plan.fetches[1]
        XCTAssertTrue(chunk1.servesHourly)
        XCTAssertEqual(chunk1.start, calendar.startOfDay(for: day(-7, from: now)))
        XCTAssertEqual(chunk1.end, calendar.startOfDay(for: day(-2, from: now)))
        let chunk2 = plan.fetches[2]
        XCTAssertEqual(chunk2.start, calendar.startOfDay(for: day(-1, from: now)))
        XCTAssertEqual(chunk2.end, calendar.startOfDay(for: now))
    }

    func testPlanSyncSixDayDailyGapNoLongerMerges() {
        // 并集 T-6（7 个自然日）超出 credit-usage 的 HOUR 阈值：不能合并，
        // hourly 增量（今天）单日一块，共 2 个请求。
        let now = day(0, from: Date())
        let cache = ZAIServerUsageCache(
            lastDailyFetchedAt: day(-6, from: now),
            lastHourlyFetchedAt: now,
            daily: []
        )
        let plan = ZAIServerUsageCacheLogic.planSync(now: now, cache: cache, calendar: calendar)
        XCTAssertEqual(plan.fetches.count, 2)
        XCTAssertTrue(plan.fetches[0].servesDaily)
        XCTAssertEqual(plan.fetches[0].start, calendar.startOfDay(for: day(-6, from: now)))
        XCTAssertEqual(plan.fetches[1].start, calendar.startOfDay(for: now))
        XCTAssertEqual(plan.fetches[1].end, calendar.startOfDay(for: now))
    }

    func testHourlyFetchesChunkAtMostSixCalendarDays() {
        let now = day(0, from: Date())
        // 8 天窗（T-7..T）→ 两块 6+2；6 天窗（T-5..T）→ 一块；同日 → 一块。
        let eightDays = ZAIServerUsageCacheLogic.hourlyFetches(
            from: calendar.startOfDay(for: day(-7, from: now)),
            to: calendar.startOfDay(for: now), calendar: calendar
        )
        XCTAssertEqual(eightDays.map(\.start), [
            calendar.startOfDay(for: day(-7, from: now)),
            calendar.startOfDay(for: day(-1, from: now)),
        ])
        XCTAssertEqual(eightDays.map(\.end), [
            calendar.startOfDay(for: day(-2, from: now)),
            calendar.startOfDay(for: now),
        ])
        let sixDays = ZAIServerUsageCacheLogic.hourlyFetches(
            from: calendar.startOfDay(for: day(-5, from: now)),
            to: calendar.startOfDay(for: now), calendar: calendar
        )
        XCTAssertEqual(sixDays.count, 1)
        XCTAssertEqual(sixDays[0].end, calendar.startOfDay(for: now))
        let sameDay = ZAIServerUsageCacheLogic.hourlyFetches(
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: now), calendar: calendar
        )
        XCTAssertEqual(sameDay.count, 1)
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

    // MARK: - 缓存 schema

    @MainActor
    func testPreloadKeepsLegacyAndCurrentSchemaButDropsFuture() throws {
        let suite = "ZAIServerUsagePreloadTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let bucket = "zai-coding-plan|a@b.c"
        let storageKey = "local.codex.touchbar.quota.serverPlanUsage.\(bucket)"
        let encoder = JSONEncoder()

        func writeCache(_ cache: ZAIServerUsageCache) {
            defaults.set(try! encoder.encode(cache), forKey: storageKey)
        }
        // preload 对同 bucket 去重，每个场景用全新 Store 实例验证。
        func loadFresh() -> ZAIServerUsageCache? {
            let store = ZAIServerUsageStore(defaults: defaults)
            store.preload(bucket: bucket)
            return store.cache
        }

        // 旧 model-usage 时代（schema nil）：Token 口径与键格式兼容，保留。
        writeCache(ZAIServerUsageCache(lastDailyFetchedAt: Date(), daily: [
            .init(date: "2026-09-18", usage: 10, hourly: nil),
        ]))
        XCTAssertEqual(loadFresh()?.daily.first?.usage, 10)

        // 当前 schema：保留。
        writeCache(ZAIServerUsageCache(schema: ZAIServerUsageCache.currentSchema,
                                       daily: [.init(date: "2026-09-18", usage: 20, hourly: nil)]))
        XCTAssertEqual(loadFresh()?.daily.first?.usage, 20)

        // 高于当前版本的缓存（降级运行）：安全丢弃。
        writeCache(ZAIServerUsageCache(schema: ZAIServerUsageCache.currentSchema + 1,
                                       daily: [.init(date: "2026-09-18", usage: 30, hourly: nil)]))
        XCTAssertNil(loadFresh())
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
