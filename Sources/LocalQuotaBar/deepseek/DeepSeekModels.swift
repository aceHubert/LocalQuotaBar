import Foundation

// MARK: - DeepSeek 平台快照模型（Chrome Web 会话口径，token 只在内存短时使用）

/// 钱包余额（充值 / 赠送）。
struct DeepSeekWallet: Equatable {
    enum Kind: String, Equatable {
        case normal
        case bonus

        var title: String {
            switch self {
            case .normal: return "充值"
            case .bonus: return "赠送"
            }
        }
    }

    let kind: Kind
    let currency: String
    let balance: Double
    /// 平台按余额估算的可用 tokens（tooltip 展示参考）。
    let tokenEstimation: Double?
}

/// 累计消费金额（按币种）。
struct DeepSeekCost: Equatable {
    let currency: String
    let amount: Double
}

/// 单日用量聚合（本地自然日；tokens = HIT + MISS + RESPONSE，requests = REQUEST 计数）。
struct DeepSeekDailyUsage: Equatable {
    let date: Date
    var amount: Double = 0
    var tokens: Double = 0
    var requests: Double = 0
}

struct DeepSeekUsageSummary: Equatable {
    /// 主币种：优先有余额的 USD，其次任意有余额币种，最后 CNY。
    let currency: String
    /// 近 30 个自然日（含今天），无数据日补零。
    let days: [DeepSeekDailyUsage]

    var totalAmount: Double { days.reduce(0) { $0 + $1.amount } }
    var totalTokens: Double { days.reduce(0) { $0 + $1.tokens } }
}

struct DeepSeekSnapshot: Equatable {
    let fetchedAt: Date
    /// 来源 Chrome profile 目录名（只持久化标识，token 不落盘）。
    let profileID: String
    let profileName: String
    let wallets: [DeepSeekWallet]
    let totalCosts: [DeepSeekCost]
    let usage: DeepSeekUsageSummary

    /// 可用余额（充值 + 赠送）按币种求和。
    var balancesByCurrency: [String: Double] {
        var result: [String: Double] = [:]
        for wallet in wallets where wallet.balance > 0 {
            result[wallet.currency, default: 0] += wallet.balance
        }
        return result
    }

    /// 主币种余额（卡片段与图的口径一致）。
    var primaryBalance: (currency: String, amount: Double)? {
        DeepSeekSnapshot.pickCurrency(balancesByCurrency).map { currency in
            (currency, balancesByCurrency[currency] ?? 0)
        }
    }

    /// 币种选择规则：优先有余额的 USD，其次任意有余额币种，兜底 CNY。
    static func pickCurrency(_ balances: [String: Double]) -> String? {
        if let usd = balances["USD"], usd > 0 { return "USD" }
        if let first = balances.first(where: { $0.value > 0 }) { return first.key }
        return balances.isEmpty ? nil : "CNY"
    }

    static func currencySymbol(_ currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return ""
        }
    }
}

// MARK: - JSON 宽松取值（平台响应数字 / 字符串混用）

enum DeepSeekJSON {
    static func object(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [[String: Any]]? {
        (any as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    static func string(_ any: Any?) -> String? {
        if let value = any as? String { return value }
        if let value = any as? NSNumber { return value.stringValue }
        return nil
    }

    /// 数字字段兼容 NSNumber 与数字字符串（"5.13"）。
    static func number(_ any: Any?) -> Double? {
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value) }
        return nil
    }
}

// MARK: - 响应解析

enum DeepSeekAPIError: LocalizedError, Equatable {
    /// HTTP 401/403 或业务码 40002/40003：Web 会话失效。
    case sessionExpired(String)
    case apiError(code: Int64?, message: String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired(let detail):
            return "DeepSeek Web 会话已过期（\(detail)），请在 Chrome 重新登录 platform.deepseek.com"
        case .apiError(let code, let message):
            let codeText = code.map(String.init) ?? "--"
            return "DeepSeek 接口返回错误（code \(codeText)）：\(message)"
        case .badPayload(let detail):
            return "DeepSeek 响应解析失败：\(detail)"
        }
    }
}

enum DeepSeekEnvelope {
    /// 三层 envelope 校验：HTTP JSON 的 code == 0 → data.biz_code == 0 → 返回 data.biz_data。
    static func payload(in body: [String: Any]) throws -> [String: Any] {
        let code = DeepSeekJSON.number(body["code"]) ?? -1
        if code == 40002 || code == 40003 {
            throw DeepSeekAPIError.sessionExpired("code \(Int(code))")
        }
        guard code == 0 else {
            throw DeepSeekAPIError.apiError(code: Int64(code),
                                            message: DeepSeekJSON.string(body["msg"]) ?? "未知错误")
        }
        guard let data = DeepSeekJSON.object(body["data"]) else {
            throw DeepSeekAPIError.badPayload("缺少 data 节点")
        }
        let bizCode = DeepSeekJSON.number(data["biz_code"]) ?? -1
        guard bizCode == 0 else {
            throw DeepSeekAPIError.apiError(code: Int64(bizCode),
                                            message: DeepSeekJSON.string(data["biz_msg"]) ?? "未知业务错误")
        }
        guard let bizData = DeepSeekJSON.object(data["biz_data"]) else {
            throw DeepSeekAPIError.badPayload("缺少 data.biz_data 节点")
        }
        return bizData
    }
}

