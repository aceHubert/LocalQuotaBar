import CryptoKit
import Darwin
import Foundation

struct ZAIResetContext {
    let scopeID: String
    let jwt: String
    let oauthToken: String
    /// 团队 Coding Plan 的重置请求必须携带组织与项目作用域；个人套餐为 nil。
    let teamContext: ZAITeamContext?
}

enum ZAIResetState: Equatable {
    case idle
    case submitting
    case succeeded
    case failed(String)
}

/// 每个账号、每种额度分别保留未确认操作，进程重启后仍复用原幂等键。
@MainActor
final class ZAIResetService {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private struct StoredKeys: Codable {
        let version: Int
        var keys: [String: String]
    }

    private enum StorageFailure: Error {
        case invalidRecord
        case lockUnavailable
        case lockFailed
    }

    private struct ResetResponse: Decodable {
        let code: Int
        let success: Bool?
        let data: Result

        struct Result: Decodable {
            let used: Bool
        }
    }

    private let storageURL: URL
    private let transport: Transport
    private let now: () -> Date
    private var pendingKeys: [String: String] = [:]
    private var states: [String: ZAIResetState] = [:]
    private var completedAt: [String: Date] = [:]
    private var storageIsUnreadable = false

    var onChange: (() -> Void)?

    init(storageURL: URL? = nil,
         transport: Transport? = nil,
         now: @escaping () -> Date = Date.init) {
        self.storageURL = storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalQuotaBar/pending-reset-keys.json")
        self.transport = transport ?? Self.performRequest
        self.now = now
        do {
            pendingKeys = try readPendingKeys()
        } catch {
            storageIsUnreadable = true
        }
    }

    func state(scopeID: String, kind: ZAIResetCreditCard.Kind) -> ZAIResetState {
        let key = storageKey(scopeID: scopeID, kind: kind)
        if let state = states[key] { return state }
        if storageIsUnreadable { return .failed("无法读取待确认重置记录，暂时无法重置") }
        return pendingKeys[key] == nil ? .idle : .failed("上次重置未确认，请重试")
    }

    /// 返回服务端是否确认成功；本地清理失败仍返回 true 以刷新额度，状态保留失败供原键重试。
    func use(context: ZAIResetContext, kind: ZAIResetCreditCard.Kind) async -> Bool {
        let key = storageKey(scopeID: context.scopeID, kind: kind)
        switch state(scopeID: context.scopeID, kind: kind) {
        case .submitting, .succeeded: return false
        case .idle, .failed: break
        }
        guard !context.scopeID.isEmpty,
              !context.jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !context.oauthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setState(.failed("登录信息不完整，请重新登录 ZCode"), for: key)
            return false
        }
        setState(.submitting, for: key)

        // 独立锁文件不会随 JSON 的原子替换而改变，串行保护跨实例读写与请求。
        let lockDescriptor: Int32
        do {
            lockDescriptor = try acquireStorageLock()
        } catch StorageFailure.lockUnavailable {
            setState(.failed("另一项重置正在处理，请稍后重试"), for: key)
            return false
        } catch {
            setState(.failed("无法锁定重置记录，未发送请求"), for: key)
            return false
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = close(lockDescriptor)
        }
        var diskKeys: [String: String]
        do {
            // 初始化时的内存快照可能已过时，持锁后必须重新读取完整文件。
            diskKeys = try readPendingKeys()
            storageIsUnreadable = false
        } catch {
            storageIsUnreadable = true
            setState(.failed("无法读取待确认重置记录，暂时无法重置"), for: key)
            return false
        }

