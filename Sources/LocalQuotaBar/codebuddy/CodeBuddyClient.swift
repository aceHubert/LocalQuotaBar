import CryptoKit
import Darwin
import Foundation

// MARK: - CodeBuddy 个人中心资源接口（国际版 www.codebuddy.ai / 国内版 www.codebuddy.cn）

/// 刷新链路诊断日志：只输出状态码与 Cookie 指纹（SHA256 前 16 位），不落任何凭证。
enum CodeBuddyDiagnostics {
    static func cookieFingerprint(_ header: String) -> String {
        let digest = SHA256.hash(data: Data(header.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func log(_ message: String) {
        NSLog("[CodeBuddy] \(message)")
    }
}

/// 本机 Chrome 版本检测：会话 Cookie 绑定登录浏览器的 UA 主版本，
/// 网关严格按 UA 主版本校验（差 1 个版本即判 401）。
/// 需覆盖两类边界：
/// 1. Chrome 后台静默更新已改写 Info.plist，但运行中的进程仍是旧版本；
/// 2. 直接读取文件而不使用 Bundle(url:)，避免 Foundation 进程级缓存导致 Chrome 升级重启后仍发旧版本。
enum CodeBuddyChromeVersion {
    /// Chrome 稳定版常见安装位置（系统与用户 Applications）。
    static var appBundlePaths: [String] {
        [
            "/Applications/Google Chrome.app",
            NSHomeDirectory() + "/Applications/Google Chrome.app"
        ]
    }

    /// Chrome Local State 路径（记录实际运行过的浏览器版本，后台静默更新不会改写）。
    static var localStatePaths: [String] {
        [
            NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
        ]
    }

    private static let frameworkVersionsMarker = "Google Chrome Framework.framework/Versions/"

    /// 从版本字符串开头提取主版本号（如 "157.0.8103.79-64" → "157"）。
    static func extractMajorVersion(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: ".").first,
              !first.isEmpty,
              first.allSatisfy(\.isNumber) else {
            return nil
        }
        return String(first)
    }

    /// 读取指定 Chrome bundle 的主版本号（直接读磁盘 Info.plist，绕过 Bundle 缓存）。
    static func majorVersion(bundlePaths: [String] = appBundlePaths) -> String? {
        for path in bundlePaths {
            if let major = bundleInfoMajorVersion(bundlePath: path) {
                return major
            }
        }
        return nil
    }

    /// 汇总本机 Chrome 候选主版本（去重保序）：
    /// 1. 正在运行的 Chrome 进程加载的框架版本（最贴合当前登录态）；
    /// 2. Chrome Local State 记录的最近运行版本（Chrome 未启动时有效）；
    /// 3. 磁盘 Info.plist 版本（无缓存）；
    /// 4. Frameworks/Versions 目录中保留的所有版本（降序）；
    /// 5. 若候选非空，补充最大主版本 - 1 兜底（覆盖刚重启升级后 7 天有效期的老 Cookie）。
    static func candidateMajorVersions(
        bundlePaths: [String] = appBundlePaths,
        localStatePaths: [String] = localStatePaths,
        runningVersions: () -> [String] = runningMajorVersions
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        func append(_ version: String?) {
            guard let version, let major = extractMajorVersion(from: version),
                  seen.insert(major).inserted else { return }
            ordered.append(major)
        }

        for version in runningVersions() {
            append(version)
        }
        append(localStateMajorVersion(paths: localStatePaths))
        for path in bundlePaths {
            append(bundleInfoMajorVersion(bundlePath: path))
        }
        for path in bundlePaths {
            for version in installedFrameworkMajorVersions(bundlePath: path) {
                append(version)
            }
        }
        if let highest = ordered.compactMap(Int.init).max(), highest > 1 {
            append(String(highest - 1))
        }
        return ordered
    }

    /// 通过 Darwin proc_pidpath 直接获取正在运行的 Chrome 进程所加载的框架主版本（降序去重）。
    static func runningMajorVersions() -> [String] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) * 2)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }

        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var versions: Set<String> = []

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard let range = path.range(of: frameworkVersionsMarker) else { continue }
            let tail = path[range.upperBound...]
            guard let slash = tail.firstIndex(of: "/"),
                  let major = extractMajorVersion(from: String(tail[..<slash])) else { continue }
            versions.insert(major)
        }

        return versions.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
    }

    /// 从 Chrome Local State 读取最近一次实际运行的主版本号。
    static func localStateMajorVersion(paths: [String] = localStatePaths) -> String? {
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let candidates: [String?] = [
                nestedString(json, path: ["user_experience_metrics", "stability", "stats_version"]),
                nestedString(json, path: ["optimization_guide", "on_device", "last_version"]),
                nestedString(json, path: ["toast", "non_milestone_update_toast_version"])
            ]
            for raw in candidates {
                if let raw, let major = extractMajorVersion(from: raw) {
                    return major
                }
            }
        }
        return nil
    }

    private static func bundleInfoMajorVersion(bundlePath: String) -> String? {
        let baseURL = URL(fileURLWithPath: bundlePath)
        let plistURLs = [
            baseURL.appendingPathComponent("Contents/Info.plist"),
            baseURL.appendingPathComponent("Info.plist")
        ]
        for url in plistURLs {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let shortVersion = plist["CFBundleShortVersionString"] as? String,
                  let major = extractMajorVersion(from: shortVersion) else {
                continue
            }
            return major
        }
        return nil
    }

    private static func installedFrameworkMajorVersions(bundlePath: String) -> [String] {
        let versionsURL = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/Frameworks/\(frameworkVersionsMarker)")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsURL.path) else {
            return []
        }
        var versions: Set<String> = []
        for entry in entries {
            if let major = extractMajorVersion(from: entry) {
                versions.insert(major)
            }
        }
        return versions.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
    }

    private static func nestedString(_ root: [String: Any], path: [String]) -> String? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? String
    }
}

