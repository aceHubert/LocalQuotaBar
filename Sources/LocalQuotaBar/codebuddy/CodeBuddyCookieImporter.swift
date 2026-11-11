import Foundation
import SQLite3
import SweetCookieKit

// MARK: - Chrome Cookie 导入（国际版 / 国内版共用；Cookie 只在内存短时使用）

enum CodeBuddyCookieImporter {
    struct Candidate: Equatable {
        /// Chrome profile 目录名（如 "Default"）。
        let profileID: String
        let profileName: String
        /// 组装好的目标站点 Cookie 请求头值，不落盘、不打日志。
        let cookieHeader: String
    }

    enum ImportError: LocalizedError, Equatable {
        /// host 为本次导入的目标域名，用于提示用户到正确站点登录。
        case chromeNotFound(host: String)
        case cookieNotFound(host: String)
        case keychainDenied

        var errorDescription: String? {
            switch self {
            case .chromeNotFound(let host):
                return "未找到本机 Chrome，请先安装并登录 \(host)"
            case .cookieNotFound(let host):
                return "Chrome 中未找到 CodeBuddy 会话 Cookie，请先在 Chrome 登录 \(host)"
            case .keychainDenied:
                return "macOS Keychain 拒绝访问 Chrome Safe Storage，请在面板手动刷新完成一次授权"
            }
        }
    }

    /// 国际版域名（www.codebuddy.ai）。
    static let internationalDomain = "codebuddy.ai"
    /// 国内版域名（www.codebuddy.cn）。
    static let domesticDomain = "codebuddy.cn"

    /// 枚举 Chrome 各 profile 下目标域名的会话 Cookie 候选。
    /// - Parameter allowKeychainUI: 手动刷新传 true（可弹 Keychain 授权）；
    ///   后台周期传 false（禁 UI 读取，失败保留缓存并提示需手动刷新）。
    static func importCandidates(
        domain: String = internationalDomain,
        allowKeychainUI: Bool = true
    ) -> Result<[Candidate], ImportError> {
        let client = BrowserCookieClient()
        let stores = client.stores(for: .chrome)
        let requestHost = domain.hasPrefix("www.") ? domain : "www.\(domain)"
        guard !stores.isEmpty else { return .failure(.chromeNotFound(host: requestHost)) }

        let query = BrowserCookieQuery(
            domains: [domain],
            domainMatch: .suffix,
            includeExpired: false
        )

        var candidates: [Candidate] = []
        for store in stores {
            let records: [BrowserCookieRecord]
            do {
                records = try withCookieStoreSnapshot(of: store) { readableStore in
                    if allowKeychainUI {
                        return try client.records(matching: query, in: readableStore)
                    }
                    return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                        try client.records(matching: query, in: readableStore)
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

            let header = cookieHeader(
                from: records,
                host: requestHost,
                path: "/billing/meter/get-user-resource"
            )
            guard !header.isEmpty,
                  header.split(separator: ";").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("session=") }) else {
                continue
            }
            candidates.append(Candidate(
                profileID: store.profile.id,
                profileName: store.profile.name.isEmpty ? store.profile.id : store.profile.name,
                cookieHeader: header
            ))
        }
        if candidates.isEmpty { return .failure(.cookieNotFound(host: requestHost)) }
        return .success(candidates)
    }

    /// 通过 SQLite 读取 Chrome 已提交的数据，避免分别拷贝主库和日志时跨越一次写入。
    static func withCookieStoreSnapshot<T>(
        of store: BrowserCookieStore,
        read: (BrowserCookieStore) throws -> T
    ) rethrows -> T {
        guard let source = store.databaseURL else { return try read(store) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localquotabar-codebuddy-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return try read(store)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = directory.appendingPathComponent("Cookies")
        // 遇到 Chrome 独占锁等无法在线备份的情况，交由原有导入器尝试读取。
        guard backupCookies(from: source, to: snapshot) else { return try read(store) }
        return try read(BrowserCookieStore(
            browser: store.browser,
            profile: store.profile,
            kind: store.kind,
            label: store.label,
            databaseURL: snapshot
        ))
    }

    private static func backupCookies(from source: URL, to snapshot: URL) -> Bool {
        var sourceDB: OpaquePointer?
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_busy_timeout(sourceDB, 250)

        var snapshotDB: OpaquePointer?
        defer { sqlite3_close(snapshotDB) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(snapshot.path, &snapshotDB, flags, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(snapshotDB, "main", sourceDB, "main") else {
            return false
        }
        let status = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finishStatus == SQLITE_OK else { return false }
        // 备份会继承 WAL 模式。切换临时副本，确保导入器只读主库即可打开。
        return sqlite3_exec(snapshotDB, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK
    }

    /// 组装浏览器对目标 URL 会发送的 Cookie 集合：按域名 / path 过滤并按名称去重。
    static func cookieHeader(
        from records: [BrowserCookieRecord],
        host: String,
        path: String,
        now: Date = Date()
    ) -> String {
        let matching = records.filter { record in
            guard !record.value.isEmpty, record.expires.map({ $0 > now }) ?? true else { return false }
            return hostMatches(record, host: host) && pathMatches(record.path, requestPath: path)
        }

        var selected: [String: BrowserCookieRecord] = [:]
        for record in matching {
            guard let existing = selected[record.name] else {
                selected[record.name] = record
                continue
            }
            if isMoreSpecific(record, than: existing, host: host) {
                selected[record.name] = record
            }
        }

        return selected.values
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
                return lhs.name < rhs.name
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func hostMatches(_ record: BrowserCookieRecord, host: String) -> Bool {
        switch record.scope {
        case .hostOnly:
            return record.domain == host
        case .domain:
            return record.domain == host || host.hasSuffix(".\(record.domain)")
        }
    }

    private static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        if normalized == "/" || requestPath == normalized { return true }
        let prefix = normalized.hasSuffix("/") ? normalized : "\(normalized)/"
        return requestPath.hasPrefix(prefix)
    }

    private static func isMoreSpecific(
        _ candidate: BrowserCookieRecord,
        than existing: BrowserCookieRecord,
        host: String
    ) -> Bool {
        let candidateHost = candidate.domain == host ? 1 : 0
        let existingHost = existing.domain == host ? 1 : 0
        if candidateHost != existingHost { return candidateHost > existingHost }
        if candidate.scope != existing.scope { return candidate.scope == .hostOnly }
        if candidate.path.count != existing.path.count {
            return candidate.path.count > existing.path.count
        }
        return (candidate.expires ?? .distantPast) > (existing.expires ?? .distantPast)
    }

    /// 单候选自动使用；多候选按 store 顺序取第一个（Chrome Default 优先）。
    static func selectProfile(candidates: [Candidate]) -> Candidate? {
        candidates.first
    }
}
