import AppKit
import Foundation

// MARK: - Models

enum QuotaKind: String, Hashable, Codable {
    case fiveHour
    case weekly
}

struct QuotaBucket: Equatable, Codable {
    let kind: QuotaKind
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date?

    var title: String {
        Self.displayTitles(forDurationMins: windowDurationMins).full
    }

    var shortTitle: String {
        Self.displayTitles(forDurationMins: windowDurationMins).short
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var roundedRemainingPercent: Int {
        Int(remainingPercent.rounded())
    }

    // Codex 不同账号类型的额度窗口不同（如 free 账号是月限额），按窗口时长归类标题。
    static func displayTitles(forDurationMins mins: Int) -> (full: String, short: String) {
        let day = 24 * 60
        if mins < day {
            let hours = max(1, Int((Double(mins) / 60).rounded()))
            return ("\(hours)小时", "\(hours)H")
        }
        if abs(mins - 7 * day) <= day {
            return ("周限额", "W")
        }
        if (25 * day...35 * day).contains(mins) {
            return ("月限额", "M")
        }
        let days = max(1, Int((Double(mins) / Double(day)).rounded()))
        return ("\(days)天", "\(days)D")
    }
}

struct QuotaSnapshot: Equatable, Codable {
    let fiveHour: QuotaBucket?
    let weekly: QuotaBucket?
    let resetCreditCount: Int?
    let resetCreditCards: [ResetCreditCard]?
    /// 额度余额（credits 积分）；rateLimits 响应里的 credits.balance，$100 = 2500 积分。
    let creditBalance: Double?
    let planType: String?
    let fetchedAt: Date

    var primaryStatusTitle: String {
        if let fiveHour {
            return "Codex \(fiveHour.roundedRemainingPercent)%"
        }
        if let weekly {
            return "Codex \(weekly.shortTitle)\(weekly.roundedRemainingPercent)%"
        }
        return "Codex --%"
    }
}

struct ResetCreditCard: Equatable, Codable {
    var id: String? = nil
    var status: String? = nil
    let issuedAt: Date?
    let expiresAt: Date?
}

enum SnapshotCache {
    static let key = "local.codex.touchbar.quota.lastSnapshot"

    static func load() -> QuotaSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(QuotaSnapshot.self, from: data)
    }

    static func save(_ snapshot: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum AccountPlanCache {
    private static let key = "local.codex.touchbar.quota.planTypesByAccountID"
    private static let noPlan = ""

    static func contains(_ accountID: String) -> Bool {
        values[accountID] != nil
    }

    static func planType(for accountID: String) -> String? {
        values[accountID].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ planType: String?, for accountID: String) {
        var next = values
        next[accountID] = planType ?? noPlan
        UserDefaults.standard.set(next, forKey: key)
    }

    private static var values: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

struct CodexAuthAccount: Equatable {
    let accountId: String
    let label: String
    let fileName: String
}

enum CodexAuthSwitchError: LocalizedError {
    case authDirectoryMissing(String)
    case authFileMissing(String)
    case invalidSelection(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .authDirectoryMissing(let path):
            return "找不到 Codex 认证目录：\(path)"
        case .authFileMissing(let path):
            return "找不到认证文件：\(path)"
        case .invalidSelection(let fileName):
            return "账号文件不可切换：\(fileName)"
        case .copyFailed(let detail):
            return "切换账号失败：\(detail)"
        }
    }
}

final class CodexAuthManager {
    private let fileManager: FileManager
    private let authDirectoryURL: URL
    private let authJSONURL: URL
    private var cachedAccountsByAccountId: [String: CodexAuthAccount] = [:]

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.authDirectoryURL = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        self.authJSONURL = authDirectoryURL.appendingPathComponent("auth.json")
    }

    func loadAccounts() throws -> (accounts: [CodexAuthAccount], selectedAccountId: String?) {
        guard fileManager.fileExists(atPath: authDirectoryURL.path) else {
            throw CodexAuthSwitchError.authDirectoryMissing(authDirectoryURL.path)
        }

        var accountsByAccountId: [String: CodexAuthAccount] = [:]
        for authFileURL in try authAccountFileURLs() {
            guard let account = parseChatGPTAccount(from: authFileURL, requiresChatGPTMode: false) else { continue }
            let existing = accountsByAccountId[account.accountId]
            accountsByAccountId[account.accountId] = preferredAccount(existing, account)
        }

        let currentAuthObject = jsonObject(from: authJSONURL)
        let currentAccountId = currentAuthObject.flatMap { authStringValue("account_id", in: $0) }
        let selectedFileName = currentAccountId.map { "auth_\($0).json" }

        if let selectedFileName,
           let currentAccountId,
           isSwitchableAuthFileName(selectedFileName),
           accountsByAccountId[currentAccountId] == nil {
            let copiedURL = authDirectoryURL.appendingPathComponent(selectedFileName)
            if !fileManager.fileExists(atPath: copiedURL.path) {
                try fileManager.copyItem(at: authJSONURL, to: copiedURL)
            }
            if let currentAccount = parseChatGPTAccount(from: copiedURL, requiresChatGPTMode: false) {
                accountsByAccountId[currentAccount.accountId] = currentAccount
            } else if let currentAccount = parseChatGPTAccount(from: authJSONURL, fileName: selectedFileName, requiresChatGPTMode: false) {
                accountsByAccountId[currentAccount.accountId] = currentAccount
            }
        }

        let accounts = accountsByAccountId.values.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        cachedAccountsByAccountId = accountsByAccountId
        return (accounts, currentAccountId)
    }

    func switchAccount(to fileName: String) throws {
        guard isSwitchableAuthFileName(fileName) else {
            throw CodexAuthSwitchError.invalidSelection(fileName)
        }

        let selectedURL = authDirectoryURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: selectedURL.path) else {
            throw CodexAuthSwitchError.authFileMissing(selectedURL.path)
        }

        try syncCurrentAuthIfRefreshed()

        let backupURL = try currentAuthBackupURL()
        let temporaryURL = authDirectoryURL.appendingPathComponent("auth_switch_tmp_\(UUID().uuidString).json")

        do {
            try fileManager.copyItem(at: selectedURL, to: temporaryURL)
            if let backupURL {
                try replaceFile(at: backupURL, withContentsOf: authJSONURL, operationName: "备份当前账号")
                try fileManager.removeItem(at: authJSONURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: authJSONURL)
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if let backupURL,
               !fileManager.fileExists(atPath: authJSONURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.copyItem(at: backupURL, to: authJSONURL)
            }
            throw CodexAuthSwitchError.copyFailed(error.localizedDescription)
        }
    }

    private func syncCurrentAuthIfRefreshed() throws {
        guard let currentAuthObject = jsonObject(from: authJSONURL) else { return }
        guard let currentAccountId = authStringValue("account_id", in: currentAuthObject) else { return }
        guard let currentLastRefresh = authStringValue("last_refresh", in: currentAuthObject) else { return }
        guard let currentAccount = cachedAccountsByAccountId[currentAccountId] else { return }
        guard isSwitchableAuthFileName(currentAccount.fileName) else { return }

        let targetURL = authDirectoryURL.appendingPathComponent(currentAccount.fileName)
        guard fileManager.fileExists(atPath: targetURL.path) else { return }

        guard let targetObject = jsonObject(from: targetURL) else { return }
        guard authStringValue("account_id", in: targetObject) == currentAccountId else { return }

        let targetLastRefresh = authStringValue("last_refresh", in: targetObject)
        if targetLastRefresh.map({ currentLastRefresh > $0 }) ?? true {
            try replaceFile(at: targetURL, withContentsOf: authJSONURL, operationName: "同步当前账号")
        }
    }

    private func replaceFile(at targetURL: URL, withContentsOf sourceURL: URL, operationName: String) throws {
        let temporaryURL = authDirectoryURL.appendingPathComponent("auth_sync_tmp_\(UUID().uuidString).json")
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw CodexAuthSwitchError.copyFailed("\(operationName)：\(error.localizedDescription)")
        }
    }

    private func authAccountFileURLs() throws -> [URL] {
        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return fileURLs.filter { url in
            let fileName = url.lastPathComponent
            return fileName.hasPrefix("auth_")
                && fileName.hasSuffix(".json")
                && !fileName.hasPrefix("auth_switch_tmp_")
        }
    }

    private func parseChatGPTAccount(
        from url: URL,
        fileName overrideFileName: String? = nil,
        requiresChatGPTMode: Bool = true
    ) -> CodexAuthAccount? {
        guard let object = jsonObject(from: url) else { return nil }
        if requiresChatGPTMode {
            guard object["auth_mode"] as? String == "chatgpt" else { return nil }
        }
        guard let accountId = authStringValue("account_id", in: object) else { return nil }
        guard let idToken = authStringValue("id_token", in: object) else { return nil }

        let payload = jwtPayload(from: idToken)
        let label = (payload?["email"] as? String)
            ?? (payload?["sub"] as? String)
            ?? overrideFileName
            ?? url.lastPathComponent

        return CodexAuthAccount(accountId: accountId, label: label, fileName: overrideFileName ?? url.lastPathComponent)
    }

    private func preferredAccount(_ lhs: CodexAuthAccount?, _ rhs: CodexAuthAccount) -> CodexAuthAccount {
        guard let lhs else { return rhs }
        let canonicalFileName = "auth_\(rhs.accountId).json"
        if lhs.fileName == canonicalFileName { return lhs }
        if rhs.fileName == canonicalFileName { return rhs }
        return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending ? lhs : rhs
    }

    private func jsonObject(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private func authStringValue(_ key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let tokens = object["tokens"] as? [String: Any],
           let value = tokens[key] as? String {
            return value
        }
        return nil
    }

    private func jwtPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private func isSwitchableAuthFileName(_ fileName: String) -> Bool {
        fileName == (fileName as NSString).lastPathComponent
            && fileName.hasPrefix("auth_")
            && fileName.hasSuffix(".json")
            && !fileName.hasPrefix("auth_switch_tmp_")
    }

    private func currentAuthBackupURL() throws -> URL? {
        guard fileManager.fileExists(atPath: authJSONURL.path) else { return nil }
        guard let object = jsonObject(from: authJSONURL),
              let accountId = authStringValue("account_id", in: object)
        else {
            throw CodexAuthSwitchError.copyFailed("无法读取当前账号 ID")
        }

        let fileName = "auth.json.bak-codexswitch-\(accountId)"
        guard fileName == (fileName as NSString).lastPathComponent else {
            throw CodexAuthSwitchError.copyFailed("当前账号 ID 不能用于备份文件名")
        }
        return authDirectoryURL.appendingPathComponent(fileName)
    }
}

private struct ParsedWindow {
    let limitId: String
    let fieldName: String
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date?
}

// MARK: - Errors

enum CodexRateLimitError: LocalizedError {
    case appServerNotFound(String)
    case processLaunchFailed(String)
    case timeout
    case serverError(String)
    case malformedResponse
    case noRateLimitWindows

    var errorDescription: String? {
        switch self {
        case .appServerNotFound(let path):
            return "找不到 ChatGPT.app 内置的 Codex 可执行文件：\(path)"
        case .processLaunchFailed(let detail):
            return "启动 ChatGPT app-server 失败：\(detail)"
        case .timeout:
            return "读取 ChatGPT app-server 超时"
        case .serverError(let message):
            return "ChatGPT app-server 返回错误：\(message)"
        case .malformedResponse:
            return "ChatGPT app-server 返回格式不符合预期"
        case .noRateLimitWindows:
            return "没有从 ChatGPT app-server 读到额度窗口"
        }
    }
}

// MARK: - ChatGPT app-server RPC client

enum CodexResetOutcome: String {
    case reset, alreadyRedeemed, noCredit, nothingToReset
}

final class CodexRateLimitClient {
    let appServerExecutablePath: String
    let requestTimeout: TimeInterval

