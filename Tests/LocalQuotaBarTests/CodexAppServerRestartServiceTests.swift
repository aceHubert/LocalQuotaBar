import Foundation
import XCTest
@testable import LocalQuotaBar

final class CodexAppServerRestartServiceTests: XCTestCase {
    private enum TestError: Error {
        case enumerationFailed
    }

    // MARK: - 进程匹配

    private func identity(args: [String]) -> CodexAppServerProcessIdentity {
        CodexAppServerProcessIdentity(pid: 1, uid: 501, startedAt: "Mon Sep 21 10:12:34 2026", args: args)
    }

    func testMatchingAcceptsCodexAppServerVariants() {
        let accepted: [[String]] = [
            ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server", "--listen", "stdio://"],
            ["/usr/local/bin/codex", "app-server"],
            ["codex-aarch64-apple-darwin", "app-server"],
            ["codex-x86_64-pc-windows-msvc", "app-server"],
            ["C:\\Users\\x\\codex.exe", "app-server"],
            ["codex-code-mode-host"],
            ["codex-code-mode-host", "--foo"],
            ["/usr/local/bin/codex", "--strict-config", "app-server"],
            ["/usr/local/bin/codex", "-c", "/tmp/x.toml", "app-server"],
            ["/usr/local/bin/codex", "--config=/tmp/x.toml", "app-server"],
            ["/usr/local/bin/codex", "-mGPT5", "app-server"],
            ["/usr/local/bin/codex", "--", "app-server"],
        ]
        for args in accepted {
            XCTAssertTrue(
                CodexAppServerRestartService.isCodexAppServerProcess(identity(args: args)),
                "应当匹配：\(args)"
            )
        }
    }

    func testMatchingRejectsNonAppServerProcesses() {
        let rejected: [[String]] = [
            ["/usr/local/bin/codex", "exec", "task"],
            ["/usr/local/bin/codex", "app-server-extra"],
            ["/usr/local/bin/codex"],
            ["/usr/local/bin/codex", "--unknown-flag", "app-server"],
            ["/usr/local/bin/codex", "--", "exec"],
            ["/usr/local/bin/codex", "-c"],  // 选项缺值
            ["/Users/x/bin/my-codex", "app-server"],  // 文件名不是 codex
            ["codex-aarch64-apple-darwin", "exec"],
            ["codex-aarch64-linux-musl", "app-server"],  // target-triple 缺 OS 段
            ["/usr/local/bin/node", "app-server"],
        ]
        for args in rejected {
            XCTAssertFalse(
                CodexAppServerRestartService.isCodexAppServerProcess(identity(args: args)),
                "不应匹配：\(args)"
            )
        }
    }

    func testExecutableNameIsCaseInsensitiveBasename() {
        XCTAssertEqual(
            CodexAppServerRestartService.executableName(of: "/Applications/ChatGPT.app/Contents/Resources/Codex"),
            "codex"
        )
        XCTAssertEqual(CodexAppServerRestartService.executableName(of: ""), "")
    }

    // MARK: - ps 输出解析

    private func psLine(
        pid: String,
        ppid: String = "400",
        uid: String = "501",
        startedAt: String = "Mon Sep 21 10:12:34 2026",
        command: String = "/usr/local/bin/codex app-server"
    ) -> String {
        "\(pid)  \(ppid)  \(uid)  \(startedAt) \(command)\n"
    }

    private func parse(
        _ psOutput: String,
        argsByPID: [pid_t: [String]],
        currentUID: uid_t = 501,
        excludedParentPID: pid_t = 9999
    ) -> [CodexAppServerProcessIdentity] {
        CodexAppServerRestartService.parseProcessList(
            psOutput,
            currentUID: currentUID,
            excludedParentPID: excludedParentPID,
            argvReader: { pid in
                guard let args = argsByPID[pid] else { throw TestError.enumerationFailed }
                return args
            }
        )
    }

    func testParseKeepsOnlyCurrentUserExternalAppServers() {
        let output =
            psLine(pid: "100", command: "/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://")
            + psLine(pid: "101", ppid: "9999", command: "/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://")
            + psLine(pid: "102", uid: "502", command: "/usr/local/bin/codex app-server")
            + psLine(pid: "103", command: "/usr/local/bin/codex exec task")
            + psLine(pid: "104", command: "/usr/local/bin/node server.js")
            + psLine(pid: "105", command: "codex-aarch64-apple-darwin app-server")

        let processes = parse(output, argsByPID: [
            100: ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server", "--listen", "stdio://"],
            101: ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server", "--listen", "stdio://"],
            102: ["/usr/local/bin/codex", "app-server"],
            103: ["/usr/local/bin/codex", "exec", "task"],
            104: ["/usr/local/bin/node", "server.js"],
            105: ["codex-aarch64-apple-darwin", "app-server"],
        ])

        XCTAssertEqual(processes.map(\.pid), [100, 105])
        XCTAssertEqual(processes[0].startedAt, "Mon Sep 21 10:12:34 2026")
        XCTAssertEqual(
            processes[0].args,
            ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server", "--listen", "stdio://"]
        )
    }

