import Foundation

// MARK: - CodeBuddy Credits 快照模型（国际版 www.codebuddy.ai 逆向口径）

/// 一组资源额度（主套餐 / 购买积分 / 平台奖励积分）。
struct CodeBuddyPackage: Equatable {
    enum Group: String, Equatable {
        case subscription
        case paid
        case free
        case other

        var title: String {
            switch self {
            case .subscription: return "套餐基础积分"
            case .paid: return "购买积分"
            case .free: return "奖励包"
            case .other: return "其他积分"
            }
        }
    }

    let group: Group
    let packageCode: String
    let resourceID: String?
    let totalCapacity: Double
    let remainCapacity: Double
    let inUsage: Bool
    /// 权益周期更新时间（主套餐）/ 到期时间（资源包）。
    let cycleEndTime: Date?
    let expiredTime: Date?

    var usedCapacity: Double { max(totalCapacity - remainCapacity, 0) }
    /// 剩余比例（0...100），环与进度条口径；总量缺失时为 0。
    var remainingPercent: Double {
        totalCapacity > 0 ? max(0, min(100, remainCapacity / totalCapacity * 100)) : 0
    }
}

struct CodeBuddySnapshot: Equatable {
    let fetchedAt: Date
    /// 站点区域：首版固定国际版（.ai）；国内版（.cn）留待后续计划。
    let region: String
    let profileID: String
    let profileName: String
    /// 套餐名（tab tag 与面板标题），如“体验版”。
    let planName: String?
    let planPackage: CodeBuddyPackage?
    let paidPackages: [CodeBuddyPackage]
    let freePackages: [CodeBuddyPackage]

    /// 未知 PackageCode 的兜底分组归入“其他积分”，不丢弃数据。
    static let knownPlanCodes: [String: String] = [
        "FREE": "体验版",
        "TRIAL": "体验版",
        "PRO": "Pro",
        "PRO_MONTHLY": "Pro",
        "MAX": "Max"
    ]

    static func planName(for packageCode: String?) -> String? {
        guard let packageCode else { return nil }
        return knownPlanCodes[packageCode.uppercased()] ?? packageCode
    }
}

enum CodeBuddyFormat {
    /// Credits 两位小数、去除末尾零：1.62 / 500 / 498.38 / 2.5。
    static func credits(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }
}

enum CodeBuddyAPIError: LocalizedError, Equatable {
    case sessionExpired(String)
    case http(Int)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired(let detail):
            return "CodeBuddy 会话已失效（\(detail)），请在 Chrome 重新登录 www.codebuddy.ai"
        case .http(let status):
            return "CodeBuddy 接口请求失败（HTTP \(status)）"
        case .badPayload(let detail):
            return "CodeBuddy 响应解析失败：\(detail)"
        }
    }
}

// MARK: - 响应解析（envelope 与字段口径见执行计划，宽松数字/日期兼容）

enum CodeBuddyParser {
    /// 解析 get-user-resource-summary：主套餐包与套餐代码。
    static func parseSummary(json: [String: Any]) throws -> (planPackage: CodeBuddyPackage?,
                                                              subscriptionCode: String?) {
        let data = try payload(json)
        let packages = DeepSeekJSON.array(data["Packages"]) ?? []
        guard !packages.isEmpty else {
            throw CodeBuddyAPIError.badPayload("缺少 Packages 字段")
        }
        let subscriptionCode = DeepSeekJSON.string(data["SubscriptionPackageCode"])

        var candidates: [CodeBuddyPackage] = []
        for entry in packages {
            guard let package = package(group: .subscription, entry: entry) else { continue }
            candidates.append(package)
        }
        guard !candidates.isEmpty else {
            throw CodeBuddyAPIError.badPayload("Packages 无有效条目")
        }
        // 主套餐 = SubscriptionPackageCode 匹配项；缺失时取第一个
        let plan = candidates.first { $0.packageCode == subscriptionCode } ?? candidates[0]
        return (plan, subscriptionCode)
    }

    /// 解析 paid / free 资源包列表：data.Accounts[]，未知 PackageCode 归入其他积分。
    static func parsePackages(json: [String: Any], group: CodeBuddyPackage.Group) throws -> [CodeBuddyPackage] {
        let data = try payload(json)
        let accounts = DeepSeekJSON.array(data["Accounts"]) ?? []
        var packages: [CodeBuddyPackage] = []
        for entry in accounts {
            let code = DeepSeekJSON.string(entry["PackageCode"])?.uppercased() ?? ""
            let resolved: CodeBuddyPackage.Group
            switch code {
            case "PAID", "PURCHASE", "BUYOUT": resolved = .paid
            case "FREE", "REWARD", "GIFT", "ACTIVITY": resolved = .free
            default: resolved = group == .paid ? .paid : .free
            }
            guard let package = package(group: resolved, entry: entry) else { continue }
            packages.append(package)
        }
        // 到期时间升序、未到期优先；同到期按 ResourceId 稳定排序
        return packages.sorted { lhs, rhs in
            let lhsTime = lhs.expiredTime ?? lhs.cycleEndTime ?? .distantFuture
            let rhsTime = rhs.expiredTime ?? rhs.cycleEndTime ?? .distantFuture
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return (lhs.resourceID ?? "") < (rhs.resourceID ?? "")
        }
    }

    private static func payload(_ json: [String: Any]) throws -> [String: Any] {
        // CodeBuddy envelope：HTTP JSON 的 data 直接是业务节点（无 DeepSeek 式三层）
        guard let data = DeepSeekJSON.object(json["data"]) else {
            throw CodeBuddyAPIError.badPayload("缺少 data 节点")
        }
        return data
    }

    private static func package(group: CodeBuddyPackage.Group, entry: [String: Any]) -> CodeBuddyPackage? {
        let code = DeepSeekJSON.string(entry["PackageCode"]) ?? ""
        let total = DeepSeekJSON.number(entry["CycleTotalCapacity"])
            ?? DeepSeekJSON.number(entry["CycleCapacitySizePrecise"])
            ?? 0
        // summary 条目给 CycleUsedCapacity（已用），资源包条目给 CycleCapacityRemainPrecise（剩余）
        let explicitRemain = DeepSeekJSON.number(entry["CycleCapacityRemainPrecise"])
            ?? DeepSeekJSON.number(entry["CycleCapacityRemain"])
        let used = DeepSeekJSON.number(entry["CycleUsedCapacity"])
        let remain = explicitRemain ?? used.map { max(total - $0, 0) } ?? max(total, 0)
        guard total > 0 || remain > 0 else { return nil }
        return CodeBuddyPackage(
            group: group,
            packageCode: code,
            resourceID: DeepSeekJSON.string(entry["ResourceId"]),
            totalCapacity: total,
            remainCapacity: remain,
            inUsage: (DeepSeekJSON.number(entry["InUsage"]) ?? 0) > 0
                || DeepSeekJSON.string(entry["InUsage"]) == "true",
            cycleEndTime: date(entry["CycleEndTime"]),
            expiredTime: date(entry["ExpiredTime"]) ?? date(entry["DeductionEndTime"])
        )
    }

    /// 日期字段兼容秒级时间戳与 ISO8601 / "yyyy-MM-dd HH:mm:ss" 字符串。
    static func date(_ any: Any?) -> Date? {
        if let number = DeepSeekJSON.number(any), number > 0 {
            let seconds = number > 1e12 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = DeepSeekJSON.string(any), !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8) // 平台站为 +08:00
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
