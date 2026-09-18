import XCTest
@testable import LocalQuotaBar

final class ZAIQuotaEndpointTests: XCTestCase {
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
}