    init(
        appServerExecutablePath: String = "/Applications/ChatGPT.app/Contents/Resources/codex",
        // rateLimits/read 背后有网络请求，延迟波动大（实测 2s ~ 15s+），超时不能太紧。
        requestTimeout: TimeInterval = 30
    ) {
        self.appServerExecutablePath = appServerExecutablePath
        self.requestTimeout = requestTimeout
    }

    func readRateLimits(planType: String?) async throws -> QuotaSnapshot {
        try await Task.detached(priority: .userInitiated) { [appServerExecutablePath, requestTimeout] in
            let results = try Self.readAppServerResultsBlocking(
                appServerExecutablePath: appServerExecutablePath,
                requestTimeout: requestTimeout,
                shouldReadAccount: false,
                shouldReadRateLimits: true
            )
            return try Self.parseSnapshot(
                rateLimits: results.rateLimits ?? [:],
                planType: planType
            )
        }.value
    }

    func readAccountPlanType() async throws -> String? {
        try await Task.detached(priority: .userInitiated) { [appServerExecutablePath, requestTimeout] in
            let results = try Self.readAppServerResultsBlocking(
                appServerExecutablePath: appServerExecutablePath,
                requestTimeout: requestTimeout,
                shouldReadAccount: true,
                shouldReadRateLimits: false
            )
            return results.account.flatMap(Self.planType(from:))
        }.value
    }

    func consumeRateLimitResetCredit(creditID: String, idempotencyKey: String) async throws -> CodexResetOutcome {
        try await Task.detached(priority: .userInitiated) { [appServerExecutablePath, requestTimeout] in
            let params = try Self.resetCreditParams(creditID: creditID, idempotencyKey: idempotencyKey)
            let results = try Self.readAppServerResultsBlocking(
                appServerExecutablePath: appServerExecutablePath,
                requestTimeout: requestTimeout,
                shouldReadAccount: false,
                shouldReadRateLimits: false,
                resetCreditParams: params
            )
            return try Self.parseResetOutcome(results.resetCredit ?? [:])
        }.value
    }

    /// 纯参数构造便于离线检查；卡 ID 和本次操作的幂等键必须分别传递。
    static func resetCreditParams(creditID: String, idempotencyKey: String) throws -> [String: String] {
        guard !creditID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexRateLimitError.malformedResponse
        }
        return ["creditId": creditID, "idempotencyKey": idempotencyKey]
    }

    static func parseResetOutcome(_ result: [String: Any]) throws -> CodexResetOutcome {
        guard let value = result["outcome"] as? String,
              let outcome = CodexResetOutcome(rawValue: value) else {
            throw CodexRateLimitError.malformedResponse
        }
        return outcome
    }

    private struct AppServerResults {
        let rateLimits: [String: Any]?
        let account: [String: Any]?
        let resetCredit: [String: Any]?
    }

    private static func readAppServerResultsBlocking(
        appServerExecutablePath: String,
        requestTimeout: TimeInterval,
        shouldReadAccount: Bool,
        shouldReadRateLimits: Bool,
        resetCreditParams: [String: String]? = nil
    ) throws -> AppServerResults {
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

        var targetIDs = Set<Int>()
        if shouldReadAccount { targetIDs.insert(2) }
        if shouldReadRateLimits { targetIDs.insert(3) }
        if resetCreditParams != nil { targetIDs.insert(4) }
        let initializationCollector = JSONLineResponseCollector(targetIDs: [1])
        let collector = JSONLineResponseCollector(targetIDs: targetIDs)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
                initializationCollector.append(data)
            }
        }

        // Drain stderr so the child process cannot block if it logs.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        defer { cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe) }

        do {
            try process.run()
        } catch {
            throw CodexRateLimitError.processLaunchFailed(error.localizedDescription)
        }

        var messages: [[String: Any]] = [
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
            [
                "method": "initialized",
                "params": [:]
            ],
        ]
        if shouldReadAccount {
            messages.append([
                "id": 2,
                "method": "account/read",
                "params": [:]
            ])
        }
        if shouldReadRateLimits {
            messages.append([
                "id": 3,
                "method": "account/rateLimits/read",
                "params": NSNull()
            ])
        }

        if let resetCreditParams {
            // 有副作用的方法必须等初始化成功后再发送，不因超时自行重试。
            try writeJSONLines([messages[0]], to: stdinPipe.fileHandleForWriting)
            guard initializationCollector.wait(timeout: requestTimeout) else {
                throw CodexRateLimitError.timeout
            }
            guard let initialized = initializationCollector.response(for: 1) else {
                throw CodexRateLimitError.malformedResponse
            }
            _ = try result(from: initialized)
            messages = [messages[1], [
                "id": 4,
                "method": "account/rateLimitResetCredit/consume",
                "params": resetCreditParams
            ]]
        }

        do {
            try writeJSONLines(messages, to: stdinPipe.fileHandleForWriting)
        } catch {
            cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw error
        }

        let waitResult = collector.wait(timeout: requestTimeout)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard waitResult else {
            cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw CodexRateLimitError.timeout
        }

        if shouldReadRateLimits, collector.response(for: 3) == nil {
            cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw CodexRateLimitError.malformedResponse
        }
        if shouldReadAccount, collector.response(for: 2) == nil {
            cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw CodexRateLimitError.malformedResponse
        }

        cleanup(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        return AppServerResults(
            rateLimits: try collector.response(for: 3).map(result(from:)),
            account: try collector.response(for: 2).map(result(from:)),
            resetCredit: try collector.response(for: 4).map(result(from:))
        )
    }

    private static func result(from response: [String: Any]) throws -> [String: Any] {
        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            let message = error["message"] as? String ?? "unknown error"
            if let code {
                throw CodexRateLimitError.serverError("\(message) (code \(code))")
            } else {
                throw CodexRateLimitError.serverError(message)
            }
        }

        guard let result = response["result"] as? [String: Any] else {
            throw CodexRateLimitError.malformedResponse
        }
        return result
    }

    private static func writeJSONLines(_ messages: [[String: Any]], to handle: FileHandle) throws {
        for message in messages {
            let json = try JSONSerialization.data(withJSONObject: message, options: [])
            handle.write(json)
            handle.write(Data("\n".utf8))
        }
    }

    private static func cleanup(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private static func planType(from account: [String: Any]) -> String? {
        ((account["account"] as? [String: Any])?["planType"] as? String)
            ?? (account["planType"] as? String)
    }

    private static func parseSnapshot(rateLimits result: [String: Any], planType: String?) throws -> QuotaSnapshot {
        let windows = extractRateLimitWindows(from: result)
        guard !windows.isEmpty else {
            throw CodexRateLimitError.noRateLimitWindows
        }

        let fiveHourWindow = chooseFiveHourWindow(from: windows)
        let weeklyWindow = chooseWeeklyWindow(from: windows)
        let resetCreditCount = (result["rateLimitResetCredits"] as? [String: Any])
            .flatMap { intValue($0["availableCount"]) }
        let resetCreditCards = parseResetCreditCards(from: result)
        let creditBalance = creditBalance(from: result)

        return QuotaSnapshot(
            fiveHour: fiveHourWindow.map {
                QuotaBucket(
                    kind: .fiveHour,
                    usedPercent: $0.usedPercent,
                    windowDurationMins: $0.windowDurationMins,
                    resetsAt: $0.resetsAt
                )
            },
            weekly: weeklyWindow.map {
                QuotaBucket(
                    kind: .weekly,
                    usedPercent: $0.usedPercent,
                    windowDurationMins: $0.windowDurationMins,
                    resetsAt: $0.resetsAt
                )
            },
            resetCreditCount: resetCreditCount,
            resetCreditCards: resetCreditCards,
            creditBalance: creditBalance,
            planType: planType,
            fetchedAt: Date()
        )
    }

    /// 额度余额（credits 积分）。放在顶层 rateLimits；按 limitId 展开时结构相同，兜底取 codex。
    private static func creditBalance(from result: [String: Any]) -> Double? {
        let rateLimits = (result["rateLimits"] as? [String: Any])
            ?? ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
        guard let credits = rateLimits?["credits"] as? [String: Any],
              credits["hasCredits"] as? Bool == true,
              credits["unlimited"] as? Bool == false
        else { return nil }
        // balance 实测是字符串（如 "1017.0539675000"），兼容数字形式。
        if let text = credits["balance"] as? String {
            return Double(text)
        }
        return (credits["balance"] as? NSNumber)?.doubleValue
    }

    private static func extractRateLimitWindows(from result: [String: Any]) -> [ParsedWindow] {
        var windows: [ParsedWindow] = []

        if let byLimitId = result["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = byLimitId["codex"] as? [String: Any] {
                windows.append(contentsOf: extractWindows(from: codex, limitId: "codex"))
            }

            for (limitId, value) in byLimitId.sorted(by: { $0.key < $1.key }) {
                guard limitId != "codex", let limit = value as? [String: Any] else { continue }
                // Prefer Codex-related buckets, but keep other buckets as fallback when labels change.
                if limitId.lowercased().contains("codex") || windows.isEmpty {
                    windows.append(contentsOf: extractWindows(from: limit, limitId: limitId))
                }
            }
        }

        if windows.isEmpty, let single = result["rateLimits"] as? [String: Any] {
            let limitId = single["limitId"] as? String ?? "rateLimits"
            windows.append(contentsOf: extractWindows(from: single, limitId: limitId))
        }

        return windows
    }

    private static func extractWindows(from limit: [String: Any], limitId: String) -> [ParsedWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limit[key] as? [String: Any] else { return nil }
            guard let usedPercent = doubleValue(window["usedPercent"]) else { return nil }
            guard let duration = intValue(window["windowDurationMins"]) else { return nil }

            return ParsedWindow(
                limitId: limitId,
                fieldName: key,
                usedPercent: usedPercent,
                windowDurationMins: duration,
                resetsAt: dateValue(window["resetsAt"])
            )
        }
    }

    private static func chooseFiveHourWindow(from windows: [ParsedWindow]) -> ParsedWindow? {
        let candidates = windows.filter { (240...360).contains($0.windowDurationMins) }
        if let exact = candidates.min(by: { abs($0.windowDurationMins - 300) < abs($1.windowDurationMins - 300) }) {
            return exact
        }

        // Fallback: when Codex changes the exact window duration, use the shorter non-weekly bucket.
        return windows
            .filter { $0.windowDurationMins < 24 * 60 }
            .min(by: { $0.windowDurationMins < $1.windowDurationMins })
    }

    private static func chooseWeeklyWindow(from windows: [ParsedWindow]) -> ParsedWindow? {
        let oneWeek = 7 * 24 * 60
        let candidates = windows.filter { abs($0.windowDurationMins - oneWeek) <= 24 * 60 }
        if let weekly = candidates.min(by: { abs($0.windowDurationMins - oneWeek) < abs($1.windowDurationMins - oneWeek) }) {
            return weekly
        }

        // Fallback: longest multi-day bucket.
        return windows
            .filter { $0.windowDurationMins >= 24 * 60 }
            .max(by: { $0.windowDurationMins < $1.windowDurationMins })
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let raw = doubleValue(value) else { return nil }
        // app-server docs describe seconds. Accept milliseconds defensively.
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    static func parseResetCreditCards(from result: [String: Any]) -> [ResetCreditCard]? {
        guard let summary = result["rateLimitResetCredits"] as? [String: Any],
              let credits = summary["credits"] as? [[String: Any]]
        else {
            return nil
        }

        return credits.map { credit in
            let id = (credit["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ResetCreditCard(
                id: id?.isEmpty == false ? id : nil,
                status: credit["status"] as? String,
                issuedAt: dateValue(credit["grantedAt"]),
                expiresAt: dateValue(credit["expiresAt"])
            )
        }
    }
}

private final class JSONLineResponseCollector {
    private let targetIDs: Set<Int>
    private let queue = DispatchQueue(label: "local.codex.touchbar.quota.jsonline")
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var storedResponses: [Int: [String: Any]] = [:]
    private var didSignal = false

    init(targetIDs: Set<Int>) {
        self.targetIDs = targetIDs
    }

    func response(for id: Int) -> [String: Any]? {
        queue.sync { storedResponses[id] }
    }

    func append(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            self.parseAvailableLines()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    private func parseAvailableLines() {
        while let newlineRange = buffer.firstRange(of: Data("\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
                  let message = object as? [String: Any]
            else { continue }

            if let id = message["id"] as? NSNumber, targetIDs.contains(id.intValue) {
                storedResponses[id.intValue] = message
                if !didSignal && storedResponses.count == targetIDs.count {
                    didSignal = true
                    semaphore.signal()
                }
            }
        }
    }
}

// MARK: - Store / refresh lifecycle

@MainActor
final class RateLimitStore {
    let client: CodexRateLimitClient
    private(set) var refreshInterval: TimeInterval

    private(set) var snapshot: QuotaSnapshot?
    private(set) var snapshotAccountID: String?
    private var refreshAfterCurrent = false
    private(set) var isRefreshing = false
    private var hasReadAccountPlan = false
    private var isReadingAccountPlan = false
    private var accountID = "unknown"
    private var cachedPlanType: String?
    private var timer: Timer?

    var onChange: ((QuotaSnapshot?, Bool, String?) -> Void)?

    init(
        client: CodexRateLimitClient = CodexRateLimitClient(),
        // 额度变化不快，默认 5 分钟自动刷新一次，可在状态栏右键菜单调整；手动刷新有 60 秒防重保护。
        refreshInterval: TimeInterval = RefreshSettings.load()
    ) {
        self.client = client
        self.refreshInterval = refreshInterval
        // Show the last known quota immediately after relaunch; refresh will replace it.
        self.snapshot = SnapshotCache.load()
    }

    func start() {
        refresh(force: true)
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 修改自动刷新间隔；已在运行时则按新间隔重建定时器，不额外触发一次网络刷新。
    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: false)
            }
        }
    }

    func setAccountID(_ accountID: String?) {
        let nextAccountID = accountID ?? "unknown"
        if self.accountID != nextAccountID {
            snapshotAccountID = nil
            if isRefreshing { refreshAfterCurrent = true }
        }
        self.accountID = nextAccountID
        hasReadAccountPlan = AccountPlanCache.contains(self.accountID)
        cachedPlanType = AccountPlanCache.planType(for: self.accountID)
        if hasReadAccountPlan {
            applyPlanType(cachedPlanType)
        } else {
            readAccountPlan()
        }
    }

    /// 若旧刷新仍在进行，必须在它结束后再拉取一次重置后的最新额度。
    func refreshAfterReset() {
        if isRefreshing {
            refreshAfterCurrent = true
        } else {
            refresh(force: true)
        }
    }

    func refresh(force: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?(snapshot, true, nil)
        // 套餐若还没读到成功过（如启动时 app-server 未就绪），借每次刷新重试，
        // 避免陈旧的缓存 planType（如降级前的 plus）一直显示到下次重启。
        readAccountPlan()
        let cachedPlanType = self.cachedPlanType
        let requestedAccountID = accountID

        Task { @MainActor in
            do {
                let newSnapshot = try await client.readRateLimits(planType: cachedPlanType)
                guard requestedAccountID == accountID else {
                    finishRefresh(error: nil)
                    return
                }
                snapshot = newSnapshot
                snapshotAccountID = requestedAccountID
                SnapshotCache.save(newSnapshot)
                finishRefresh(error: nil)
            } catch {
                // 保留已有快照；旧账号请求的错误不污染当前账号。
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                finishRefresh(error: requestedAccountID == accountID ? message : nil)
            }
        }
    }

    private func finishRefresh(error: String?) {
        isRefreshing = false
        if refreshAfterCurrent {
            refreshAfterCurrent = false
            refresh(force: true)
        } else {
            onChange?(snapshot, false, error)
        }
    }

    private func readAccountPlan() {
        guard !hasReadAccountPlan, !isReadingAccountPlan else { return }
        isReadingAccountPlan = true
        let requestedAccountID = accountID

        Task { @MainActor in
            defer { isReadingAccountPlan = false }
            let planType: String?
            do {
                planType = try await client.readAccountPlanType()
            } catch {
                return
            }
            guard accountID == requestedAccountID else { return }
            hasReadAccountPlan = true
            cachedPlanType = planType
            AccountPlanCache.save(planType, for: accountID)
            applyPlanType(planType)
        }
    }

    private func applyPlanType(_ planType: String?) {
        guard let snapshot else { return }
        let updatedSnapshot = QuotaSnapshot(
            fiveHour: snapshot.fiveHour,
            weekly: snapshot.weekly,
            resetCreditCount: snapshot.resetCreditCount,
            resetCreditCards: snapshot.resetCreditCards,
            creditBalance: snapshot.creditBalance,
            planType: planType,
            fetchedAt: snapshot.fetchedAt
        )
        self.snapshot = updatedSnapshot
        SnapshotCache.save(updatedSnapshot)
        onChange?(updatedSnapshot, isRefreshing, nil)
    }
}

