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
            now: { Date(timeIntervalSince1970: 1_790_000_000) },
            chromeMajorVersion: { "137" }
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
        // UA 版本跟随本机 Chrome（会话绑定登录浏览器 UA 版本，写死会在浏览器升级后 401）
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "sec-ch-ua"),
            "\"Chromium\";v=\"137\", \"Google Chrome\";v=\"137\", \"Not A(Brand\";v=\"99\""
        )
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

    /// Chrome 版本检测：从应用 bundle 的 Info.plist 读主版本号；检测失败回退兜底版本。
    func testChromeMajorVersionResolution() throws {
        // 构造伪 Chrome bundle：CFBundleShortVersionString = 999.1.2.3 → 999
        let fakeApp = NSTemporaryDirectory() + "FakeChrome-\(UUID().uuidString).app"
        defer { try? FileManager.default.removeItem(atPath: fakeApp) }
        try FileManager.default.createDirectory(atPath: fakeApp, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>999.1.2.3</string></dict></plist>
        """
        try plist.write(toFile: fakeApp + "/Info.plist", atomically: true, encoding: .utf8)

        XCTAssertEqual(CodeBuddyChromeVersion.majorVersion(bundlePaths: [fakeApp]), "999")
        // 前一个路径读取失败时尝试下一个
        XCTAssertEqual(
            CodeBuddyChromeVersion.majorVersion(bundlePaths: ["/nonexistent", fakeApp]),
            "999"
        )
        // 全部失败返回 nil
        XCTAssertNil(CodeBuddyChromeVersion.majorVersion(bundlePaths: ["/nonexistent"]))
    }

    /// Chrome 升级后磁盘 Info.plist 变更，读取必须实时生效，不能被 Bundle(url:) 缓存旧版本。
    func testChromeMajorVersionReflectsUpdatedInfoPlistWithoutBundleCache() throws {
        let fakeApp = NSTemporaryDirectory() + "UpdatingChrome-\(UUID().uuidString).app"
        let contentsDir = fakeApp + "/Contents"
        defer { try? FileManager.default.removeItem(atPath: fakeApp) }
        try FileManager.default.createDirectory(atPath: contentsDir, withIntermediateDirectories: true)

        func writeVersion(_ version: String) throws {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
            """
            try plist.write(toFile: contentsDir + "/Info.plist", atomically: true, encoding: .utf8)
        }

        try writeVersion("157.0.8103.79")
        XCTAssertEqual(CodeBuddyChromeVersion.majorVersion(bundlePaths: [fakeApp]), "157")

        try writeVersion("158.0.8127.36")
        XCTAssertEqual(CodeBuddyChromeVersion.majorVersion(bundlePaths: [fakeApp]), "158")
    }

    /// 候选版本按“运行进程 → Local State → Info.plist → Frameworks/Versions → N-1”排序去重。
    func testCandidateMajorVersionsOrderAndFallbacks() throws {
        let root = NSTemporaryDirectory() + "ChromeCandidates-\(UUID().uuidString)"
        let fakeApp = root + "/Google Chrome.app"
        let contentsDir = fakeApp + "/Contents"
        let versionsDir = contentsDir + "/Frameworks/Google Chrome Framework.framework/Versions"
        let localState = root + "/Local State"
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: versionsDir + "/157.0.8103.79", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: versionsDir + "/158.0.8127.36", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: versionsDir + "/Current", withDestinationPath: "158.0.8127.36")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>158.0.8127.36</string></dict></plist>
        """
        try plist.write(toFile: contentsDir + "/Info.plist", atomically: true, encoding: .utf8)

        let stateJSON = """
        {"user_experience_metrics":{"stability":{"stats_version":"156.0.8000.1-64"}}}
        """
        try stateJSON.write(toFile: localState, atomically: true, encoding: .utf8)

        // 运行中版本优先（后台已更新到 158，但运行进程是 157）
        let withRunning = CodeBuddyChromeVersion.candidateMajorVersions(
            bundlePaths: [fakeApp],
            localStatePaths: [localState],
            runningVersions: { ["157"] }
        )
        XCTAssertEqual(withRunning, ["157", "156", "158"])

        // Chrome 未运行时回退 Local State → Info.plist → Versions
        let withoutRunning = CodeBuddyChromeVersion.candidateMajorVersions(
            bundlePaths: [fakeApp],
            localStatePaths: [localState],
            runningVersions: { [] }
        )
        XCTAssertEqual(withoutRunning, ["156", "158", "157"])

        // 仅存在单一版本且旧目录已清理时，自动补充 N-1 兜底
        try FileManager.default.removeItem(atPath: versionsDir + "/157.0.8103.79")
        let onlyLatest = CodeBuddyChromeVersion.candidateMajorVersions(
            bundlePaths: [fakeApp],
            localStatePaths: ["/nonexistent"],
            runningVersions: { [] }
        )
        XCTAssertEqual(onlyLatest, ["158", "157"])
    }

    /// 版本检测失败时使用兜底版本号，保证请求仍可发出。
    func testFallbackVersionUsedWhenDetectionFails() async throws {
        CodeBuddyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.test"),
            session: URLSession(configuration: configuration),
            chromeMajorVersion: { nil }
        )

        _ = try await client.fetchSnapshot(
            cookieHeader: "session=test",
            profileID: "Default",
            profileName: "Default"
        )
        let request = try XCTUnwrap(CodeBuddyURLProtocol.lastRequest)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "User-Agent")?
                .contains("Chrome/\(CodeBuddyClient.fallbackChromeMajorVersion).0.0.0") == true
        )
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
        defer { CodeBuddyURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.cn"),
            session: session,
            chromeMajorVersions: { ["158"] },
            recoverySessionFactory: {
                let recoveryConfig = CodeBuddyClient.recoveryConfiguration()
                recoveryConfig.protocolClasses = [CodeBuddyURLProtocol.self]
                return URLSession(configuration: recoveryConfig)
            }
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
            XCTAssertEqual(CodeBuddyURLProtocol.requestedUserAgents.count, 2)
        }
    }

    /// 首选 Chrome 版本返回 401 时，自动用候选版本重试并记住命中的可用版本。
    func testSessionExpiredFallsBackAcrossCandidateVersionsAndRemembersWinner() async throws {
        CodeBuddyURLProtocol.reset()
        defer { CodeBuddyURLProtocol.reset() }
        CodeBuddyURLProtocol.statusResolver = { request in
            let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            return ua.contains("Chrome/157.0.0.0") ? 200 : 401
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodeBuddyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CodeBuddyClient(
            endpoints: .init(host: "www.codebuddy.test"),
            session: session,
            chromeMajorVersions: { ["158", "157"] },
            recoverySessionFactory: {
                let recoveryConfig = CodeBuddyClient.recoveryConfiguration()
                recoveryConfig.protocolClasses = [CodeBuddyURLProtocol.self]
                return URLSession(configuration: recoveryConfig)
            }
        )

        let first = try await client.fetchSnapshot(
            cookieHeader: "session=test",
            profileID: "Default",
            profileName: "Default"
        )
        XCTAssertEqual(first.planName, "体验版")
        // 主会话 158 (401) → ephemeral 158 (401) → ephemeral 157 (200)
        XCTAssertEqual(CodeBuddyURLProtocol.requestedUserAgents.count, 3)
        XCTAssertTrue(CodeBuddyURLProtocol.requestedUserAgents[2].contains("Chrome/157.0.0.0"))

        // 下一次刷新直接优先使用已命中的 157，一次请求即成功
        CodeBuddyURLProtocol.clearHistory()
        _ = try await client.fetchSnapshot(
            cookieHeader: "session=test",
            profileID: "Default",
            profileName: "Default"
        )
        XCTAssertEqual(CodeBuddyURLProtocol.requestedUserAgents.count, 1)
        XCTAssertTrue(CodeBuddyURLProtocol.requestedUserAgents[0].contains("Chrome/157.0.0.0"))
    }
}

private final class CodeBuddyURLProtocol: URLProtocol {
    static private(set) var lastRequest: URLRequest?
    static private(set) var lastBody: Data?
    static private(set) var requestedUserAgents: [String] = []
    static var statusCode = 200
    static var statusResolver: ((URLRequest) -> Int)?

    static func reset() {
        lastRequest = nil
        lastBody = nil
        requestedUserAgents = []
        statusCode = 200
        statusResolver = nil
    }

    static func clearHistory() {
        lastRequest = nil
        lastBody = nil
        requestedUserAgents = []
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
        Self.requestedUserAgents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
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
        let resolvedStatus = Self.statusResolver?(request) ?? Self.statusCode
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: resolvedStatus,
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
