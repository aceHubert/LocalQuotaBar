import CryptoKit
import Foundation

// MARK: - ZAI 配额数据模型

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

struct ZAIQuotaSnapshot: Equatable, Codable {
    let limits: [ZAILimit]
    let level: String?
    let email: String?
    let fetchedAt: Date

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
    static func isZAIDomain() -> Bool {
        guard let url = settingURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["providerFamilyDomain"] as? String) == "zai"
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
    static func loadCredentials() throws -> (accessToken: String, userInfo: [String: Any]?) {
        guard let v2 = zcodeV2URL else { throw ZAIQuotaError.credentialsMissing }
        let credsURL = v2.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: credsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw ZAIQuotaError.credentialsMissing }

        let cipher = ZAICredentialCipher()

        let encryptedToken = object["oauth:zai:access_token"] ?? ""
        guard !encryptedToken.isEmpty else { throw ZAIQuotaError.credentialsMissing }
        let token = try cipher.decrypt(encryptedToken)

        var userInfo: [String: Any]?
        if let encryptedUser = object["oauth:zai:user_info"], !encryptedUser.isEmpty {
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
        guard let userInfo = try? loadCredentials().userInfo else { return nil }
        let nestedUser = userInfo["user"] as? [String: Any]
        return ZAIAccount(
            email: (userInfo["email"] as? String) ?? (nestedUser?["email"] as? String)
        )
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
    private static let baseURL = URL(string: "https://api.z.ai")!

    static func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/monitor/usage/quota/limit"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        let (token, userInfo) = try ZAISettings.loadCredentials()
        let request = ZAIQuotaEndpoint.makeRequest(token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZAIQuotaError.requestFailed("HTTP \(status)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataPayload = object["data"] as? [String: Any]
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

        return ZAIQuotaSnapshot(limits: limits, level: level, email: email, fetchedAt: Date())
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