extension QuotaSnapshot {
    /// 提醒评估用的统一额度桶。
    var reminderBuckets: [ReminderBucket] {
        var buckets: [ReminderBucket] = []
        if let fiveHour {
            buckets.append(ReminderBucket(
                source: .codex,
                id: "codex.fiveHour",
                title: "Codex \(fiveHour.title)",
                shortTitle: fiveHour.title,
                remainingPercent: fiveHour.remainingPercent,
                resetsAt: fiveHour.resetsAt
            ))
        }
        if let weekly {
            buckets.append(ReminderBucket(
                source: .codex,
                id: "codex.weekly",
                title: "Codex \(weekly.title)",
                shortTitle: weekly.title,
                remainingPercent: weekly.remainingPercent,
                resetsAt: weekly.resetsAt
            ))
        }
        buckets.append(contentsOf: resetCardReminderBuckets(now: Date()))
        return buckets
    }

    /// 可用重置卡（状态可用且未过期）合成一个提醒桶，resetsAt 取最早到期。
    private func resetCardReminderBuckets(now: Date) -> [ReminderBucket] {
        let alertable = (resetCreditCards ?? []).filter { card in
            (card.status == nil || card.status == "available")
                && (card.expiresAt.map { $0 > now } ?? false)
        }
        guard let earliest = alertable.compactMap(\.expiresAt).min() else { return [] }
        return [
            ReminderBucket(
                source: .codex,
                id: "codex.resetCard",
                title: "Codex 重置卡",
                shortTitle: "重置卡",
                remainingPercent: 100,
                resetsAt: earliest,
                kind: .resetCard,
                cardCount: alertable.count
            )
        ]
    }
}

// MARK: - AppKit UI

extension NSTouchBarItem.Identifier {
    static let quotaPanel = NSTouchBarItem.Identifier("local.codex.touchbar.quota.panel")
}

extension NSTouchBar.CustomizationIdentifier {
    static let quotaBar = NSTouchBar.CustomizationIdentifier("local.codex.touchbar.quota.touchbar")
}

// MARK: - Touch Bar hardware detection

enum TouchBarCapability {
    // 带 Touch Bar 的机型是封闭集合（Apple 已停用 Touch Bar），按型号判断最可靠。
    static let hasTouchBar: Bool = {
        let identifier = hardwareModel()
        if ["MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3", "MacBookPro17,1"].contains(identifier) {
            return true
        }
        return identifier.hasPrefix("MacBookPro15,") || identifier.hasPrefix("MacBookPro16,")
    }()

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

/// 提醒子菜单里每个选项对应 ReminderConfiguration 的哪个字段，挂在 NSMenuItem.tag 上。
private enum ReminderMenuField: Int {
    case warningPercent = 0
    case resetSoonMinutes = 1
    case cooldownMinutes = 2
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let quotaViewController = QuotaViewController()
    private let store = RateLimitStore()
    private lazy var codexResetService = CodexResetService { [client = store.client] creditID, key in
        try await client.consumeRateLimitResetCredit(creditID: creditID, idempotencyKey: key)
    }
    /// 两个供应商共用点击锁；进入异步任务前同步上锁，避免快速连点。
    private var resetRequestInFlight = false
    /// Codex app-server 重启进行中；期间禁用账号切换，避免并发切换与停止进程交错。
    private var codexRestartInFlight = false
    private let zaiStore = ZAIQuotaStore()
    private let zaiResetService = ZAIResetService()
    private var presentedResetScopeID: String?
    private let authManager = CodexAuthManager()
    private let reminderCenter = ReminderCenter()
    /// Codex 官方日用量（account/usage/read），独立只读客户端、30 分钟节流拉取。
    private lazy var codexUsageStore = CodexUsageStore(client: CodexUsageClient())
    /// Z.AI 本机日用量（zcode SQLite 聚合），额度刷新后重查。
    private let zaiUsageStore = ZAIUsageStore()
    /// Z.AI 套餐用量的服务端口径（credit-usage 增量缓存），挂在额度刷新成功后同步。
    private let zaiServerUsageStore = ZAIServerUsageStore()
    private var accountOptions: [CodexAuthAccount] = []
    private var selectedAccountId: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Codex --%"
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        // 展开明细直接调整尺寸，避免 NSPopover 动画重绘造成内容闪烁。
        popover.animates = false
        popover.contentViewController = quotaViewController
        quotaViewController.onPreferredContentSizeChange = { [weak self] in
            guard let self else { return }
            let size = self.quotaViewController.preferredContentSize
            if self.popover.contentSize != size {
                self.popover.contentSize = size
            }
        }
        updateZAISectionVisibility()

        quotaViewController.onRefresh = { [weak self] in
            self?.store.refresh(force: true)
            // 手动刷新同时强制拉一次官方日用量（绕过 30 分钟节流）
            self?.codexUsageStore.refreshIfNeeded(force: true)
        }
        quotaViewController.onZAIRefresh = { [weak self] in
            guard let self else { return }
            if ZAISettings.resolveProviderSelection()?.kind != .apiKey {
                zaiStore.refresh()
            }
            zaiUsageStore.refresh()
        }
        quotaViewController.onResetCodexCredit = { [weak self] creditID in
            self?.useCodexResetCredit(creditID)
        }
        codexResetService.onChange = { [weak self] in self?.updateCodexResetActions() }
        quotaViewController.onUseZAIResetCard = { [weak self] kind in
            self?.useZAIResetCard(kind)
        }
        zaiResetService.onChange = { [weak self] in self?.updateZAIResetActions() }
        quotaViewController.onRefreshIntervalChange = { [weak self] minutes in
            guard let self else { return }
            // 与右键菜单 refreshIntervalSelected 同一条链：持久化 → 双 store 重建定时器 → 同步面板展示
            RefreshSettings.save(minutes: minutes)
            let interval = TimeInterval(minutes) * 60
            store.setRefreshInterval(interval)
            zaiStore.setRefreshInterval(interval)
            quotaViewController.applyRefreshInterval(minutes: minutes)
        }
        reminderCenter.start { [weak self] in
            self?.presentPopoverFromStatusItem()
        }
        quotaViewController.onMuteReminder = { [weak self] in
            self?.reminderCenter.muteCurrent()
            self?.refreshReminderUI()
        }
        quotaViewController.onUnmuteAll = { [weak self] in
            self?.reminderCenter.unmuteAll()
            self?.refreshReminderUI()
        }
        quotaViewController.onReminderConfigurationChange = { [weak self] configuration in
            self?.reminderCenter.updateConfiguration(configuration)
            self?.refreshReminderUI()
        }
        quotaViewController.applyReminderConfiguration(reminderCenter.configuration)
        initializeAccountSwitcher()

