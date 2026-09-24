import Foundation
import SweetCookieKit

// MARK: - Chrome localStorage userToken 导入（token 只在内存短时使用，不落盘、不打日志）

enum DeepSeekTokenImporter {
    struct Candidate: Equatable {
        /// Chrome profile 目录名（如 "Default"），持久化选择只存这个标识。
        let profileID: String
        let profileName: String
        let token: String
        /// leveldb 目录最近修改时间，多候选时取最新（最近使用的 Chrome profile）。
        let storageModifiedAt: Date?
    }

    enum ImportError: LocalizedError, Equatable {
        case chromeNotFound
        case tokenNotFound

        var errorDescription: String? {
            switch self {
            case .chromeNotFound:
                return "未找到本机 Chrome，请先安装并登录 platform.deepseek.com"
            case .tokenNotFound:
                return "Chrome 中未找到 DeepSeek 登录态（userToken），请先在 Chrome 登录 platform.deepseek.com"
            }
        }
    }

    static let storageOrigin = "https://platform.deepseek.com"
    static let chromeSupport = "Library/Application Support/Google/Chrome"
    /// 系统 / 来宾 profile 不参与候选。
    private static let skippedProfiles: Set<String> = ["System Profile", "Guest Profile", "Crashpad"]

    /// 枚举所有 Chrome profile 下 platform.deepseek.com 的 userToken 候选。
    /// - Parameter homeDirectory: 测试注入用。
    static func importCandidates(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        readEntries: (String, URL, ((String) -> Void)?) -> [ChromiumLocalStorageEntry] = ChromiumLocalStorageReader.readEntries
    ) -> [Candidate] {
        let chromeRoot = homeDirectory.appendingPathComponent(chromeSupport)
        guard FileManager.default.fileExists(atPath: chromeRoot.path) else { return [] }

        let profileDirs = ((try? FileManager.default.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { $0.hasDirectoryPath && !skippedProfiles.contains($0.lastPathComponent) }

        var candidates: [Candidate] = []
        for profileDir in profileDirs {
            let leveldb = profileDir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: leveldb.path) else { continue }

            let entries = readEntries(storageOrigin, leveldb, nil)
            guard let raw = entries.first(where: { $0.key == "userToken" })?.value,
                  let token = parseTokenValue(raw)
            else { continue }

            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: leveldb.path))?[.modificationDate] as? Date
            candidates.append(Candidate(
                profileID: profileDir.lastPathComponent,
                profileName: profileDir.lastPathComponent,
                token: token,
                storageModifiedAt: modifiedAt
            ))
        }
        return candidates
    }

    /// 解析 userToken 的三种形态：纯 token / JSON string / JSON object（value|token|access_token|accessToken|userToken）。
    /// 候选至少 20 个字符且不含空白。
    static func parseTokenValue(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSON object：{"value": "..."} 等字段
        if text.hasPrefix("{"), let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["value", "token", "access_token", "accessToken", "userToken"]
            for key in keys {
                if let inner = DeepSeekJSON.string(object[key]) {
                    text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        // JSON string："eyJhbGci..."
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
            let inner = String(text.dropFirst().dropLast())
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard isValidToken(text) else { return nil }
        return text
    }

    static func isValidToken(_ value: String) -> Bool {
        value.count >= 20 && !value.contains(where: { $0.isWhitespace })
    }

    /// 选择 profile：优先已持久化的选择；单候选自动使用；
    /// 多候选时取 leveldb 修改时间最新的（最近使用的 Chrome profile），面板提示候选数。
    static func selectProfile(candidates: [Candidate], preferredProfileID: String?) -> Result<Candidate, ImportError> {
        guard !candidates.isEmpty else {
            return .failure(.tokenNotFound)
        }
        if let preferredProfileID,
           let matched = candidates.first(where: { $0.profileID == preferredProfileID }) {
            return .success(matched)
        }
        if candidates.count == 1, let only = candidates.first {
            return .success(only)
        }
        let latest = candidates.max { lhs, rhs in
            (lhs.storageModifiedAt ?? .distantPast) < (rhs.storageModifiedAt ?? .distantPast)
        }
        guard let latest else { return .failure(.tokenNotFound) }
        return .success(latest)
    }
}
