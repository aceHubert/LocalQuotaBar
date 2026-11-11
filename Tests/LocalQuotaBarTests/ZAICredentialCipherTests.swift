import Foundation
import XCTest
@testable import LocalQuotaBar

final class ZAICredentialCipherTests: XCTestCase {
    private let credentialsURL = URL(fileURLWithPath: "/synthetic/home/.zcode/v2/credentials.json")
    // 使用固定密钥和随机数生成的合成向量，覆盖 ZCode 的实际序列化格式。
    private let keychainPassword = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let keychainCredential = "enc:v2:os:630dcd2966c4336691125448:"
        + "ICEiIyQlJicoKSor._71uF4tfEeIxY9wfwj9gwA.oUPIBAT9bmd5US2vtGyc1KQmh_np"
    private let environmentCredential = "enc:v2:env:65aa3f953dae9706d3e046e1:"
        + "ICEiIyQlJicoKSor.gOaS35dzp1Io1lX2xMTy7Q.GA_yVHPkVZoBoaYGn_UGj1M27A"

    func testDecryptsKeychainCredentialUsingCredentialsPathAsAccount() throws {
        let password = Data(keychainPassword.utf8)
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { account in
            XCTAssertEqual(account, "676fb820688148f4bd321ea5c24c055068b7bf0a8b70177458198c5845a0e3c8")
            return password
        }
        XCTAssertEqual(try cipher.decrypt(keychainCredential), "synthetic-oauth-token")
    }

    func testRejectsKeychainKeyWithDifferentFingerprint() {
        let wrongPassword = Data("IB8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgE".utf8)
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { _ in
            wrongPassword
        }
        XCTAssertThrowsError(try cipher.decrypt(keychainCredential))
    }

    func testReusesKeychainKeyUntilFingerprintChanges() throws {
        let rotatedPassword = "IB8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgE"
        let rotatedCredential = "enc:v2:os:4d9dd9451ec30afdac127017:"
            + "RkdISUpLTE1OT1BR.F8GnAbAxykQypsqpXUqKtw.9iE-70fX3GvZuQrcwm2IydlyWGr9h-Q"
        var password = keychainPassword
        var reads = 0
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { _ in
            reads += 1
            return Data(password.utf8)
        }

        XCTAssertEqual(try cipher.decrypt(keychainCredential), "synthetic-oauth-token")
        XCTAssertEqual(try cipher.decrypt(keychainCredential), "synthetic-oauth-token")
        XCTAssertEqual(reads, 1)

        password = rotatedPassword
        XCTAssertEqual(try cipher.decrypt(rotatedCredential), "synthetic-rotated-token")
        XCTAssertEqual(reads, 2)
    }

    func testRejectsCredentialWhenKeychainIsUnavailable() {
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { _ in
            throw ZAIQuotaError.credentialsMissing
        }
        XCTAssertThrowsError(try cipher.decrypt(keychainCredential))
    }

    func testRejectsInvalidKeychainPasswordEncoding() {
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { _ in
            Data("short-password".utf8)
        }
        XCTAssertThrowsError(try cipher.decrypt(keychainCredential))
    }

    func testRejectsTamperedCiphertextWithMatchingKeyFingerprint() {
        let password = Data(keychainPassword.utf8)
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:]) { _ in
            password
        }
        let tampered = keychainCredential.replacingOccurrences(of: ".oUPIB", with: ".pUPIB")
        XCTAssertThrowsError(try cipher.decrypt(tampered))
    }

    func testDecryptsManagedCredentialWithUntrimmedEnvironmentSecret() throws {
        let cipher = ZAICredentialCipher(
            credentialsURL: credentialsURL,
            environment: ["ZCODE_CREDENTIAL_SECRET": "  synthetic-managed-secret-123456789  "]
        ) { _ in
            XCTFail("环境密钥不应访问钥匙串")
            return Data()
        }
        XCTAssertEqual(try cipher.decrypt(environmentCredential), "synthetic-zcode-jwt")
    }

    func testReadsImplicitManagedSecretOnlyBeforeKeychainMigration() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let secretURL = directory.appendingPathComponent("credential-secret")
        try Data("  synthetic-managed-secret-123456789  ".utf8).write(to: secretURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        let credentialsURL = directory.appendingPathComponent("credentials.json")
        let cipher = ZAICredentialCipher(credentialsURL: credentialsURL, environment: [:])
        XCTAssertEqual(try cipher.decrypt(environmentCredential), "synthetic-zcode-jwt")

        try Data("os\n".utf8).write(to: directory.appendingPathComponent("credential-source"))
        XCTAssertThrowsError(try cipher.decrypt(environmentCredential))

        let explicitCipher = ZAICredentialCipher(
            credentialsURL: credentialsURL,
            environment: ["ZCODE_CREDENTIAL_SECRET_FILE": secretURL.path]
        )
        XCTAssertEqual(try explicitCipher.decrypt(environmentCredential), "synthetic-zcode-jwt")
    }

    func testDecryptsLegacyCredentialAndKeepsPlaintextReadable() throws {
        let cipher = ZAICredentialCipher(
            credentialsURL: credentialsURL,
            environment: ["ZCODE_CREDENTIAL_SECRET": "synthetic-legacy-secret"]
        ) { _ in
            XCTFail("旧版凭证不应访问钥匙串")
            return Data()
        }
        let legacy = "enc:v1:ICEiIyQlJicoKSor.DlsOpdBinTB_CwSEYm7Iyg.Gw7S6HPR6rCWz4kHNUAREQ"
        XCTAssertEqual(try cipher.decrypt(legacy), #"{"id":"example"}"#)
        XCTAssertEqual(try cipher.decrypt("synthetic-plaintext"), "synthetic-plaintext")
        XCTAssertThrowsError(try cipher.decrypt("enc:v3:os:unknown"))
    }
}
