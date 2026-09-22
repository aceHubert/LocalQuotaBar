import Foundation
import SweetCookieKit

// MARK: - Chrome Cookie 导入（国际版 www.codebuddy.ai；Cookie 只在内存短时使用）

enum CodeBuddyCookieImporter {
    struct Candidate: Equatable {
        /// Chrome profile 目录名（如 "Default"）。
        let profileID: String
        let profileName: String
        /// 组装好的 Cookie 请求头值（session=…; session_2=…），不落盘、不打日志。
        let cookieHeader: String
    }

    enum ImportError: LocalizedError, Equatable {
        case chromeNotFound
        case cookieNotFound
        case keychainDenied

        var errorDescription: String? {
            switch self {
            case .chromeNotFound:
                return "未找到本机 Chrome，请先安装并登录 www.codebuddy.ai"
            case .cookieNotFound:
                return "Chrome 中未找到 CodeBuddy 会话 Cookie，请先在 Chrome 登录 www.codebuddy.ai"
            case .keychainDenied:
                return "macOS Keychain 拒绝访问 Chrome Safe Storage，请在面板手动刷新完成一次授权"
            }
        }
    }

    /// 首版只做国际版（用户指令）：域名固定 www.codebuddy.ai。
    static let internationalDomain = "codebuddy.ai"
    /// 国内版域名（www.codebuddy.cn）：留待后续独立计划接入。
    static let domesticDomain = "codebuddy.cn"

    private static let sessionCookieNames = ["session", "session_2"]

    /// 枚举 Chrome 各 profile 下目标域名的会话 Cookie 候选。
    /// - Parameter allowKeychainUI: 手动刷新传 true（可弹 Keychain 授权）；
    ///   后台周期传 false（禁 UI 读取，失败保留缓存并提示需手动刷新）。
    static func importCandidates(
        domain: String = internationalDomain,
        allowKeychainUI: Bool = true
    ) -> Result<[Candidate], ImportError> {
        let client = BrowserCookieClient()
        let stores = client.stores(for: .chrome)
        guard !stores.isEmpty else { return .failure(.chromeNotFound) }

        let query = BrowserCookieQuery(
            domains: [domain],
            domainMatch: .suffix,
            includeExpired: false
        )

        var candidates: [Candidate] = []
        for store in stores {
            let records: [BrowserCookieRecord]
            do {
                if allowKeychainUI {
                    records = try client.records(matching: query, in: store)
                } else {
                    records = try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                        try client.records(matching: query, in: store)
                    }
                }
            } catch let error as BrowserCookieError {
                // Keychain 拒绝：明确错误分类，保留缓存由上层展示
                if case .accessDenied = error {
                    return .failure(.keychainDenied)
                }
                continue
            } catch {
                continue
            }

            let sessionCookies = records
                .filter { sessionCookieNames.contains($0.name) && !$0.value.isEmpty }
            guard !sessionCookies.isEmpty else { continue }

            let header = sessionCookies
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            candidates.append(Candidate(
                profileID: store.profile.id,
                profileName: store.profile.name.isEmpty ? store.profile.id : store.profile.name,
                cookieHeader: header
            ))
        }
        if candidates.isEmpty { return .failure(.cookieNotFound) }
        return .success(candidates)
    }

    /// 单候选自动使用；多候选按 store 顺序取第一个（Chrome Default 优先）。
    static func selectProfile(candidates: [Candidate]) -> Candidate? {
        candidates.first
    }
}
