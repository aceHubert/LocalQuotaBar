import CryptoKit
import Foundation
import Security

/// ZCode 3.18.0 起的凭证格式为 enc:v2:<密钥来源>:<密钥摘要>:<IV>.<标签>.<密文>。
struct ZAICredentialCipher {
    private let credentialsURL: URL
    private let environment: [String: String]
    private let loadKeychainPassword: (String) throws -> Data
    private let keychainKeys: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 1
        return cache
    }()

    init(credentialsURL: URL,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         loadKeychainPassword: @escaping (String) throws -> Data = ZAICredentialCipher.readKeychainPassword) {
        self.credentialsURL = credentialsURL
        self.environment = environment
        self.loadKeychainPassword = loadKeychainPassword
    }

    func decrypt(_ value: String) throws -> String {
        if value.hasPrefix("enc:v2:") {
            let fields = value.dropFirst("enc:v2:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[1].utf8.count == 24,
                  fields[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Self.invalidCiphertext
            }
            let sealed = try Self.sealedBox(fields[2])
            let key: Data
            switch fields[0] {
            case "os":
                key = try keychainKey(fingerprint: fields[1])
            case "env":
                key = Data(SHA256.hash(data: try managedSecret()))
                try Self.validateFingerprint(fields[1], key: key)
            default:
                throw Self.invalidCiphertext
            }
            return try Self.open(sealed, key: key)
        }

        if value.hasPrefix("enc:v1:") {
            let sealed = try Self.sealedBox(value.dropFirst("enc:v1:".count))
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let fallback = "zcode-credential-fallback:darwin:\(home):\(NSUserName())"
            let configured = environment["ZCODE_CREDENTIAL_SECRET"] ?? ""
            let candidates = [configured, configured.trimmingCharacters(in: .whitespacesAndNewlines), fallback]
            for secret in candidates where !secret.isEmpty {
                let key = Data(SHA256.hash(data: Data(secret.utf8)))
                if let plaintext = try? Self.open(sealed, key: key) { return plaintext }
            }
            throw Self.invalidCiphertext
        }

        guard !value.hasPrefix("enc:") else { throw Self.invalidCiphertext }
        return value
    }

    private func keychainKey(fingerprint: Substring) throws -> Data {
        // 同一凭证文件的各字段复用已授权密钥，密钥轮换后重新查询钥匙串。
        let cacheKey = String(fingerprint) as NSString
        if let key = keychainKeys.object(forKey: cacheKey) { return key as Data }

        // ZCode 以凭证文件绝对路径的 SHA-256 作为钥匙串账号名。
        let account = Self.digestHex(Data(credentialsURL.standardizedFileURL.path.utf8))
        let password = try loadKeychainPassword(account)
        guard let encoded = String(data: password, encoding: .utf8),
              encoded.utf8.count == 43,
              let key = Data(base64URLEncoded: encoded), key.count == 32 else {
            throw ZAIQuotaError.decryptionFailed("ZCode 钥匙串密钥格式异常")
        }
        try Self.validateFingerprint(fingerprint, key: key)
        keychainKeys.setObject(key as NSData, forKey: cacheKey)
        return key
    }

    private static func validateFingerprint(_ fingerprint: Substring, key: Data) throws {
        guard digestHex(key).prefix(24) == fingerprint else {
            throw ZAIQuotaError.decryptionFailed("ZCode 密钥与凭证不匹配")
        }
    }

    private func managedSecret() throws -> Data {
        let secret = environment["ZCODE_CREDENTIAL_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
        let path = environment["ZCODE_CREDENTIAL_SECRET_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        let unavailable = ZAIQuotaError.decryptionFailed("无法读取 ZCode 配置的加密密钥")
        if let secret {
            guard path == nil else { throw unavailable }
            return Data(secret.utf8)
        }

        let directory = credentialsURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        // ZCode 写入来源标记后，隐式密钥文件不再参与解析。
        guard path != nil || !fileManager.fileExists(atPath: directory.appendingPathComponent("credential-source").path) else {
            throw unavailable
        }
        let url = (path.map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("credential-secret"))
            .resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, (32...4096).contains(size),
              let permissions = attributes[.posixPermissions] as? Int,
              path != nil || (permissions & 0o077) == 0,
              let data = try? Data(contentsOf: url), (32...4096).contains(data.count) else {
            throw unavailable
        }
        return data
    }

    private static func readKeychainPassword(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ZCode Credential Encryption",
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw ZAIQuotaError.decryptionFailed("无法读取 ZCode 钥匙串密钥（\(status)）")
        }
        return password
    }

    private static var invalidCiphertext: ZAIQuotaError { .decryptionFailed("凭证密文格式或校验异常") }

    private static func sealedBox(_ payload: Substring) throws -> AES.GCM.SealedBox {
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = Data(base64URLEncoded: parts[0]), iv.count == 12,
              let tag = Data(base64URLEncoded: parts[1]), tag.count == 16,
              let ciphertext = Data(base64URLEncoded: parts[2]) else {
            throw invalidCiphertext
        }
        return try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
    }

    private static func open(_ sealed: AES.GCM.SealedBox, key: Data) throws -> String {
        guard let data = try? AES.GCM.open(sealed, using: SymmetricKey(data: key)),
              let plaintext = String(data: data, encoding: .utf8) else {
            throw invalidCiphertext
        }
        return plaintext
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    init?(base64URLEncoded input: some StringProtocol) {
        guard input.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 95
        }) else { return nil }
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
