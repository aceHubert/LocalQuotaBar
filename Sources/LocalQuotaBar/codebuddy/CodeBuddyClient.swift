import Foundation

// MARK: - CodeBuddy 个人中心资源接口（国际版 www.codebuddy.ai）

/// 资源摘要 + 付费 / 奖励资源包请求。Cookie 只在当次请求内存中使用。
final class CodeBuddyClient {
    struct Endpoints {
        let summary: URL
        let paidPackages: URL
        let freePackages: URL

        /// 首版固定国际版域名；国内版（www.codebuddy.cn）留待后续计划。
        init(host: String = "www.codebuddy.ai") {
            let base = "https://\(host)/billing/meter"
            summary = URL(string: "\(base)/get-user-resource-summary")!
            paidPackages = URL(string: "\(base)/get-user-resource-paid-packages")!
            freePackages = URL(string: "\(base)/get-user-resource-free-packages")!
        }
    }

    private let endpoints: Endpoints
    private let session: URLSession
    private let now: () -> Date

    init(endpoints: Endpoints = Endpoints(), session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.endpoints = endpoints
        self.session = session
        self.now = now
    }

    /// 一次完整刷新：资源摘要 + 付费 / 奖励资源包（首版固定小页拉取，不做全量翻页）。
    func fetchSnapshot(cookieHeader: String, profileID: String, profileName: String) async throws -> CodeBuddySnapshot {
        let fetchedAt = now()

        let summaryBody = try await post(endpoints.summary, cookieHeader: cookieHeader, body: [:])
        let (planPackage, subscriptionCode) = try CodeBuddyParser.parseSummary(json: summaryBody)

        // 沿用个人中心参数：小页拉取有效与用完状态，不做全量翻页
        let listBody: [String: Any] = [
            "PageNumber": 1,
            "PageSize": 20,
            "NeedRenewInfo": true,
            "PackageCodes": []
        ]
        let paidBody = try await post(endpoints.paidPackages, cookieHeader: cookieHeader, body: listBody)
        let freeBody = try await post(endpoints.freePackages, cookieHeader: cookieHeader, body: listBody)

        let paid = try CodeBuddyParser.parsePackages(json: paidBody, group: .paid)
        let free = try CodeBuddyParser.parsePackages(json: freeBody, group: .free)

        return CodeBuddySnapshot(
            fetchedAt: fetchedAt,
            region: "international",
            profileID: profileID,
            profileName: profileName,
            planName: CodeBuddySnapshot.planName(for: subscriptionCode ?? planPackage?.packageCode),
            planPackage: planPackage,
            paidPackages: paid,
            freePackages: free
        )
    }

    private func post(_ url: URL, cookieHeader: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.codebuddy.ai/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CodeBuddyAPIError.sessionExpired("HTTP \(status)")
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