    func testParseNormalizesPaddedStartDay() {
        let output = psLine(pid: "200", startedAt: "Mon Sep  1 10:12:34 2026")
        let processes = parse(output, argsByPID: [
            200: ["/usr/local/bin/codex", "app-server"],
        ])
        XCTAssertEqual(processes.map(\.pid), [200])
        XCTAssertEqual(processes[0].startedAt, "Mon Sep 1 10:12:34 2026")
    }

    func testParseMatchesArgumentsContainingSpaces() {
        // 参数值含空格时按空白切分 command 列会误判边界，必须依赖内核 argv。
        let output = psLine(pid: "300") + psLine(pid: "301")
        let processes = parse(output, argsByPID: [
            300: ["/usr/local/bin/codex", "-c", "my config.toml", "app-server"],
            301: ["/usr/local/bin/codex", "-c", "foo app-server", "exec"],
        ])
        XCTAssertEqual(processes.map(\.pid), [300])
    }

    func testParseSkipsRowWhenArgumentsUnavailable() {
        // argvReader 抛错（进程在 ps 快照后退出等竞态）时跳过该行，不中断整体扫描。
        let output = psLine(pid: "400") + psLine(pid: "401")
        let processes = parse(output, argsByPID: [
            401: ["/usr/local/bin/codex", "app-server"],
        ])
        XCTAssertEqual(processes.map(\.pid), [401])
    }

    // MARK: - 内核 argv 读取（KERN_PROCARGS2）

    func testKernelArgumentsReaderReturnsExactArgv() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5", "token with spaces"]
        try process.run()
        defer { process.terminate() }

