import CryptoKit
import Foundation

// MARK: - ZAI 配额数据模型

/// 账号当前使用的 Z.AI/BigModel 接入形态。
enum ZAIPlanKind: String, Codable {
    /// 体验套餐（如注册赠送、周末活动包），走 zcode.z.ai 的 billing/balance。
    case startPlan
    /// 个人付费 Coding Plan，走 api.z.ai 的 monitor 接口。
    case codingPlan
    /// 平台 API Key 模式，无余额可查。
    case apiKey
}

/// 从 ~/.zcode setting.json 解析出的当前渠道与所选 provider。
struct ZAIProviderSelection: Equatable {
    let domain: String
    let kind: ZAIPlanKind
    let selectedKey: String?
    /// ZCode 3.12.3+ 写入 `providerFamilyConnectionSelections[domain].kind` 的原始值
    /// （start-plan / individual-coding-plan / team-coding-plan）。legacy 路径下为 nil。
    /// 团队版判定依赖它：新格式不再写 selectedKey，team 只能从这里认出来。
    let connectionKind: String?
    /// 团队 Coding Plan 的作用域；个人套餐和 legacy 配置为 nil。
    let teamContext: ZAITeamContext?

    init(domain: String, kind: ZAIPlanKind, selectedKey: String?, connectionKind: String? = nil,
         teamContext: ZAITeamContext? = nil) {
        self.domain = domain
        self.kind = kind
        self.selectedKey = selectedKey
        self.connectionKind = connectionKind
        self.teamContext = teamContext
    }
}

/// Team Coding Plan 请求所需的服务端作用域。
struct ZAITeamContext: Equatable, Codable {
    let productId: String?
    let organizationId: String
    let projectId: String
}

/// 官方 MCP 聚合额度；它与 Coding Plan 的 5 小时/周限额不是同一口径。
struct ZAIMCPUsage: Equatable, Codable {
    let used: Double
    let limit: Double
    let remaining: Double
    let nextRefreshAt: Date?

    var remainingPercent: Double {
        guard limit > 0 else { return 0 }
        return max(0, min(100, remaining / limit * 100))
    }
}

extension ZAIPlanKind {
    /// ZCode 3.12.3+ 的连接类型归一化；未知值返回 nil，交给 legacy 路径兜底。
    /// api-key 模式不写连接选择，仍由 modelProviderFamilySelectedKeys 表达。
    init?(connectionKind: String) {
        switch connectionKind {
        case "start-plan": self = .startPlan
        case "individual-coding-plan", "team-coding-plan": self = .codingPlan
        default: return nil
        }
    }
}

struct ZAILimit: Equatable, Codable {
    enum WindowUnit: Int, Codable {
        case hourly = 3
        case weekly = 6
        case unknown = -1
    }

    let unit: WindowUnit
    let number: Int
    let usedPercent: Double
    let nextResetTime: Date?

    var title: String {
        switch unit {
        case .hourly: return "\(number)小时"
        case .weekly: return "\(number)周"
        case .unknown: return "限额"
        }
    }

    var shortTitle: String {
        switch unit {
        case .hourly: return "\(number)H"
        case .weekly: return "W"
        case .unknown: return "—"
        }
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var roundedRemainingPercent: Int {
        Int(remainingPercent.rounded())
    }
}

/// start-plan（体验套餐）里单个模型的余额桶，对应 billing/balance 的 balances[] 条目。
struct ZAIBalance: Equatable, Codable {
    let title: String
    let totalUnits: Double
    let remainingUnits: Double
    let expiresAt: Date?
    let period: String

    var isDaily: Bool {
        period.caseInsensitiveCompare("daily") == .orderedSame
    }

    var remainingFraction: Double {
        guard totalUnits > 0 else { return 0 }
        return min(max(remainingUnits / totalUnits, 0), 1)
    }
}

/// start-plan 的权益项（plans[].entitlements[]）。
/// 余额接口在权益生效前（effective_at 未到）不返回 balances，只返回这份数据，
/// 用于「待生效」额度展示——套餐未到开始时间是一个正常状态，不是错误。
struct ZAIPendingEntitlement: Equatable, Codable {
    let title: String
    let grantUnits: Double
    let effectiveAt: Date?
    let period: String
    /// 过期时间：权益自身 expires_at 缺失时回退到套餐 ends_at。
    /// 待生效行的进度条信息按过期时间展示，与余额行口径一致。
    let expiresAt: Date?

    var isDaily: Bool {
        period.caseInsensitiveCompare("daily") == .orderedSame
    }
}

/// coding-plan 的重置额度卡，来自 zcode.z.ai 的 coding-plan/reset/status。
struct ZAIResetCreditCard: Equatable, Codable {
    enum Kind: String, Codable {
        case fiveHour
        case week

        var title: String {
            switch self {
            case .fiveHour: return "5小时额度"
            case .week: return "周额度"
            }
        }
    }

    let kind: Kind
    let expiresAt: Date?
}

struct ZAIQuotaSnapshot: Equatable, Codable {
    let kind: ZAIPlanKind?
    let limits: [ZAILimit]
    let balances: [ZAIBalance]
    let resetCreditCards: [ZAIResetCreditCard]?
    let level: String?
    let planName: String?
    let planDescription: String?
    let apiKeySuffix: String?
    let email: String?
    let fetchedAt: Date
    /// start-plan 套餐自身状态与时间（plans[].status / starts_at / ends_at）。
    let planStatus: String?
    let planStartAt: Date?
    let planEndAt: Date?
    /// start-plan 权益项（plans[].entitlements[]）；生效前 balances 为空、用它展示待生效额度。
    let pendingEntitlements: [ZAIPendingEntitlement]
    let mcpUsage: ZAIMCPUsage?