/// 统一资源接口请求（主套餐 + 购买积分 + 奖励包一次返回）。Cookie 只在当次请求内存中使用。
final class CodeBuddyClient {
    struct Endpoints {
        /// 请求目标域名（含 www. 前缀），用于请求构造与错误文案。
        let host: String
        let resource: URL
        let origin: String
        let referer: String
        /// 站点区域：international（.ai）/ domestic（.cn）。
        let region: String

        init(host: String = "www.codebuddy.ai") {
            self.host = host
            origin = "https://\(host)"
            referer = "https://\(host)/profile/plans-usage"
            resource = URL(string: "https://\(host)/billing/meter/get-user-resource")!
            region = host.hasSuffix("codebuddy.cn") ? "domestic" : "international"
        }
    }

    private static let packageCodes = [
        "TCACA_code_002_AkiJS3ZHF5",
        "TCACA_code_003_FAnt7lcmRT",
        "TCACA_code_009_0XmEQc2xOf",
        "TCACA_code_036_lupO5WgNdG",
        "TCACA_code_001_PqouKr6QWV",
        "TCACA_code_035_ArVxJcGDsm",
        "TCACA_code_039_KRcQj7wUat",
        "TCACA_code_040_mi9rCYg46x",
        "TCACA_code_006_DbXS0lrypC",
        "TCACA_code_007_nzdH5h4Nl0",
        "TCACA_code_008_cfWoLwvjU4",
        "TCACA_code_037_WxOD3MpI2o"
    ]

    private let endpoints: Endpoints
    private let session: URLSession
    private let now: () -> Date
    private let chromeMajorVersions: () -> [String]
    private let recoverySessionFactory: () -> URLSession
    private let preferredVersionLock = NSLock()
    /// 记住最近一次成功通过校验的 Chrome 主版本，避免过渡期每次都先撞 401。
    private var preferredChromeMajor: String?

    /// 检测失败（Chrome 不在标准路径）时的兜底版本号，仅保证请求可发出；
    /// 与本机 Chrome 实际版本不一致仍会被网关判 401。
    static let fallbackChromeMajorVersion = "154"

    init(
        endpoints: Endpoints = Endpoints(),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        chromeMajorVersion: (() -> String?)? = nil,
        chromeMajorVersions: (() -> [String])? = nil,
        recoverySessionFactory: (() -> URLSession)? = nil
    ) {
        self.endpoints = endpoints
        self.session = session
        self.now = now
        if let chromeMajorVersions {
            self.chromeMajorVersions = chromeMajorVersions
        } else if let chromeMajorVersion {
            self.chromeMajorVersions = { chromeMajorVersion().map { [$0] } ?? [] }
        } else {
            self.chromeMajorVersions = { CodeBuddyChromeVersion.candidateMajorVersions() }
        }
        self.recoverySessionFactory = recoverySessionFactory ?? {
            URLSession(configuration: Self.recoveryConfiguration())
        }
    }

