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
    let issuedAt: Date?
    let expiresAt: Date?
}

enum ReminderLevel: Int, Comparable {
    case resetSoon = 1
    case warning = 2
    case critical = 3

    static func < (lhs: ReminderLevel, rhs: ReminderLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var emoji: String {
        switch self {
        case .critical: return "🚨"
        case .warning: return "⚠️"
        case .resetSoon: return "⏳"
        }
    }
}

struct ReminderPresentation: Equatable {
    let level: ReminderLevel?
    let affectedKinds: Set<QuotaKind>

    static let inactive = ReminderPresentation(level: nil, affectedKinds: [])

    var isActive: Bool {
        level != nil && !affectedKinds.isEmpty
    }

    var emoji: String {
        level?.emoji ?? ""
    }
}

struct ReminderConfiguration {
    var isEnabled: Bool
    var warningRemainingPercent: Double
    var criticalRemainingPercent: Double
    var resetSoonMinutes: TimeInterval
    var cooldown: TimeInterval

    static let `default` = ReminderConfiguration(
        isEnabled: true,
        warningRemainingPercent: 20,
        criticalRemainingPercent: 10,
        resetSoonMinutes: 30,
        cooldown: 10 * 60
    )
}

enum ReminderSettings {
    static let enabledKey = "local.codex.touchbar.quota.reminder.enabled"
    static let warningPercentKey = "local.codex.touchbar.quota.reminder.warningPercent"
    static let resetSoonMinutesKey = "local.codex.touchbar.quota.reminder.resetSoonMinutes"
    static let cooldownMinutesKey = "local.codex.touchbar.quota.reminder.cooldownMinutes"

    static func registerDefaults() {
        let defaults = ReminderConfiguration.default
        UserDefaults.standard.register(defaults: [
            enabledKey: defaults.isEnabled,
            warningPercentKey: defaults.warningRemainingPercent,
            resetSoonMinutesKey: defaults.resetSoonMinutes,
            cooldownMinutesKey: defaults.cooldown / 60
        ])
    }

    static func load() -> ReminderConfiguration {
        registerDefaults()
        return ReminderConfiguration(
            isEnabled: UserDefaults.standard.bool(forKey: enabledKey),
            warningRemainingPercent: UserDefaults.standard.double(forKey: warningPercentKey),
            criticalRemainingPercent: ReminderConfiguration.default.criticalRemainingPercent,
            resetSoonMinutes: UserDefaults.standard.double(forKey: resetSoonMinutesKey),
            cooldown: UserDefaults.standard.double(forKey: cooldownMinutesKey) * 60
        )
    }

    static func save(_ configuration: ReminderConfiguration) {
        UserDefaults.standard.set(configuration.isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(configuration.warningRemainingPercent, forKey: warningPercentKey)
        UserDefaults.standard.set(configuration.resetSoonMinutes, forKey: resetSoonMinutesKey)
        UserDefaults.standard.set(configuration.cooldown / 60, forKey: cooldownMinutesKey)
    }
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

    private struct AppServerResults {
        let rateLimits: [String: Any]?
        let account: [String: Any]?
    }

    private static func readAppServerResultsBlocking(
        appServerExecutablePath: String,
        requestTimeout: TimeInterval,
        shouldReadAccount: Bool,
        shouldReadRateLimits: Bool
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
        let collector = JSONLineResponseCollector(targetIDs: targetIDs)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
            }
        }

        // Drain stderr so the child process cannot block if it logs.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

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
            account: try collector.response(for: 2).map(result(from:))
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
            planType: planType,
            fetchedAt: Date()
        )
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