    init(kind: ZAIPlanKind? = nil,
         limits: [ZAILimit] = [],
         balances: [ZAIBalance] = [],
         resetCreditCards: [ZAIResetCreditCard]? = nil,
         level: String? = nil,
         planName: String? = nil,
         planDescription: String? = nil,
         apiKeySuffix: String? = nil,
         email: String? = nil,
         fetchedAt: Date = Date(),
         planStatus: String? = nil,
         planStartAt: Date? = nil,
         planEndAt: Date? = nil,
         pendingEntitlements: [ZAIPendingEntitlement] = [],
         mcpUsage: ZAIMCPUsage? = nil) {
        self.kind = kind
        self.limits = limits
        self.balances = balances
        self.resetCreditCards = resetCreditCards
        self.level = level
        self.planName = planName
        self.planDescription = planDescription
        self.apiKeySuffix = apiKeySuffix
        self.email = email
        self.fetchedAt = fetchedAt
        self.planStatus = planStatus
        self.planStartAt = planStartAt
        self.planEndAt = planEndAt
        self.pendingEntitlements = pendingEntitlements
        self.mcpUsage = mcpUsage
    }

    /// 新增字段用 decodeIfPresent，保证 UserDefaults 里的旧缓存仍能解码。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ZAIPlanKind.self, forKey: .kind)
        limits = try container.decodeIfPresent([ZAILimit].self, forKey: .limits) ?? []
        balances = try container.decodeIfPresent([ZAIBalance].self, forKey: .balances) ?? []
        resetCreditCards = try container.decodeIfPresent([ZAIResetCreditCard].self, forKey: .resetCreditCards)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        planDescription = try container.decodeIfPresent(String.self, forKey: .planDescription)
        apiKeySuffix = try container.decodeIfPresent(String.self, forKey: .apiKeySuffix)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        planStatus = try container.decodeIfPresent(String.self, forKey: .planStatus)
        planStartAt = try container.decodeIfPresent(Date.self, forKey: .planStartAt)
        planEndAt = try container.decodeIfPresent(Date.self, forKey: .planEndAt)
        pendingEntitlements = try container.decodeIfPresent([ZAIPendingEntitlement].self, forKey: .pendingEntitlements) ?? []
        mcpUsage = try container.decodeIfPresent(ZAIMCPUsage.self, forKey: .mcpUsage)
    }
}

struct ZAIAccount: Equatable {
    let email: String?
}

enum ZAIQuotaError: LocalizedError {
    case credentialsMissing
    case decryptionFailed(String)
    case requestFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "未找到 ZAI 登录凭证"
        case .decryptionFailed(let detail):
            return "ZAI 凭证解密失败：\(detail)"
        case .requestFailed(let detail):
            return "ZAI 额度请求失败：\(detail)"
        case .malformedResponse:
            return "ZAI 额度响应格式异常"
        }
    }
}

// MARK: - ZAI 凭证 / 配置读取

enum ZAISettings {
    /// 优先读 ~/.zcode/setting.json；兼容当前 zcode 的 v2 子目录。
    /// zai / bigmodel 两个渠道都属于 GLM 家族，都展示余额区块。
    static func isZAIDomain() -> Bool {
        resolveProviderSelection() != nil
    }

    /// 从 setting.json 解析当前渠道（zai/bigmodel）与所选 provider 对应的账号形态。
    /// selectedKey 形如 "coding-plan:builtin:zai-start-plan" / "api-key:builtin:zai"。
    static func resolveProviderSelection() -> ZAIProviderSelection? {
        guard let url = settingURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return resolveProviderSelection(object: object)
    }

    /// 纯解析入口，供单测直接注入 setting.json 的字典内容。
    /// ZCode 3.12.3 起切换套餐只写 `providerFamilyConnectionSelections[domain].kind`，
    /// `modelProviderFamilySelectedKeys` 已冻结在旧值上；连接选择存在时必须以它为准，
    /// 否则会跟着冻结的旧套餐走（例如切到 start-plan 后仍查 coding-plan 额度）。
    static func resolveProviderSelection(object: [String: Any]) -> ZAIProviderSelection? {
        guard let domain = object["providerFamilyDomain"] as? String,
              domain == "zai" || domain == "bigmodel"
        else { return nil }

        let selectedKey = (object["modelProviderFamilySelectedKeys"] as? [String: String])?[domain]

        if let connectionKind = connectionSelectionKind(object: object, domain: domain),
           let kind = ZAIPlanKind(connectionKind: connectionKind) {
            let teamContext = teamContext(object: object, domain: domain, connectionKind: connectionKind)
            return ZAIProviderSelection(domain: domain, kind: kind,
                                        selectedKey: selectedKey, connectionKind: connectionKind,
                                        teamContext: teamContext)
        }

        let kind: ZAIPlanKind
        if let key = selectedKey?.lowercased() {
            if key.contains("start-plan") {
                kind = .startPlan
            } else if key.contains("coding-plan") {
                kind = .codingPlan
            } else if key.hasPrefix("api-key") {
                kind = .apiKey
            } else {
                kind = fallbackKind(object: object, domain: domain)
            }
        } else {
            kind = fallbackKind(object: object, domain: domain)
        }
        return ZAIProviderSelection(domain: domain, kind: kind, selectedKey: selectedKey)
    }

    /// `providerFamilyConnectionSelections[domain].kind`；条目缺失或形状非法时返回 nil，
    /// 由 legacy 路径接管（api-key 模式、未重启的惰性迁移窗口、team 连接未解析）。
    private static func connectionSelectionKind(object: [String: Any], domain: String) -> String? {
        guard let selections = object["providerFamilyConnectionSelections"] as? [String: Any],
              let entry = selections[domain] as? [String: Any]
        else { return nil }
        guard let kind = entry["kind"] as? String, !kind.isEmpty else { return nil }
        return kind
    }