        zaiStore.onChange = { [weak self] snapshot, account, isRefreshing, error in
            guard let self else { return }
            // 渠道切换（zai ↔ bigmodel）后标题、区块显隐必须按新 selection 重算。
            self.updateZAISectionVisibility()
            self.quotaViewController.applyZAI(
                snapshot: snapshot,
                account: account,
                isRefreshing: isRefreshing,
                error: error
            )
            if !isRefreshing, error == nil, snapshot?.resetCreditCards != nil,
               let scope = self.zaiStore.lastResetScopeID,
               let startedAt = self.zaiStore.lastRefreshStartedAt {
                self.zaiResetService.acknowledgeFreshSnapshot(scopeID: scope, refreshStartedAt: startedAt)
            }
            self.updateZAIResetActions()
            if !isRefreshing, error == nil, let snapshot {
                // 渠道身份 = 套餐类型 + 账号邮箱；BigModel/ZAI 切换或换号后状态互不干扰。
                let channel = "\(snapshot.kind?.rawValue ?? "unknown")|\(account?.email ?? "")"
                self.reminderCenter.ingest(
                    source: .zai,
                    buckets: snapshot.reminderBuckets.map { $0.namespacedByChannel(channel) }
                )
            }
            // 本机 SQLite 快查：日用量独立于余额模式，API Key 模式也正常读取。
            self.zaiUsageStore.refresh()
            // 视图顺序：套餐列表已随文件监听更新 → active 快照已到达 →
            // 再按新 active 重算用量与配速，避免沿用旧渠道缓存。
            self.recomputeZAIUsage()
            self.refreshZAIPaceChart()
        }
        quotaViewController.applyZAI(
            snapshot: zaiStore.snapshot,
            account: zaiStore.account,
            isRefreshing: zaiStore.isRefreshing,
            error: zaiStore.lastError
        )
        refreshZAIPaceChart()

        store.onChange = { [weak self] snapshot, isRefreshing, error in
            guard let self else { return }
            self.statusItem.button?.title = snapshot?.primaryStatusTitle ?? "Codex --%"

            var reminder = self.reminderCenter.presentation(for: .codex)
            if !isRefreshing, error == nil, let snapshot {
                // 渠道身份 = 当前 Codex 账号；换账号后静音/去重互不影响。
                let channel = self.selectedAccountId ?? "default"
                reminder = self.reminderCenter.ingest(
                    source: .codex,
                    buckets: snapshot.reminderBuckets.map { $0.namespacedByChannel(channel) },
                    codexSnapshot: snapshot
                )
                // 官方日用量节流拉取（默认 30 分钟一次，失败静默）
                self.codexUsageStore.refreshIfNeeded(force: false)
            }

            self.quotaViewController.apply(
                snapshot: snapshot,
                isRefreshing: isRefreshing,
                error: error,
                reminder: reminder
            )
            self.quotaViewController.setUnmuteButtonVisible(self.reminderCenter.canRestore)
            self.updateCodexResetActions()
            // 额度刷新到达后重算配速图（周限桶与窗口锚点可能已变）
            self.refreshCodexPaceChart()
        }
        store.start()
        zaiStore.start()