    private static func parseResetCreditCards(from result: [String: Any]) -> [ResetCreditCard]? {
        guard let summary = result["rateLimitResetCredits"] as? [String: Any],
              let credits = summary["credits"] as? [[String: Any]]
        else {
            return nil
        }

        return credits.compactMap { credit in
            guard let grantedAt = dateValue(credit["grantedAt"]) else { return nil }
            return ResetCreditCard(
                issuedAt: grantedAt,
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
    let refreshInterval: TimeInterval
    private(set) var reminderConfiguration: ReminderConfiguration

    private(set) var snapshot: QuotaSnapshot?
    private(set) var isRefreshing = false
    private(set) var reminder: ReminderPresentation = .inactive
    private var hasReadAccountPlan = false
    private var isReadingAccountPlan = false
    private var accountID = "unknown"
    private var cachedPlanType: String?
    private var timer: Timer?

    var onChange: ((QuotaSnapshot?, Bool, String?, ReminderPresentation) -> Void)?

    init(
        client: CodexRateLimitClient = CodexRateLimitClient(),
        // 额度变化不快，5 分钟自动刷新一次足够；手动刷新有 60 秒防重保护。
        refreshInterval: TimeInterval = 5 * 60,
        reminderConfiguration: ReminderConfiguration = ReminderSettings.load()
    ) {
        self.client = client
        self.refreshInterval = refreshInterval
        self.reminderConfiguration = reminderConfiguration
        // Show the last known quota immediately after relaunch; refresh will replace it.
        self.snapshot = SnapshotCache.load()
    }

    func start() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setAccountID(_ accountID: String?) {
        self.accountID = accountID ?? "unknown"
        hasReadAccountPlan = AccountPlanCache.contains(self.accountID)
        cachedPlanType = AccountPlanCache.planType(for: self.accountID)
        if hasReadAccountPlan {
            applyPlanType(cachedPlanType)
        } else {
            readAccountPlan()
        }
    }

    func refresh(force: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?(snapshot, true, nil, reminder)
        let cachedPlanType = self.cachedPlanType

        Task { @MainActor in
            do {
                let newSnapshot = try await client.readRateLimits(planType: cachedPlanType)
                snapshot = newSnapshot
                SnapshotCache.save(newSnapshot)
                reminder = evaluateReminder(for: newSnapshot, now: Date())
                isRefreshing = false
                onChange?(newSnapshot, false, nil, reminder)
            } catch {
                isRefreshing = false
                // Keep the old snapshot. Only surface the error text.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                onChange?(snapshot, false, message, reminder)
            }
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
            planType: planType,
            fetchedAt: snapshot.fetchedAt
        )
        self.snapshot = updatedSnapshot
        SnapshotCache.save(updatedSnapshot)
        onChange?(updatedSnapshot, isRefreshing, nil, reminder)
    }


    func muteCurrentReminder() {
        guard reminder.isActive, let snapshot else { return }

        for kind in reminder.affectedKinds {
            guard let bucket = snapshot.bucket(for: kind), let resetsAt = bucket.resetsAt else { continue }
            UserDefaults.standard.set(resetsAt.timeIntervalSince1970, forKey: mutedUntilKey(for: kind))
        }

        reminder = .inactive
        onChange?(snapshot, false, nil, reminder)
    }

    var canRestoreReminders: Bool {
        // 仅在用户点过“不再提醒”（静默本周期）后显示恢复入口，普通冷却不算。
        let now = Date()
        return [QuotaKind.fiveHour, QuotaKind.weekly].contains { kind in
            isMuted(kind: kind, now: now)
        }
    }

    func unmuteAll() {
        for kind in [QuotaKind.fiveHour, QuotaKind.weekly] {
            UserDefaults.standard.removeObject(forKey: mutedUntilKey(for: kind))
            UserDefaults.standard.removeObject(forKey: lastAlertKey(for: kind))
        }

        if let snapshot {
            reminder = evaluateReminder(for: snapshot, now: Date())
        } else {
            reminder = .inactive
        }

        onChange?(snapshot, isRefreshing, nil, reminder)
    }

    func updateReminderConfiguration(_ configuration: ReminderConfiguration) {
        reminderConfiguration = configuration
        ReminderSettings.save(configuration)

        if let snapshot {
            reminder = evaluateReminder(for: snapshot, now: Date(), recordAlert: false)
        } else {
            reminder = .inactive
        }

        onChange?(snapshot, isRefreshing, nil, reminder)
    }

    private func evaluateReminder(
        for snapshot: QuotaSnapshot,
        now: Date,
        recordAlert: Bool = true
    ) -> ReminderPresentation {
        guard TouchBarCapability.hasTouchBar, reminderConfiguration.isEnabled else { return .inactive }

        var bestLevel: ReminderLevel?
        var affectedKinds = Set<QuotaKind>()

        for kind in [QuotaKind.fiveHour, QuotaKind.weekly] {
            guard let bucket = snapshot.bucket(for: kind) else { continue }
            guard let level = triggerLevel(for: bucket, now: now) else { continue }
            guard !isMuted(kind: kind, now: now) else { continue }
            guard !isCoolingDown(kind: kind, now: now) else { continue }

            bestLevel = max(bestLevel ?? level, level)
            affectedKinds.insert(kind)
        }

        guard let bestLevel, !affectedKinds.isEmpty else { return .inactive }

        if recordAlert {
            for kind in affectedKinds {
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastAlertKey(for: kind))
            }
        }

        return ReminderPresentation(level: bestLevel, affectedKinds: affectedKinds)
    }

    private func triggerLevel(for bucket: QuotaBucket, now: Date) -> ReminderLevel? {
        if bucket.remainingPercent <= reminderConfiguration.criticalRemainingPercent {
            return .critical
        }

        if bucket.remainingPercent <= reminderConfiguration.warningRemainingPercent {
            return .warning
        }

        if reminderConfiguration.resetSoonMinutes > 0, let resetsAt = bucket.resetsAt {
            let minutesToReset = resetsAt.timeIntervalSince(now) / 60
            if minutesToReset >= 0 && minutesToReset <= reminderConfiguration.resetSoonMinutes {
                return .resetSoon
            }
        }

        return nil
    }

    private func isMuted(kind: QuotaKind, now: Date) -> Bool {
        let mutedUntil = UserDefaults.standard.double(forKey: mutedUntilKey(for: kind))
        return mutedUntil > now.timeIntervalSince1970
    }

    private func isCoolingDown(kind: QuotaKind, now: Date) -> Bool {
        let lastAlertAt = UserDefaults.standard.double(forKey: lastAlertKey(for: kind))
        guard lastAlertAt > 0 else { return false }
        return now.timeIntervalSince1970 - lastAlertAt < reminderConfiguration.cooldown
    }

    private func lastAlertKey(for kind: QuotaKind) -> String {
        "local.codex.touchbar.quota.\(kind.rawValue).lastAlertAt"
    }

    private func mutedUntilKey(for kind: QuotaKind) -> String {
        "local.codex.touchbar.quota.\(kind.rawValue).mutedUntilResetAt"
    }
}

private extension QuotaSnapshot {
    func bucket(for kind: QuotaKind) -> QuotaBucket? {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        }
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

// MARK: - System modal Touch Bar (private API, runtime-checked)

@MainActor
enum SystemModalTouchBar {
    private static let presentSelectorNames = [
        "presentSystemModalTouchBar:systemTrayItemIdentifier:",
        "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
    ]
    private static let dismissSelectorNames = [
        "dismissSystemModalTouchBar:",
        "dismissSystemModalFunctionBar:"
    ]

    static var isSupported: Bool {
        firstClassMethod(named: presentSelectorNames) != nil
            && firstClassMethod(named: dismissSelectorNames) != nil
    }

    static func present(_ touchBar: NSTouchBar) {
        guard let (selector, method) = firstClassMethod(named: presentSelectorNames) else { return }
        typealias PresentIMP = @convention(c) (AnyObject, Selector, NSTouchBar, AnyObject?) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: PresentIMP.self)
        imp(NSTouchBar.self, selector, touchBar, nil)
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        guard let (selector, method) = firstClassMethod(named: dismissSelectorNames) else { return }
        typealias DismissIMP = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: DismissIMP.self)
        imp(NSTouchBar.self, selector, touchBar)
    }

    private static func firstClassMethod(named selectorNames: [String]) -> (Selector, Method)? {
        for name in selectorNames {
            let selector = NSSelectorFromString(name)
            if let method = class_getClassMethod(NSTouchBar.self, selector) {
                return (selector, method)
            }
        }
        return nil
    }
}

@MainActor
final class TouchBarAlertPresenter: NSObject, NSTouchBarDelegate {
    static let displayDuration: TimeInterval = 12