    private static func teamContext(object: [String: Any], domain: String,
                                    connectionKind: String) -> ZAITeamContext? {
        guard connectionKind == "team-coding-plan",
              let selections = object["providerFamilyConnectionSelections"] as? [String: Any],
              let entry = selections[domain] as? [String: Any],
              let organizationId = nonEmptyString(entry["organizationId"]),
              let projectId = nonEmptyString(entry["projectId"]) else { return nil }
        return ZAITeamContext(productId: nonEmptyString(entry["productId"]),
                              organizationId: organizationId, projectId: projectId)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackKind(object: [String: Any], domain: String) -> ZAIPlanKind {
        let mode = (object["modelProviderFamilyModes"] as? [String: String])?[domain]
        return mode == "oauth" ? .codingPlan : .apiKey
    }

    private static var zcodeV2URL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    private static var settingURLs: [URL] {
        let zcodeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode", isDirectory: true)
        return [
            zcodeURL.appendingPathComponent("setting.json"),
            zcodeURL.appendingPathComponent("v2", isDirectory: true)
                .appendingPathComponent("setting.json")
        ]
    }

    /// 从 credentials.json 解密出 OAuth access token 与用户信息。
    /// bigmodel 渠道优先找 oauth:bigmodel:*，回退 oauth:zai:*（两渠道共用 zai OAuth 的历史布局）。
    static func loadCredentials(domain: String = "zai", allowZaiFallback: Bool = true) throws -> (accessToken: String, userInfo: [String: Any]?) {
        guard let v2 = zcodeV2URL else { throw ZAIQuotaError.credentialsMissing }
        let credsURL = v2.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: credsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw ZAIQuotaError.credentialsMissing }

        let cipher = ZAICredentialCipher()

        let encryptedToken = object["oauth:\(domain):access_token"]
            ?? (allowZaiFallback ? object["oauth:zai:access_token"] : nil) ?? ""
        guard !encryptedToken.isEmpty else { throw ZAIQuotaError.credentialsMissing }
        let token = try cipher.decrypt(encryptedToken)

        var userInfo: [String: Any]?
        let encryptedUser = object["oauth:\(domain):user_info"] ?? (allowZaiFallback ? object["oauth:zai:user_info"] : nil)
        if let encryptedUser, !encryptedUser.isEmpty {
            if let plain = try? cipher.decrypt(encryptedUser),
               let jsonData = plain.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                userInfo = parsed
            }
        }