        // 日用量图表：先回放缓存，再接变更回调并启动官方用量拉取
        quotaViewController.applyCodexUsage(codexUsageStore.snapshot?.last30Days)
        codexUsageStore.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.quotaViewController.applyCodexUsage(snapshot?.last30Days)
            // 用量刷新同样触发配速图重算（历史点位依赖日桶）
            self.refreshCodexPaceChart()
        }
        codexUsageStore.start()
        zaiUsageStore.onChange = { [weak self] _, _ in
            self?.recomputeZAIUsage()
        }
        zaiUsageStore.onPaceChange = { [weak self] daily, total in
            self?.finishZAIPaceChart(daily: daily, total: total)
        }
        zaiUsageStore.refresh()
        // 套餐用量服务端同步：额度刷新成功后带着已捕获凭证增量拉取，缓存更新后重组图表。
        zaiStore.onUsageSyncContext = { [weak self] context in
            self?.zaiServerUsageStore.sync(context: context)
        }
        zaiServerUsageStore.onChange = { [weak self] _ in
            self?.recomputeZAIUsage()
            self?.refreshZAIPaceChart()
        }
        // 启动回放当前账号的服务端用量缓存：首次网络同步到达前图表先有昨日读数。
        if let selection = ZAISettings.resolveProviderSelection(), selection.kind == .codingPlan {
            zaiServerUsageStore.preload(bucket: ZAIUsageSyncContext.bucket(
                domain: selection.domain,
                email: ZAISettings.loadAccount()?.email,
                teamContext: selection.teamContext
            ))
        }
    }

    // MARK: - Z.AI 用量组合（服务端套餐 + 本机非套餐，不双计）

    /// coding-plan 模式：总量 = 服务端套餐日桶（账号维度、全设备，已含本机套餐
    /// 部分）+ 本机非套餐渠道日桶；叠加高亮 = 服务端套餐。其余模式仅本机全渠道。
    /// 服务端缓存未建立时展示空图，不回落全渠道。
    private func recomputeZAIUsage() {
        guard let selection = ZAISettings.resolveProviderSelection() else { return }
        guard selection.kind == .codingPlan else {
            quotaViewController.applyZAIUsage(zaiUsageStore.days, channelDays: nil)
            return
        }
        guard let serverDays = zaiServerUsageStore.last30DayUsage() else {
            quotaViewController.applyZAIUsage(nil, channelDays: nil)
            return
        }
        let thirdPartyByDay = Dictionary(
            (zaiUsageStore.thirdPartyDays ?? []).map { (ZAIServerUsageCacheLogic.dayKey($0.date), $0.tokens) },
            uniquingKeysWith: { first, _ in first }
        )
        let combined = serverDays.map { day -> DayUsage in
            let key = ZAIServerUsageCacheLogic.dayKey(day.date)
            return DayUsage(date: day.date, tokens: day.tokens + (thirdPartyByDay[key] ?? 0))
        }
        quotaViewController.applyZAIUsage(combined, channelDays: serverDays)
    }

    // MARK: - 周配速图接线（额度刷新与用量刷新任一到达都重算）

    /// Z.AI 配速窗口参数（refreshZAIPaceChart 记录，估算器重算时使用）。
    private var zaiPaceWindow: (start: Date, end: Date, bucket: String)?

    /// Codex：周限桶 + 官方日桶（首日折算）→ 估算器 → 配速图快照。
    /// 月限窗口（Codex free）不启用：仅 7±1 天的周限窗按周配速展示。
    private func refreshCodexPaceChart() {
        guard let bucket = store.snapshot?.weekly,
              let resetsAt = bucket.resetsAt,
              // 与 QuotaBucket.displayTitles 同一判定：|mins − 7天| ≤ 1 天才算周限窗
              abs(bucket.windowDurationMins - 7 * 24 * 60) <= 24 * 60 else {
            quotaViewController.applyCodexPace(nil)
            return
        }

        let windowStart = resetsAt.addingTimeInterval(TimeInterval(-bucket.windowDurationMins * 60))
        let naturalDays = codexUsageStore.snapshot?.last30Days ?? []
        let daily = WeeklyPaceCodexBridge.windowDailyUsage(
            naturalDays: naturalDays, windowStart: windowStart, now: Date()
        )
        let windowTokens = daily.reduce(0) { $0 + $1.tokens }
        // E 持久化按渠道 + 账号分桶：Codex 用当前账号 ID
        let estimator = WeeklyPaceEstimator(bucket: "codex|\(selectedAccountId ?? "default")")
        let budget = estimator.update(windowEnd: resetsAt, windowTokens: windowTokens, usedPercent: bucket.usedPercent)
        let snapshot = WeeklyPaceSnapshot.make(
            windowStart: windowStart,
            windowEnd: resetsAt,
            now: Date(),
            dailyUsage: daily,
            budgetEstimate: budget,
            usedPercent: bucket.usedPercent
        )
        quotaViewController.applyCodexPace(snapshot)
    }

    /// Z.AI：coding-plan 周限桶 → 窗口锚点 → 服务端 hourly 缓存切窗（同步读取，
    /// 缓存由 ZAIServerUsageStore 在额度刷新后增量维护）。
    private func refreshZAIPaceChart() {
        guard let selection = ZAISettings.resolveProviderSelection(),
              selection.kind == .codingPlan,
              let snapshot = zaiStore.snapshot, snapshot.kind == .codingPlan,
              let limit = snapshot.limits.first(where: { $0.unit == .weekly }),
              let resetTime = limit.nextResetTime else {
            zaiPaceWindow = nil
            quotaViewController.applyZAIPace(nil)
            return
        }

        let windowDays = 7 * max(limit.number, 1)
        let windowStart = resetTime.addingTimeInterval(TimeInterval(-windowDays * 86400))
        // E 持久化按渠道（domain + 套餐）+ 账号邮箱分桶，不受 CLI 渠道 id 前缀迁移影响
        let email = zaiStore.account?.email ?? snapshot.email ?? ""
        zaiPaceWindow = (windowStart, resetTime, "\(selection.domain)-coding-plan|\(email)")
        let windowUsage = zaiServerUsageStore.windowUsage(windowStart: windowStart)
        finishZAIPaceChart(daily: windowUsage?.daily, total: windowUsage?.total)
    }

    /// Z.AI 读库结果回来：估算器重算 E → 配速图快照。
    private func finishZAIPaceChart(daily: [DayUsage]?, total: Double?) {
        guard let window = zaiPaceWindow,
              let snapshot = zaiStore.snapshot, snapshot.kind == .codingPlan,
              let limit = snapshot.limits.first(where: { $0.unit == .weekly }) else { return }
        let estimator = WeeklyPaceEstimator(bucket: window.bucket)
        let budget = estimator.update(
            windowEnd: window.end, windowTokens: total ?? 0, usedPercent: limit.usedPercent
        )
        let pace = WeeklyPaceSnapshot.make(
            windowStart: window.start,
            windowEnd: window.end,
            now: Date(),
            dailyUsage: daily ?? [],
            budgetEstimate: budget,
            usedPercent: limit.usedPercent
        )
        quotaViewController.applyZAIPace(pace)
    }

    private func codexResetAction(for card: ResetCreditCard) -> ResetCardsRow.ResetAction {
        guard let accountID = selectedAccountId, let creditID = card.id else {
            return .init(title: "重置", isEnabled: false, toolTip: "请先刷新当前账号的重置卡")
        }
        let canUse = !resetRequestInFlight && !codexResetService.isSubmitting
            && !store.isRefreshing && store.snapshotAccountID == accountID
        switch codexResetService.state(accountID: accountID, creditID: creditID) {
        case .submitting:
            return .init(title: "重置中", isEnabled: false)
        case .succeeded:
            return .init(title: "已重置", isEnabled: false)
        case .failed(let message):
            // 未确认请求即使卡已过期或状态改变，也使用原键重试以确认结果。
            return .init(title: "重试", isEnabled: canUse, toolTip: message)
        case .idle:
            let available = (card.status == nil || card.status == "available")
                && (card.expiresAt.map { $0 > Date() } ?? true)
            return .init(title: "重置", isEnabled: canUse && available,
                         toolTip: available ? "使用这张重置卡" : "这张重置卡当前不可用")
        }
    }

    private func updateCodexResetActions() {
        var actions: [String: ResetCardsRow.ResetAction] = [:]
        for (index, card) in (store.snapshot?.resetCreditCards ?? []).enumerated() {
            actions[card.id ?? "codex-missing-id-\(index)"] = codexResetAction(for: card)
        }
        quotaViewController.applyCodexResetActions(actions)
    }

    private func updateAllResetActions() {
        updateCodexResetActions()
        updateZAIResetActions()
    }

    /// 重置卡按钮点击后的二次确认弹框；取消则不发送任何请求。
    /// "取消"放第一个成为默认按钮，回车即取消，避免误触直接消耗重置卡。
    private func confirmResetCardUse(informativeText: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认使用重置卡？"
        alert.informativeText = informativeText
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确认重置")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 重置调用结束后弹出结果提示；失败时展示具体原因，仅有"关闭"一个按钮。
    private func presentResetResultAlert(success: Bool, failureMessage: String?) {
        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .warning
        alert.messageText = success ? "重置成功" : "重置失败"
        if !success {
            alert.informativeText = failureMessage ?? "重置未完成，请重试"
        }
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private func useCodexResetCredit(_ creditID: String) {
        guard let accountID = selectedAccountId,
              let card = store.snapshot?.resetCreditCards?.first(where: { $0.id == creditID }),
              codexResetAction(for: card).isEnabled else { return }
        guard confirmResetCardUse(informativeText: "将消耗一张重置卡，立即重置当前 Codex 额度窗口。") else { return }
        resetRequestInFlight = true
        updateAllResetActions()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resetRequestInFlight = false
                self.updateAllResetActions()
            }
            let succeeded = await self.codexResetService.use(accountID: accountID, creditID: creditID)
            if succeeded {
                self.store.refreshAfterReset()
            }
            var failureMessage: String?
            if !succeeded,
               case .failed(let message) = self.codexResetService.state(accountID: accountID, creditID: creditID) {
                failureMessage = message
            }
            self.presentResetResultAlert(success: succeeded, failureMessage: failureMessage)
        }
    }

    private func updateZAIResetActions() {
        do {
            let context = try ZAIResetContextResolver.resolve()
            presentedResetScopeID = context.scopeID
            let states = Dictionary(uniqueKeysWithValues: [ZAIResetCreditCard.Kind.fiveHour, .week].map {
                ($0, zaiResetService.state(scopeID: context.scopeID, kind: $0))
            })
            let canUse = zaiStore.lastResetScopeID == context.scopeID
                && zaiStore.snapshot?.kind == .codingPlan && zaiStore.snapshot?.resetCreditCards != nil
                && !zaiStore.isRefreshing && zaiStore.lastError == nil && !resetRequestInFlight
            quotaViewController.applyZAIResetState(states, canUseCards: canUse,
                                                canRetry: !zaiStore.isRefreshing && !resetRequestInFlight,
                                                unavailableReason: canUse ? nil : "请先刷新当前账号的额度和重置卡")
        } catch {
            presentedResetScopeID = nil
            quotaViewController.applyZAIResetState([:], canUseCards: false, canRetry: false,
                                                unavailableReason: error.localizedDescription)
        }
    }

    private func useZAIResetCard(_ kind: ZAIResetCreditCard.Kind) {
        guard !resetRequestInFlight, !zaiStore.isRefreshing,
              let context = try? ZAIResetContextResolver.resolve(),
              context.scopeID == presentedResetScopeID else {
            updateZAIResetActions()
            return
        }
        let state = zaiResetService.state(scopeID: context.scopeID, kind: kind)
        switch state {
        case .submitting, .succeeded: return
        case .failed: break // 未确认请求即使列表变化，仍可使用原 key 重试。
        case .idle:
            guard zaiStore.lastResetScopeID == context.scopeID, zaiStore.lastError == nil,
                  zaiStore.snapshot?.kind == .codingPlan,
                  zaiStore.snapshot?.resetCreditCards?.contains(where: {
                      $0.kind == kind && ($0.expiresAt.map { $0 > Date() } ?? false)
                  }) == true else {
                updateZAIResetActions()
                return
            }
        }
        guard confirmResetCardUse(informativeText: "将消耗一张重置卡，立即重置 ZAI \(kind.title)。") else { return }
        resetRequestInFlight = true
        updateAllResetActions()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resetRequestInFlight = false
                self.updateAllResetActions()
            }
            let succeeded = await self.zaiResetService.use(context: context, kind: kind)
            if succeeded {
                self.zaiStore.refreshAfterReset()
            }
            var failureMessage: String?
            if !succeeded,
               case .failed(let message) = self.zaiResetService.state(scopeID: context.scopeID, kind: kind) {
                failureMessage = message
            }
            self.presentResetResultAlert(success: succeeded, failureMessage: failureMessage)
        }
    }

    private func initializeAccountSwitcher() {
        defer { updateCodexResetActions() }
        do {
            let result = try authManager.loadAccounts()
            accountOptions = result.accounts
            selectedAccountId = result.selectedAccountId
            store.setAccountID(selectedAccountId)
            quotaViewController.setAccountLabel(currentAccountLabel())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            accountOptions = []
            selectedAccountId = nil
            store.setAccountID(nil)
            quotaViewController.setAccountLabel(nil)
            quotaViewController.showAccountSwitchStatus(message)
        }
    }

    private func currentAccountLabel() -> String? {
        guard let selectedAccountId else { return nil }
        return accountOptions.first { $0.accountId == selectedAccountId }?.label
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminderCenter.retractAll()
        store.stop()
        zaiStore.stop()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let switchItem = NSMenuItem(title: "Codex账号切换", action: nil, keyEquivalent: "")
        switchItem.submenu = makeAccountSubmenu()
        menu.addItem(switchItem)

        let zaiPlanItem = NSMenuItem(title: "ZCode套餐切换", action: nil, keyEquivalent: "")
        zaiPlanItem.submenu = makeZAIPlanViewSubmenu()
        menu.addItem(zaiPlanItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeReminderMenuItem())
        menu.addItem(makeRefreshIntervalMenuItem())

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
    }

    /// 提醒设置入口：有可用通道时给完整子菜单，否则置灰提示设备不支持。
    private func makeReminderMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "提醒设置", action: nil, keyEquivalent: "")
        if ReminderCapability.hasAnyChannel {
            item.submenu = makeReminderSubmenu()
            item.isEnabled = true
        } else {
            item.isEnabled = false
            item.toolTip = "当前设备没有 Touch Bar，屏幕也没有刘海，无可用提醒通道"
        }
        return item
    }

    /// 刷新频率入口：Codex 与 ZAI 共用一个间隔，按固定档位勾选。
    private func makeRefreshIntervalMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
        item.submenu = makeRefreshIntervalSubmenu()
        item.isEnabled = true
        return item
    }

    // MARK: - Z.AI 套餐视图切换

    /// Zcode 3.14.0 起套餐选择是会话级、不落盘，应用无从得知各会话实际所用套餐，
    /// 由用户在此指定要展示与查询的套餐；未设置时跟随 setting.json 的默认套餐。
    /// 可选项按 codex-cliproxy 的文件判定法（setting.json 连接形态槽位），
    /// 每次右键现读文件——不依赖网络探测，也不占用定时刷新周期。
    private func makeZAIPlanViewSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selection = ZAISettings.resolveProviderSelection()

        // api-key / 未连接：套餐间不可切换。
        guard selection?.kind == .codingPlan || selection?.kind == .startPlan else {
            let item = NSMenuItem(title: "当前连接不可切换套餐", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }

        let options = ZAISettings.planMenuOptions(object: ZAISettings.loadSettingObject())
        let entries: [(option: ZAIPlanViewOverride, shown: Bool, checked: Bool)] = [
            (.startPlan, options.startPlan, selection?.kind == .startPlan),
            (.codingPlan, options.personal,
             selection?.kind == .codingPlan && selection?.teamContext == nil),
            (.teamCodingPlan, options.team,
             selection?.kind == .codingPlan && selection?.teamContext != nil),
        ]
        var addedCount = 0
        for entry in entries where entry.shown {
            let item = NSMenuItem(title: entry.option.title,
                                  action: #selector(zaiPlanViewSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.option.rawValue
            item.state = entry.checked ? .on : .off
            item.isEnabled = true
            submenu.addItem(item)
            addedCount += 1
        }
        if addedCount == 0 {
            let none = NSMenuItem(title: "无可用套餐", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        return submenu
    }

    @objc private func zaiPlanViewSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = ZAIPlanViewOverride(rawValue: raw),
              option != ZAIPlanViewSettings.load() else { return }
        ZAIPlanViewSettings.save(option, accountID: ZAISettings.currentAccountIdentity())
        // 立即按新视图重查额度（查询中则排队），用量口径同步重算。
        zaiStore.refreshAfterPlanViewChange()
        recomputeZAIUsage()
    }


    private func makeRefreshIntervalSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let currentMinutes = RefreshSettings.loadMinutes()
        for minutes in RefreshSettings.availableMinutes {
            let item = NSMenuItem(title: "\(minutes) 分钟", action: #selector(refreshIntervalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.isEnabled = true
            if minutes == currentMinutes {
                item.state = .on
            }
            submenu.addItem(item)
        }

        return submenu
    }

    private func makeReminderSubmenu() -> NSMenu {
        let configuration = reminderCenter.configuration

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let warningItem = NSMenuItem(title: "额度低于", action: nil, keyEquivalent: "")
        warningItem.submenu = makeReminderOptionSubmenu(
            field: .warningPercent,
            currentValue: Int(configuration.warningRemainingPercent),
            options: [("50%", 50), ("40%", 40), ("30%", 30), ("20%", 20), ("10%", 10)]
        )
        submenu.addItem(warningItem)

        let resetSoonItem = NSMenuItem(title: "重置还剩", action: nil, keyEquivalent: "")
        resetSoonItem.submenu = makeReminderOptionSubmenu(
            field: .resetSoonMinutes,
            currentValue: Int(configuration.resetSoonMinutes),
            options: [("50 分钟", 50), ("40 分钟", 40), ("30 分钟", 30), ("20 分钟", 20), ("10 分钟", 10), ("关闭", 0)]
        )
        submenu.addItem(resetSoonItem)

        let cooldownItem = NSMenuItem(title: "提醒间隔", action: nil, keyEquivalent: "")
        cooldownItem.submenu = makeReminderOptionSubmenu(
            field: .cooldownMinutes,
            currentValue: Int(configuration.cooldown / 60),
            options: [("5 分钟", 5), ("10 分钟", 10), ("15 分钟", 15), ("30 分钟", 30), ("60 分钟", 60)]
        )
        submenu.addItem(cooldownItem)

        submenu.addItem(NSMenuItem.separator())

        let restoreItem = NSMenuItem(title: "恢复默认", action: #selector(reminderRestoreDefaultsTapped), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = true
        restoreItem.toolTip = "恢复为默认：开启、额度低于 20%、重置还剩 30 分钟、提醒间隔 10 分钟"
        submenu.addItem(restoreItem)

        let testItem = NSMenuItem(title: "测试", action: #selector(testReminderTapped), keyEquivalent: "")
        testItem.target = self
        testItem.isEnabled = true
        testItem.toolTip = "手动触发一次提醒，验证投递链路"
        submenu.addItem(testItem)

        return submenu
    }

    private func makeReminderOptionSubmenu(
        field: ReminderMenuField,
        currentValue: Int,
        options: [(title: String, value: Int)]
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        var nearestItem: NSMenuItem?
        var nearestDistance = Int.max

        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(reminderOptionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = field.rawValue
            item.representedObject = option.value
            item.isEnabled = true
            submenu.addItem(item)

            // 持久化的可能是旧版选项列表里的值；没有精确匹配时高亮最接近的一项。
            let distance = abs(option.value - currentValue)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestItem = item
            }
        }
        nearestItem?.state = .on

        return submenu
    }

    private func makeAccountSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if accountOptions.isEmpty {
            let noneItem = NSMenuItem(title: "无", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            submenu.addItem(noneItem)
            return submenu
        }

        for account in accountOptions {
            let item = NSMenuItem(title: account.label, action: #selector(accountMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.fileName
            item.state = account.accountId == selectedAccountId ? .on : .off
            item.isEnabled = !resetRequestInFlight && !codexRestartInFlight
            submenu.addItem(item)
        }

        return submenu
    }

    @objc private func accountMenuItemSelected(_ sender: NSMenuItem) {
        guard !resetRequestInFlight, !codexRestartInFlight,
              let fileName = sender.representedObject as? String else { return }
        do {
            try authManager.switchAccount(to: fileName)
            initializeAccountSwitcher()
            guard confirmRestartCodexAfterSwitch(label: currentAccountLabel()) else {
                // 不重启也刷新：本应用的读取进程每次新拉起，直接读新 auth.json。
                quotaViewController.showAccountSwitchStatus("已切换账号，重启 Codex 后新账号生效")
                store.refresh(force: true)
                // 取消重启必须给出明确反馈，避免误以为新账号已对 Codex 客户端生效。
                presentSwitchDeferredAlert()
                return
            }
            codexRestartInFlight = true
            quotaViewController.showAccountSwitchStatus("已切换账号，正在重启 Codex…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                // ps 枚举与 2 秒等待都在后台线程执行，不阻塞主线程。
                let outcome = await Task.detached(priority: .userInitiated) {
                    CodexAppServerRestartService.stopAppServers()
                }.value
                self.codexRestartInFlight = false
                self.presentRestartOutcome(outcome)
                self.store.refresh(force: true)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            quotaViewController.showAccountSwitchStatus(message)
        }
    }

    /// 切换账号成功后的重启确认弹框。
    /// “取消”放第一个成为默认按钮，回车即取消：重启会中断 Codex 正在执行的任务，默认动作必须保守。
    private func confirmRestartCodexAfterSwitch(label: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "立即重启 Codex？"
        let switchedTo = label.map { "已切换到 \($0)。" } ?? "已切换账号。"
        alert.informativeText = switchedTo
            + "将停止当前用户的 Codex app-server 进程（正在执行的任务可能被中断），"
            + "Codex 会自动拉起新进程并使用新账号。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "立即重启")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 取消重启后的结果提示：切换的账号要等 Codex 重启后才对 Codex 客户端生效。
    private func presentSwitchDeferredAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已切换账号"
        alert.informativeText = "切换的账号将在 Codex 重启后生效。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentRestartOutcome(_ outcome: CodexAppServerRestartOutcome) {
        switch outcome {
        case .finished(let stopped, let notStopped) where notStopped.isEmpty:
            quotaViewController.showAccountSwitchStatus(
                "已停止 \(stopped.count) 个 Codex app-server，Codex 重新拉起后新账号生效"
            )
        case .finished(_, let notStopped):
            presentRestartFailureAlert(
                messageText: "部分 Codex app-server 未停止",
                informativeText: "未停止的进程 PID：\(notStopped.map(String.init).joined(separator: "、"))。"
                    + "账号已切换；建议重启 ChatGPT.app 或结束对应会话使新账号生效。"
            )
        case .noneFound:
            quotaViewController.showAccountSwitchStatus("已切换账号，未发现运行中的 Codex app-server")
        case .unknownScan(let message):
            presentRestartFailureAlert(
                messageText: "无法确认 Codex app-server 状态",
                informativeText: "\(message)。账号已切换；建议重启 ChatGPT.app 使新账号生效。"
            )
        }
    }

    private func presentRestartFailureAlert(messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    /// 手动测试提醒投递链；无可用通道（无 Touch Bar 且无刘海屏）时给出提示。
    /// 正常情况下入口在禁用态，这里只是兜底。
    @objc private func testReminderTapped() {
        if reminderCenter.deliverTestAlert(codexSnapshot: store.snapshot) { return }

        let alert = NSAlert()
        alert.messageText = "无可用提醒通道"
        alert.informativeText = "当前设备没有 Touch Bar，屏幕也没有刘海，无法弹出提醒。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func reminderOptionSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int,
              let field = ReminderMenuField(rawValue: sender.tag) else { return }

        var configuration = reminderCenter.configuration
        switch field {
        case .warningPercent:
            configuration.warningRemainingPercent = Double(value)
        case .resetSoonMinutes:
            configuration.resetSoonMinutes = TimeInterval(value) // 0 表示关闭"重置还剩"提醒
        case .cooldownMinutes:
            configuration.cooldown = TimeInterval(value * 60)
        }
        updateReminderConfigurationFromMenu(configuration)
    }

    @objc private func reminderRestoreDefaultsTapped() {
        updateReminderConfigurationFromMenu(.default)
    }

    /// 菜单侧修改配置后与面板回调走同一条链：持久化+重评 → 同步面板只读展示 → 刷新提醒 UI。
    private func updateReminderConfigurationFromMenu(_ configuration: ReminderConfiguration) {
        reminderCenter.updateConfiguration(configuration)
        quotaViewController.applyReminderConfiguration(configuration)
        refreshReminderUI()
    }

    /// 修改刷新频率：持久化 → 两个 store 重建定时器 → 同步面板只读展示。
    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        RefreshSettings.save(minutes: minutes)
        let interval = TimeInterval(minutes) * 60
        store.setRefreshInterval(interval)
        zaiStore.setRefreshInterval(interval)
        quotaViewController.applyRefreshInterval(minutes: minutes)
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    /// 提醒通道（刘海屏弹窗等）点击后打开主面板。
    private func presentPopoverFromStatusItem() {
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
    }

    /// 静音 / 改配置后立即刷新 UI 上的提醒表现（emoji、恢复提醒按钮），
    /// 与旧链路里 store.onChange 的即时回调保持一致。
    private func refreshReminderUI() {
        quotaViewController.applyReminderConfiguration(reminderCenter.configuration)
        quotaViewController.apply(
            snapshot: store.snapshot,
            isRefreshing: store.isRefreshing,
            error: nil,
            reminder: reminderCenter.presentation(for: .codex)
        )
        quotaViewController.setUnmuteButtonVisible(reminderCenter.canRestore)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)
        updateZAISectionVisibility()
        // 从刘海卡片静音不会经过面板回调，打开面板时必须重取 canRestore，
        // 否则"恢复提醒"按钮要等下一次额度轮询（store.onChange）才出现。
        quotaViewController.setUnmuteButtonVisible(reminderCenter.canRestore)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // NSPopover 首次加载 view 后会重新取一次 preferredContentSize，这里再设一次避免底部被裁切。
            popover.contentSize = quotaViewController.preferredContentSize
        }
        updateAllResetActions()
        quotaViewController.focusTouchBarHost()
    }

    private func updateZAISectionVisibility() {
        quotaViewController.setZAISectionVisible(ZAISettings.isZAIDomain())
        popover.contentSize = quotaViewController.preferredContentSize
    }
}

// MARK: - 额度弹窗视图控制器（quota-popup-redesign-9319 原型落地版）
// 宽 322 固定深色弹窗：顶部栏 + Codex/ZAI provider 区块 + 图例页脚；齿轮进入设置页。

@MainActor
final class QuotaViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onZAIRefresh: (() -> Void)?
    var onUseZAIResetCard: ((ZAIResetCreditCard.Kind) -> Void)?
    var onResetCodexCredit: ((String) -> Void)?
    var onPreferredContentSizeChange: (() -> Void)?
    var onMuteReminder: (() -> Void)?
    var onUnmuteAll: (() -> Void)?
    var onReminderConfigurationChange: ((ReminderConfiguration) -> Void)?
    var onRefreshIntervalChange: ((Int) -> Void)?

    private let rootView = TouchBarHostingVisualEffectView()
    /// 实色背景层：盖住半透明材质，保证面板颜色与原型 #1A1A1C 一致
    private let solidBackground = NSView()

    /// 额度页 / 设置页两页切换，共用同一个 popover。
    private let quotaPage = NSStackView()
    private let settingsPageView = SettingsPageView()
    /// 设置页的定宽容器（makeBlock 产物），切页时按它控制显隐
    private var settingsBlock: NSView = NSView()
    private let pageContainer = NSStackView()

    // 顶部栏
    private let updatedLabel = NSTextField(labelWithString: "")
    private var updatedLabelTimer: Timer?
    private let refreshTabButton = PanelIconButton(symbolName: "arrow.clockwise", toolTipText: "刷新", side: 22)
    private let settingsButton = PanelIconButton(symbolName: "gearshape", toolTipText: "设置", side: 22)

    // Tab 栏 + provider 面板：同一时刻只显示 active tab 的区块（Codex / Z.AI 内容区不变）
    private let tabBar = PanelTabBarView()
    private let codexSection = CodexPanelSection()
    private let zaiSection = ZAIPanelSection()
    private var panelBlocks: [QuotaTabID: NSView] = [:]
    private let footer = PanelFooterView()
    private var activeTab: QuotaTabID = .codex
    private var isZAITabVisible = false

    /// 最近一次 Codex 状态；账号标签等外部更新后重放（与旧版行为一致）。
    private var lastCodexSnapshot: QuotaSnapshot?
    private var lastCodexIsRefreshing = false
    private var lastCodexError: String?
    private var accountLabelText: String?

    /// 最近一次 Z.AI 状态，供 tab 摘要与切换重放使用。
    private var lastZAISnapshot: ZAIQuotaSnapshot?
    private var lastZAIError: String?
    private var lastZAITitleOverride: String?

    /// 顶部更新时间：跟随 active tab 各自最近一次成功刷新的时刻。快照只在成功时生成，
    /// 刷新中的重放会带旧 fetchedAt，每个 tab 取 max 防止乱序回放把时间回退。
    private var refreshedAtByTab: [QuotaTabID: Date] = [:]

    /// 当前生效的提醒配置；面板/设置页改动后走 onReminderConfigurationChange 与右键菜单共用一条链。
    private var reminderConfiguration = ReminderConfiguration.default
    private var refreshIntervalMinutes = RefreshSettings.loadMinutes()
    private var canRestoreMuted = false

    override func loadView() {
        rootView.material = .popover
        rootView.blendingMode = .withinWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 14
        rootView.layer?.masksToBounds = true
        // 原型为固定深色弹窗，文本/状态色见 PanelTheme
        rootView.appearance = PanelTheme.appearance
        rootView.touchBarQuotaView.onMuteReminder = { [weak self] in
            self?.onMuteReminder?()
        }
        view = rootView

        // 实色底：NSVisualEffectView 的材质是半透明的，会把背后内容透进来，
        // 整体颜色像加了透明度。垫一层原型同色 #1A1A1C 实色背景后再放内容。
        solidBackground.wantsLayer = true
        solidBackground.layer?.backgroundColor = PanelTheme.panelBackground.cgColor
        solidBackground.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(solidBackground, positioned: .below, relativeTo: nil)

        configureSubviews()
        updatePreferredContentSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // popover 每次重新打开都回到额度页与默认 Codex tab（选择不持久化）
        setShowsSettings(false)
        setActiveTab(.codex)
        focusTouchBarHost()
        updateLastUpdatedLabel()
        updatedLabelTimer?.invalidate()
        // 只在面板打开时更新相对时间文案，不触发数据刷新。
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLastUpdatedLabel() }
        }
        timer.tolerance = 1
        updatedLabelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        updatedLabelTimer?.invalidate()
        updatedLabelTimer = nil
    }

    func focusTouchBarHost() {
        view.window?.makeFirstResponder(rootView)
        rootView.touchBar = rootView.makeTouchBar()
    }

    // MARK: - 对外状态入口（apply/applyZAI 签名与旧版一致）

    func setUnmuteButtonVisible(_ visible: Bool) {
        canRestoreMuted = visible
        syncControlStates()
    }

    func setZAISectionVisible(_ visible: Bool) {
        isZAITabVisible = visible
        if isViewLoaded {
            if !visible, activeTab == .zai {
                setActiveTab(.codex)
            }
            syncTabBar()
        }
        updateRefreshButton()
        updatePreferredContentSize()
    }

    func applyZAI(snapshot: ZAIQuotaSnapshot?, account: ZAIAccount?, isRefreshing: Bool, error: String?) {
        let selection = ZAISettings.resolveProviderSelection()
        let title = selection?.domain == "bigmodel" ? "BigModel" : "Z.AI"
        lastZAISnapshot = snapshot
        lastZAIError = error
        lastZAITitleOverride = title
        zaiSection.apply(snapshot: snapshot, account: account, isRefreshing: isRefreshing, error: error, titleOverride: title)
        recordRefreshedAt(.zai, snapshot?.fetchedAt)
        syncTabBar()
        updateLastUpdatedLabel()
        updatePreferredContentSize()
    }

    func applyZAIResetState(_ states: [ZAIResetCreditCard.Kind: ZAIResetState],
                            canUseCards: Bool, canRetry: Bool, unavailableReason: String?) {
        zaiSection.applyResetState(states, canUseCards: canUseCards, canRetry: canRetry,
                                   unavailableReason: unavailableReason)
        updatePreferredContentSize()
    }

    func showAccountSwitchStatus(_ message: String) {
        codexSection.showTransientStatus(message)
        replayCodexState()
    }

    func setAccountLabel(_ text: String?) {
        accountLabelText = text
        replayCodexState()
    }

    func apply(
        snapshot: QuotaSnapshot?,
        isRefreshing: Bool,
        error: String?,
        reminder: ReminderPresentation
    ) {
        lastCodexSnapshot = snapshot
        lastCodexIsRefreshing = isRefreshing
        lastCodexError = error
        recordRefreshedAt(.codex, snapshot?.fetchedAt)

        codexSection.apply(snapshot: snapshot, isRefreshing: isRefreshing, error: error, accountLabel: accountLabelText)
        syncTabBar()
        updateLastUpdatedLabel()
        if let snapshot {
            rootView.touchBarQuotaView.update(snapshot: snapshot, reminder: reminder)
        }
    }

    /// 任一渠道成功返回快照后推进该 tab 的顶部时间；旧快照重放不会回退。
    private func recordRefreshedAt(_ tab: QuotaTabID, _ fetchedAt: Date?) {
        guard let fetchedAt else { return }
        let current = refreshedAtByTab[tab] ?? .distantPast
        refreshedAtByTab[tab] = max(current, fetchedAt)
    }

    /// 顶部更新时间文案（测试读取用）。
    var lastUpdatedDisplayText: String { updatedLabel.stringValue }

    private func updateLastUpdatedLabel() {
        guard let refreshedAt = refreshedAtByTab[activeTab] else {
            updatedLabel.stringValue = ""
            updatedLabel.toolTip = nil
            return
        }
        updatedLabel.stringValue = PanelTheme.relativeTime(from: refreshedAt)
        updatedLabel.toolTip = "\(activeTabDisplayName) 上次成功刷新：\(PanelTheme.formatFetchedAt(refreshedAt))"
    }

    func applyReminderConfiguration(_ configuration: ReminderConfiguration) {
        reminderConfiguration = configuration
        syncControlStates()
    }

    func applyRefreshInterval(minutes: Int) {
        refreshIntervalMinutes = minutes
        syncControlStates()
    }

    func applyCodexResetActions(_ actions: [String: ResetCardsRow.ResetAction]) {
        codexSection.applyResetActions(actions)
    }

    func applyCodexUsage(_ days: [DayUsage]?) {
        codexSection.applyUsage(days: days)
        updatePreferredContentSize()
    }

    func applyZAIUsage(_ days: [DayUsage]?, channelDays: [DayUsage]? = nil) {
        zaiSection.applyUsage(days: days, channelDays: channelDays)
        // 叠加图例行显隐会改变高度
        updatePreferredContentSize()
    }

    func applyCodexPace(_ snapshot: WeeklyPaceSnapshot?) {
        codexSection.applyPace(snapshot)
    }

    func applyZAIPace(_ snapshot: WeeklyPaceSnapshot?) {
        zaiSection.applyPace(snapshot)
    }

    // MARK: - 布局

    private func configureSubviews() {
        buildTopBar()
        buildTabBar()
        buildSections()
        buildFooter()
        buildSettingsPage()

        pageContainer.orientation = .horizontal
        pageContainer.alignment = .top
        pageContainer.spacing = 0
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addView(quotaPage, in: .leading)
        // 设置页走 makeBlock：与额度页同款 12pt 内边距，避免 stack 自动贴边约束吃掉边距
        let settingsBlock = makeBlock(settingsPageView, top: 10, bottom: 10)
        pageContainer.addView(settingsBlock, in: .leading)
        settingsBlock.isHidden = true
        self.settingsBlock = settingsBlock

        rootView.addSubview(pageContainer)
        NSLayoutConstraint.activate([
            solidBackground.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            solidBackground.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            solidBackground.topAnchor.constraint(equalTo: rootView.topAnchor),
            solidBackground.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            pageContainer.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor),
            quotaPage.widthAnchor.constraint(equalTo: pageContainer.widthAnchor),
            settingsBlock.widthAnchor.constraint(equalTo: pageContainer.widthAnchor)
        ])
    }

    private func buildTopBar() {
        let titleLabel = NSTextField(labelWithString: "LocalQuotaBar")
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = PanelTheme.primaryText

        updatedLabel.font = .systemFont(ofSize: 10, weight: .regular)
        updatedLabel.textColor = PanelTheme.tertiaryText

        refreshTabButton.identifier = NSUserInterfaceItemIdentifier("refresh-active")
        refreshTabButton.onTap = { [weak self] in
            self?.requestActiveTabRefresh()
        }
        settingsButton.onTap = { [weak self] in
            self?.setShowsSettings(true)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [titleLabel, spacer, updatedLabel, refreshTabButton, settingsButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8

        quotaPage.orientation = .vertical
        quotaPage.alignment = .leading
        quotaPage.spacing = 0
        quotaPage.translatesAutoresizingMaskIntoConstraints = false

        quotaPage.addArrangedSubview(makeBlock(topBar, top: 10, bottom: 4))
    }

    /// Tab 栏：通栏容器（自带底部分隔线），点击切换 active 面板。
    private func buildTabBar() {
        tabBar.onSelectionChange = { [weak self] tab in
            self?.setActiveTab(tab)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: PanelTheme.panelWidth)
        ])
        quotaPage.addArrangedSubview(container)
    }

    private func buildSections() {
        codexSection.onRefresh = { [weak self] in self?.onRefresh?() }
        codexSection.onResetCredit = { [weak self] id in self?.onResetCodexCredit?(id) }
        codexSection.onRefreshAvailabilityChange = { [weak self] in self?.updateRefreshButton() }
        codexSection.onContentHeightChange = { [weak self] in self?.updatePreferredContentSize() }
        panelBlocks[.codex] = makeBlock(codexSection, top: 8, bottom: 10)

        zaiSection.onRefresh = { [weak self] in self?.onZAIRefresh?() }
        zaiSection.onUseResetCard = { [weak self] kind in self?.onUseZAIResetCard?(kind) }
        zaiSection.onRefreshAvailabilityChange = { [weak self] in self?.updateRefreshButton() }
        zaiSection.onContentHeightChange = { [weak self] in self?.updatePreferredContentSize() }
        panelBlocks[.zai] = makeBlock(zaiSection, top: 8, bottom: 10)

        for id in QuotaTabID.allCases {
            guard let block = panelBlocks[id] else { continue }
            quotaPage.addArrangedSubview(block)
        }
        syncTabBar()
        updatePanelVisibility()
        updateRefreshButton()
    }

    // MARK: - Tab 切换与刷新语义（顶栏刷新只作用于当前 active tab）

    /// 当前可见 tab：Codex 常驻；Z.AI 由 ZAISettings 决定；DeepSeek / CodeBuddy 在后续阶段接入。
    private var visibleTabs: Set<QuotaTabID> {
        var tabs: Set<QuotaTabID> = [.codex]
        if isZAITabVisible { tabs.insert(.zai) }
        return tabs
    }

    private var activeTabDisplayName: String {
        if activeTab == .zai { return lastZAITitleOverride ?? QuotaTabID.zai.displayName }
        return activeTab.displayName
    }

    private func setActiveTab(_ tab: QuotaTabID) {
        guard visibleTabs.contains(tab) else { return }
        activeTab = tab
        tabBar.select(tab, notify: false)
        updatePanelVisibility()
        updateRefreshButton()
        updateLastUpdatedLabel()
        updatePreferredContentSize()
    }

    /// 各面板常驻视图树、按 active 显隐；隐藏的区块在 stack 中自动塌缩。
    private func updatePanelVisibility() {
        guard isViewLoaded else { return }
        for (id, block) in panelBlocks where id != activeTab {
            block.isHidden = true
        }
        panelBlocks[activeTab]?.isHidden = false
    }

    /// 汇总各 tab 的环 / tag / 状态点 / tooltip（apply 链路与显隐变化后调用）。
    private func syncTabBar() {
        guard isViewLoaded else { return }
        if !visibleTabs.contains(activeTab) {
            activeTab = .codex
            tabBar.select(.codex, notify: false)
        }
        tabBar.configure(statuses: tabStatuses(), visible: visibleTabs)
    }

    private var activeSectionCanRefresh: Bool {
        switch activeTab {
        case .codex: return codexSection.canRequestRefresh
        case .zai: return zaiSection.canRequestRefresh
        case .deepSeek, .codeBuddy: return false
        }
    }

    private func updateRefreshButton() {
        let canRefresh = activeSectionCanRefresh
        refreshTabButton.isEnabled = canRefresh
        refreshTabButton.alphaValue = canRefresh ? 1 : 0.35
        refreshTabButton.toolTip = canRefresh
            ? "刷新 \(activeTabDisplayName)"
            : "当前项目正在刷新或冷却，请稍后重试"
    }

    /// 顶栏刷新：只刷新当前 active tab（60 秒冷却由各 section 承担）。
    private func requestActiveTabRefresh() {
        guard activeSectionCanRefresh else { return }
        switch activeTab {
        case .codex: codexSection.requestRefresh()
        case .zai: zaiSection.requestRefresh()
        case .deepSeek, .codeBuddy: break
        }
    }

    private func tabStatuses() -> [QuotaTabID: PanelTabStatus] {
        var statuses: [QuotaTabID: PanelTabStatus] = [:]

        var codex = PanelTabStatus()
        if let weekly = lastCodexSnapshot?.weekly {
            codex.ring = .percent(remaining: weekly.remainingPercent)
        } else if let fiveHour = lastCodexSnapshot?.fiveHour {
            codex.ring = .percent(remaining: fiveHour.remainingPercent)
        }
        codex.tagText = lastCodexSnapshot?.planType.flatMap { $0.isEmpty ? nil : $0 }
        codex.isFailed = lastCodexError != nil
        codex.summary = codexTabSummary()
        statuses[.codex] = codex

        var zai = PanelTabStatus()
        zai.titleOverride = lastZAITitleOverride
        zai.isFailed = lastZAIError != nil
        zai.tagText = zaiTabTag()
        zai.ring = zaiTabRing()
        zai.summary = zaiTabSummary()
        statuses[.zai] = zai

        return statuses
    }

    private func codexTabSummary() -> String? {
        var parts: [String] = []
        if let bucket = lastCodexSnapshot?.weekly ?? lastCodexSnapshot?.fiveHour {
            parts.append("\(bucket.title)剩余 \(bucket.roundedRemainingPercent)%")
            if let countdown = PanelTheme.formatCountdown(until: bucket.resetsAt) {
                parts.append("\(countdown)后重置")
            }
        }
        if let balance = lastCodexSnapshot?.creditBalance {
            parts.append("余额 \(String(format: "$%.2f", balance / 25))")
        }
        if let accountLabelText, !accountLabelText.isEmpty {
            parts.append(ProviderHeaderView.compactAccountLabel(accountLabelText))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func zaiTabRing() -> PanelTabStatus.RingValue {
        guard let snapshot = lastZAISnapshot else { return .unavailable }
        switch snapshot.kind {
        case .apiKey, nil:
            return .unavailable
        case .startPlan:
            guard let balance = snapshot.balances.first else { return .unavailable }
            return .percent(remaining: balance.remainingFraction * 100)
        case .codingPlan:
            let limits = snapshot.limits
            if let weekly = limits.first(where: { $0.unit == .weekly }) {
                return .percent(remaining: weekly.remainingPercent)
            }
            if let hourly = limits.first(where: { $0.unit == .hourly }) {
                return .percent(remaining: hourly.remainingPercent)
            }
            return .unavailable
        }
    }

    private func zaiTabTag() -> String? {
        guard let snapshot = lastZAISnapshot else { return nil }
        switch snapshot.kind {
        case .apiKey:
            return snapshot.apiKeySuffix.map { "API Key ····\($0)" } ?? "API Key"
        case .startPlan:
            return snapshot.planName.flatMap { $0.isEmpty ? nil : $0 } ?? "体验套餐"
        case .codingPlan:
            return snapshot.level.flatMap { $0.isEmpty ? nil : $0 }
        case nil:
            return nil
        }
    }

    private func zaiTabSummary() -> String? {
        guard let snapshot = lastZAISnapshot else { return nil }
        var parts: [String] = []
        switch snapshot.kind {
        case .apiKey:
            parts.append("API Key 模式，无余额功能")
        case nil:
            break
        case .startPlan:
            if let email = snapshot.email, !email.isEmpty {
                parts.append(ProviderHeaderView.compactAccountLabel(email))
            }
        case .codingPlan:
            let limits = snapshot.limits
            if let hourly = limits.first(where: { $0.unit == .hourly }) {
                parts.append("\(hourly.title)剩余 \(hourly.roundedRemainingPercent)%")
            }
            if let weekly = limits.first(where: { $0.unit == .weekly }) {
                parts.append("\(weekly.title)剩余 \(weekly.roundedRemainingPercent)%")
            }
            if let email = snapshot.email, !email.isEmpty {
                parts.append(ProviderHeaderView.compactAccountLabel(email))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func buildFooter() {
        footer.onToggleReminder = { [weak self] enabled in
            self?.pushReminderConfiguration { configuration in
                configuration.isEnabled = enabled
            }
        }
        footer.onRestoreReminders = { [weak self] in
            self?.onUnmuteAll?()
        }

        quotaPage.addArrangedSubview(makeHairline())
        quotaPage.addArrangedSubview(makeBlock(footer, top: 8, bottom: 10))
    }

    private func buildSettingsPage() {
        settingsPageView.onBack = { [weak self] in
            self?.setShowsSettings(false)
        }
        settingsPageView.onReminderEnabledChange = { [weak self] enabled in
            self?.pushReminderConfiguration { $0.isEnabled = enabled }
        }
        settingsPageView.onWarningPercentChange = { [weak self] value in
            self?.pushReminderConfiguration { $0.warningRemainingPercent = Double(value) }
        }
        settingsPageView.onResetSoonChange = { [weak self] value in
            // 0 表示关闭"重置还剩"提醒
            self?.pushReminderConfiguration { $0.resetSoonMinutes = TimeInterval(value) }
        }
        settingsPageView.onCooldownChange = { [weak self] value in
            self?.pushReminderConfiguration { $0.cooldown = TimeInterval(value * 60) }
        }
        settingsPageView.onRefreshIntervalChange = { [weak self] minutes in
            self?.onRefreshIntervalChange?(minutes)
        }
        settingsPageView.onRestoreDefaults = { [weak self] in
            self?.applyReminderConfiguration(.default)
            self?.onReminderConfigurationChange?(.default)
        }
        settingsPageView.onUnmuteAll = { [weak self] in
            self?.onUnmuteAll?()
        }

        syncControlStates()
    }

    /// 设置页/页脚改动统一入口：基于当前副本改字段后走回调链持久化。
    private func pushReminderConfiguration(_ mutate: (inout ReminderConfiguration) -> Void) {
        var configuration = reminderConfiguration
        mutate(&configuration)
        // 先更新面板副本，避免后续刷新或另一项设置把旧阈值重新写回。
        applyReminderConfiguration(configuration)
        onReminderConfigurationChange?(configuration)
    }

    private func syncControlStates() {
        footer.configure(reminder: reminderConfiguration, canRestore: canRestoreMuted)
        settingsPageView.configure(
            reminder: reminderConfiguration,
            refreshMinutes: refreshIntervalMinutes,
            canRestore: canRestoreMuted
        )
    }

    private func setShowsSettings(_ shows: Bool) {
        quotaPage.isHidden = shows
        settingsBlock.isHidden = !shows
        updatePreferredContentSize()
    }

    private func replayCodexState() {
        codexSection.apply(
            snapshot: lastCodexSnapshot,
            isRefreshing: lastCodexIsRefreshing,
            error: lastCodexError,
            accountLabel: accountLabelText
        )
    }

    // MARK: - 尺寸自适应

    /// 内容块加左右 12pt 内边距与上下自定义留白（对应原型各区块 padding）。
    /// 内容宽度钉常量：若让容器宽度由内容反推，"内容↔容器"宽度自引用会产生
    /// 歧义解，曾把顶栏撑出面板右缘（齿轮被裁掉）。
    private func makeBlock(_ content: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PanelTheme.contentInset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PanelTheme.contentInset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
            content.widthAnchor.constraint(equalToConstant: PanelTheme.contentWidth)
        ])
        return container
    }

    private func makeHairline() -> NSView {
        // 原型分隔线：--divider #26262A 的 1pt 实线，横贯面板全宽。
        // 宽度用固定常量：若约束到 quotaPage.width，stack 在 fittingSize 求解时
        // 宽度自引用会把全部内容高度坍缩成 0（弹窗变空白）。
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = PanelTheme.dividerColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: PanelTheme.panelWidth).isActive = true
        return line
    }

    private var quotaContentSize: NSSize {
        let contentHeight = ceil(pageContainer.fittingSize.height) + PanelTheme.contentInset
        return NSSize(width: PanelTheme.panelWidth, height: contentHeight)
    }

    private func updatePreferredContentSize() {
        guard isViewLoaded else { return }
        rootView.layoutSubtreeIfNeeded()
        let size = quotaContentSize
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        onPreferredContentSizeChange?()
    }
}


final class TouchBarHostingVisualEffectView: NSVisualEffectView, NSTouchBarDelegate {
    let touchBarQuotaView = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 370, height: 30))

    override var acceptsFirstResponder: Bool { true }

    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = .quotaBar
        bar.defaultItemIdentifiers = [.quotaPanel]
        bar.customizationAllowedItemIdentifiers = [.quotaPanel]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .quotaPanel else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.customizationLabel = "Codex 余额"
        item.view = touchBarQuotaView
        return item
    }
}