    var onMute: (() -> Void)?

    private let quotaView = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 370, height: 30))
    private lazy var touchBar: NSTouchBar = {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.quotaPanel]
        return bar
    }()
    private var dismissTimer: Timer?
    private(set) var isPresenting = false

    override init() {
        super.init()
        quotaView.onMuteReminder = { [weak self] in
            self?.onMute?()
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .quotaPanel else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.customizationLabel = "Codex 余额"
        item.view = quotaView
        return item
    }

    func present(snapshot: QuotaSnapshot, reminder: ReminderPresentation) {
        quotaView.update(snapshot: snapshot, reminder: reminder)

        if !isPresenting {
            SystemModalTouchBar.present(touchBar)
            isPresenting = true
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard isPresenting else { return }
        isPresenting = false
        SystemModalTouchBar.dismiss(touchBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let quotaViewController = QuotaViewController()
    private let store = RateLimitStore()
    private let zaiStore = ZAIQuotaStore()
    private let authManager = CodexAuthManager()
    private let alertPresenter = TouchBarAlertPresenter()
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
        popover.animates = true
        popover.contentViewController = quotaViewController
        quotaViewController.onPreferredContentSizeChange = { [weak self] in
            guard let self else { return }
            self.popover.contentSize = self.quotaViewController.preferredContentSize
        }
        updateZAISectionVisibility()

        quotaViewController.onRefresh = { [weak self] in
            self?.store.refresh(force: true)
        }
        quotaViewController.onZAIRefresh = { [weak self] in
            self?.zaiStore.refresh()
        }
        quotaViewController.onMuteReminder = { [weak self] in
            self?.store.muteCurrentReminder()
            self?.alertPresenter.dismiss()
        }
        quotaViewController.onUnmuteAll = { [weak self] in
            self?.store.unmuteAll()
        }
        alertPresenter.onMute = { [weak self] in
            self?.store.muteCurrentReminder()
            self?.alertPresenter.dismiss()
        }
        quotaViewController.onReminderConfigurationChange = { [weak self] configuration in
            self?.store.updateReminderConfiguration(configuration)
        }
        quotaViewController.applyReminderConfiguration(store.reminderConfiguration)
        initializeAccountSwitcher()

        zaiStore.onChange = { [weak self] snapshot, account, isRefreshing, error in
            self?.quotaViewController.applyZAI(
                snapshot: snapshot,
                account: account,
                isRefreshing: isRefreshing,
                error: error
            )
        }
        quotaViewController.applyZAI(
            snapshot: zaiStore.snapshot,
            account: zaiStore.account,
            isRefreshing: zaiStore.isRefreshing,
            error: zaiStore.lastError
        )

        store.onChange = { [weak self] snapshot, isRefreshing, error, reminder in
            guard let self else { return }
            self.statusItem.button?.title = snapshot?.primaryStatusTitle ?? "Codex --%"
            self.quotaViewController.apply(
                snapshot: snapshot,
                isRefreshing: isRefreshing,
                error: error,
                reminder: reminder
            )
            self.quotaViewController.setUnmuteButtonVisible(self.store.canRestoreReminders)

            if TouchBarCapability.hasTouchBar, reminder.isActive && !isRefreshing, let snapshot {
                if SystemModalTouchBar.isSupported {
                    self.alertPresenter.present(snapshot: snapshot, reminder: reminder)
                } else {
                    self.showPopoverForReminder()
                }
            }
        }
        store.start()
    }

    private func initializeAccountSwitcher() {
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
        alertPresenter.dismiss()
        store.stop()
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

        let switchItem = NSMenuItem(title: "切换账号", action: nil, keyEquivalent: "")
        switchItem.submenu = makeAccountSubmenu()
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
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
            item.isEnabled = true
            submenu.addItem(item)
        }

        return submenu
    }

    @objc private func accountMenuItemSelected(_ sender: NSMenuItem) {
        guard let fileName = sender.representedObject as? String else { return }
        do {
            try authManager.switchAccount(to: fileName)
            initializeAccountSwitcher()
            quotaViewController.showAccountSwitchStatus("已切换账号，正在刷新…")
            store.refresh(force: true)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            quotaViewController.showAccountSwitchStatus(message)
        }
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    private func showPopoverForReminder() {
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)
        updateZAISectionVisibility()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // NSPopover 首次加载 view 后会重新取一次 preferredContentSize，这里再设一次避免底部被裁切。
            popover.contentSize = quotaViewController.preferredContentSize
        }
        if ZAISettings.isZAIDomain() {
            zaiStore.refreshIfNeeded()
        }
        quotaViewController.focusTouchBarHost()
    }

    private func updateZAISectionVisibility() {
        quotaViewController.setZAISectionVisible(ZAISettings.isZAIDomain())
        popover.contentSize = quotaViewController.preferredContentSize
    }
}