        // 本实例曾发送的操作身份不能被其他实例的成功清理或新操作改变。
        let knownKey = pendingKeys[key]
        if let knownKey, let diskKey = diskKeys[key], knownKey != diskKey {
            setState(.failed("存在另一项待确认重置，请等待其完成后重试原操作"), for: key)
            return false
        }
        let idempotencyKey: String
        if let existing = knownKey ?? diskKeys[key] {
            idempotencyKey = existing
        } else {
            idempotencyKey = UUID().uuidString
        }
        if diskKeys[key] == nil {
            diskKeys[key] = idempotencyKey
            do {
                // 已知键被其他实例清理时也先恢复原记录，绝不为旧操作另造键。
                try persist(diskKeys)
            } catch {
                setState(.failed("无法保存重置记录，未发送请求"), for: key)
                return false
            }
        }
        // 保留其他类型的本实例旧操作，避免刷新磁盘快照时丢失重试身份。
        pendingKeys.merge(diskKeys) { known, _ in known }
        pendingKeys[key] = idempotencyKey

        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/coding-plan/reset/use")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let jwt = context.jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorization = jwt.lowercased().hasPrefix("bearer ") ? jwt : "Bearer \(jwt)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(context.oauthToken, forHTTPHeaderField: "X-Bigmodel-Authorization")
        request.setValue(context.teamContext == nil ? "PERSONAL" : "TEAM",
                         forHTTPHeaderField: "Bigmodel-Target-Type")
        if let teamContext = context.teamContext {
            request.setValue(teamContext.organizationId, forHTTPHeaderField: "Bigmodel-Organization")
            request.setValue(teamContext.projectId, forHTTPHeaderField: "Bigmodel-Project")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode([
            "idempotency_key": idempotencyKey,
            "reset_type": kind == .fiveHour ? "FIVE_HOUR" : "WEEK"
        ])

        do {
            let (data, response) = try await transport(request)
            guard response.statusCode == 200 else {
                setState(.failed("重置未确认（HTTP \(response.statusCode)），请重试"), for: key)
                return false
            }
            guard let result = try? JSONDecoder().decode(ResetResponse.self, from: data),
                  [0, 200].contains(result.code), result.success != false, result.data.used else {
                setState(.failed("服务端尚未确认重置成功，请重试"), for: key)
                return false
            }
            var updated = diskKeys
            updated.removeValue(forKey: key)
            do {
                try persist(updated)
                pendingKeys.removeValue(forKey: key)
            } catch {
                setState(.failed("重置已响应，但记录未能保存，请重试确认"), for: key)
                return true
            }
            completedAt[key] = now()
            setState(.succeeded, for: key)
            return true
        } catch {
            setState(.failed("重置请求未确认，请重试"), for: key)
            return false
        }
    }

    func acknowledgeFreshSnapshot(scopeID: String, refreshStartedAt: Date) {
        var changed = false
        for kind: ZAIResetCreditCard.Kind in [.fiveHour, .week] {
            let key = storageKey(scopeID: scopeID, kind: kind)
            if let completion = completedAt[key], refreshStartedAt >= completion,
               states[key] == .succeeded {
                states[key] = .idle
                completedAt.removeValue(forKey: key)
                changed = true
            }
        }
        if changed { onChange?() }
    }

    private func storageKey(scopeID: String, kind: ZAIResetCreditCard.Kind) -> String {
        let hash = SHA256.hash(data: Data(scopeID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(hash):\(kind.rawValue)"
    }

    private func persist(_ keys: [String: String]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredKeys(version: 1, keys: keys))
        try data.write(to: storageURL, options: .atomic)
    }

    private func readPendingKeys() throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            let error = error as NSError
            let missingFile = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            if missingFile { return [:] }
            throw error
        }
        let stored = try JSONDecoder().decode(StoredKeys.self, from: data)
        guard stored.version == 1,
              stored.keys.allSatisfy({ entry in
                  let parts = entry.key.split(separator: ":")
                  return parts.count == 2 && parts[0].count == 64
                      && parts[0].allSatisfy { $0.isHexDigit }
                      && ZAIResetCreditCard.Kind(rawValue: String(parts[1])) != nil
                      && UUID(uuidString: entry.value) != nil
              }) else { throw StorageFailure.invalidRecord }
        return stored.keys
    }

    private func acquireStorageLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let lockURL = storageURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StorageFailure.lockFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let isBusy = errno == EWOULDBLOCK || errno == EAGAIN
            _ = close(descriptor)
            throw isBusy ? StorageFailure.lockUnavailable : StorageFailure.lockFailed
        }
        return descriptor
    }

    private func setState(_ state: ZAIResetState, for key: String) {
        states[key] = state
        onChange?()
    }

    private nonisolated static func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration,
                                 delegate: ResetRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// 重置请求含登录令牌，任何重定向均由调用方作为非 200 响应处理。
private final class ResetRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
