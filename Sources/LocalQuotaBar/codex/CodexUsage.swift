import Foundation

// MARK: - Codex 官方日用量（app-server account/usage/read）

/// 独立的 app-server 只读客户端：单方法调用，不触碰 CodexRateLimitClient 的现有读取路径。
/// 每次调用拉起一个 codex app-server 进程，由 CodexUsageStore 节流（默认 30 分钟一次）。
final class CodexUsageClient {
    private let appServerExecutablePath: String
    private let requestTimeout: TimeInterval

    init(
        appServerExecutablePath: String = "/Applications/ChatGPT.app/Contents/Resources/codex",
        requestTimeout: TimeInterval = 30
    ) {
        self.appServerExecutablePath = appServerExecutablePath
        self.requestTimeout = requestTimeout
    }

    func readUsage() async throws -> CodexUsageSnapshot {
        try await Task.detached(priority: .utility) { [appServerExecutablePath, requestTimeout] in
            try Self.readUsageBlocking(
                appServerExecutablePath: appServerExecutablePath,
                requestTimeout: requestTimeout
            )
        }.value
    }

    private static func readUsageBlocking(
        appServerExecutablePath: String,
        requestTimeout: TimeInterval
    ) throws -> CodexUsageSnapshot {
        guard FileManager.default.isExecutableFile(atPath: appServerExecutablePath) else {
            throw CodexRateLimitError.appServerNotFound(appServerExecutablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: appServerExecutablePath)
        process.arguments = ["app-server", "--listen", "stdio://"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let queue = DispatchQueue(label: "local.codex.touchbar.quota.usage")
        let semaphore = DispatchSemaphore(value: 0)
        var buffer = Data()
        var response: [String: Any]?

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                buffer.append(data)
                while let newline = buffer.firstRange(of: Data("\n".utf8)) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: line, options: []),
                          let message = object as? [String: Any],
                          (message["id"] as? NSNumber)?.intValue == 2
                    else { continue }
                    response = message
                    semaphore.signal()
                }
            }
        }
        // 排空 stderr，避免子进程日志写满管道阻塞
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            throw CodexRateLimitError.processLaunchFailed(error.localizedDescription)
        }

        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex_touchbar_quota",
                        "title": "Codex Touch Bar Quota",
                        "version": "1.0.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/usage/read", "params": [:]],
        ]
        for message in messages {
            let json = try JSONSerialization.data(withJSONObject: message, options: [])
            stdinPipe.fileHandleForWriting.write(json)
            stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
            throw CodexRateLimitError.timeout
        }
        // 响应写入发生在收集队列上，读取也走同一队列保证可见性
        let collected: [String: Any]? = queue.sync { response }
        guard let response = collected else {
            throw CodexRateLimitError.malformedResponse
        }
        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown error"
            throw CodexRateLimitError.serverError(message)
        }
        guard let result = response["result"] as? [String: Any],
              let buckets = result["dailyUsageBuckets"] as? [[String: Any]]
        else {
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
