import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexAppServerProtocolTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var sessions: [CodexAppServerSession] = []

    override func tearDownWithError() throws {
        for session in sessions {
            session.invalidate()
        }
        sessions.removeAll()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    /// 构造走假 app-server 的独立会话（不触碰 .shared 与真实 codex）。
    /// - Parameters:
    ///   - looping: true 时假服务循环应答（会话可跨请求复用进程）；
    ///     false 时应答一次后退出（EOF 驱动会话失效重拉）。
    ///   - runsLog: 每次进程启动追加一行 PID，用于断言复用/重拉次数。
    private func makeSession(response: String, looping: Bool = true, runsLog: URL? = nil) throws -> CodexAppServerSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let executable = directory.appendingPathComponent("app-server")
        var script = """
        #!/bin/bash
        set -eu
        """
        if let runsLog {
            script += "\necho $$ >> '\(runsLog.path)'"
        }
        script += """

        IFS= read -r initialize
        [[ "$initialize" == *'"method":"initialize"'* ]]

        # 旧客户端会在 initialize 响应前把后续请求写入管道；新客户端此时不应有数据。
        if IFS= read -r -t 0 premature; then
            exit 42
        fi

        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        [[ "$initialized" == *'"method":"initialized"'* ]]
        """
        if looping {
            script += """

            while IFS= read -r request; do
                [[ "$request" == *'"method":"account/'* ]]
                printf '%s\\n' '\(response)'
            done
            """
        } else {
            script += """

            IFS= read -r request
            [[ "$request" == *'"method":"account/'* ]]
            printf '%s\\n' '\(response)'
            """
        }
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let authJSON = directory.appendingPathComponent("auth.json")
        try Data(#"{"account_id":"test"}"#.utf8).write(to: authJSON)

        let session = CodexAppServerSession(
            executablePath: executable.path,
            authJSONPath: authJSON.path,
            requestTimeout: 5
        )
        sessions.append(session)
        return session
    }

    private func makeRunsLog() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerProtocolTests-runs-\(UUID().uuidString).log")
        temporaryDirectories.append(url.deletingLastPathComponent())
        return url
    }

    private func runsCount(_ url: URL) -> Int {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").filter { !$0.isEmpty }.count ?? 0
    }

    // MARK: - 协议顺序

    func testRateLimitReadWaitsForInitializeResponse() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988},"secondary":{"usedPercent":87,"windowDurationMins":10080,"resetsAt":1790508848},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}}}}"#
        let session = try makeSession(response: response)
        let client = CodexRateLimitClient(session: session)

        let snapshot = try await client.readRateLimits(planType: "plus")

        XCTAssertEqual(snapshot.creditBalance, 12.5)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 20)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 87)
    }

    func testUsageReadWaitsForInitializeResponse() async throws {
        let response = #"{"id":2,"result":{"dailyUsageBuckets":[{"startDate":"2026-09-24","tokens":42}]}}"#
        let session = try makeSession(response: response)
        let client = CodexUsageClient(session: session)

        let snapshot = try await client.readUsage()

        XCTAssertEqual(snapshot.days.map(\.tokens), [42])
    }

    // MARK: - 会话复用与重拉

    func testSessionReusesProcessAcrossRequests() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988}}}}"#
        let runsLog = try makeRunsLog()
        let session = try makeSession(response: response, runsLog: runsLog)
        let client = CodexRateLimitClient(session: session)

        _ = try await client.readRateLimits(planType: nil)
        _ = try await client.readRateLimits(planType: nil)

        XCTAssertEqual(runsCount(runsLog), 1, "两次请求必须复用同一子进程")
    }

    func testSessionRespawnsAfterConnectionDrops() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988}}}}"#
        let runsLog = try makeRunsLog()
        // 单发模式：应答一次后进程退出，下一次请求应透明重拉
        let session = try makeSession(response: response, looping: false, runsLog: runsLog)
        let client = CodexRateLimitClient(session: session)

        _ = try await client.readRateLimits(planType: nil)
        _ = try await client.readRateLimits(planType: nil)

        XCTAssertEqual(runsCount(runsLog), 2, "连接断开后应重拉一个新进程并完成请求")
    }

    func testSessionRespawnsWhenAuthStampChanges() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988}}}}"#
        let runsLog = try makeRunsLog()
        let session = try makeSession(response: response, runsLog: runsLog)

        _ = try session.send(id: 3, method: "account/rateLimits/read", params: NSNull())

        // 模拟切换账号：原子替换 auth.json（新 inode），戳变化应触发重拉
        let authURL = URL(fileURLWithPath: session.authJSONPath)
        let replacement = authURL.deletingLastPathComponent()
            .appendingPathComponent("auth-replacement-\(UUID().uuidString).json")
        try Data(#"{"account_id":"another"} extended padding"#.utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(authURL, withItemAt: replacement)

        _ = try session.send(id: 3, method: "account/rateLimits/read", params: NSNull())

        XCTAssertEqual(runsCount(runsLog), 2, "auth.json 变化后应重拉新进程读取新凭证")
    }

    func testEOFRemovesReadabilityHandlerAndStopsCallbacks() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988}}}}"#
        // 单发模式：应答一次后进程退出，stdout 进入 EOF
        let session = try makeSession(response: response, looping: false)

        _ = try session.send(id: 3, method: "account/rateLimits/read", params: NSNull())
        try await Task.sleep(nanoseconds: 500_000_000)
        let earlyCount = session.currentChildEOFCountForTesting ?? 0
        try await Task.sleep(nanoseconds: 500_000_000)
        let midCount = session.currentChildEOFCountForTesting ?? 0
        try await Task.sleep(nanoseconds: 300_000_000)
        let lateCount = session.currentChildEOFCountForTesting ?? 0

        // EOF 使 fd 永久可读：handler 若不自摘除会以空数据无限回调（自旋），
        // 计数会随时间持续增长。修复后最多 1 次且不再增长。
        XCTAssertLessThanOrEqual(earlyCount, 1)
        XCTAssertLessThanOrEqual(midCount, 1)
        XCTAssertEqual(midCount, lateCount, "EOF 回调计数应稳定，持续增长即自旋回归")

        // EOF 后会话仍应能透明重拉并正常服务
        _ = try session.send(id: 3, method: "account/rateLimits/read", params: NSNull())
    }

    func testHandshakeTimeoutThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        // 收到 initialize 后挂死不回包：握手超时（两轮启动重试均超时）
        let executable = directory.appendingPathComponent("app-server")
        let script = """
        #!/bin/bash
        read -r initialize
        sleep 30
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let session = CodexAppServerSession(
            executablePath: executable.path,
            authJSONPath: directory.appendingPathComponent("auth.json").path,
            requestTimeout: 0.5
        )
        sessions.append(session)

        do {
            _ = try session.send(id: 3, method: "account/rateLimits/read", params: NSNull())
            XCTFail("应抛出超时错误")
        } catch let error as CodexRateLimitError {
            guard case .timeout = error else {
                return XCTFail("期望 timeout，实际 \(error)")
            }
        }
    }
}