final class TouchBarQuotaView: NSView {
    var onMuteReminder: (() -> Void)?

    private let fiveHourRow = TouchBarQuotaRowView(title: "5H")
    private let weeklyRow = TouchBarQuotaRowView(title: "W")
    private let codexLabel = NSTextField(labelWithString: "Codex")
    private let emojiLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton(title: "不再提醒", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: QuotaSnapshot, reminder: ReminderPresentation) {
        emojiLabel.stringValue = reminder.emoji
        muteButton.isEnabled = reminder.isActive
        muteButton.alphaValue = reminder.isActive ? 1 : 0
        fiveHourRow.update(bucket: snapshot.fiveHour)
        weeklyRow.update(bucket: snapshot.weekly)
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        codexLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        codexLabel.textColor = .secondaryLabelColor
        codexLabel.alignment = .center
        codexLabel.lineBreakMode = .byClipping
        codexLabel.translatesAutoresizingMaskIntoConstraints = false

        emojiLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emojiLabel.alignment = .center
        emojiLabel.lineBreakMode = .byClipping
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        muteButton.bezelStyle = .rounded
        muteButton.font = .systemFont(ofSize: 10, weight: .medium)
        muteButton.target = self
        muteButton.action = #selector(muteReminderTapped)
        muteButton.isEnabled = false
        muteButton.alphaValue = 0
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [fiveHourRow, weeklyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [codexLabel, emojiLabel, stack, muteButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            codexLabel.widthAnchor.constraint(equalToConstant: 40),
            emojiLabel.widthAnchor.constraint(equalToConstant: 22),
            muteButton.widthAnchor.constraint(equalToConstant: 68),
            fiveHourRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            weeklyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fiveHourRow.heightAnchor.constraint(equalToConstant: 14),
            weeklyRow.heightAnchor.constraint(equalToConstant: 14),
            stack.widthAnchor.constraint(equalToConstant: 260)
        ])
    }