    /// 会话失效重试专用配置：全新连接池，且完全关闭 Cookie 自动处理（不读不存）。
    static func recoveryConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return configuration
    }

    /// 一次完整刷新：统一资源接口返回主套餐、购买积分和奖励包。
    /// 401/403 时用全新 ephemeral 会话重试（全新连接池、空 Cookie 存储与缓存），
    /// 并按候选 Chrome 主版本依次回退，覆盖共享会话污染与 Chrome 后台更新/升级过渡期。
    func fetchSnapshot(cookieHeader: String, profileID: String, profileName: String) async throws -> CodeBuddySnapshot {
        let fetchedAt = now()
        let body = resourceRequestBody(at: fetchedAt)
        let fingerprint = CodeBuddyDiagnostics.cookieFingerprint(cookieHeader)
        let candidates = resolvedCandidateVersions()
        let primary = candidates[0]

        let responseBody: [String: Any]
        do {
            responseBody = try await post(
                endpoints.resource,
                cookieHeader: cookieHeader,
                body: body,
                chromeMajor: primary,
                session: session,
                attempt: "shared"
            )
            setPreferredChromeMajor(primary)
        } catch CodeBuddyAPIError.sessionExpired(let host, let detail) {
            CodeBuddyDiagnostics.log(
                "host=\(host) 主会话\(detail) ua=\(primary) cookie=\(fingerprint)，ephemeral 会话重试(candidates=\(candidates.joined(separator: ",")))"
            )
            let recovery = recoverySessionFactory()
            defer { recovery.finishTasksAndInvalidate() }
            responseBody = try await retryWithRecoverySession(
                recovery: recovery,
                candidates: candidates,
                primary: primary,
                cookieHeader: cookieHeader,
                body: body,
                fingerprint: fingerprint
            )
        }
        let resources = try CodeBuddyParser.parseResource(json: responseBody)

        return CodeBuddySnapshot(
            fetchedAt: fetchedAt,
            region: endpoints.region,
            profileID: profileID,
            profileName: profileName,
            planName: resources.planName,
            planPackage: resources.planPackage,
            paidPackages: resources.paidPackages,
            freePackages: resources.freePackages,
            otherPackages: resources.otherPackages
        )
    }

    private func resourceRequestBody(at date: Date) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8)!
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return [
            "PageNumber": 1,
            "PageSize": 200,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "OnlyValidPeriod": true,
            "PackageCodes": Self.packageCodes,
            "SlicePeriodStartTime": formatter.string(from: start),
            "SlicePeriodEndTime": formatter.string(from: end)
        ]
    }

    /// UA 与 sec-ch-ua 的版本号必须与本机 Chrome 一致（会话绑定登录浏览器的 UA 版本）。
    static func userAgentString(chromeMajor: String) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajor).0.0.0 Safari/537.36"
    }

    /// sec-ch-ua 结构对齐 Chrome 实际发送（Chromium / Google Chrome 同版本 + GREASE 品牌）。
    static func secCHUAString(chromeMajor: String) -> String {
        "\"Chromium\";v=\"\(chromeMajor)\", \"Google Chrome\";v=\"\(chromeMajor)\", \"Not A(Brand\";v=\"99\""
    }

    private func resolvedCandidateVersions() -> [String] {
        var detected: [String] = []
        var seen: Set<String> = []
        for raw in chromeMajorVersions() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            detected.append(trimmed)
        }
        guard !detected.isEmpty else { return [Self.fallbackChromeMajorVersion] }

        if let preferred = getPreferredChromeMajor(), let idx = detected.firstIndex(of: preferred), idx > 0 {
            detected.remove(at: idx)
            detected.insert(preferred, at: 0)
        }
        return detected
    }

    private func getPreferredChromeMajor() -> String? {
        preferredVersionLock.lock()
        defer { preferredVersionLock.unlock() }
        return preferredChromeMajor
    }

    private func setPreferredChromeMajor(_ version: String) {
        preferredVersionLock.lock()
        preferredChromeMajor = version
        preferredVersionLock.unlock()
    }

    private func retryWithRecoverySession(
        recovery: URLSession,
        candidates: [String],
        primary: String,
        cookieHeader: String,
        body: [String: Any],
        fingerprint: String
    ) async throws -> [String: Any] {
        var lastSessionError: Error = CodeBuddyAPIError.sessionExpired(host: endpoints.host, detail: "HTTP 401")
        for version in candidates {
            do {
                let result = try await post(
                    endpoints.resource,
                    cookieHeader: cookieHeader,
                    body: body,
                    chromeMajor: version,
                    session: recovery,
                    attempt: "ephemeral"
                )
                setPreferredChromeMajor(version)
                if version != primary {
                    CodeBuddyDiagnostics.log(
                        "host=\(endpoints.host) 版本回退成功 ua=\(primary)->\(version) cookie=\(fingerprint)"
                    )
                }
                return result
            } catch let error as CodeBuddyAPIError {
                if case .sessionExpired = error {
                    lastSessionError = error
                    continue
                }
                throw error
            }
        }
        throw lastSessionError
    }

    private func post(
        _ url: URL,
        cookieHeader: String,
        body: [String: Any],
        chromeMajor: String,
        session: URLSession,
        attempt: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Cookie 完全由导入值决定：关闭请求级自动 Cookie 处理，
        // 防止响应 Set-Cookie 写入共享存储后干扰后续请求（实测会发生）。
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "X-Client-Platform")
        request.setValue(endpoints.referer, forHTTPHeaderField: "Referer")
        // APISIX 对 Web 请求会检查一组浏览器上下文头；这些值不包含凭证。
        request.setValue(Self.userAgentString(chromeMajor: chromeMajor), forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue(Self.secCHUAString(chromeMajor: chromeMajor), forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            // 当前接口在有效登录态下不会返回 401；走到这里视为该站点会话失效。
            CodeBuddyDiagnostics.log(
                "host=\(endpoints.host) status=\(status) ua=\(chromeMajor) cookie=\(CodeBuddyDiagnostics.cookieFingerprint(cookieHeader)) session=\(attempt)"
            )
            throw CodeBuddyAPIError.sessionExpired(host: endpoints.host, detail: "HTTP \(status)")
        }
        guard (200..<300).contains(status) else {
            throw CodeBuddyAPIError.http(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeBuddyAPIError.badPayload("响应不是 JSON 对象")
        }
        return json
    }
}
