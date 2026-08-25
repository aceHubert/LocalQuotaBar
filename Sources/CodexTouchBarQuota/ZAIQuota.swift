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
}

struct ZAILimit: Equatable, Codable {
    enum WindowUnit: Int, Codable {
        case hourly = 3
        case weekly = 4
        case unknown = -1

        init?(rawValue: Int) {
            switch rawValue {
            case 3: self = .hourly
            case 4: self = .weekly
            default: self = .unknown
            }
        }
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

    init(kind: ZAIPlanKind? = nil,
         limits: [ZAILimit] = [],
         balances: [ZAIBalance] = [],
         resetCreditCards: [ZAIResetCreditCard]? = nil,
         level: String? = nil,
         planName: String? = nil,
         planDescription: String? = nil,
         apiKeySuffix: String? = nil,
         email: String? = nil,
         fetchedAt: Date = Date()) {
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
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domain = object["providerFamilyDomain"] as? String,
              domain == "zai" || domain == "bigmodel"
        else { return nil }

        let selectedKey = (object["modelProviderFamilySelectedKeys"] as? [String: String])?[domain]
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
    static func loadCredentials(domain: String = "zai") throws -> (accessToken: String, userInfo: [String: Any]?) {
        guard let v2 = zcodeV2URL else { throw ZAIQuotaError.credentialsMissing }
        let credsURL = v2.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: credsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw ZAIQuotaError.credentialsMissing }

        let cipher = ZAICredentialCipher()

        let encryptedToken = object["oauth:\(domain):access_token"]
            ?? object["oauth:zai:access_token"] ?? ""
        guard !encryptedToken.isEmpty else { throw ZAIQuotaError.credentialsMissing }
        let token = try cipher.decrypt(encryptedToken)

        var userInfo: [String: Any]?
        let encryptedUser = object["oauth:\(domain):user_info"] ?? object["oauth:zai:user_info"]
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

    static func makeCodingPlanRequest(token: String, domain: String) -> URLRequest {
        var request = URLRequest(url: codingPlanBaseURL(domain: domain)
            .appendingPathComponent("api/monitor/usage/quota/limit"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// start-plan（体验套餐）计费余额，凭证是套餐 JWT 而非 OAuth token。
    static func makeStartPlanBalanceRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// coding-plan 重置额度状态。z.ai / bigmodel 两渠道共用 zcode.z.ai，
    /// 靠 X-Bigmodel-Authorization 里的 OAuth token 区分账号体系。
    static func makeCodingPlanResetStatusRequest(jwt: String, oauthToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/coding-plan/reset/status")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthToken, forHTTPHeaderField: "X-Bigmodel-Authorization")
        request.setValue("PERSONAL", forHTTPHeaderField: "Bigmodel-Target-Type")
        request.timeoutInterval = 15
        return request
    }
}

// MARK: - ZAI 额度 Store

@MainActor
final class ZAIQuotaStore {
    static let refreshCooldown: TimeInterval = 5 * 60
    private let session: URLSession

    private(set) var snapshot: ZAIQuotaSnapshot?
    private(set) var account: ZAIAccount?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var lastRefreshedAt: Date?

    var onChange: ((ZAIQuotaSnapshot?, ZAIAccount?, Bool, String?) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        snapshot = ZAIQuotaCache.load()
        account = ZAISettings.loadAccount()
    }

    /// 展开面板时调用；受 5 分钟冷却保护，避免频繁请求。
    func refreshIfNeeded() {
        if isRefreshing { return }
        if let last = lastRefreshedAt, Date().timeIntervalSince(last) < Self.refreshCooldown {
            onChange?(snapshot, account, false, lastError)
            return
        }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshedAt = Date()
        account = ZAISettings.loadAccount()
        onChange?(snapshot, account, true, lastError)

        Task { @MainActor in
            do {
                let next = try await fetchSnapshot()
                snapshot = next
                account = ZAIAccount(email: next.email ?? account?.email)
                lastError = nil
                ZAIQuotaCache.save(next)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isRefreshing = false
            onChange?(snapshot, account, false, lastError)
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

    /// 体验套餐：GET zcode.z.ai/api/v1/zcode-plan/billing/balance（Bearer 套餐 JWT）。
    private func fetchStartPlanSnapshot(selection: ZAIProviderSelection) async throws -> ZAIQuotaSnapshot {
        let token = try ZAISettings.loadStartPlanToken(domain: selection.domain)
        let request = ZAIQuotaEndpoint.makeStartPlanBalanceRequest(token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZAIQuotaError.requestFailed("HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }
        try Self.checkBusinessError(object)

        guard let dataPayload = object["data"] as? [String: Any]
        else { throw ZAIQuotaError.malformedResponse }

        // plans[] 提供套餐名；entitlements[] 的 period 需按 entitlement_id 关联到 balances[]。
        let plans = (dataPayload["plans"] as? [[String: Any]]) ?? []
        let activePlan = plans.first { ($0["status"] as? String) == "active" } ?? plans.first
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
            email: ZAISettings.loadAccount()?.email
        )
    }

    /// 个人付费 Coding Plan：GET api/monitor/usage/quota/limit（Bearer OAuth token）。
    private func fetchCodingPlanSnapshot(selection: ZAIProviderSelection) async throws -> ZAIQuotaSnapshot {
        let (token, userInfo) = try ZAISettings.loadCredentials(domain: selection.domain)
        let request = ZAIQuotaEndpoint.makeCodingPlanRequest(token: token, domain: selection.domain)

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
        // 仅保留 TOKENS_LIMIT，过滤工具配额 TIME_LIMIT。
        let limits: [ZAILimit] = rawLimits.compactMap { limit in
            guard (limit["type"] as? String) == "TOKENS_LIMIT" else { return nil }
            guard let unitRaw = limit["unit"] as? Int,
                  let unit = ZAILimit.WindowUnit(rawValue: unitRaw),
                  unit != .unknown
            else { return nil }
            let usedPercent: Double
            if let pct = limit["percentage"] as? Double {
                usedPercent = pct
            } else if let pct = limit["percentage"] as? Int {
                usedPercent = Double(pct)
            } else {
                usedPercent = 0
            }
            let resetTime = (limit["nextResetTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? (limit["nextResetTime"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            return ZAILimit(
                unit: unit,
                number: (limit["number"] as? NSNumber)?.intValue ?? 1,
                usedPercent: usedPercent,
                nextResetTime: resetTime
            )
        }.sorted { $0.unit.rawValue < $1.unit.rawValue }

        let level = dataPayload["level"] as? String
        let email = userInfo?["email"] as? String

        // 重置额度是增量信息：单独容错，失败不影响主额度展示。
        let resetCreditCards = try? await fetchResetCreditCards(domain: selection.domain, oauthToken: token)

        return ZAIQuotaSnapshot(
            kind: .codingPlan,
            limits: limits,
            resetCreditCards: resetCreditCards,
            level: level,
            email: email
        )
    }

    /// coding-plan 重置额度：GET zcode.z.ai/api/v1/coding-plan/reset/status。
    /// 响应 data.available_five_hour_resets / available_week_resets 各是 {expire_at} 数组。
    private func fetchResetCreditCards(domain: String, oauthToken: String) async throws -> [ZAIResetCreditCard]? {
        let jwt = try ZAISettings.loadZCodeJWTToken()
        let request = ZAIQuotaEndpoint.makeCodingPlanResetStatusRequest(jwt: jwt, oauthToken: oauthToken)

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
