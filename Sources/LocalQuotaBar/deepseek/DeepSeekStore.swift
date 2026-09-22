import Foundation

// MARK: - DeepSeek 刷新编排（token 每次刷新重新导入，快照只在内存保留）

@MainActor
final class DeepSeekStore {
    private let client: DeepSeekClient
    private(set) var refreshInterval: TimeInterval

    private(set) var snapshot: DeepSeekSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// 最近的 profile 候选（含数量），面板据此提示多 profile 场景。
    private(set) var lastProfileCount = 0
    private var timer: Timer?

    var onChange: ((DeepSeekSnapshot?, Bool, String?) -> Void)?

    /// profile 选择的持久化标识（不落 token）；nil 表示自动选择。
    var preferredProfileID: String? {
        get { UserDefaults.standard.string(forKey: Self.preferredProfileKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredProfileKey) }
    }

    private static let preferredProfileKey = "deepseek.preferredChromeProfileID"

    init(client: DeepSeekClient = DeepSeekClient(),
         refreshInterval: TimeInterval = RefreshSettings.load()) {
        self.client = client
        self.refreshInterval = refreshInterval
    }

    func start() {
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 修改自动刷新间隔；已在运行时按新间隔重建定时器，不额外触发刷新。
    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// 手动 / 自动刷新共用入口：导入 token → 请求余额与用量 → 组装快照。
    /// 失败保留上次快照与错误信息；token 永不进入错误描述。
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?(snapshot, true, nil)

        let preferredProfileID = preferredProfileID
        Task { @MainActor in
            // localStorage 读取是同步文件 IO，放到协作线程池执行避免卡主线程。
            let candidates = await Task.detached(priority: .utility) {
                DeepSeekTokenImporter.importCandidates()
            }.value

            switch DeepSeekTokenImporter.selectProfile(candidates: candidates,
                                                       preferredProfileID: preferredProfileID) {
            case .failure(let error):
                lastProfileCount = candidates.count
                finishRefresh(error: error.localizedDescription)
            case .success(let candidate):
                lastProfileCount = candidates.count
                do {
                    let snapshot = try await client.fetchSnapshot(
                        token: candidate.token,
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
}
