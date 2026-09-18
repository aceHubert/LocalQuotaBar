import CryptoKit
import Foundation

enum CodexResetState: Equatable {
    case idle
    case submitting
    case succeeded
    case failed(String)
}

/// 每个账号、每张重置卡分别保留未确认操作，进程重启后仍复用原幂等键。
@MainActor
final class CodexResetService {
    typealias Transport = (
        _ creditID: String,
        _ idempotencyKey: String
    ) async throws -> CodexResetOutcome

    private struct StoredKeys: Codable {
        let version: Int
        var keys: [String: String]
    }

    private let storageURL: URL
    private let transport: Transport
    private var pendingKeys: [String: String] = [:]
    private var states: [String: CodexResetState] = [:]
    private var inFlightKey: String?
    private var storageIsUnreadable = false

    var onChange: (() -> Void)?

    var isSubmitting: Bool {
        inFlightKey != nil
    }

    init(storageURL: URL? = nil, transport: @escaping Transport) {
        self.storageURL = storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalQuotaBar/codex-pending-reset-keys.json")
        self.transport = transport

        do {
            let stored = try JSONDecoder().decode(
                StoredKeys.self,
                from: Data(contentsOf: self.storageURL)
            )
            guard stored.version == 1,
                  stored.keys.allSatisfy({ entry in
                      let parts = entry.key.split(separator: ":")
                      return parts.count == 2
                          && parts.allSatisfy { part in
                              part.count == 64 && part.allSatisfy { $0.isHexDigit }
                          }
                          && UUID(uuidString: entry.value) != nil
                  }) else {
                storageIsUnreadable = true
                return
            }
            pendingKeys = stored.keys
        } catch {
            let error = error as NSError
            let missingFile = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            storageIsUnreadable = !missingFile
        }
    }

    func state(accountID: String, creditID: String) -> CodexResetState {
        let key = storageKey(accountID: accountID, creditID: creditID)
        if let state = states[key] { return state }
        if storageIsUnreadable {
            return .failed("无法读取待确认重置记录，暂时无法重置")
        }
        return pendingKeys[key] == nil ? .idle : .failed("上次重置未确认，请重试")
    }

    /// 返回值表示上游是否已确认成功，与本地清理记录是否成功分开处理。
    func use(accountID: String, creditID: String) async -> Bool {
        let trimmedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCreditID = creditID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountID.isEmpty, !trimmedCreditID.isEmpty else {
            let key = storageKey(accountID: accountID, creditID: creditID)
            setState(.failed("重置卡信息不完整，请刷新后重试"), for: key)
            return false
        }

        let key = storageKey(accountID: trimmedAccountID, creditID: trimmedCreditID)
        guard inFlightKey == nil else { return false }
        switch state(accountID: trimmedAccountID, creditID: trimmedCreditID) {
        case .submitting, .succeeded:
            return false
        case .idle, .failed:
            break
        }
        guard !storageIsUnreadable else {
            setState(.failed("无法读取待确认重置记录，暂时无法重置"), for: key)
            return false
        }

        beginSubmission(for: key)

        let idempotencyKey: String
        if let existing = pendingKeys[key] {
            idempotencyKey = existing
        } else {
            idempotencyKey = UUID().uuidString
            var updated = pendingKeys
            updated[key] = idempotencyKey
            do {
                // 必须先完成原子落盘，才能交给 app-server 发送重置请求。
                try persist(updated)
                pendingKeys = updated
            } catch {
                finishSubmission(.failed("无法保存重置记录，未发送请求"), for: key)
                return false
            }
        }

        do {
            let outcome = try await transport(trimmedCreditID, idempotencyKey)
            switch outcome {
            case .reset, .alreadyRedeemed:
                var updated = pendingKeys
                updated.removeValue(forKey: key)
                do {
                    try persist(updated)
                    pendingKeys = updated
                } catch {
                    finishSubmission(.failed("重置已成功，但记录未能保存，请重试确认"), for: key)
                    // 上游已经完成重置，调用方仍须刷新额度；原键留在内存和文件中。
                    return true
                }
                finishSubmission(.succeeded, for: key)
                return true
            case .noCredit:
                finishSubmission(.failed("没有可用的重置卡，请刷新后重试"), for: key)
                return false
            case .nothingToReset:
                finishSubmission(.failed("当前额度无需重置，请刷新后重试"), for: key)
                return false
            }
        } catch {
            finishSubmission(.failed("重置请求未确认，请重试"), for: key)
            return false
        }
    }

    private func storageKey(accountID: String, creditID: String) -> String {
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCreditID = creditID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(hash(normalizedAccountID)):\(hash(normalizedCreditID))"
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func persist(_ keys: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(StoredKeys(version: 1, keys: keys))
        try data.write(to: storageURL, options: .atomic)
    }

    private func beginSubmission(for key: String) {
        inFlightKey = key
        states[key] = .submitting
        onChange?()
    }

    private func finishSubmission(_ state: CodexResetState, for key: String) {
        inFlightKey = nil
        states[key] = state
        onChange?()
    }

    private func setState(_ state: CodexResetState, for key: String) {
        states[key] = state
        onChange?()
    }
}