enum DeepSeekSummaryParser {
    /// 解析 get_user_summary：normal/bonus 钱包与累计消费（按币种求和）。
    static func parse(json: [String: Any]) throws -> (wallets: [DeepSeekWallet], totalCosts: [DeepSeekCost]) {
        let payload = try DeepSeekEnvelope.payload(in: json)

        var wallets: [DeepSeekWallet] = []
        for (key, kind) in [("normal_wallets", DeepSeekWallet.Kind.normal),
                            ("bonus_wallets", DeepSeekWallet.Kind.bonus)] {
            for entry in DeepSeekJSON.array(payload[key]) ?? [] {
                guard let currency = DeepSeekJSON.string(entry["currency"])?.uppercased(),
                      let balance = DeepSeekJSON.number(entry["balance"]) else { continue }
                wallets.append(DeepSeekWallet(
                    kind: kind,
                    currency: currency,
                    balance: balance,
                    tokenEstimation: DeepSeekJSON.number(entry["token_estimation"])
                ))
            }
        }
        // 钱包都不缺失但余额为 0 时也保留条目（区分“无数据”与“余额为零”）
        if wallets.isEmpty, DeepSeekJSON.array(payload["normal_wallets"]) == nil,
           DeepSeekJSON.array(payload["bonus_wallets"]) == nil {
            throw DeepSeekAPIError.badPayload("缺少钱包字段")
        }

        var costs: [String: Double] = [:]
        for entry in DeepSeekJSON.array(payload["total_costs"]) ?? [] {
            guard let currency = DeepSeekJSON.string(entry["currency"])?.uppercased() else { continue }
            // 兼容 amount / total_cost 两种字段名
            let amount = DeepSeekJSON.number(entry["amount"])
                ?? DeepSeekJSON.number(entry["total_cost"])
                ?? 0
            costs[currency, default: 0] += amount
        }
        return (wallets, costs.map { DeepSeekCost(currency: $0.key, amount: $0.value) }
            .sorted { $0.currency < $1.currency })
    }
}

enum DeepSeekUsageParser {
    /// 聚合 amount + cost 两个接口：按本地自然日合并 tokens / requests / 金额。
    /// - Parameters:
    ///   - amountJSON / costJSON: 完整响应体。
    ///   - currency: 金额主币种（与余额卡片段一致）。
    ///   - window: 聚合的自然日窗口（含首尾，通常为近 30 天）。
    static func parse(
        amountJSON: [String: Any],
        costJSON: [String: Any],
        currency: String,
        window: [Date],
        calendar: Calendar = .current
    ) throws -> DeepSeekUsageSummary {
        guard !window.isEmpty else {
            throw DeepSeekAPIError.badPayload("空窗口")
        }
        let amountPayload = try DeepSeekEnvelope.payload(in: amountJSON)
        let costPayload = try DeepSeekEnvelope.payload(in: costJSON)

        var byDay: [Date: DeepSeekDailyUsage] = [:]

        func dayKey(_ bucket: [String: Any]) -> Date? {
            // 实测字段名是 time（兼容 timestamp 的旧假设）；秒级时间戳，兼容毫秒
            let timestamp = DeepSeekJSON.number(bucket["time"])
                ?? DeepSeekJSON.number(bucket["timestamp"])
            guard let timestamp else { return nil }
            let seconds = timestamp > 1e12 ? timestamp / 1000 : timestamp
            return calendar.startOfDay(for: Date(timeIntervalSince1970: seconds))
        }

        func merge(_ day: Date, _ mutate: (inout DeepSeekDailyUsage) -> Void) {
            var usage = byDay[day] ?? DeepSeekDailyUsage(date: day)
            mutate(&usage)
            byDay[day] = usage
        }

        // tokens / requests：amount 接口 biz_data.series[].buckets[].usage
        for item in DeepSeekJSON.array(amountPayload["series"]) ?? [] {
            for bucket in DeepSeekJSON.array(item["buckets"]) ?? [] {
                guard let day = dayKey(bucket), let usage = DeepSeekJSON.object(bucket["usage"]) else { continue }
                let hit = DeepSeekJSON.number(usage["PROMPT_CACHE_HIT_TOKEN"]) ?? 0
                let miss = DeepSeekJSON.number(usage["PROMPT_CACHE_MISS_TOKEN"]) ?? 0
                let response = DeepSeekJSON.number(usage["RESPONSE_TOKEN"]) ?? 0
                let requests = DeepSeekJSON.number(usage["REQUEST"]) ?? 0
                merge(day) { dayUsage in
                    dayUsage.tokens += hit + miss + response
                    dayUsage.requests += requests
                }
            }
        }

        // 金额：cost 接口 biz_data.data[] 按货币分组，取主币种组
        for group in DeepSeekJSON.array(costPayload["data"]) ?? []
        where DeepSeekJSON.string(group["currency"])?.uppercased() == currency.uppercased() {
            for item in DeepSeekJSON.array(group["series"]) ?? [] {
                for bucket in DeepSeekJSON.array(item["buckets"]) ?? [] {
                    guard let day = dayKey(bucket) else { continue }
                    let usage = DeepSeekJSON.object(bucket["usage"])
                    let amount = DeepSeekJSON.number(bucket["cost"])
                        ?? DeepSeekJSON.number(bucket["amount"])
                        ?? usage.flatMap { DeepSeekJSON.number($0["COST"]) }
                        ?? usage.flatMap { DeepSeekJSON.number($0["AMOUNT"]) }
                        ?? 0
                    merge(day) { dayUsage in
                        dayUsage.amount += amount
                    }
                }
            }
        }

        // 窗口内无数据补零，按日期升序
        let days = window.map { day in
            byDay[calendar.startOfDay(for: day)] ?? DeepSeekDailyUsage(date: calendar.startOfDay(for: day))
        }
        return DeepSeekUsageSummary(currency: currency, days: days)
    }

    /// 近 30 个自然日窗口（含今天）。
    static func recentWindow(now: Date = Date(), calendar: Calendar = .current, days: Int = 30) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (1..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) } + [today]
    }
}