        let args = try DarwinProcessArguments.read(pid: process.processIdentifier)
        XCTAssertEqual(args, ["/bin/sleep", "5", "token with spaces"])
    }

    func testKernelArgumentsParserWalksBufferLayout() throws {
        // 布局：argc（小端 Int32）、可执行路径、argv[0..argc-1]、envp……
        var buffer: [UInt8] = [2, 0, 0, 0]
        buffer.append(contentsOf: Array("/bin/x".utf8) + [0])
        buffer.append(contentsOf: Array("/bin/x".utf8) + [0])
        buffer.append(contentsOf: Array("hello world".utf8) + [0])
        buffer.append(contentsOf: Array("PATH=/bin".utf8) + [0])

        XCTAssertEqual(try DarwinProcessArguments.parseArguments(fromBuffer: buffer), ["/bin/x", "hello world"])
    }

    func testKernelArgumentsParserRejectsMalformedBuffers() {
        XCTAssertThrowsError(try DarwinProcessArguments.parseArguments(fromBuffer: [1, 0, 0, 0]))
        // argc=3 但只附了两个 argv 条目
        var truncated: [UInt8] = [3, 0, 0, 0]
        truncated += Array("/bin/x".utf8) + [0]
        truncated += Array("/bin/x".utf8) + [0]
        truncated += Array("only".utf8) + [0]
        XCTAssertThrowsError(try DarwinProcessArguments.parseArguments(fromBuffer: truncated))
    }

    // MARK: - 停止流程

    private final class RuntimeSpy {
        var scans: [[CodexAppServerProcessIdentity]] = []
        var scanError: Error?
        var terminateError: Error?
        private(set) var terminated: [pid_t] = []
        private(set) var waited: [TimeInterval] = []

        var runtime: CodexAppServerRestartService.Runtime {
            .init(
                listProcesses: { [unowned self] in
                    if let error = self.scanError { throw error }
                    guard !self.scans.isEmpty else { throw TestError.enumerationFailed }
                    return self.scans.removeFirst()
                },
                terminate: { [unowned self] pid in
                    if let error = self.terminateError { throw error }
                    self.terminated.append(pid)
                },
                wait: { [unowned self] seconds in self.waited.append(seconds) }
            )
        }
    }

    private func appServer(
        pid: pid_t,
        startedAt: String = "Mon Sep 21 10:12:34 2026",
        args: [String] = ["/usr/local/bin/codex", "app-server"]
    ) -> CodexAppServerProcessIdentity {
        CodexAppServerProcessIdentity(pid: pid, uid: 501, startedAt: startedAt, args: args)
    }

    func testStopReturnsNoneFoundWhenNoProcessMatches() {
        let spy = RuntimeSpy()
        spy.scans = [[]]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .noneFound
        )
        XCTAssertTrue(spy.terminated.isEmpty)
        XCTAssertTrue(spy.waited.isEmpty)
    }

    func testCurrentPresenceReturnsNoneWhenNoProcessMatches() {
        let spy = RuntimeSpy()
        spy.scans = [[]]

        XCTAssertEqual(
            CodexAppServerRestartService.currentPresence(runtime: spy.runtime),
            .none
        )
    }

    func testCurrentPresenceReturnsRunningWhenProcessMatches() {
        let spy = RuntimeSpy()
        spy.scans = [[appServer(pid: 100)]]

        XCTAssertEqual(
            CodexAppServerRestartService.currentPresence(runtime: spy.runtime),
            .running
        )
    }

    func testCurrentPresenceReturnsUnknownWhenEnumerationFails() {
        let spy = RuntimeSpy()
        spy.scanError = TestError.enumerationFailed

        guard case .unknown = CodexAppServerRestartService.currentPresence(runtime: spy.runtime) else {
            return XCTFail("枚举失败时不能误判为没有运行中的 app-server")
        }
    }

    func testStopSignalsVerifiedProcessAndReportsStopped() {
        let spy = RuntimeSpy()
        let target = appServer(pid: 100)
        spy.scans = [[target], [target], []]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [100], notStopped: [])
        )
        XCTAssertEqual(spy.terminated, [100])
        XCTAssertEqual(spy.waited, [CodexAppServerRestartService.settleInterval])
    }

    func testStopReportsSurvivingWhenProcessPersistsAfterSignal() {
        let spy = RuntimeSpy()
        let target = appServer(pid: 100)
        spy.scans = [[target], [target], [target]]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [], notStopped: [100])
        )
    }

    func testStopTreatsReusedPIDAsStopped() {
        let spy = RuntimeSpy()
        spy.scans = [
            [appServer(pid: 100, startedAt: "Mon Sep 21 10:12:34 2026")],
            [appServer(pid: 100, startedAt: "Mon Sep 21 10:12:34 2026")],
            [appServer(pid: 100, startedAt: "Mon Sep 21 10:59:59 2026")],
        ]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [100], notStopped: [])
        )
    }

    func testStopSkipsSignalWhenIdentityChangesBetweenScans() {
        let spy = RuntimeSpy()
        spy.scans = [
            [appServer(pid: 100)],
            [appServer(pid: 100, startedAt: "Mon Sep 21 10:13:00 2026")],
        ]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [], notStopped: [100])
        )
        XCTAssertTrue(spy.terminated.isEmpty)
        XCTAssertTrue(spy.waited.isEmpty)
    }

    func testStopReportsFailedWhenTerminateThrows() {
        let spy = RuntimeSpy()
        let target = appServer(pid: 100)
        spy.scans = [[target], [target], []]
        spy.terminateError = TestError.enumerationFailed

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [], notStopped: [100])
        )
        XCTAssertTrue(spy.waited.isEmpty)
    }

    func testStopMixesVerifiedAndVanishedCandidates() {
        let spy = RuntimeSpy()
        let first = appServer(pid: 100)
        let second = appServer(pid: 200)
        spy.scans = [[first, second], [first], []]

        XCTAssertEqual(
            CodexAppServerRestartService.stopAppServers(runtime: spy.runtime),
            .finished(stopped: [100], notStopped: [200])
        )
        XCTAssertEqual(spy.terminated, [100])
    }

    func testStopReturnsUnknownScanWhenEnumerationFails() {
        let spy = RuntimeSpy()
        spy.scanError = TestError.enumerationFailed

        guard case .unknownScan = CodexAppServerRestartService.stopAppServers(runtime: spy.runtime) else {
            return XCTFail("应当返回 unknownScan")
        }
    }

    func testStopReturnsUnknownScanWhenSecondScanFails() {
        let spy = RuntimeSpy()
        spy.scans = [[appServer(pid: 100)]]  // 第二次扫描时列表为空，抛枚举失败

        guard case .unknownScan = CodexAppServerRestartService.stopAppServers(runtime: spy.runtime) else {
            return XCTFail("应当返回 unknownScan")
        }
        XCTAssertTrue(spy.terminated.isEmpty)
    }
}