        return (token, userInfo)
    }

    /// 账号信息来自本地加密的 user_info，不依赖额度接口。
    static func loadAccount() -> ZAIAccount? {
        let domain = resolveProviderSelection()?.domain ?? "zai"
        guard let userInfo = try? loadCredentials(domain: domain).userInfo else { return nil }
        let nestedUser = userInfo["user"] as? [String: Any]
        return ZAIAccount(
            email: (userInfo["email"] as? String) ?? (nestedUser?["email"] as? String)
        )
    }

    // MARK: config.json（provider 明文配置）

    /// 读取 config.json 中某个 provider 的配置块。
    private static func providerConfig(_ providerID: String) -> [String: Any]? {
        guard let v2 = zcodeV2URL,
              let data = try? Data(contentsOf: v2.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = object["provider"] as? [String: Any]
        else { return nil }
        return provider[providerID] as? [String: Any]
    }

    /// provider 配置里的明文 apiKey（zai-start-plan 存的是 JWT，api-key 模式存的是平台 Key）。
    static func providerAPIKey(_ providerID: String) -> String? {
        guard let config = providerConfig(providerID),
              let apiKey = (config["options"] as? [String: Any])?["apiKey"] as? String,
              !apiKey.isEmpty
        else { return nil }
        return apiKey
    }

    /// start-plan provider（builtin:<domain>-start-plan）的 baseURL 与 apiKey。
    /// 不同 plan 的 provider 各自独立配置；余额端点与凭证都从它取，
    /// 不再硬编码 zcode.z.ai。
    static func startPlanProviderConfig(domain: String) -> (baseURL: URL?, apiKey: String?) {
        guard let config = providerConfig("builtin:\(domain)-start-plan"),
              let options = config["options"] as? [String: Any]
        else { return (nil, nil) }
        let baseURL = (options["baseURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let apiKey = (options["apiKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (baseURL, apiKey)
    }

    /// start-plan 计费查询凭证：优先 config.json 里体验套餐 provider 的明文 JWT，
    /// 回退解密 credentials.json 的 zcodejwttoken。
    static func loadStartPlanToken(domain: String) throws -> String {
        if let jwt = providerAPIKey("builtin:\(domain)-start-plan"),
           jwt.split(separator: ".").count == 3 {
            return jwt
        }
        return try loadZCodeJWTToken()
    }

    /// coding-plan 重置额度接口的凭证之一：credentials.json 的 zcodejwttoken。
    static func loadZCodeJWTToken() throws -> String {
        guard let v2 = zcodeV2URL,
              let data = try? Data(contentsOf: v2.appendingPathComponent("credentials.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let encrypted = object["zcodejwttoken"], !encrypted.isEmpty
        else { throw ZAIQuotaError.credentialsMissing }
        return try ZAICredentialCipher().decrypt(encrypted)
    }

    /// 设备标识（对齐 zcode.cjs 的 readExistingDeviceMid）：
    /// 读 ~/.zcode/v2/telemetry-state.json 的 deviceMid，只读不生成。
    /// zcode.z.ai 网关对缺该头的 billing/balance 返回 400 "parameter error"。
    static func loadDeviceMid() -> String? {
        guard let v2 = zcodeV2URL,
              let data = try? Data(contentsOf: v2.appendingPathComponent("telemetry-state.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mid = object["deviceMid"] as? String
        else { return nil }
        let trimmed = mid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// selectedKey（"api-key:builtin:zai"）里去掉首个模式前缀后的 provider id。
    static func providerID(fromSelectedKey selectedKey: String?, domain: String) -> String {
        guard let selectedKey else { return "builtin:\(domain)" }
        let parts = selectedKey.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return "builtin:\(domain)" }
        return parts[1...].joined(separator: ":")
    }
}

/// 与 zcode.cjs 对齐的 AES-256-GCM 凭证加解密。
/// Key 派生：sha256("zcode-credential-fallback:<platform>:<homedir>:<username>")。
/// 密文格式：enc:v1:<iv>.<authTag>.<ciphertext>（均为 base64url）。
struct ZAICredentialCipher {
    private let key: SymmetricKey

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let username = NSUserName()
        let platform = "darwin"
        let fallback = "zcode-credential-fallback:\(platform):\(home):\(username)"
        let configuredSecret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = configuredSecret?.isEmpty == false ? configuredSecret! : fallback
        let digest = SHA256.hash(data: Data(secret.utf8))
        key = SymmetricKey(data: Data(digest))
    }

    func decrypt(_ value: String) throws -> String {
        let prefix = "enc:v1:"
        guard value.hasPrefix(prefix) else { return value }
        let body = String(value.dropFirst(prefix.count))
        let parts = body.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let iv = Data(base64URLEncoded: parts[0]),
              let tag = Data(base64URLEncoded: parts[1]),
              let ciphertext = Data(base64URLEncoded: parts[2])
        else { throw ZAIQuotaError.decryptionFailed("invalid ciphertext") }

        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                           ciphertext: ciphertext,
                                           tag: tag)
        let plaintext = try AES.GCM.open(sealed, using: key)
        return String(data: plaintext, encoding: .utf8) ?? ""
    }
}

private extension Data {
    /// 解析 base64url（RFC 4648 §5），对齐 zcode 的 IV/tag/ciphertext 编码。
    init?(base64URLEncoded input: String) {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s.append(String(repeating: "=", count: pad)) }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}

// MARK: - ZAI 额度 HTTP 客户端

enum ZAIQuotaEndpoint {
    /// 个人付费 Coding Plan 用 api.z.ai，bigmodel 渠道用 open.bigmodel.cn。
    private static func codingPlanBaseURL(domain: String) -> URL {
        URL(string: domain == "bigmodel" ? "https://open.bigmodel.cn" : "https://api.z.ai")!
    }

    static func makeCodingPlanRequest(token: String, domain: String,
                                      teamContext: ZAITeamContext? = nil,
                                      authorization: String? = nil) -> URLRequest {
        var components = URLComponents(url: codingPlanBaseURL(domain: domain)
            .appendingPathComponent("api/monitor/usage/quota/limit"), resolvingAgainstBaseURL: false)!
        if teamContext != nil { components.queryItems = [URLQueryItem(name: "type", value: "2")] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization ?? "Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "bigmodel-organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "bigmodel-project")
        }
        request.timeoutInterval = 15
        return request
    }

    static func makeMCPUsageRequest(jwt: String, oauthToken: String,
                                    teamContext: ZAITeamContext?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/mcp/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "X-Bigmodel-Authorization")
        request.setValue(teamContext == nil ? "PERSONAL" : "TEAM", forHTTPHeaderField: "Bigmodel-Target-Type")
        if let teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "Bigmodel-Organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "Bigmodel-Project")
        }
        request.timeoutInterval = 15
        return request
    }

    static func makeTeamCustomerInfoRequest(oauthToken: String, domain: String) -> URLRequest {
        var request = URLRequest(url: codingPlanBaseURL(domain: domain)
            .appendingPathComponent("api/biz/customer/getCustomerInfo"))
        request.httpMethod = "GET"
        request.setValue(oauthToken, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    static func makeTeamAPIKeysRequest(oauthToken: String, domain: String,
                                       teamContext: ZAITeamContext, apiKey: String? = nil) -> URLRequest {
        var url = codingPlanBaseURL(domain: domain)
            .appendingPathComponent("api/biz/v1/organization")
            .appendingPathComponent(teamContext.organizationId)
            .appendingPathComponent("projects")
            .appendingPathComponent(teamContext.projectId)
            .appendingPathComponent("api_keys")
        if let apiKey {
            url.appendPathComponent("copy")
            url.appendPathComponent(apiKey)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(oauthToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(teamContext.organizationId, forHTTPHeaderField: "bigmodel-organization")
        request.setValue(teamContext.projectId, forHTTPHeaderField: "bigmodel-project")
        request.timeoutInterval = 15
        return request
    }

    /// start-plan（体验套餐）计费余额。端点跟随该 provider 自身配置：
    /// baseURL 取自 config.json 的 builtin:<domain>-start-plan（形如 …/api/v1/zcode-plan/anthropic），
    /// 余额端点为同 origin 下的 /api/v1/zcode-plan/billing/balance，需带 app_version（与 zcode 官方一致）。
    /// 凭证是套餐 JWT（provider 的 options.apiKey），而非 OAuth token。
    /// deviceMid 是网关强制的设备标识（缺失时 400 "parameter error"），
    /// 来自 telemetry-state.json，官方 host 的其余来源头（UA/平台等）经二分验证均非必需。
    static func makeStartPlanBalanceRequest(token: String, baseURL: URL, deviceMid: String?) -> URLRequest {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = "/api/v1/zcode-plan/billing/balance"
        components.queryItems = [URLQueryItem(name: "app_version", value: "3.10.1")]
        let url = components.url
            ?? URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.10.1")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let deviceMid, !deviceMid.isEmpty {
            request.setValue(deviceMid, forHTTPHeaderField: "X-Device-Mid")
        }
        request.timeoutInterval = 15
        return request
    }

    /// coding-plan 重置额度状态。z.ai / bigmodel 两渠道共用 zcode.z.ai，
    /// 靠 X-Bigmodel-Authorization 里的 OAuth token 区分账号体系。
    static func makeCodingPlanResetStatusRequest(jwt: String, oauthToken: String,
                                                 teamContext: ZAITeamContext? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/coding-plan/reset/status")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "X-Bigmodel-Authorization")
        request.setValue(teamContext == nil ? "PERSONAL" : "TEAM", forHTTPHeaderField: "Bigmodel-Target-Type")
        if let teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "Bigmodel-Organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "Bigmodel-Project")
        }
        request.timeoutInterval = 15
        return request
    }
}

// MARK: - ZAI 额度 Store

@MainActor
final class ZAIQuotaStore {
    static let refreshCooldown: TimeInterval = 5 * 60
    /// 后台周期刷新间隔，默认与 Codex 一致，可在状态栏右键菜单调整。
    private(set) var refreshInterval: TimeInterval
    private let session: URLSession

    private(set) var snapshot: ZAIQuotaSnapshot?
    private(set) var account: ZAIAccount?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastRefreshStartedAt: Date?
    private(set) var lastResetScopeID: String?
    private var needsRefreshAfterCurrent = false
    private var timer: Timer?

    var onChange: ((ZAIQuotaSnapshot?, ZAIAccount?, Bool, String?) -> Void)?
    /// coding-plan 额度刷新成功后触发，携带发起时刻捕获的凭证与作用域；
    /// ZAIServerUsageStore 挂此回调做 model-usage 增量同步，复用同一凭证。
    var onUsageSyncContext: ((ZAIUsageSyncContext) -> Void)?
    private var pendingUsageSyncContext: ZAIUsageSyncContext?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        snapshot = ZAIQuotaCache.load()
        account = ZAISettings.loadAccount()
        refreshInterval = RefreshSettings.load()
    }

    /// 启动后台周期刷新：启动立即刷一次，之后按设置的间隔重复（与 Codex store 行为对齐）。
    /// 显隐控制交给 UI 层（setZAISectionVisible / isZAIDomain），refresh 内部用
    /// `guard !isRefreshing` 防止重入。
    func start() {
        timer?.invalidate()
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 修改自动刷新间隔；已在运行时则按新间隔重建定时器，不额外触发一次网络刷新。
    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// 已弃用：start() 与 timer 回调直接调 refresh()，行为与 Codex `refresh(force:)` 一致。
    /// 保留以兼容可能存在的旧调用点（实际目前已无人调用）。
    func refreshIfNeeded() {
        refresh()
    }

    /// 重置成功后必须开始一次新查询；已有查询尚未结束时排队执行。
    func refreshAfterReset() {
        if isRefreshing {
            needsRefreshAfterCurrent = true
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshStartedAt = Date()
        lastResetScopeID = nil
        pendingUsageSyncContext = nil
        account = ZAISettings.loadAccount()
        onChange?(snapshot, account, true, lastError)

        Task { @MainActor in
            do {
                let next = try await fetchSnapshot()
                snapshot = next
                account = ZAIAccount(email: next.email ?? account?.email)
                lastError = nil
                ZAIQuotaCache.save(next)
                if let usageContext = pendingUsageSyncContext {
                    onUsageSyncContext?(usageContext)
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isRefreshing = false
            onChange?(snapshot, account, false, lastError)
            if needsRefreshAfterCurrent {
                needsRefreshAfterCurrent = false
                refresh()
            }
        }
    }

    private func fetchSnapshot() async throws -> ZAIQuotaSnapshot {
        guard let selection = ZAISettings.resolveProviderSelection() else {
            throw ZAIQuotaError.credentialsMissing
        }
        switch selection.kind {
        case .apiKey:
            return makeAPIKeySnapshot(selection: selection)
        case .startPlan:
            return try await fetchStartPlanSnapshot(selection: selection)
        case .codingPlan:
            return try await fetchCodingPlanSnapshot(selection: selection)
        }
    }

    /// API Key 模式没有余额接口，本地组装快照供 UI 区分展示。
    private func makeAPIKeySnapshot(selection: ZAIProviderSelection) -> ZAIQuotaSnapshot {
        let providerID = ZAISettings.providerID(fromSelectedKey: selection.selectedKey, domain: selection.domain)
        let apiKey = ZAISettings.providerAPIKey(providerID)
            ?? ZAISettings.providerAPIKey("builtin:\(selection.domain)")
        return ZAIQuotaSnapshot(
            kind: .apiKey,
            apiKeySuffix: apiKey.map { String($0.suffix(4)) },
            email: ZAISettings.loadAccount()?.email
        )
    }

    /// 体验套餐余额。数据源顺序：
    /// 1) zcode host 日志（host 每 ~秒拉一次 billing/balance 并把完整响应落盘，
    ///    与 ZCode 界面一致；app 直连 zcode.z.ai 常被网关拦截，用日志兜底）。
    /// 2) 直连 GET zcode.z.ai/api/v1/zcode-plan/billing/balance（provider 自身的 baseURL + JWT）。
    private func fetchStartPlanSnapshot(selection: ZAIProviderSelection) async throws -> ZAIQuotaSnapshot {
        let now = Date()
        if let payload = Self.latestStartPlanBalancePayload(domain: selection.domain) {
            return try Self.parseStartPlanSnapshot(payload: payload, selection: selection, fetchedAt: now)
        }
        return try await fetchStartPlanSnapshotNetwork(selection: selection)
    }

    private func fetchStartPlanSnapshotNetwork(selection: ZAIProviderSelection) async throws -> ZAIQuotaSnapshot {
        let providerConfig = ZAISettings.startPlanProviderConfig(domain: selection.domain)
        let token = try ZAISettings.loadStartPlanToken(domain: selection.domain)
        let baseURL = providerConfig.baseURL
            ?? URL(string: "https://zcode.z.ai/api/v1/zcode-plan/anthropic")!
        let request = ZAIQuotaEndpoint.makeStartPlanBalanceRequest(
            token: token, baseURL: baseURL, deviceMid: ZAISettings.loadDeviceMid()
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZAIQuotaError.requestFailed("HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }
        return try Self.parseStartPlanSnapshot(payload: object, selection: selection)
    }

    /// 解析 billing/balance 响应（payload：{code,msg,data:{plans,balances}}），网络与 host 日志共用。
    private static func parseStartPlanSnapshot(payload: [String: Any],
                                               selection: ZAIProviderSelection,
                                               fetchedAt: Date = Date()) throws -> ZAIQuotaSnapshot {
        try Self.checkBusinessError(payload)

        guard let dataPayload = payload["data"] as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }

        // plans[] 提供套餐名；entitlements[] 提供权益生效时间与额度。
        let plans = (dataPayload["plans"] as? [[String: Any]]) ?? []
        let activePlan = plans.first { ($0["status"] as? String) == "active" } ?? plans.first

        // 套餐级信息：权益生效前（新规则：套餐未到开始时间）接口 balances 为空，
        // 只返回 plans[].entitlements[]，这里保留用于「待生效」展示，不算错误。
        let planStatus = activePlan?["status"] as? String
        let planStartAt = activePlan.flatMap { Self.secondLevelDate($0["starts_at"]) }
        let planEndAt = activePlan.flatMap { Self.secondLevelDate($0["ends_at"]) }
        let pendingEntitlements: [ZAIPendingEntitlement] =
            ((activePlan?["entitlements"] as? [[String: Any]]) ?? []).compactMap { item in
                let title = (item["show_name"] as? String) ?? ""
                guard !title.isEmpty else { return nil }
                return ZAIPendingEntitlement(
                    title: title,
                    grantUnits: (item["grant_units"] as? NSNumber)?.doubleValue ?? 0,
                    effectiveAt: Self.secondLevelDate(item["effective_at"]),
                    period: (item["period"] as? String) ?? "one_time",
                    expiresAt: Self.secondLevelDate(item["expires_at"]) ?? planEndAt
                )
            }
            .filter { $0.effectiveAt.map { $0 > Date() } ?? true }

        var periodByEntitlement: [String: String] = [:]
        for plan in plans {
            for entitlement in (plan["entitlements"] as? [[String: Any]]) ?? [] {
                if let id = entitlement["entitlement_id"] as? String,
                   let period = entitlement["period"] as? String {
                    periodByEntitlement[id] = period
                }
            }
        }

        let balances: [(priority: Int, balance: ZAIBalance)] = ((dataPayload["balances"] as? [[String: Any]]) ?? []).compactMap { balance in
            let totalUnits = (balance["total_units"] as? NSNumber)?.doubleValue ?? 0
            guard totalUnits > 0 else { return nil }
            let entitlementID = balance["entitlement_id"] as? String
            // period 缺失时按周期跨度推断：跨天视为 one_time，当天内视为 daily。
            let period = entitlementID.flatMap { periodByEntitlement[$0] }
                ?? Self.inferPeriod(start: (balance["period_start"] as? NSNumber)?.doubleValue,
                                    end: (balance["period_end"] as? NSNumber)?.doubleValue)
            return (
                priority: (balance["priority"] as? NSNumber)?.intValue ?? 0,
                balance: ZAIBalance(
                    title: (balance["show_name"] as? String) ?? "额度",
                    totalUnits: totalUnits,
                    remainingUnits: (balance["remaining_units"] as? NSNumber)?.doubleValue
                        ?? (balance["available_units"] as? NSNumber)?.doubleValue ?? 0,
                    expiresAt: Self.secondLevelDate(balance["expires_at"]),
                    period: period
                )
            )
        }.sorted { $0.priority > $1.priority }
        let visibleBalances = balances.map(\.balance)

        return ZAIQuotaSnapshot(
            kind: .startPlan,
            balances: Array(visibleBalances),
            planName: activePlan?["name"] as? String,
            planDescription: activePlan?["description"] as? String,
            email: ZAISettings.loadAccount()?.email,
            fetchedAt: fetchedAt,
            planStatus: planStatus,
            planStartAt: planStartAt,
            planEndAt: planEndAt,
            pendingEntitlements: pendingEntitlements
        )
    }

    /// start-plan 日志条目的 providerId 匹配：ZCode ≤3.11 写 `builtin:<domain>-start-plan`，
    /// 3.12.3 起 host 改写 `account:<domain>-start-plan`（zcode.cjs 的 provider 正则两种都认）。
    nonisolated static func isStartPlanLogProviderID(_ providerID: String, domain: String) -> Bool {
        let lowered = providerID.lowercased()
        return lowered == "builtin:\(domain)-start-plan" || lowered == "account:\(domain)-start-plan"
    }

    /// 从 ~/.zcode/v2/logs/<当天>.log 取最新一条 start-plan 的 billing/balance 响应 payload。
    /// host 每 ~秒把完整响应写进 [usage-stats]/[coding-plan-availability] 行，
    /// 只认 providerId 为 start-plan 的条目（前缀见 isStartPlanLogProviderID）。
    private static func latestStartPlanBalancePayload(domain: String) -> [String: Any]? {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = logs.appendingPathComponent("\(formatter.string(from: Date())).log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let marker = "billing/balance 请求完成"
        var searchRange = text.startIndex..<text.endIndex
        var lastPayload: [String: Any]?
        while let matched = text.range(of: marker, range: searchRange) {
            let after = matched.upperBound
            if let newline = text[after...].firstIndex(of: "\n") {
                let line = String(text[after..<newline])
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let providerID = object["providerId"] as? String,
                   isStartPlanLogProviderID(providerID, domain: domain),
                   let payload = object["payload"] as? [String: Any] {
                    lastPayload = payload
                }
            }
            searchRange = after..<text.endIndex
        }
        return lastPayload
    }

    /// Coding Plan 额度。个人使用 OAuth；团队使用项目 API Key/Secret 与 type=2。
    private func fetchCodingPlanSnapshot(selection: ZAIProviderSelection) async throws -> ZAIQuotaSnapshot {
        let (token, userInfo) = try ZAISettings.loadCredentials(domain: selection.domain)
        // 身份标识和两个查询都使用同一组已捕获凭证，不能在 await 后重读切换中的账号。
        let resetJWT = try? ZAISettings.loadZCodeJWTToken()
        if let resetJWT {
            lastResetScopeID = try? ZAIResetContextResolver.makeContext(
                selection: selection, jwt: resetJWT, oauthToken: token, userInfo: userInfo
            ).scopeID
        }
        let teamContext = selection.teamContext
        if selection.connectionKind == "team-coding-plan" && teamContext == nil {
            throw ZAIQuotaError.requestFailed("团队套餐缺少 organizationId 或 projectId")
        }
        let projectAuthorization: String?
        if let teamContext {
            projectAuthorization = try await fetchTeamProjectAuthorization(
                selection: selection, token: token, context: teamContext
            )
        } else {
            projectAuthorization = nil
        }
        let request = ZAIQuotaEndpoint.makeCodingPlanRequest(
            token: token,
            domain: selection.domain,
            teamContext: teamContext,
            authorization: projectAuthorization
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZAIQuotaError.requestFailed("HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }

        // 业务失败时接口仍返回 HTTP 200，但 success=false，此时把服务端 msg 展示出来。
        try Self.checkBusinessError(object)

        guard let dataPayload = object["data"] as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }

        let rawLimits = (dataPayload["limits"] as? [[String: Any]]) ?? []
        // 账号版本不同会返回 TOKENS_LIMIT / TIME_LIMIT / CREDIT_LIMIT；
        // 统一按窗口 unit 归一化，避免旧 Token 口径漏掉 v3 积分口径。
        let limits = Self.parseCodingPlanLimits(rawLimits)

        let level = dataPayload["level"] as? String
        let email = userInfo?["email"] as? String

        // 重置额度是增量信息：单独容错，失败不影响主额度展示。
        let resetCreditCards: [ZAIResetCreditCard]?
        if let resetJWT {
            resetCreditCards = try? await fetchResetCreditCards(
                jwt: resetJWT, oauthToken: token, teamContext: teamContext
            )
        } else {
            resetCreditCards = nil
        }

        let mcpUsage: ZAIMCPUsage?
        if let resetJWT {
            mcpUsage = try? await fetchMCPUsage(jwt: resetJWT, oauthToken: token, teamContext: teamContext)
        } else {
            mcpUsage = nil
        }

        // 用量同步上下文：与额度查询同一组已捕获凭证（团队含项目 Key/Secret），
        // ZAIServerUsageStore 复用它请求 model-usage，避免重复换取项目 Key。
        pendingUsageSyncContext = ZAIUsageSyncContext(
            domain: selection.domain,
            email: email,
            teamContext: teamContext,
            authorization: projectAuthorization ?? "Bearer \(token)"
        )

        return ZAIQuotaSnapshot(
            kind: .codingPlan,
            limits: limits,
            resetCreditCards: resetCreditCards,
            level: level,
            email: email,
            mcpUsage: mcpUsage
        )
    }

    nonisolated static func parseCodingPlanLimits(_ rawLimits: [[String: Any]]) -> [ZAILimit] {
        rawLimits.compactMap { limit in
            let number = (limit["number"] as? NSNumber)?.intValue ?? 1
            let unit: ZAILimit.WindowUnit
            if let unitRaw = Self.limitUnitRawValue(limit["unit"]),
               let parsed = ZAILimit.WindowUnit(rawValue: unitRaw), parsed != .unknown {
                unit = parsed
            } else if let unitName = (limit["unit"] as? String)?.uppercased() {
                switch unitName {
                case "HOUR", "HOURLY", "5H", "5_HOUR", "5_HOURS": unit = .hourly
                case "WEEK", "WEEKLY", "1W", "1_WEEK", "1_WEEKLY": unit = .weekly
                default: return nil
                }
            } else {
                return nil
            }
            let usedPercent: Double
            if let percentage = (limit["percentage"] as? NSNumber)?.doubleValue {
                usedPercent = percentage
            } else if let current = (limit["currentValue"] as? NSNumber)?.doubleValue,
                      let remaining = (limit["remaining"] as? NSNumber)?.doubleValue {
                let total = current + remaining
                usedPercent = total > 0 ? current / total * 100 : 0
            } else {
                usedPercent = 0
            }
            let resetTime = (limit["nextResetTime"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            return ZAILimit(
                unit: unit,
                number: number,
                usedPercent: usedPercent,
                nextResetTime: resetTime
            )
        }.sorted { $0.unit.rawValue < $1.unit.rawValue }
    }

    private nonisolated static func limitUnitRawValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func fetchTeamProjectAuthorization(selection: ZAIProviderSelection,
                                               token: String,
                                               context: ZAITeamContext) async throws -> String {
        let customerRequest = ZAIQuotaEndpoint.makeTeamCustomerInfoRequest(
            oauthToken: token, domain: selection.domain
        )
        let (customerData, customerResponse) = try await session.data(for: customerRequest)
        guard let customerHTTP = customerResponse as? HTTPURLResponse,
              customerHTTP.statusCode == 200,
              let customer = try? JSONSerialization.jsonObject(with: customerData) as? [String: Any]
        else { throw ZAIQuotaError.requestFailed("团队项目身份校验失败") }

        let organizations = ((customer["data"] as? [String: Any])?["organizations"] as? [[String: Any]])
            ?? (customer["organizations"] as? [[String: Any]]) ?? []
        let projectExists = organizations.contains { organization in
            guard (organization["organizationId"] as? String) == context.organizationId else { return false }
            return ((organization["projects"] as? [[String: Any]]) ?? []).contains {
                ($0["projectId"] as? String) == context.projectId
            }
        }
        guard projectExists else { throw ZAIQuotaError.requestFailed("团队项目不存在或无权限") }

        let listRequest = ZAIQuotaEndpoint.makeTeamAPIKeysRequest(
            oauthToken: token, domain: selection.domain, teamContext: context
        )
        let (listData, listResponse) = try await session.data(for: listRequest)
        guard let listHTTP = listResponse as? HTTPURLResponse,
              listHTTP.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: listData) as? [String: Any]
        else { throw ZAIQuotaError.requestFailed("团队项目 API Key 查询失败") }

        let keys = ((list["data"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        guard let projectKey = keys.first(where: {
            ($0["name"] as? String) == "zcode-team-api-key"
                && (($0["keyType"] as? NSNumber)?.intValue ?? -1) == 2
        }), let apiKey = projectKey["apiKey"] as? String, !apiKey.isEmpty else {
            throw ZAIQuotaError.requestFailed("团队项目 API Key 不可用")
        }

        let copyRequest = ZAIQuotaEndpoint.makeTeamAPIKeysRequest(
            oauthToken: token, domain: selection.domain, teamContext: context, apiKey: apiKey
        )
        let (copyData, copyResponse) = try await session.data(for: copyRequest)
        guard let copyHTTP = copyResponse as? HTTPURLResponse,
              copyHTTP.statusCode == 200,
              let copy = try? JSONSerialization.jsonObject(with: copyData) as? [String: Any],
              let copyPayload = copy["data"] as? [String: Any],
              let secret = copyPayload["secretKey"] as? String, !secret.isEmpty else {
            throw ZAIQuotaError.requestFailed("团队项目 API Key Secret 不可用")
        }
        return "\(apiKey).\(secret)"
    }

    private func fetchMCPUsage(jwt: String, oauthToken: String,
                               teamContext: ZAITeamContext?) async throws -> ZAIMCPUsage {
        let request = ZAIQuotaEndpoint.makeMCPUsageRequest(
            jwt: jwt, oauthToken: oauthToken, teamContext: teamContext
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataPayload = object["data"] as? [String: Any],
              let usage = dataPayload["total_usage"] as? [String: Any],
              let limit = (usage["limit"] as? NSNumber)?.doubleValue,
              let remaining = (usage["remaining"] as? NSNumber)?.doubleValue else {
            throw ZAIQuotaError.malformedResponse
        }
        let used = (usage["used"] as? NSNumber)?.doubleValue ?? max(0, limit - remaining)
        let nextRefresh = (dataPayload["next_refresh_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return ZAIMCPUsage(used: used, limit: limit, remaining: remaining, nextRefreshAt: nextRefresh)
    }

    /// coding-plan 重置额度：GET zcode.z.ai/api/v1/coding-plan/reset/status。
    /// 响应 data.available_five_hour_resets / available_week_resets 各是 {expire_at} 数组。
    private func fetchResetCreditCards(jwt: String, oauthToken: String,
                                       teamContext: ZAITeamContext?) async throws -> [ZAIResetCreditCard]? {
        let request = ZAIQuotaEndpoint.makeCodingPlanResetStatusRequest(
            jwt: jwt, oauthToken: oauthToken, teamContext: teamContext
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (try? Self.checkBusinessError(object)) != nil,
              let dataPayload = object["data"] as? [String: Any]
        else { return nil }

        func cards(_ key: String, kind: ZAIResetCreditCard.Kind) -> [ZAIResetCreditCard] {
            ((dataPayload[key] as? [[String: Any]]) ?? []).map {
                ZAIResetCreditCard(kind: kind, expiresAt: Self.secondLevelDate($0["expire_at"]))
            }
        }
        return cards("available_five_hour_resets", kind: .fiveHour)
            + cards("available_week_resets", kind: .week)
    }

    /// 两套接口的业务错误风格：api.z.ai 成功码是 200，zcode.z.ai 是 0，失败时都带 msg。
    private static func checkBusinessError(_ object: [String: Any]) throws {
        if let success = object["success"] as? Bool, !success {
            let message = (object["msg"] as? String) ?? "未知错误"
            throw ZAIQuotaError.requestFailed(message)
        }
        if let code = (object["code"] as? NSNumber)?.intValue, code != 0 && code != 200 {
            let message = (object["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未知错误(\(code))"
            throw ZAIQuotaError.requestFailed(message)
        }
    }

    /// billing/balance 的时间戳是秒级，超过 1e12 视为毫秒兜底。
    private static func secondLevelDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func inferPeriod(start: Double?, end: Double?) -> String {
        guard let start, let end else { return "one_time" }
        return (end - start) > 36 * 3600 ? "one_time" : "daily"
    }
}

// MARK: - ZAI 缓存

enum ZAIQuotaCache {
    private static let key = "local.codex.touchbar.quota.zai.lastSnapshot"

    static func load() -> ZAIQuotaSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ZAIQuotaSnapshot.self, from: data)
    }

    static func save(_ snapshot: ZAIQuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - ZAI 提醒桶映射

extension ZAIQuotaSnapshot {
    /// 提醒评估用的统一额度桶；apiKey 模式无余额数据、无桶。
    var reminderBuckets: [ReminderBucket] {
        switch kind {
        case .codingPlan?:
            return limits.map { limit in
                ReminderBucket(
                    source: .zai,
                    id: "zai.limit.\(limit.unit.rawValue).\(limit.number)",
                    title: Self.reminderTitle(for: limit),
                    shortTitle: Self.reminderShortTitle(for: limit),
                    remainingPercent: limit.remainingPercent,
                    resetsAt: limit.nextResetTime
                )
            } + Self.resetCardReminderBuckets(cards: resetCreditCards, now: Date())
        case .startPlan?:
            return balances.map { balance in
                ReminderBucket(
                    source: .zai,
                    id: "zai.balance.\(balance.title)",
                    title: "ZAI \(balance.title)",
                    shortTitle: balance.title,
                    remainingPercent: balance.remainingFraction * 100,
                    resetsAt: balance.expiresAt
                )
            } + pendingEntitlements.map { entitlement in
                ReminderBucket(
                    source: .zai,
                    id: "zai.pending.\(entitlement.title)",
                    title: "ZAI \(entitlement.title)",
                    shortTitle: entitlement.title,
                    remainingPercent: 100,
                    resetsAt: entitlement.expiresAt
                )
            }
        default:
            return []
        }
    }

    private static func reminderTitle(for limit: ZAILimit) -> String {
        switch limit.unit {
        case .hourly: return "ZAI \(limit.number)小时额度"
        case .weekly: return "ZAI 周额度"
        case .unknown: return "ZAI \(limit.title)"
        }
    }

    /// 与 reminderTitle 对应的短名（不含 "ZAI " 前缀），供灵动岛每行展示用。
    private static func reminderShortTitle(for limit: ZAILimit) -> String {
        switch limit.unit {
        case .hourly: return "\(limit.number)小时额度"
        case .weekly: return "周额度"
        case .unknown: return limit.title
        }
    }

    /// 未过期的重置卡按种类各合成一个提醒桶，resetsAt 取该种类最早到期。
    private static func resetCardReminderBuckets(cards: [ZAIResetCreditCard]?, now: Date) -> [ReminderBucket] {
        let alertable = (cards ?? []).filter { $0.expiresAt.map { $0 > now } ?? false }
        return [ZAIResetCreditCard.Kind.fiveHour, .week].compactMap { kind in
            let group = alertable.filter { $0.kind == kind }
            guard let earliest = group.compactMap(\.expiresAt).min() else { return nil }
            return ReminderBucket(
                source: .zai,
                id: "zai.resetCard.\(kind.rawValue)",
                title: "ZAI \(Self.resetCardTitle(for: kind))",
                shortTitle: Self.resetCardShortTitle(for: kind),
                remainingPercent: 100,
                resetsAt: earliest,
                kind: .resetCard,
                cardCount: group.count
            )
        }
    }

    private static func resetCardTitle(for kind: ZAIResetCreditCard.Kind) -> String {
        switch kind {
        case .fiveHour: return "5小时重置卡"
        case .week: return "周额度重置卡"
        }
    }

    private static func resetCardShortTitle(for kind: ZAIResetCreditCard.Kind) -> String {
        switch kind {
        case .fiveHour: return "5H重置卡"
        case .week: return "周重置卡"
        }
    }
}
