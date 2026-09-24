import Foundation
import XCTest
@testable import LocalQuotaBar

/// 验证 CodeBuddy 当前 Web 资源接口的 URL、请求头与请求体契约。
final class CodeBuddyClientRequestTests: XCTestCase {
    func testResourceRequestUsesCurrentWebContract() async throws {
        CodeBuddyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.test"),
            session: session,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )

        _ = try await client.fetchSnapshot(
            cookieHeader: "session=test; session_2=test2",
            profileID: "Default",
            profileName: "Default"
        )

        let request = try XCTUnwrap(CodeBuddyURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/billing/meter/get-user-resource")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Platform"), "web")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/plain, */*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.codebuddy.test/profile/plans-usage")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/153") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Mode"), "cors")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Dest"), "empty")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=test; session_2=test2")

        let body = try XCTUnwrap(CodeBuddyURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["ProductCode"] as? String, "p_tcaca")
        XCTAssertEqual(json["PageNumber"] as? Int, 1)
        XCTAssertEqual(json["PageSize"] as? Int, 200)
        XCTAssertEqual(json["OnlyValidPeriod"] as? Bool, true)
        XCTAssertEqual(json["Status"] as? [Int], [0, 3])
        XCTAssertEqual((json["PackageCodes"] as? [String])?.count, 12)
        XCTAssertNotNil(json["SlicePeriodStartTime"] as? String)
        XCTAssertNotNil(json["SlicePeriodEndTime"] as? String)
    }

    /// 国内版（.cn）与国际版共用同一接口契约，仅域名相关字段不同。
    func testDomesticHostUsesSameContractWithCNOrigin() async throws {
        CodeBuddyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.cn"),
            session: session,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )

        let snapshot = try await client.fetchSnapshot(
            cookieHeader: "session=test; session_2=test2",
            profileID: "Default",
            profileName: "Default"
        )

        let request = try XCTUnwrap(CodeBuddyURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "www.codebuddy.cn")
        XCTAssertEqual(request.url?.path, "/billing/meter/get-user-resource")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.codebuddy.cn/profile/plans-usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Platform"), "web")
        // 区域随目标域名判定，供面板 / 角标区分两站。
        XCTAssertEqual(snapshot.region, "domestic")
    }

    /// 当前接口在有效登录态下不会 401：该状态归类为会话失效，并带上目标域名。
    func testUnauthorizedMapsToSessionExpiredWithTargetHost() async throws {
        CodeBuddyURLProtocol.reset()
        CodeBuddyURLProtocol.statusCode = 401
        defer { CodeBuddyURLProtocol.statusCode = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.cn"),
            session: session
        )

        do {
            _ = try await client.fetchSnapshot(
                cookieHeader: "session=test",
                profileID: "Default",
                profileName: "Default"
            )
            XCTFail("401 应抛出会话失效")
        } catch let error as CodeBuddyAPIError {
            XCTAssertEqual(error, .sessionExpired(host: "www.codebuddy.cn", detail: "HTTP 401"))
            XCTAssertTrue(error.errorDescription?.contains("www.codebuddy.cn") == true)
            XCTAssertFalse(error.errorDescription?.contains("codebuddy.ai") == true)
        }
    }
}

private final class CodeBuddyURLProtocol: URLProtocol {
    static private(set) var lastRequest: URLRequest?
    static private(set) var lastBody: Data?
    static var statusCode = 200

    static func reset() {
        lastRequest = nil
        lastBody = nil
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("www.codebuddy.") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let body: [String: Any] = [
            "code": 0,
            "msg": "OK",
            "data": [
                "Response": [
                    "Data": [
                        "TotalCount": 1,
                        "TotalDosage": 100,
                        "Accounts": [[
                            "PackageCode": "TCACA_code_035_ArVxJcGDsm",
                            "PackageName": "Free Plan Subscription",
                            "CapacityType": 4,
                            "CycleCapacitySizePrecise": "100",
                            "CycleCapacityRemainPrecise": "100"
                        ]]
                    ]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
