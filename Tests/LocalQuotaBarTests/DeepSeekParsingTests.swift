import XCTest
@testable import LocalQuotaBar

/// DeepSeek 数据链路单测：token 三形态、envelope、钱包/消费解析、用量聚合与窗口。
final class DeepSeekParsingTests: XCTestCase {
    // MARK: - userToken 形态

    func testParseTokenValueAcceptsPlainQuotedAndJSONObject() {
        let plain = String(repeating: "a", count: 32)
        XCTAssertEqual(DeepSeekTokenImporter.parseTokenValue(plain), plain)
        XCTAssertEqual(DeepSeekTokenImporter.parseTokenValue("  \(plain)  "), plain)
        XCTAssertEqual(DeepSeekTokenImporter.parseTokenValue("\"\(plain)\""), plain)
        XCTAssertEqual(
            DeepSeekTokenImporter.parseTokenValue(#"{"value":"\#(plain)"}"#),
            plain
        )
        XCTAssertEqual(
            DeepSeekTokenImporter.parseTokenValue(#"{"access_token":"\#(plain)"}"#),
            plain
        )
        // object 内 JSON string 值再包一层引号
        XCTAssertEqual(
            DeepSeekTokenImporter.parseTokenValue(#"{"value":"\"\#(plain)\""}"#),
            plain
        )
    }

    func testParseTokenValueRejectsShortAndWhitespaceTokens() {
        XCTAssertNil(DeepSeekTokenImporter.parseTokenValue("short-token"))
        XCTAssertNil(DeepSeekTokenImporter.parseTokenValue(String(repeating: "a", count: 15) + " " + String(repeating: "b", count: 15)))
        XCTAssertNil(DeepSeekTokenImporter.parseTokenValue(""))
        XCTAssertNil(DeepSeekTokenImporter.parseTokenValue(#"{"value":"too-short-value"}"#))
    }

    // MARK: - profile 选择

    func testSelectProfilePrefersPersistedThenSingleThenLatest() {
        let a = DeepSeekTokenImporter.Candidate(
            profileID: "Default", profileName: "Default",
            token: String(repeating: "a", count: 30), storageModifiedAt: Date(timeIntervalSince1970: 100))
        let b = DeepSeekTokenImporter.Candidate(
            profileID: "Profile 1", profileName: "Profile 1",
            token: String(repeating: "b", count: 30), storageModifiedAt: Date(timeIntervalSince1970: 200))

        guard case .success(let preferred) = DeepSeekTokenImporter.selectProfile(
            candidates: [a, b], preferredProfileID: "Default") else {
            return XCTFail("应使用已持久化的 profile")
        }
        XCTAssertEqual(preferred.profileID, "Default")

        guard case .success(let latest) = DeepSeekTokenImporter.selectProfile(
            candidates: [a, b], preferredProfileID: nil) else {
            return XCTFail("多候选应回退到最近修改的 profile")
        }
        XCTAssertEqual(latest.profileID, "Profile 1")

        guard case .success(let only) = DeepSeekTokenImporter.selectProfile(
            candidates: [a], preferredProfileID: nil) else {
            return XCTFail("单候选自动使用")
        }
        XCTAssertEqual(only.profileID, "Default")

        guard case .failure(let error) = DeepSeekTokenImporter.selectProfile(
            candidates: [], preferredProfileID: nil) else {
            return XCTFail("无候选应失败")
        }
        XCTAssertEqual(error, .tokenNotFound)
    }

    // MARK: - envelope

    private func envelope(_ bizData: [String: Any], code: NSNumber = 0, bizCode: NSNumber = 0) -> [String: Any] {
        ["code": code, "data": ["biz_code": bizCode, "biz_data": bizData]]
    }

    func testEnvelopeRejectsAuthAndBusinessErrors() throws {
        XCTAssertThrowsError(try DeepSeekEnvelope.payload(in: ["code": 40002, "data": [:]])) { error in
            guard case DeepSeekAPIError.sessionExpired = error else { return XCTFail("应为会话过期") }
        }
        XCTAssertThrowsError(try DeepSeekEnvelope.payload(in: ["code": 0, "data": ["biz_code": 1]])) { error in
            guard case DeepSeekAPIError.apiError = error else { return XCTFail("应为业务错误") }
        }
        let payload = try DeepSeekEnvelope.payload(in: envelope(["k": 1]))
        XCTAssertEqual(payload["k"] as? Int, 1)
    }

    // MARK: - summary 解析

    func testSummaryParsesWalletsAndCostsWithStringNumbers() throws {
        let json: [String: Any] = envelope([
            "normal_wallets": [
                ["balance": "5.13", "currency": "CNY", "token_estimation": "102600"],
                ["balance": 0.5, "currency": "USD"]
            ],
            "bonus_wallets": [
                ["balance": 1.0, "currency": "CNY"]
            ],
            "total_costs": [
                ["currency": "CNY", "amount": "4.92"],
                ["currency": "CNY", "amount": 0.08]
            ]
        ])
        let (wallets, costs) = try DeepSeekSummaryParser.parse(json: json)
        XCTAssertEqual(wallets.count, 3)
        XCTAssertEqual(wallets[0].kind, .normal)
        XCTAssertEqual(wallets[0].currency, "CNY")
        XCTAssertEqual(wallets[0].balance, 5.13, accuracy: 0.001)
        XCTAssertEqual(wallets[0].tokenEstimation ?? 0, 102600, accuracy: 1)
        XCTAssertEqual(wallets[2].kind, .bonus)
        XCTAssertEqual(costs, [DeepSeekCost(currency: "CNY", amount: 5.0)])
    }

    func testSummaryEmptyWalletsStillParses() throws {
        let json: [String: Any] = envelope([
            "normal_wallets": [],
            "bonus_wallets": [],
            "total_costs": []
        ])
        let (wallets, costs) = try DeepSeekSummaryParser.parse(json: json)
        XCTAssertTrue(wallets.isEmpty)
        XCTAssertTrue(costs.isEmpty)
    }

    // MARK: - 用量聚合

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func bucket(_ day: String, values: [String: Any]) -> [String: Any] {
        // 实测响应的时间字段名是 time（金额字段 cost）
        [
            "time": Int(date(day).timeIntervalSince1970) as NSNumber,
            "usage": values
        ]
    }

    func testUsageAggregatesTokensRequestsAndAmountsByDay() throws {
        let window = [
            date("2026-09-20 00:00:00"),
            date("2026-09-21 00:00:00"),
            date("2026-09-22 00:00:00")
        ]
        let amountJSON: [String: Any] = envelope([
            "series": [[
                "api_key": ["name": "key-1"],
                "model": "deepseek-chat",
                "buckets": [
                    bucket("2026-09-20 10:00:00", values: [
                        "PROMPT_CACHE_HIT_TOKEN": 100, "PROMPT_CACHE_MISS_TOKEN": 20,
                        "RESPONSE_TOKEN": 30, "REQUEST": 2
                    ]),
                    bucket("2026-09-21 11:00:00", values: [
                        "PROMPT_CACHE_HIT_TOKEN": 1000, "PROMPT_CACHE_MISS_TOKEN": 0,
                        "RESPONSE_TOKEN": 0, "REQUEST": "5"
                    ]),
                    // 窗口外（前一天）应被丢弃
                    bucket("2026-09-19 23:00:00", values: ["REQUEST": 99])
                ]
            ]]
        ])
        let costJSON: [String: Any] = envelope([
            "data": [
                [
                    "currency": "CNY",
                    "series": [["buckets": [
                        bucket("2026-09-20 10:00:00", values: ["COST": "0.10"]),
                        bucket("2026-09-21 11:00:00", values: ["COST": 0.21])
                    ]]]
                ],
                // 非主币种组不参与
                ["currency": "USD", "series": [["buckets": [
                    bucket("2026-09-21 11:00:00", values: ["COST": 9.99])
                ]]]]
            ]
        ])

        let usage = try DeepSeekUsageParser.parse(
            amountJSON: amountJSON, costJSON: costJSON, currency: "CNY",
            window: window, calendar: calendar
        )
        XCTAssertEqual(usage.currency, "CNY")
        XCTAssertEqual(usage.days.count, 3)
        XCTAssertEqual(usage.days[0].tokens, 150, accuracy: 0.001)
        XCTAssertEqual(usage.days[0].requests, 2, accuracy: 0.001)
        XCTAssertEqual(usage.days[0].amount, 0.10, accuracy: 0.001)
        XCTAssertEqual(usage.days[1].tokens, 1000, accuracy: 0.001)
        XCTAssertEqual(usage.days[1].amount, 0.21, accuracy: 0.001)
        // 无数据日补零
        XCTAssertEqual(usage.days[2].tokens, 0)
        XCTAssertEqual(usage.days[2].amount, 0)
        XCTAssertEqual(usage.totalAmount, 0.31, accuracy: 0.001)
    }

    func testRecentWindowCovers30DaysEndingToday() {
        let now = date("2026-09-22 15:00:00")
        let window = DeepSeekUsageParser.recentWindow(now: now, calendar: calendar)
        XCTAssertEqual(window.count, 30)
        XCTAssertEqual(calendar.startOfDay(for: window.last!), calendar.startOfDay(for: now))
        let first = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(calendar.startOfDay(for: window.first!), first)
    }

    // MARK: - 快照口径

    func testSnapshotPicksPrimaryCurrencyAndSumsBalances() {
        let snapshot = DeepSeekSnapshot(
            fetchedAt: date("2026-09-22 09:00:00"),
            profileID: "Default", profileName: "Default",
            wallets: [
                .init(kind: .normal, currency: "CNY", balance: 4.13, tokenEstimation: nil),
                .init(kind: .bonus, currency: "CNY", balance: 1.0, tokenEstimation: nil),
                .init(kind: .normal, currency: "USD", balance: 0, tokenEstimation: nil)
            ],
            totalCosts: [.init(currency: "CNY", amount: 4.92)],
            usage: .init(currency: "CNY", days: [])
        )
        // USD 余额为 0：不选 USD；任意有余额币种 → CNY
        XCTAssertEqual(snapshot.primaryBalance?.currency, "CNY")
        XCTAssertEqual(snapshot.primaryBalance?.amount ?? 0, 5.13, accuracy: 0.001)
    }

    func testUSDWithBalanceWinsOverCNY() {
        let snapshot = DeepSeekSnapshot(
            fetchedAt: Date(), profileID: "Default", profileName: "Default",
            wallets: [
                .init(kind: .normal, currency: "CNY", balance: 5, tokenEstimation: nil),
                .init(kind: .normal, currency: "USD", balance: 1, tokenEstimation: nil)
            ],
            totalCosts: [], usage: .init(currency: "CNY", days: [])
        )
        XCTAssertEqual(snapshot.primaryBalance?.currency, "USD")
    }
}
