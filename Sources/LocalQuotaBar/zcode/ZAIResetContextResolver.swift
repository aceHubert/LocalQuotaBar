import CryptoKit
import Foundation

/// 使用稳定账号身份隔离未确认重置；凭证刷新不会改变幂等键所属作用域。
enum ZAIResetContextResolver {
    enum ContextError: LocalizedError {
        case unsupportedPlan
        case missingIdentity

        var errorDescription: String? {
            switch self {
            case .unsupportedPlan: return "仅支持个人 Coding Plan 重置"
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
              ["zai", "bigmodel"].contains(selection.domain),
              !Self.isTeamConnection(selection) else {
            throw ContextError.unsupportedPlan
        }
        let nestedUser = userInfo?["user"] as? [String: Any]
        guard let zcodeIdentity = identity(in: claims(jwt)),
              let platformIdentity = identity(in: claims(oauthToken))
                ?? identity(in: userInfo) ?? identity(in: nestedUser)
                ?? email(in: userInfo) ?? email(in: nestedUser),
              !oauthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextError.missingIdentity
        }
        let identityData = try JSONEncoder().encode([selection.domain, zcodeIdentity, platformIdentity])
        let scope = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        return ZAIResetContext(scopeID: scope, jwt: jwt, oauthToken: oauthToken)
    }

    /// 团队版没有个人重置卡。新格式（ZCode 3.12.3+）不写 selectedKey，team 只能从
    /// providerFamilyConnectionSelections 的 connectionKind 认出来；legacy 才看 selectedKey。
    private static func isTeamConnection(_ selection: ZAIProviderSelection) -> Bool {
        if let connectionKind = selection.connectionKind {
            return connectionKind == "team-coding-plan"
        }
        return selection.selectedKey?.lowercased().contains("team") ?? false
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
