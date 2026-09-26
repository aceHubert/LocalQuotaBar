import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexAppServerProtocolTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testRateLimitReadWaitsForInitializeResponse() async throws {
        let response = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1790246988},"secondary":{"usedPercent":87,"windowDurationMins":10080,"resetsAt":1790508848},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}}}}"#
        let client = CodexRateLimitClient(
            appServerExecutablePath: try makeAppServer(response: response),
            requestTimeout: 2
        )

        let snapshot = try await client.readRateLimits(planType: "plus")

        XCTAssertEqual(snapshot.creditBalance, 12.5)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 20)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 87)
    }

    func testUsageReadWaitsForInitializeResponse() async throws {
        let response = #"{"id":2,"result":{"dailyUsageBuckets":[{"startDate":"2026-09-24","tokens":42}]}}"#
        let client = CodexUsageClient(
            appServerExecutablePath: try makeAppServer(response: response),
            requestTimeout: 2
        )

        let snapshot = try await client.readUsage()

        XCTAssertEqual(snapshot.days.map(\.tokens), [42])
    }

    private func makeAppServer(response: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let executable = directory.appendingPathComponent("app-server")
        let script = """
        #!/bin/bash
        set -eu
        IFS= read -r initialize
        [[ "$initialize" == *'"method":"initialize"'* ]]

        # 旧客户端会在 initialize 响应前把后续请求写入管道；新客户端此时不应有数据。
        if IFS= read -r -t 0 premature; then
            exit 42
        fi

        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        [[ "$initialized" == *'"method":"initialized"'* ]]
        IFS= read -r request
        [[ "$request" == *'"method":"account/'* ]]
        printf '%s\\n' '\(response)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable.path
    }
}
