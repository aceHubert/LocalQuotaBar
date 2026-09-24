import Foundation

// MARK: - DeepSeek 平台 Web 接口（逆向口径，参考 CodexBar 已验证实现）

/// 平台接口客户端：余额 summary + 用量 amount/cost。
/// token 只在当次请求内存中使用，不进入任何日志或错误描述。
final class DeepSeekClient {
    struct Endpoints {
        let summary: URL
        let usageAmount: URL
        let usageCost: URL

        init(base: URL = URL(string: "https://platform.deepseek.com")!) {
            summary = base.appendingPathComponent("api/v0/users/get_user_summary")
            usageAmount = base.appendingPathComponent("api/v0/usage/by_api_key/amount")
            usageCost = base.appendingPathComponent("api/v0/usage/by_api_key/cost")
        }
    }

    private let endpoints: Endpoints
    private let session: URLSession
    private let now: () -> Date
    private let calendar: Calendar

    init(
        endpoints: Endpoints = Endpoints(),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.endpoints = endpoints
        self.session = session
        self.now = now
        self.calendar = calendar
    }

    // MARK: - 对外请求

    /// 一次完整刷新：余额 + 近 30 天用量（amount 与 cost 全部成功才产出快照）。
    func fetchSnapshot(
        token: String,
        profileID: String,
        profileName: String
    ) async throws -> DeepSeekSnapshot {
        let fetchedAt = now()
        let summaryBody = try await get(endpoints.summary, token: token, query: nil)
        let (wallets, totalCosts) = try DeepSeekSummaryParser.parse(json: summaryBody)

        // 主币种：优先有余额的 USD，其次任意有余额币种（与面板余额卡口径一致）
        var balances: [String: Double] = [:]
        for wallet in wallets where wallet.balance > 0 {
            balances[wallet.currency, default: 0] += wallet.balance
        }
        let currency = DeepSeekSnapshot.pickCurrency(balances) ?? "CNY"

        let window = DeepSeekUsageParser.recentWindow(now: fetchedAt, calendar: calendar)
        var components = URLComponents(url: endpoints.usageAmount, resolvingAgainstBaseURL: false)!
        components.queryItems = usageQueryItems(window: window, now: fetchedAt)
        let amountBody = try await get(components.url!, token: token, query: nil)

        components = URLComponents(url: endpoints.usageCost, resolvingAgainstBaseURL: false)!
        components.queryItems = usageQueryItems(window: window, now: fetchedAt)
        let costBody = try await get(components.url!, token: token, query: nil)

        let usage = try DeepSeekUsageParser.parse(
            amountJSON: amountBody,
            costJSON: costBody,
            currency: currency,
            window: window,
            calendar: calendar
        )

        return DeepSeekSnapshot(
            fetchedAt: fetchedAt,
            profileID: profileID,
            profileName: profileName,
            wallets: wallets,
            totalCosts: totalCosts,
            usage: usage
        )
    }

    // MARK: - 传输

    private func usageQueryItems(window: [Date], now date: Date) -> [URLQueryItem] {
        // 实测要求窗口对齐自然日：start = 今天-29 天 0 点，end = 明天 0 点（含今天全天）；
        // 传非对齐的 end（如当前时刻）会返回 INVALID_PARAM。展示窗口仍只取 30 天，
        // 多余的"明天"桶由解析器按窗口过滤。
        let today = calendar.startOfDay(for: date)
        let start = window.first ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? date
        let tz = TimeZone.current.secondsFromGMT(for: date)
        return [
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(tz))
        ]
    }

    private func get(_ url: URL, token: String, query: [URLQueryItem]?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw DeepSeekAPIError.sessionExpired("HTTP \(status)")
        }
        guard (200..<300).contains(status) else {
            throw DeepSeekAPIError.apiError(code: Int64(status), message: "HTTP \(status)")
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekAPIError.badPayload("响应不是 JSON 对象")
        }
        return body
    }
}
