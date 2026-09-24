import Foundation

// MARK: - CodeBuddy Credits 快照模型（国际版 / 国内版共用逆向口径）

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
    /// 站点区域：international（.ai）/ domestic（.cn），由请求目标 host 判定。
    let region: String
    let profileID: String
    let profileName: String
    /// 套餐名（面板基础积分行与 tab tooltip 摘要），如“体验版”；tab 角标显示区域标识。
    let planName: String?
    let planPackage: CodeBuddyPackage?
    let paidPackages: [CodeBuddyPackage]
    let freePackages: [CodeBuddyPackage]
    /// 无法可靠归类的资源包，先保留在数据层，首版面板不展示。
    let otherPackages: [CodeBuddyPackage]

    init(
        fetchedAt: Date,
        region: String,
        profileID: String,
        profileName: String,
        planName: String?,
        planPackage: CodeBuddyPackage?,
        paidPackages: [CodeBuddyPackage],
        freePackages: [CodeBuddyPackage],
        otherPackages: [CodeBuddyPackage] = []
    ) {
        self.fetchedAt = fetchedAt
        self.region = region
        self.profileID = profileID
        self.profileName = profileName
        self.planName = planName
        self.planPackage = planPackage
        self.paidPackages = paidPackages
        self.freePackages = freePackages
        self.otherPackages = otherPackages
    }

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

    /// 优先使用个人中心套餐名称，同时把官方英文 Free 套餐映射为面板已有文案。
    static func planName(packageName: String?, packageCode: String?) -> String? {
        if let packageName, !packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = normalized.lowercased()
            if lowercased.contains("free") { return "体验版" }
            if lowercased.contains("pro") { return "Pro" }
            if lowercased.contains("max") { return "Max" }
            return normalized
        }
        return planName(for: packageCode)
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
    /// 目标站点会话失效（HTTP 401 / 403）；host 用于提示用户到对应站点重新登录。
    case sessionExpired(host: String, detail: String)
    case http(Int)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired(let host, let detail):
            return "CodeBuddy 会话已失效（\(detail)），请在 Chrome 重新登录 \(host)"
        case .http(let status):
            return "CodeBuddy 接口请求失败（HTTP \(status)）"
        case .badPayload(let detail):
            return "CodeBuddy 响应解析失败：\(detail)"
        }
    }
}

// MARK: - 响应解析（envelope 与字段口径见执行计划，宽松数字/日期兼容）

enum CodeBuddyParser {
    struct ParsedResources: Equatable {
        let planPackage: CodeBuddyPackage?
        let planName: String?
        let paidPackages: [CodeBuddyPackage]
        let freePackages: [CodeBuddyPackage]
        let otherPackages: [CodeBuddyPackage]
    }

    /// 解析当前 Web 端 `get-user-resource` 响应，并从同一 Accounts 数组分组。
    static func parseResource(json: [String: Any]) throws -> ParsedResources {
        let data = try resourceData(json)
        guard let accounts = DeepSeekJSON.array(data["Accounts"]), !accounts.isEmpty else {
            throw CodeBuddyAPIError.badPayload("缺少 Accounts 字段")
        }

        var parsed: [(entry: [String: Any], package: CodeBuddyPackage)] = []
        for entry in accounts {
            let group = classify(entry)
            guard let package = package(group: group, entry: entry) else { continue }
            parsed.append((entry, package))
        }
        guard !parsed.isEmpty else {
            throw CodeBuddyAPIError.badPayload("Accounts 无有效额度条目")
        }

        let sorted = parsed.sorted { lhs, rhs in
            let lhsTime = lhs.package.expiredTime ?? lhs.package.cycleEndTime ?? .distantFuture
            let rhsTime = rhs.package.expiredTime ?? rhs.package.cycleEndTime ?? .distantFuture
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return (lhs.package.resourceID ?? "") < (rhs.package.resourceID ?? "")
        }
        let plan = sorted.first { $0.package.group == .subscription }
        let planName = plan.flatMap {
            CodeBuddySnapshot.planName(
                packageName: DeepSeekJSON.string($0.entry["PackageName"]),
                packageCode: $0.package.packageCode
            )
        }
        return ParsedResources(
            planPackage: plan?.package,
            planName: planName,
            paidPackages: sorted.filter { $0.package.group == .paid }.map(\.package),
            freePackages: sorted.filter { $0.package.group == .free }.map(\.package),
            otherPackages: sorted.filter { $0.package.group == .other }.map(\.package)
        )
    }

    private static func resourceData(_ json: [String: Any]) throws -> [String: Any] {
        let code = DeepSeekJSON.number(json["code"]) ?? -1
        guard code == 0 else {
            throw CodeBuddyAPIError.badPayload(
                "业务错误 \(Int(code)): \(DeepSeekJSON.string(json["msg"]) ?? "未知错误")"
            )
        }
        guard let data = DeepSeekJSON.object(json["data"]),
              let response = DeepSeekJSON.object(data["Response"]),
              let resourceData = DeepSeekJSON.object(response["Data"]) else {
            throw CodeBuddyAPIError.badPayload("缺少 data.Response.Data 节点")
        }
        return resourceData
    }

    private static func package(group: CodeBuddyPackage.Group, entry: [String: Any]) -> CodeBuddyPackage? {
        let code = DeepSeekJSON.string(entry["PackageCode"]) ?? ""
        let total = DeepSeekJSON.number(entry["CycleCapacitySizePrecise"])
            ?? DeepSeekJSON.number(entry["CycleCapacitySize"])
            ?? DeepSeekJSON.number(entry["CycleTotalCapacity"])
            ?? 0
        let explicitRemain = DeepSeekJSON.number(entry["CycleCapacityRemainPrecise"])
            ?? DeepSeekJSON.number(entry["CycleCapacityRemain"])
        let explicitUsed = DeepSeekJSON.number(entry["CycleCapacityUsedPrecise"])
            ?? DeepSeekJSON.number(entry["CycleCapacityUsed"])
            ?? DeepSeekJSON.number(entry["CycleUsedCapacity"])
        let remain = explicitRemain ?? explicitUsed.map { max(total - $0, 0) } ?? max(total, 0)
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

    /// 根据当前个人中心字段综合判断资源包类型；无法可靠识别时保留为 other。
    private static func classify(_ entry: [String: Any]) -> CodeBuddyPackage.Group {
        let name = normalizedText(entry["PackageName"])
        let packageType = normalizedText(entry["PackageType"])
        let subProduct = normalizedText(entry["SubProductCode"])
        let packageCode = normalizedText(entry["PackageCode"])
        let capacityType = Int(DeepSeekJSON.number(entry["CapacityType"]) ?? -1)

        if capacityType == 4 || name.contains("subscription") || name.contains("plan subscription") {
            return .subscription
        }
        if name.contains("bonus") || name.contains("reward") || name.contains("gift")
            || name.contains("free") || packageType.contains("bonus") || subProduct.contains("bonus")
            || packageCode.contains("bonus") {
            return .free
        }
        if name.contains("paid") || name.contains("purchase") || name.contains("buy")
            || name.contains("topup") || name.contains("recharge") || name.contains("add-on")
            || packageType.contains("paid") || subProduct.contains("purchase")
            || subProduct.contains("recharge") {
            return .paid
        }
        return .other
    }

    private static func normalizedText(_ any: Any?) -> String {
        (DeepSeekJSON.string(any) ?? "")
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
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
