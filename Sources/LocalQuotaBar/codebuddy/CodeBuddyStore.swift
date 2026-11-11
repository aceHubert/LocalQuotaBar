import Foundation

// MARK: - CodeBuddy 刷新编排（后台周期禁 Keychain UI；手动刷新完成一次授权）

@MainActor
final class CodeBuddyStore {
    typealias CookieImport = @Sendable (String, Bool) -> Result<
        [CodeBuddyCookieImporter.Candidate], CodeBuddyCookieImporter.ImportError
    >

    private let client: CodeBuddyClient
    private let importCookies: CookieImport
    /// 两次相邻尝试的间隔，总计约在失败后 45 秒与 3 分钟重试。
    private let sessionRecoveryDelays: [TimeInterval]
    private(set) var refreshInterval: TimeInterval

    private(set) var snapshot: CodeBuddySnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var timer: Timer?
    private var sessionRecoveryTimer: Timer?

    var onChange: ((CodeBuddySnapshot?, Bool, String?) -> Void)?

    /// Cookie 候选域名（国际版 codebuddy.ai / 国内版 codebuddy.cn）。
    let domain: String

    /// 错峰相位（基准 5 分钟档位下的秒偏移）：国际版 135s / 国内版 180s，
    /// 由 AppDelegate 按实例注入。
    private let phaseOffset: TimeInterval
    /// 相位锚点（store 创建时刻）；改档位重建定时器后相位关系保持不变。
    private let refreshAnchor = Date()

    init(domain: String = CodeBuddyCookieImporter.internationalDomain,
         client: CodeBuddyClient = CodeBuddyClient(),
         refreshInterval: TimeInterval = RefreshSettings.load(),
         phaseOffset: TimeInterval = 135,
         sessionRecoveryDelays: [TimeInterval] = [45, 135],
         importCookies: @escaping CookieImport = {
             CodeBuddyCookieImporter.importCandidates(domain: $0, allowKeychainUI: $1)
         }) {
        self.domain = domain
        self.client = client
        self.refreshInterval = refreshInterval
        self.phaseOffset = phaseOffset
        self.sessionRecoveryDelays = sessionRecoveryDelays
        self.importCookies = importCookies
    }

    func start() {
        refresh(allowKeychainUI: false)
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelSessionRecovery()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        let interval = refreshInterval
        let fireDelay = RefreshPhasePlanner.nextDelay(
            offset: phaseOffset,
            interval: interval,
            anchor: refreshAnchor
        )
        let timer = Timer(
            fire: Date(timeIntervalSinceNow: fireDelay),
            interval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                // 后台周期禁 Keychain UI：授权弹窗无人响应；失败保留缓存提示手动刷新
                self?.refresh(allowKeychainUI: false)
            }
        }
        timer.tolerance = RefreshPhasePlanner.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    /// 手动刷新（顶栏）：允许 Keychain 授权弹窗，完成一次授权后后续周期读取即可复用。
    func refreshFromUser() {
        refresh(allowKeychainUI: true)
    }

    func refresh(allowKeychainUI: Bool) {
        refresh(allowKeychainUI: allowKeychainUI, recoveryDelays: sessionRecoveryDelays[...])
    }

    private func refresh(allowKeychainUI: Bool, recoveryDelays: ArraySlice<TimeInterval>) {
        guard !isRefreshing else { return }
        cancelSessionRecovery()
        isRefreshing = true
        onChange?(snapshot, true, nil)

        Task { @MainActor in
            // Cookie 导入涉及 SQLite 拷贝与 Keychain，放协作线程池
            let imported = await Task.detached(priority: .utility) { [importCookies, domain] in
                importCookies(domain, allowKeychainUI)
            }.value

            switch imported {
            case .failure(let error):
                CodeBuddyDiagnostics.log("host=\(self.requestHost) 导入失败: \(error.localizedDescription)")
                if case .cookieNotFound = error {
                    finishRefresh(error: error.localizedDescription, recoveryDelays: recoveryDelays)
                } else {
                    finishRefresh(error: error.localizedDescription)
                }
            case .success(let candidates):
                guard let candidate = CodeBuddyCookieImporter.selectProfile(candidates: candidates) else {
                    finishRefresh(error: CodeBuddyCookieImporter.ImportError
                        .cookieNotFound(host: self.requestHost).localizedDescription, recoveryDelays: recoveryDelays)
                    return
                }
                CodeBuddyDiagnostics.log(
                    "host=\(self.requestHost) 导入 candidates=\(candidates.count) cookie=\(CodeBuddyDiagnostics.cookieFingerprint(candidate.cookieHeader))"
                )
                do {
                    let snapshot = try await client.fetchSnapshot(
                        cookieHeader: candidate.cookieHeader,
                        profileID: candidate.profileID,
                        profileName: candidate.profileName
                    )
                    self.snapshot = snapshot
                    finishRefresh(error: nil)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if case CodeBuddyAPIError.sessionExpired = error {
                        finishRefresh(error: message, recoveryDelays: recoveryDelays)
                    } else {
                        finishRefresh(error: message)
                    }
                }
            }
        }
    }

    private func finishRefresh(error: String?, recoveryDelays: ArraySlice<TimeInterval> = []) {
        isRefreshing = false
        lastError = error
        scheduleSessionRecovery(delays: recoveryDelays)
        onChange?(snapshot, false, error)
    }

    // MARK: - 会话失效自愈

    /// Chrome 会批量写入 Cookie，未找到会话和接口拒绝会话都可能在重新导入后恢复。
    private func scheduleSessionRecovery(delays: ArraySlice<TimeInterval>) {
        guard timer != nil, let delay = delays.first else { return }
        let recoveryTimer = Timer(
            fire: Date(timeIntervalSinceNow: delay),
            interval: 0,
            repeats: false
        ) { [weak self] firedTimer in
            Task { @MainActor in
                guard let self, self.sessionRecoveryTimer === firedTimer else { return }
                CodeBuddyDiagnostics.log("host=\(self.requestHost) 重新导入会话")
                self.refresh(allowKeychainUI: false, recoveryDelays: delays.dropFirst())
            }
        }
        sessionRecoveryTimer = recoveryTimer
        RunLoop.main.add(recoveryTimer, forMode: .common)
    }

    private func cancelSessionRecovery() {
        sessionRecoveryTimer?.invalidate()
        sessionRecoveryTimer = nil
    }

    /// 目标请求域名（含 www. 前缀）：Cookie 导入与错误文案共用。
    private var requestHost: String {
        domain.hasPrefix("www.") ? domain : "www.\(domain)"
    }
}