    @objc private func muteReminderTapped() {
        onMuteReminder?()
    }
}

final class TouchBarQuotaRowView: NSView {
    private let titleLabel: NSTextField
    private let barView = SegmentedBatteryBarView(segmentCount: 10)
    private let percentLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        setup()
        update(bucket: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(bucket: QuotaBucket?) {
        guard let bucket else {
            barView.percent = 0
            percentLabel.stringValue = "--%"
            resetLabel.stringValue = "--"
            return
        }

        titleLabel.stringValue = bucket.shortTitle
        barView.percent = bucket.remainingPercent
        percentLabel.stringValue = "\(bucket.roundedRemainingPercent)%"
        resetLabel.stringValue = formatCompactReset(bucket.resetsAt)
    }

    private func setup() {
        titleLabel.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = .labelColor
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .right

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        barView.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [titleLabel, barView, percentLabel, resetLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 24),
            percentLabel.widthAnchor.constraint(equalToConstant: 36),
            resetLabel.widthAnchor.constraint(equalToConstant: 48),
            barView.heightAnchor.constraint(equalToConstant: 6),
            barView.widthAnchor.constraint(equalToConstant: 128)
        ])
    }
}

final class SegmentedBatteryBarView: NSView {
    var percent: Double = 0 {
        didSet {
            percent = max(0, min(100, percent))
            needsDisplay = true
        }
    }