final class QuotaViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onZAIRefresh: (() -> Void)?
    var onPreferredContentSizeChange: (() -> Void)?
    var onMuteReminder: (() -> Void)?
    var onUnmuteAll: (() -> Void)?
    var onReminderConfigurationChange: ((ReminderConfiguration) -> Void)?

    private let rootView = TouchBarHostingVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Codex 余额")
    private let accountLabel = NSTextField(labelWithString: "")
    private let accountPlanTag = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "等待刷新")
    private let fiveHourRow = QuotaRowView(title: "5小时")
    private let weeklyRow = QuotaRowView(title: "周限额")
    private let zaiTitleLabel = NSTextField(labelWithString: "Z.AI 余额")
    private let zaiEmailLabel = NSTextField(labelWithString: "")
    private let zaiLevelTag = NSTextField(labelWithString: "")
    private let zaiStatusLabel = NSTextField(labelWithString: "等待刷新")
    private let zaiRefreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let zaiRows = [
        // 标题列加宽以容纳模型名（如 GLM-5-Turbo），放不下时截断并靠 tooltip 显示全名。
        QuotaRowView(title: "小时", titleWidth: 80, detailWidth: 160, barMinWidth: 156),
        QuotaRowView(title: "周", titleWidth: 80, detailWidth: 160, barMinWidth: 156)
    ]
    private let zaiResetCreditsTitleLabel = NSTextField(labelWithString: "可用重置次数：")
    private let zaiResetCreditsValueLabel = NSTextField(labelWithString: "--")
    private let zaiResetCreditsExpirationButton = NSButton(title: "过期时间", target: nil, action: nil)
    private lazy var zaiResetCreditsRow = makeZAIResetCreditsRow()
    private var currentZAIResetCreditCards: [ZAIResetCreditCard]?
    private lazy var zaiSection = makeZAISection()
    private var shouldShowZAISection = false
    private var contentStack: NSStackView?
    private let resetCreditsTitleLabel = NSTextField(labelWithString: "可用重置次数：")
    private let resetCreditsValueLabel = NSTextField(labelWithString: "--")
    private let resetCreditsExpirationButton = NSButton(title: "过期时间", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private var refreshCooldownTimer: Timer?
    private var zaiRefreshCooldownTimer: Timer?
    private var currentResetCreditCount = 0
    private var currentResetCreditCards: [ResetCreditCard]?
    private let reminderEnabledButton = NSButton(checkboxWithTitle: "主动 Touch Bar 提醒", target: nil, action: nil)
    private let warningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resetSoonPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cooldownPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let unmuteButton = NSButton(title: "恢复提醒", target: nil, action: nil)
    private let restoreDefaultsButton = NSButton(title: "恢复默认", target: nil, action: nil)

    override func loadView() {
        rootView.material = .popover
        rootView.blendingMode = .withinWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 14
        rootView.layer?.masksToBounds = true
        rootView.touchBarQuotaView.onMuteReminder = { [weak self] in
            self?.onMuteReminder?()
        }
        view = rootView
        // 无 Touch Bar 机型只显示额度，不显示提醒设置。
        preferredContentSize = quotaContentSize

        configureSubviews()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusTouchBarHost()
    }

    func focusTouchBarHost() {
        view.window?.makeFirstResponder(rootView)
        rootView.touchBar = rootView.makeTouchBar()
    }

    func setUnmuteButtonVisible(_ visible: Bool) {
        unmuteButton.isHidden = !visible
    }

    func setZAISectionVisible(_ visible: Bool) {
        shouldShowZAISection = visible
        if isViewLoaded {
            zaiSection.isHidden = !visible
        }
        updatePreferredContentSize()
    }

    func applyZAI(snapshot: ZAIQuotaSnapshot?, account: ZAIAccount?, isRefreshing: Bool, error: String?) {
        guard shouldShowZAISection else { return }

        // setting.json 是当前事实；快照可能还是切换账号/套餐前的旧缓存，
        // 刷新失败展示旧数据时 tag 也要跟本地配置走。
        let selection = ZAISettings.resolveProviderSelection()
        let kind = selection?.kind ?? snapshot?.kind ?? .codingPlan

        setLabelText(zaiTitleLabel, selection?.domain == "bigmodel" ? "BigModel 余额" : "Z.AI 余额")
        setLabelText(zaiEmailLabel, account?.email ?? snapshot?.email ?? "")
        zaiEmailLabel.isHidden = zaiEmailLabel.stringValue.isEmpty

        switch kind {
        case .apiKey:
            let suffix = snapshot?.apiKeySuffix.map { " ····\($0)" } ?? ""
            setLabelText(zaiLevelTag, "API Key\(suffix)")
            zaiLevelTag.backgroundColor = .systemGray
            zaiLevelTag.toolTip = "API Key 模式，无余额数据"
            zaiRows.forEach { $0.isHidden = true }
            zaiResetCreditsRow.isHidden = true
        case .startPlan:
            // tag 显示 name（如 "ZCode Start Plan"）；description（如 "GLM-5.3 周末活动"）可能过长，放 tooltip。
            let planName = snapshot?.planName.flatMap { $0.isEmpty ? nil : $0 } ?? "体验套餐"
            setLabelText(zaiLevelTag, planName)
            zaiLevelTag.backgroundColor = .systemGreen
            zaiLevelTag.toolTip = snapshot?.planDescription.flatMap { $0.isEmpty ? nil : $0 }
                ?? snapshot?.planName.flatMap { $0.isEmpty ? nil : $0 }
            let balances = (snapshot?.balances ?? []).prefix(zaiRows.count)
            for (index, row) in zaiRows.enumerated() {
                if index < balances.count {
                    row.update(balance: balances[index])
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
            zaiResetCreditsRow.isHidden = true
        case .codingPlan:
            setLabelText(zaiLevelTag, snapshot?.level ?? "")
            zaiLevelTag.backgroundColor = .systemBlue
            let limits = snapshot?.limits ?? []
            let zaiUnits: [ZAILimit.WindowUnit] = [.hourly, .weekly]
            for (unit, row) in zip(zaiUnits, zaiRows) {
                row.update(limit: limits.first { $0.unit == unit })
                row.isHidden = false
            }
            zaiResetCreditsRow.isHidden = false
            updateZAIResetCredits(snapshot?.resetCreditCards)
        }
        zaiLevelTag.isHidden = zaiLevelTag.stringValue.isEmpty

        if kind == .apiKey {
            setLabelText(zaiStatusLabel, "API Key 模式，无余额数据")
        } else if isRefreshing {
            setLabelText(zaiStatusLabel, snapshot.map { "刷新中（上次更新 \(Self.formatFetchedAt($0.fetchedAt))）…" } ?? "刷新中…")
        } else if let error {
            setLabelText(zaiStatusLabel, snapshot.map { "刷新失败，显示 \(Self.formatFetchedAt($0.fetchedAt)) 数据 · \(error)" } ?? "刷新失败：\(error)")
        } else if let snapshot {
            setLabelText(zaiStatusLabel, "更新：\(Self.formatFetchedAt(snapshot.fetchedAt))")
        } else {
            setLabelText(zaiStatusLabel, "暂无数据")
        }
        updatePreferredContentSize()
    }

    func showAccountSwitchStatus(_ message: String) {
        setLabelText(statusLabel, message)
    }

    func setAccountLabel(_ text: String?) {
        setLabelText(accountLabel, text ?? "")
        accountLabel.isHidden = text == nil
    }

    /// 设置文本并同步 toolTip：文本被截断时，鼠标悬停可查看完整内容（类似 Web 的 title）。
    private func setLabelText(_ label: NSTextField, _ text: String) {
        label.stringValue = text
        label.toolTip = text
    }

    private func showResetCreditExpirations(_ cards: [ResetCreditCard]) {
        let alert = NSAlert()
        alert.messageText = "重置卡过期时间"
        if cards.isEmpty {
            alert.informativeText = "没有查到可展示的重置卡过期时间。"
        } else {
            alert.accessoryView = Self.makeResetCreditExpirationList(cards)
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func apply(
        snapshot: QuotaSnapshot?,
        isRefreshing: Bool,
        error: String?,
        reminder: ReminderPresentation
    ) {
        if let snapshot {
            fiveHourRow.update(bucket: snapshot.fiveHour)
            weeklyRow.update(bucket: snapshot.weekly)
            updateResetCredits(snapshot.resetCreditCount, cards: snapshot.resetCreditCards)
            rootView.touchBarQuotaView.update(snapshot: snapshot, reminder: reminder)
        }
        accountPlanTag.stringValue = snapshot?.planType ?? ""
        accountPlanTag.isHidden = accountPlanTag.stringValue.isEmpty

        if isRefreshing {
            if let snapshot {
                setLabelText(statusLabel, "刷新中（上次更新 \(Self.formatFetchedAt(snapshot.fetchedAt))）…")
            } else {
                setLabelText(statusLabel, "正在读取 ChatGPT app-server…")
            }
        } else if let error {
            if let snapshot {
                setLabelText(statusLabel, "刷新失败，显示 \(Self.formatFetchedAt(snapshot.fetchedAt)) 数据 · \(error)")
            } else {
                setLabelText(statusLabel, "刷新失败：\(error)")
            }
        } else if let snapshot {
            setLabelText(statusLabel, "更新：\(Self.formatFetchedAt(snapshot.fetchedAt))")
        } else {
            setLabelText(statusLabel, "暂无数据")
        }
    }

    private func configureSubviews() {
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        accountLabel.font = .systemFont(ofSize: 11, weight: .regular)
        accountLabel.textColor = .secondaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingMiddle
        accountLabel.isHidden = accountLabel.stringValue.isEmpty

        accountPlanTag.font = .systemFont(ofSize: 10, weight: .semibold)
        accountPlanTag.textColor = .white
        accountPlanTag.alignment = .center
        accountPlanTag.drawsBackground = true
        accountPlanTag.backgroundColor = .systemBlue
        accountPlanTag.wantsLayer = true
        accountPlanTag.layer?.cornerRadius = 4
        accountPlanTag.layer?.masksToBounds = true
        accountPlanTag.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        resetCreditsTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        resetCreditsTitleLabel.textColor = .labelColor
        resetCreditsValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        resetCreditsValueLabel.textColor = .labelColor
        resetCreditsValueLabel.alignment = .left

        resetCreditsExpirationButton.bezelStyle = .rounded
        resetCreditsExpirationButton.controlSize = .small
        resetCreditsExpirationButton.font = .systemFont(ofSize: 11)
        resetCreditsExpirationButton.target = self
        resetCreditsExpirationButton.action = #selector(showResetCreditExpirationsTapped)
        updateResetCreditsExpirationButton()

        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = "手动刷新（60 秒内只能刷新一次）"
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        if TouchBarCapability.hasTouchBar {
            configureReminderControls()
        }

        let titleLine = NSStackView(views: [titleLabel, accountLabel, accountPlanTag])
        titleLine.orientation = .horizontal
        titleLine.alignment = .lastBaseline
        titleLine.spacing = 8

        let headerLeftStack = NSStackView(views: [titleLine, statusLabel])
        headerLeftStack.orientation = .vertical
        headerLeftStack.alignment = .leading
        headerLeftStack.spacing = 2

        let headerRightStack = NSStackView(views: [refreshButton])
        headerRightStack.orientation = .horizontal
        headerRightStack.alignment = .centerY
        headerRightStack.spacing = 8

        let header = NSStackView(views: [headerLeftStack, NSView(), headerRightStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let resetCreditsRow = makeResetCreditsRow()
        let rows = NSStackView(views: [fiveHourRow, weeklyRow, resetCreditsRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4

        var contentViews: [NSView] = [header, rows]
        if TouchBarCapability.hasTouchBar {
            contentViews.append(makeSettingsView())
        }
        contentViews.append(zaiSection)

        let content = NSStackView(views: contentViews)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        contentStack = content

        rootView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            content.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: 424),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
            zaiSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            resetCreditsRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            titleLine.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            accountLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            accountPlanTag.widthAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        updatePreferredContentSize()
    }

    private var quotaContentSize: NSSize {
        let fallbackHeight: CGFloat = TouchBarCapability.hasTouchBar ? 248 : 158
        let contentHeight = contentStack.map { ceil($0.fittingSize.height) + 24 } ?? fallbackHeight
        return NSSize(width: 460, height: contentHeight)
    }

    private func updatePreferredContentSize() {
        guard isViewLoaded else {
            preferredContentSize = quotaContentSize
            return
        }
        rootView.layoutSubtreeIfNeeded()
        preferredContentSize = quotaContentSize
        onPreferredContentSizeChange?()
    }

    private func makeZAISection() -> NSView {
        zaiTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        zaiEmailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        zaiEmailLabel.textColor = .secondaryLabelColor
        zaiEmailLabel.lineBreakMode = .byTruncatingMiddle

        zaiLevelTag.font = .systemFont(ofSize: 10, weight: .semibold)
        zaiLevelTag.textColor = .white
        zaiLevelTag.alignment = .center
        zaiLevelTag.drawsBackground = true
        zaiLevelTag.backgroundColor = .systemBlue
        zaiLevelTag.wantsLayer = true
        zaiLevelTag.layer?.cornerRadius = 4
        zaiLevelTag.layer?.masksToBounds = true

        zaiStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        zaiStatusLabel.textColor = .secondaryLabelColor
        zaiStatusLabel.lineBreakMode = .byTruncatingTail

        zaiRefreshButton.bezelStyle = .rounded
        zaiRefreshButton.toolTip = "手动刷新（60 秒内只能刷新一次）"
        zaiRefreshButton.target = self
        zaiRefreshButton.action = #selector(zaiRefreshTapped)

        zaiResetCreditsTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        zaiResetCreditsTitleLabel.textColor = .labelColor
        zaiResetCreditsValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zaiResetCreditsValueLabel.textColor = .labelColor
        zaiResetCreditsValueLabel.alignment = .left

        zaiResetCreditsExpirationButton.bezelStyle = .rounded
        zaiResetCreditsExpirationButton.controlSize = .small
        zaiResetCreditsExpirationButton.font = .systemFont(ofSize: 11)
        zaiResetCreditsExpirationButton.toolTip = "查看每张重置额度的过期时间"
        zaiResetCreditsExpirationButton.target = self
        zaiResetCreditsExpirationButton.action = #selector(showZAIResetCreditExpirationsTapped)
        zaiResetCreditsExpirationButton.isHidden = true

        let titleLine = NSStackView(views: [zaiTitleLabel, zaiEmailLabel, zaiLevelTag, NSView()])
        titleLine.orientation = .horizontal
        titleLine.alignment = .lastBaseline
        titleLine.spacing = 8

        let headerLeft = NSStackView(views: [titleLine, zaiStatusLabel])
        headerLeft.orientation = .vertical
        headerLeft.alignment = .leading
        headerLeft.spacing = 2

        let header = NSStackView(views: [headerLeft, NSView(), zaiRefreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let rows = NSStackView(views: zaiRows + [zaiResetCreditsRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4

        let divider = NSBox()
        divider.boxType = .separator

        let section = NSStackView(views: [divider, header, rows])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.isHidden = !shouldShowZAISection

        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 424),
            header.widthAnchor.constraint(equalToConstant: 424),
            titleLine.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            zaiEmailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 210),
            zaiLevelTag.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            zaiRefreshButton.widthAnchor.constraint(equalToConstant: 64),
            rows.widthAnchor.constraint(equalToConstant: 424)
        ])

        return section
    }

    private func makeResetCreditsRow() -> NSStackView {
        let row = NSStackView(views: [resetCreditsTitleLabel, resetCreditsValueLabel, resetCreditsExpirationButton, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 20),
            resetCreditsTitleLabel.widthAnchor.constraint(equalToConstant: 108),
            resetCreditsValueLabel.widthAnchor.constraint(equalToConstant: 32),
            resetCreditsExpirationButton.widthAnchor.constraint(equalToConstant: 76)
        ])

        return row
    }

    private func updateResetCredits(_ count: Int?, cards: [ResetCreditCard]?) {
        currentResetCreditCount = count ?? 0
        currentResetCreditCards = cards
        resetCreditsValueLabel.stringValue = count.map(String.init) ?? "--"
        updateResetCreditsExpirationButton()
    }

    private func updateResetCreditsExpirationButton() {
        resetCreditsExpirationButton.isHidden = currentResetCreditCount <= 0
    }

    @objc private func showResetCreditExpirationsTapped() {
        showResetCreditExpirations(currentResetCreditCards ?? [])
    }

    // MARK: ZAI 重置额度（coding-plan）

    private func makeZAIResetCreditsRow() -> NSStackView {
        let row = NSStackView(views: [zaiResetCreditsTitleLabel, zaiResetCreditsValueLabel, zaiResetCreditsExpirationButton, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 20),
            zaiResetCreditsTitleLabel.widthAnchor.constraint(equalToConstant: 108),
            zaiResetCreditsValueLabel.widthAnchor.constraint(equalToConstant: 32),
            zaiResetCreditsExpirationButton.widthAnchor.constraint(equalToConstant: 76)
        ])

        return row
    }

    private func updateZAIResetCredits(_ cards: [ZAIResetCreditCard]?) {
        currentZAIResetCreditCards = cards
        zaiResetCreditsValueLabel.stringValue = cards.map { String($0.count) } ?? "--"
        zaiResetCreditsExpirationButton.isHidden = (cards?.count ?? 0) <= 0
    }

    @objc private func showZAIResetCreditExpirationsTapped() {
        let alert = NSAlert()
        alert.messageText = "重置额度过期时间"
        let cards = currentZAIResetCreditCards ?? []
        if cards.isEmpty {
            alert.informativeText = "没有查到可展示的重置额度过期时间。"
        } else {
            alert.accessoryView = Self.makeZAIResetCreditExpirationList(cards)
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func makeZAIResetCreditExpirationList(_ cards: [ZAIResetCreditCard]) -> NSView {
        let now = Date()
        let warningInterval: TimeInterval = 7 * 24 * 60 * 60
        let listWidth: CGFloat = 320
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, card) in cards.enumerated() {
            let line = "\(index + 1). \(card.kind.title) · 过期 \(formatCompactDateTime(card.expiresAt))"
            let expiresSoon = card.expiresAt.map { $0.timeIntervalSince(now) < warningInterval } ?? false
            let label = NSTextField(labelWithString: line)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = expiresSoon ? .systemRed : .labelColor
            label.alignment = .center
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: listWidth).isActive = true
        }

        let listHeight = min(CGFloat(cards.count * 22), 180)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: listWidth, height: listHeight))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = cards.count > 8
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: listWidth),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(cards.count * 20))
        ])

        return scrollView
    }

    @objc private func refreshTapped() {
        guard refreshButton.isEnabled else { return }
        // 手动刷新 60 秒防重：点击后禁用按钮一分钟。
        refreshButton.isEnabled = false
        refreshCooldownTimer?.invalidate()
        refreshCooldownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshButton.isEnabled = true
            }
        }
        onRefresh?()
    }

    @objc private func zaiRefreshTapped() {
        guard zaiRefreshButton.isEnabled else { return }
        // 与 Codex 刷新一致：手动请求也在 60 秒内防重。
        zaiRefreshButton.isEnabled = false
        zaiRefreshCooldownTimer?.invalidate()
        zaiRefreshCooldownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.zaiRefreshButton.isEnabled = true
            }
        }
        onZAIRefresh?()
    }

    @objc fileprivate func muteReminderTapped() {
        onMuteReminder?()
    }

    @objc private func reminderControlChanged() {
        onReminderConfigurationChange?(currentReminderConfiguration())
    }

    @objc private func unmuteAllTapped() {
        onUnmuteAll?()
    }

    @objc private func restoreDefaultsTapped() {
        applyReminderConfiguration(.default)
        onReminderConfigurationChange?(currentReminderConfiguration())
    }

    private static func formatFetchedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func formatDateTime(_ date: Date?) -> String {
        formatDate(date, dateFormat: "yyyy-MM-dd HH:mm:ss")
    }

    private static func formatCompactDateTime(_ date: Date?) -> String {
        formatDate(date, dateFormat: "MM-dd HH:mm:ss")
    }

    private static func formatDate(_ date: Date?, dateFormat: String) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    private static func makeResetCreditExpirationList(_ cards: [ResetCreditCard]) -> NSView {
        let now = Date()
        let warningInterval: TimeInterval = 7 * 24 * 60 * 60
        let listWidth: CGFloat = 320
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, card) in cards.enumerated() {
            let line = "\(index + 1). 发放 \(formatCompactDateTime(card.issuedAt))  过期 \(formatCompactDateTime(card.expiresAt))"
            let expiresSoon = card.expiresAt.map { $0.timeIntervalSince(now) < warningInterval } ?? false
            let label = NSTextField(labelWithString: line)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = expiresSoon ? .systemRed : .labelColor
            label.alignment = .center
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: listWidth).isActive = true
        }

        let listHeight = min(CGFloat(cards.count * 22), 180)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: listWidth, height: listHeight))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = cards.count > 8
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: listWidth),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(cards.count * 20))
        ])

        return scrollView
    }

    func applyReminderConfiguration(_ configuration: ReminderConfiguration) {
        reminderEnabledButton.state = configuration.isEnabled ? .on : .off
        selectPopupItem(warningPopup, representedValue: Int(configuration.warningRemainingPercent))
        selectPopupItem(resetSoonPopup, representedValue: Int(configuration.resetSoonMinutes))
        selectPopupItem(cooldownPopup, representedValue: Int(configuration.cooldown / 60))
    }

    private func configureReminderControls() {
        reminderEnabledButton.target = self
        reminderEnabledButton.action = #selector(reminderControlChanged)
        reminderEnabledButton.font = .systemFont(ofSize: 12, weight: .medium)

        unmuteButton.bezelStyle = .rounded
        unmuteButton.controlSize = .small
        unmuteButton.font = .systemFont(ofSize: 11)
        unmuteButton.toolTip = "撤销“不再提醒”并清除冷却，本周期内重新允许提醒"
        unmuteButton.target = self
        unmuteButton.action = #selector(unmuteAllTapped)
        unmuteButton.isHidden = true

        restoreDefaultsButton.bezelStyle = .rounded
        restoreDefaultsButton.controlSize = .small
        restoreDefaultsButton.font = .systemFont(ofSize: 11)
        restoreDefaultsButton.toolTip = "恢复提醒设置为默认值：开启、额度低于 20%、重置还剩 30 分钟、提醒间隔 10 分钟"
        restoreDefaultsButton.target = self
        restoreDefaultsButton.action = #selector(restoreDefaultsTapped)

        configurePopup(
            warningPopup,
            items: [
                ("50%", 50), ("40%", 40), ("30%", 30), ("20%", 20), ("10%", 10)
            ]
        )
        configurePopup(
            resetSoonPopup,
            items: [
                ("50 分钟", 50), ("40 分钟", 40), ("30 分钟", 30), ("20 分钟", 20), ("10 分钟", 10), ("关闭", 0)
            ]
        )
        configurePopup(
            cooldownPopup,
            items: [
                ("5 分钟", 5), ("10 分钟", 10), ("15 分钟", 15), ("30 分钟", 30), ("60 分钟", 60)
            ]
        )

        applyReminderConfiguration(ReminderSettings.load())
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, Int)]) {
        popup.removeAllItems()
        popup.font = .systemFont(ofSize: 11)
        popup.target = self
        popup.action = #selector(reminderControlChanged)

        for item in items {
            popup.addItem(withTitle: item.0)
            popup.lastItem?.representedObject = item.1
        }
    }

    private func makeSettingsView() -> NSView {
        let title = NSTextField(labelWithString: "提醒设置")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let lowRow = makeSettingRow(label: "额度低于", control: warningPopup)
        let resetRow = makeSettingRow(label: "重置还剩", control: resetSoonPopup)
        let cooldownRow = makeSettingRow(label: "提醒间隔", control: cooldownPopup)

        let titleLine = NSStackView(views: [title, NSView()])
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = 8

        let firstLine = NSStackView(views: [reminderEnabledButton, NSView(), unmuteButton, restoreDefaultsButton])
        firstLine.orientation = .horizontal
        firstLine.alignment = .centerY
        firstLine.spacing = 8

        let secondLine = NSStackView(views: [lowRow, NSView(), resetRow])
        secondLine.orientation = .horizontal
        secondLine.alignment = .centerY
        secondLine.spacing = 10

        let thirdLine = NSStackView(views: [cooldownRow, NSView()])
        thirdLine.orientation = .horizontal
        thirdLine.alignment = .centerY
        thirdLine.spacing = 10

        let stack = NSStackView(views: [titleLine, firstLine, secondLine, thirdLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLine.widthAnchor.constraint(equalToConstant: 424),
            firstLine.widthAnchor.constraint(equalToConstant: 424),
            secondLine.widthAnchor.constraint(equalToConstant: 424),
            thirdLine.widthAnchor.constraint(equalToConstant: 424)
        ])

        return stack
    }

    private func makeSettingRow(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 11)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .right

        let stack = NSStackView(views: [labelView, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: 86)
        ])

        return stack
    }

    private func currentReminderConfiguration() -> ReminderConfiguration {
        ReminderConfiguration(
            isEnabled: reminderEnabledButton.state == .on,
            warningRemainingPercent: Double(selectedIntValue(warningPopup)),
            criticalRemainingPercent: ReminderConfiguration.default.criticalRemainingPercent,
            resetSoonMinutes: TimeInterval(selectedIntValue(resetSoonPopup)),
            cooldown: TimeInterval(selectedIntValue(cooldownPopup) * 60)
        )
    }

    private func selectPopupItem(_ popup: NSPopUpButton, representedValue: Int) {
        var nearestItem: NSMenuItem?
        var nearestDistance = Int.max

        for item in popup.itemArray {
            guard let value = item.representedObject as? Int else { continue }
            if value == representedValue {
                popup.select(item)
                return
            }
            let distance = abs(value - representedValue)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestItem = item
            }
        }

        // Stored value may come from an older option list; fall back to the closest one.
        if let nearestItem {
            popup.select(nearestItem)
        }
    }

    private func selectedIntValue(_ popup: NSPopUpButton) -> Int {
        popup.selectedItem?.representedObject as? Int ?? 0
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

final class QuotaRowView: NSView {
    private let placeholderTitle: String
    private let titleLabel: NSTextField
    private let barView = SegmentedBatteryBarView(segmentCount: 28)
    private let detailLabel: NSTextField
    private let titleWidth: CGFloat
    private let detailWidth: CGFloat
    private let barMinWidth: CGFloat

    init(title: String, titleWidth: CGFloat = 52, detailWidth: CGFloat = 112, barMinWidth: CGFloat = 220) {
        self.placeholderTitle = title
        self.titleLabel = NSTextField(labelWithString: title)
        self.detailLabel = NSTextField(labelWithString: "--% · --")
        self.titleWidth = titleWidth
        self.detailWidth = detailWidth
        self.barMinWidth = barMinWidth
        super.init(frame: .zero)
        setup()
        update(bucket: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 标题可能被截断（如 GLM-5-Turbo），悬停显示完整文本。
    private func setRowTitle(_ text: String) {
        titleLabel.stringValue = text
        titleLabel.toolTip = text
    }

    func update(bucket: QuotaBucket?) {
        guard let bucket else {
            setRowTitle(placeholderTitle)
            barView.percent = 0
            detailLabel.stringValue = "--% · --"
            detailLabel.toolTip = nil
            return
        }

        setRowTitle(bucket.title)
        barView.percent = bucket.remainingPercent
        detailLabel.stringValue = "\(bucket.roundedRemainingPercent)% · \(formatReset(bucket.resetsAt))"
    }

    func update(limit: ZAILimit?) {
        guard let limit else {
            setRowTitle(placeholderTitle)
            barView.percent = 0
            detailLabel.stringValue = "--% · --"
            detailLabel.toolTip = nil
            return
        }

        setRowTitle(limit.title)
        barView.percent = limit.remainingPercent
        detailLabel.stringValue = "\(limit.roundedRemainingPercent)% · \(formatReset(limit.nextResetTime))"
    }

    /// 体验套餐余额行：电量条按剩余/总量，detail 显示绝对 token 数与到期时间。
    func update(balance: ZAIBalance?) {
        guard let balance else {
            setRowTitle(placeholderTitle)
            barView.percent = 0
            detailLabel.stringValue = "-- · --"
            detailLabel.toolTip = nil
            return
        }

        setRowTitle(balance.title)
        barView.percent = balance.remainingFraction * 100
        detailLabel.stringValue = "\(Self.formatTokenCount(balance.remainingUnits))/\(Self.formatTokenCount(balance.totalUnits)) · \(formatReset(balance.expiresAt))"
        let used = Self.formatTokenCount(max(balance.totalUnits - balance.remainingUnits, 0))
        let periodText = balance.isDaily ? "每日额度" : "一次性额度"
        let verb = balance.isDaily ? "重置" : "到期"
        detailLabel.toolTip = "\(balance.title) · \(periodText)，\(formatReset(balance.expiresAt)) \(verb)（已用 \(used)）"
    }

    /// token 数格式化：100000000 → "100.0M"。
    static func formatTokenCount(_ value: Double) -> String {
        switch value {
        case 1e9...: return String(format: "%.1fB", value / 1e9)
        case 1e6...: return String(format: "%.1fM", value / 1e6)
        case 1e3...: return String(format: "%.1fK", value / 1e3)
        default: return String(format: "%.0f", value)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.cell?.wraps = false

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = .labelColor
        detailLabel.alignment = .right

        barView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [titleLabel, barView, detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            titleLabel.widthAnchor.constraint(equalToConstant: titleWidth),
            detailLabel.widthAnchor.constraint(equalToConstant: detailWidth),
            barView.heightAnchor.constraint(equalToConstant: 12),
            barView.widthAnchor.constraint(greaterThanOrEqualToConstant: barMinWidth)
        ])
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
        let fillColor = color(for: percent)

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

private func formatReset(_ date: Date?) -> String {
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

private func formatCompactReset(_ date: Date?) -> String {
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
final class CodexTouchBarQuotaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
