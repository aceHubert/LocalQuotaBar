import Foundation

// MARK: - CodeBuddy 刷新编排（后台周期禁 Keychain UI；手动刷新完成一次授权）

@MainActor
final class CodeBuddyStore {
    private let client: CodeBuddyClient
    private(set) var refreshInterval: TimeInterval

    private(set) var snapshot: CodeBuddySnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private var timer: Timer?

    var onChange: ((CodeBuddySnapshot?, Bool, String?) -> Void)?

    /// Cookie 候选域名（国际版 codebuddy.ai / 国内版 codebuddy.cn）。
    let domain: String

    init(domain: String = CodeBuddyCookieImporter.internationalDomain,
         client: CodeBuddyClient = CodeBuddyClient(),
         refreshInterval: TimeInterval = RefreshSettings.load()) {
        self.domain = domain
        self.client = client
        self.refreshInterval = refreshInterval
    }

    func start() {
        refresh(allowKeychainUI: false)
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // 后台周期禁 Keychain UI：授权弹窗无人响应；失败保留缓存提示手动刷新
                self?.refresh(allowKeychainUI: false)
            }
        }
    }

    /// 手动刷新（顶栏）：允许 Keychain 授权弹窗，完成一次授权后后续周期读取即可复用。
    func refreshFromUser() {
        refresh(allowKeychainUI: true)
    }

    func refresh(allowKeychainUI: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?(snapshot, true, nil)

        Task { @MainActor in
            // Cookie 导入涉及 SQLite 拷贝与 Keychain，放协作线程池
            let imported = await Task.detached(priority: .utility) {
                CodeBuddyCookieImporter.importCandidates(domain: self.domain, allowKeychainUI: allowKeychainUI)
            }.value

            switch imported {
            case .failure(let error):
                finishRefresh(error: error.localizedDescription)
            case .success(let candidates):
                guard let candidate = CodeBuddyCookieImporter.selectProfile(candidates: candidates) else {
                    finishRefresh(error: CodeBuddyCookieImporter.ImportError
                        .cookieNotFound(host: self.requestHost).localizedDescription)
                    return
                }
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
                    finishRefresh(error: message)
                }
            }
        }
    }

    private func finishRefresh(error: String?) {
        isRefreshing = false
        lastError = error
        onChange?(snapshot, false, error)
    }

    /// 目标请求域名（含 www. 前缀）：Cookie 导入与错误文案共用。
    private var requestHost: String {
        domain.hasPrefix("www.") ? domain : "www.\(domain)"
    }
}