    /// 待生效（额度尚未启用）时整条用灰色，不按百分比上色。
    var isPending: Bool = false {
        didSet { needsDisplay = true }
    }

    private let segmentCount: Int

    init(segmentCount: Int) {
        self.segmentCount = max(1, segmentCount)
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 0, dy: 1)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let gap: CGFloat = 2
        let totalGap = CGFloat(segmentCount - 1) * gap
        let segmentWidth = max(1, (bounds.width - totalGap) / CGFloat(segmentCount))
        let filledSegments = Int((percent / 100 * Double(segmentCount)).rounded(.up))

        let backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35)
        let fillColor = isPending ? NSColor.systemGray : color(for: percent)

        for index in 0..<segmentCount {
            let x = bounds.minX + CGFloat(index) * (segmentWidth + gap)
            let rect = NSRect(x: x, y: bounds.minY, width: segmentWidth, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: min(2, rect.height / 2), yRadius: min(2, rect.height / 2))
            if index < filledSegments {
                fillColor.setFill()
            } else {
                backgroundColor.setFill()
            }
            path.fill()
        }
    }

    private func color(for percent: Double) -> NSColor {
        switch percent {
        case 0..<20:
            return NSColor.systemRed
        case 20..<50:
            return NSColor.systemYellow
        default:
            return NSColor.systemGreen
        }
    }
}

func formatReset(_ date: Date?) -> String {
    guard let date else { return "--" }

    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")

    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    if calendar.isDateInTomorrow(date) {
        formatter.dateFormat = "明天 HH:mm"
        return formatter.string(from: date)
    }

    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

func formatCompactReset(_ date: Date?) -> String {
    guard let date else { return "--" }

    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")

    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    if calendar.isDateInTomorrow(date) {
        formatter.dateFormat = "明HH:mm"
        return formatter.string(from: date)
    }

    formatter.dateFormat = "EHH"
    return formatter.string(from: date)
}

// MARK: - Entry point

@main
final class LocalQuotaBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
