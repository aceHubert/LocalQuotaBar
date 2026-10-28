import Foundation

// MARK: - Codex 官方日用量（app-server account/usage/read）

/// 独立的 app-server 只读客户端：单方法调用，走共享常驻会话，
/// 不触碰 CodexRateLimitClient 的现有读取路径。由 CodexUsageStore 节流（默认 30 分钟一次）。
final class CodexUsageClient {
    let session: CodexAppServerSession

    init(session: CodexAppServerSession = .shared) {
        self.session = session
    }

    func readUsage() async throws -> CodexUsageSnapshot {
        try await Task.detached(priority: .utility) { [session] in
            let result = try session.send(id: 2, method: "account/usage/read", params: [:])
            return try Self.parseSnapshot(from: result)
        }.value
    }

    /// dailyUsageBuckets 为账号级每日 token 用量，startDate 形如 "2026-09-14"（无流水的日期跳过）。
    static func parseSnapshot(from result: [String: Any]) throws -> CodexUsageSnapshot {
        guard let buckets = result["dailyUsageBuckets"] as? [[String: Any]] else {
            throw CodexRateLimitError.malformedResponse
        }

        func doubleValue(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }

        let days: [CodexUsageSnapshot.Day] = buckets.compactMap { bucket in
            guard let startDate = bucket["startDate"] as? String,
                  let tokens = doubleValue(bucket["tokens"])
            else { return nil }
            return CodexUsageSnapshot.Day(startDate: startDate, tokens: tokens)
        }

        return CodexUsageSnapshot(days: days, fetchedAt: Date())
    }
}

/// dailyUsageBuckets 为账号级每日 token 用量，startDate 形如 "2026-09-14"（无流水的日期跳过）。
struct CodexUsageSnapshot: Codable, Equatable {
    struct Day: Codable, Equatable {
        let startDate: String
        let tokens: Double
    }

    let days: [Day]
    let fetchedAt: Date

    /// 展示用：最近 30 个自然日（无数据的天补 0），按日期升序。
    var last30Days: [DayUsage] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let byKey = Dictionary(days.map { (formatter.date(from: $0.startDate), $0.tokens) }.compactMap { date, tokens in
            date.map { (formatter.string(from: $0), tokens) }
        }, uniquingKeysWith: { _, last in last })

        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = formatter.string(from: day)
            return DayUsage(date: day, tokens: byKey[key] ?? 0)
        }
    }
}

/// Codex 用量 Store：独立于 RateLimitStore，节流拉取（默认 30 分钟），
/// 失败静默保留缓存，不影响主额度链路。
@MainActor
final class CodexUsageStore {
    private let client: CodexUsageClient
    private(set) var snapshot: CodexUsageSnapshot?
    private var isRefreshing = false
    private var lastFetchedAt: Date?

    var onChange: ((CodexUsageSnapshot?) -> Void)?

    static let minRefreshInterval: TimeInterval = 30 * 60

    init(client: CodexUsageClient) {
        self.client = client
        snapshot = Self.loadCache()
    }

    func start() {
        refreshIfNeeded(force: true)
    }

    func refreshIfNeeded(force: Bool) {
        if !force, let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.minRefreshInterval {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                let snapshot = try await client.readUsage()
                self.snapshot = snapshot
                lastFetchedAt = Date()
                Self.saveCache(snapshot)
                onChange?(snapshot)
            } catch {
                // 官方用量是附加信息：失败静默，保留缓存，等待下次节流窗口
                lastFetchedAt = Date()
            }
        }
    }

    // MARK: 缓存（UserDefaults，回滚无副作用）

    private static let cacheKey = "local.codex.touchbar.quota.codexUsage"

    private static func loadCache() -> CodexUsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    }

    private static func saveCache(_ snapshot: CodexUsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
