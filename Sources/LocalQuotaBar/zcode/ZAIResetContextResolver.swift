import CryptoKit
import Foundation

/// 使用稳定账号身份隔离未确认重置；凭证刷新不会改变幂等键所属作用域。
enum ZAIResetContextResolver {
    enum ContextError: LocalizedError {
        case unsupportedPlan
        case missingTeamContext
        case missingIdentity

        var errorDescription: String? {
            switch self {
            case .unsupportedPlan: return "仅支持 Coding Plan 重置"
            case .missingTeamContext: return "团队套餐缺少组织或项目信息，无法重置"
            case .missingIdentity: return "无法确认当前账号身份，请重新登录 ZCode"
            }
        }
    }

    static func resolve() throws -> ZAIResetContext {
        guard let selection = ZAISettings.resolveProviderSelection() else {
            throw ContextError.unsupportedPlan
        }
        let credentials = try ZAISettings.loadCredentials(domain: selection.domain, allowZaiFallback: false)
        return try makeContext(
            selection: selection,
            jwt: ZAISettings.loadZCodeJWTToken(),
            oauthToken: credentials.accessToken,
            userInfo: credentials.userInfo
        )
    }

    static func makeContext(
        selection: ZAIProviderSelection,
        jwt: String,
        oauthToken: String,
        userInfo: [String: Any]?
    ) throws -> ZAIResetContext {
        guard selection.kind == .codingPlan,
              ["zai", "bigmodel"].contains(selection.domain) else {
            throw ContextError.unsupportedPlan
        }
        let teamContext = try Self.teamContext(selection)
        let nestedUser = userInfo?["user"] as? [String: Any]
        guard let zcodeIdentity = identity(in: claims(jwt)),
              let platformIdentity = identity(in: claims(oauthToken))
                ?? identity(in: userInfo) ?? identity(in: nestedUser)
                ?? email(in: userInfo) ?? email(in: nestedUser),
              !oauthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextError.missingIdentity
        }
        let scopeParts = [selection.domain, zcodeIdentity, platformIdentity,
                          teamContext?.organizationId, teamContext?.projectId].compactMap { $0 }
        let identityData = try JSONEncoder().encode(scopeParts)
        let scope = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        return ZAIResetContext(scopeID: scope, jwt: jwt, oauthToken: oauthToken,
                               teamContext: teamContext)
    }

    /// 团队连接必须同时具备组织与项目作用域；新格式优先看 connectionKind，
    /// legacy 配置才回退到 selectedKey。
    private static func teamContext(_ selection: ZAIProviderSelection) throws -> ZAITeamContext? {
        let isTeam: Bool
        if let connectionKind = selection.connectionKind {
            isTeam = connectionKind == "team-coding-plan"
        } else {
            isTeam = selection.selectedKey?.lowercased().contains("team") ?? false
        }
        guard isTeam else { return nil }
        guard let context = selection.teamContext else {
            throw ContextError.missingTeamContext
        }
        return context
    }

    private static func identity(in object: [String: Any]?) -> String? {
        for key in ["sub", "id", "user_id", "userId", "uid"] {
            if let value = object?[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return "\(key):\(trimmed)" }
            }
            if let value = object?[key] as? NSNumber {
                return "\(key):\(value.stringValue)"
            }
        }
        return nil
    }

    private static func email(in object: [String: Any]?) -> String? {
        guard let email = object?["email"] as? String else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : "email:\(trimmed)"
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let bareToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^Bearer\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        let parts = bareToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
