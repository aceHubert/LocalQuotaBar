import Foundation

// MARK: - CodeBuddy 个人中心资源接口（国际版 www.codebuddy.ai / 国内版 www.codebuddy.cn）

/// 统一资源接口请求（主套餐 + 购买积分 + 奖励包一次返回）。Cookie 只在当次请求内存中使用。
final class CodeBuddyClient {
    struct Endpoints {
        /// 请求目标域名（含 www. 前缀），用于请求构造与错误文案。
        let host: String
        let resource: URL
        let origin: String
        let referer: String
        /// 站点区域：international（.ai）/ domestic（.cn）。
        let region: String

        init(host: String = "www.codebuddy.ai") {
            self.host = host
            origin = "https://\(host)"
            referer = "https://\(host)/profile/plans-usage"
            resource = URL(string: "https://\(host)/billing/meter/get-user-resource")!
            region = host.hasSuffix("codebuddy.cn") ? "domestic" : "international"
        }
    }

    private static let packageCodes = [
        "TCACA_code_002_AkiJS3ZHF5",
        "TCACA_code_003_FAnt7lcmRT",
        "TCACA_code_009_0XmEQc2xOf",
        "TCACA_code_036_lupO5WgNdG",
        "TCACA_code_001_PqouKr6QWV",
        "TCACA_code_035_ArVxJcGDsm",
        "TCACA_code_039_KRcQj7wUat",
        "TCACA_code_040_mi9rCYg46x",
        "TCACA_code_006_DbXS0lrypC",
        "TCACA_code_007_nzdH5h4Nl0",
        "TCACA_code_008_cfWoLwvjU4",
        "TCACA_code_037_WxOD3MpI2o"
    ]

    private let endpoints: Endpoints
    private let session: URLSession
    private let now: () -> Date

    init(endpoints: Endpoints = Endpoints(), session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.endpoints = endpoints
        self.session = session
        self.now = now
    }

    /// 一次完整刷新：统一资源接口返回主套餐、购买积分和奖励包。
    func fetchSnapshot(cookieHeader: String, profileID: String, profileName: String) async throws -> CodeBuddySnapshot {
        let fetchedAt = now()
        let responseBody = try await post(
            endpoints.resource,
            cookieHeader: cookieHeader,
            body: resourceRequestBody(at: fetchedAt)
        )
        let resources = try CodeBuddyParser.parseResource(json: responseBody)

        return CodeBuddySnapshot(
            fetchedAt: fetchedAt,
            region: endpoints.region,
            profileID: profileID,
            profileName: profileName,
            planName: resources.planName,
            planPackage: resources.planPackage,
            paidPackages: resources.paidPackages,
            freePackages: resources.freePackages,
            otherPackages: resources.otherPackages
        )
    }

    private func resourceRequestBody(at date: Date) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8)!
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return [
            "PageNumber": 1,
            "PageSize": 200,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "OnlyValidPeriod": true,
            "PackageCodes": Self.packageCodes,
            "SlicePeriodStartTime": formatter.string(from: start),
            "SlicePeriodEndTime": formatter.string(from: end)
        ]
    }

    private func post(_ url: URL, cookieHeader: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "X-Client-Platform")
        request.setValue(endpoints.referer, forHTTPHeaderField: "Referer")
        // APISIX 对 Web 请求会检查一组浏览器上下文头；这些值不包含凭证。
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("\"Google Chrome\";v=\"153\", \"Not_A Brand\";v=\"8\", \"Chromium\";v=\"153\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            // 当前接口在有效登录态下不会返回 401；走到这里视为该站点会话失效。
            throw CodeBuddyAPIError.sessionExpired(host: endpoints.host, detail: "HTTP \(status)")
        }
        guard (200..<300).contains(status) else {
            throw CodeBuddyAPIError.http(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeBuddyAPIError.badPayload("响应不是 JSON 对象")
        }
        return json
    }
}
