import XCTest
@testable import LocalQuotaBar

final class ZAIQuotaEndpointTests: XCTestCase {
    func testCodingPlanParserKeepsLegacyTokenLimits() {
        let limits = ZAIQuotaStore.parseCodingPlanLimits([
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12.5],
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 25]
        ])
        XCTAssertEqual(limits.map(\.unit), [.hourly, .weekly])
        XCTAssertEqual(limits.map(\.number), [5, 1])
        XCTAssertEqual(limits.map(\.usedPercent), [12.5, 25])
    }

    func testCodingPlanParserDropsTimeLimitWithoutUnit() {
        let limits = ZAIQuotaStore.parseCodingPlanLimits([
            ["type": "TIME_LIMIT", "number": 5, "percentage": 10],
            ["type": "TIME_LIMIT", "number": 1, "percentage": 20]
        ])
        XCTAssertTrue(limits.isEmpty)
    }

    func testCodingPlanParserDropsPersonalUnknownUnitFiveTimeLimit() {
        let limits = ZAIQuotaStore.parseCodingPlanLimits([
            ["type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 100,
             "currentValue": 100, "remaining": 0, "percentage": 100,
             "nextResetTime": 1_790_561_154_998],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 44,
             "nextResetTime": 1_789_803_224_987]
        ])
        XCTAssertEqual(limits.map(\.unit), [.hourly])
    }

    func testCodingPlanParserAcceptsStringWeeklyUnit() {
        let limits = ZAIQuotaStore.parseCodingPlanLimits([
            ["type": "TIME_LIMIT", "unit": "WEEKLY", "number": 1, "percentage": 20]
        ])
        XCTAssertEqual(limits.first?.unit, .weekly)
    }

    func testCodingPlanParserMapsTeamCreditLimitUnitSixToWeekly() {
        let limits = ZAIQuotaStore.parseCodingPlanLimits([
            ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 42,
             "remaining": 37976, "nextResetTime": 1_790_245_813_984]
        ])
        XCTAssertEqual(limits.first?.unit, .weekly)
        XCTAssertEqual(limits.first?.usedPercent, 42)
        XCTAssertNotNil(limits.first?.nextResetTime)
    }

    func testTeamCodingPlanRequestUsesTeamScope() throws {
        let context = ZAITeamContext(productId: "product-test", organizationId: "org-test", projectId: "proj-test")
        let request = ZAIQuotaEndpoint.makeCodingPlanRequest(
            token: "oauth", domain: "bigmodel", teamContext: context, authorization: "api.secret"
        )
        XCTAssertEqual(request.url?.absoluteString,
                       "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "api.secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-organization"), "org-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "bigmodel-project"), "proj-test")
    }

    func testMCPUsageRequestUsesBearerTeamScope() throws {
        let context = ZAITeamContext(productId: nil, organizationId: "org-test", projectId: "proj-test")
        let request = ZAIQuotaEndpoint.makeMCPUsageRequest(
            jwt: "jwt", oauthToken: "oauth", teamContext: context
        )
        XCTAssertEqual(request.url?.absoluteString, "https://zcode.z.ai/api/v1/mcp/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bigmodel-Authorization"), "Bearer oauth")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Bigmodel-Target-Type"), "TEAM")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Bigmodel-Organization"), "org-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Bigmodel-Project"), "proj-test")
    }

    func testTeamAPIKeyCopyRequestUsesPathSegment() throws {
        let context = ZAITeamContext(productId: nil, organizationId: "org-test", projectId: "proj-test")
        let request = ZAIQuotaEndpoint.makeTeamAPIKeysRequest(
            oauthToken: "oauth", domain: "bigmodel", teamContext: context, apiKey: "key-test"
        )
        XCTAssertEqual(request.url?.path,
                       "/api/biz/v1/organization/org-test/projects/proj-test/api_keys/copy/key-test")
    }
    private let baseURL = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/anthropic")!

    func testStartPlanBalanceRequestCarriesDeviceMid() throws {
        let request = ZAIQuotaEndpoint.makeStartPlanBalanceRequest(
            token: "jwt", baseURL: baseURL, deviceMid: "mid-123"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Mid"), "mid-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/zcode-plan/billing/balance")
        XCTAssertTrue(url.query?.contains("app_version=") == true)
    }

    func testStartPlanBalanceRequestOmitsEmptyDeviceMid() {
        for missing in [nil, ""] {
            let request = ZAIQuotaEndpoint.makeStartPlanBalanceRequest(
                token: "jwt", baseURL: baseURL, deviceMid: missing
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Mid"))
        }
    }

    func testStartPlanLogProviderIDAcceptsBuiltinAndAccountPrefixes() {
        XCTAssertTrue(ZAIQuotaStore.isStartPlanLogProviderID("builtin:zai-start-plan", domain: "zai"))
        XCTAssertTrue(ZAIQuotaStore.isStartPlanLogProviderID("account:zai-start-plan", domain: "zai"))
        XCTAssertTrue(ZAIQuotaStore.isStartPlanLogProviderID("ACCOUNT:Bigmodel-Start-Plan", domain: "bigmodel"))
        XCTAssertFalse(ZAIQuotaStore.isStartPlanLogProviderID("builtin:zai-coding-plan", domain: "zai"))
        XCTAssertFalse(ZAIQuotaStore.isStartPlanLogProviderID("account:zai-start-plan", domain: "bigmodel"))
    }

    @MainActor
    func testStartPlanUsesBalanceOwningPlanMetadata() throws {
        // 同一响应可同时包含“待生效 Global Build”和“已生效 Start Plan”。
        // 展示必须跟 balances 对应的套餐走，不能取 plans[] 里第一个 active 项。
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "plans": [
                    [
                        "name": "ZCode Global Build",
                        "description": "ZCode Global Build",
                        "priority": 110,
                        "status": "active",
                        "starts_at": 1_789_802_823,
                        "ends_at": 1_789_866_000,
                        "entitlements": [
                            [
                                "entitlement_id": "future-flash",
                                "show_name": "GLM-5.3-Flash",
                                "grant_units": 100_000_000,
                                "effective_at": 1_789_830_000,
                                "period": "one_time"
                            ]
                        ]
                    ],
                    [
                        "name": "ZCode Start Plan",
                        "description": "免费 GLM 旗舰模型体验",
                        "priority": 90,
                        "status": "active",
                        "starts_at": 1_789_784_492,
                        "ends_at": 1_790_179_199,
                        "entitlements": [
                            [
                                "entitlement_id": "daily-glm",
                                "show_name": "GLM-5.3",
                                "grant_units": 3_000_000,
                                "effective_at": 0,
                                "period": "daily"
                            ],
                            [
                                "entitlement_id": "daily-flash",
                                "show_name": "GLM-5.3-Flash",
                                "grant_units": 5_000_000,
                                "effective_at": 0,
                                "period": "daily"
                            ]
                        ]
                    ]
                ],
                "balances": [
                    [
                        "entitlement_id": "daily-glm",
                        "show_name": "GLM-5.3",
                        "total_units": 3_000_000,
                        "remaining_units": 2_000_000,
                        "priority": 110,
                        "period_start": 1_789_747_200,
                        "period_end": 1_789_833_599,
                        "expires_at": 1_789_833_599
                    ],
                    [
                        "entitlement_id": "daily-flash",
                        "show_name": "GLM-5.3-Flash",
                        "total_units": 5_000_000,
                        "remaining_units": 4_000_000,
                        "priority": 80,
                        "period_start": 1_789_747_200,
                        "period_end": 1_789_833_599,
                        "expires_at": 1_789_833_599
                    ]
                ]
            ]
        ]
        let selection = ZAIProviderSelection(domain: "zai", kind: .startPlan, selectedKey: nil)
        let snapshot = try ZAIQuotaStore.parseStartPlanSnapshot(
            payload: payload,
            selection: selection,
            fetchedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 1_789_784_492)
        )

        XCTAssertEqual(snapshot.planName, "ZCode Start Plan")
        XCTAssertEqual(snapshot.balances.map(\.title), ["GLM-5.3", "GLM-5.3-Flash"])
        XCTAssertTrue(snapshot.pendingEntitlements.isEmpty)
        XCTAssertEqual(snapshot.planItems.map(\.name), ["ZCode Global Build", "ZCode Start Plan"])
        XCTAssertEqual(snapshot.planItems.map(\.status), [.upcoming, .active])
        XCTAssertEqual(snapshot.planItems[0].pendingEntitlements.map(\.title), ["GLM-5.3-Flash"])
        XCTAssertEqual(snapshot.planItems[0].startsAt, Date(timeIntervalSince1970: 1_789_802_823))
        XCTAssertEqual(snapshot.planItems[1].balances.map(\.title), ["GLM-5.3", "GLM-5.3-Flash"])
        XCTAssertEqual(snapshot.planStartAt, Date(timeIntervalSince1970: 1_789_784_492))
        XCTAssertEqual(snapshot.planEndAt, Date(timeIntervalSince1970: 1_790_179_199))
    }
}
