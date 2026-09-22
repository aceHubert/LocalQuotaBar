import Darwin
import Foundation

// MARK: - Codex app-server 进程识别

/// 从 `ps` 输出识别出的 Codex app-server 进程；startedAt 与完整 argv 参与身份复核，防 PID 复用误杀。
struct CodexAppServerProcessIdentity: Equatable {
    let pid: pid_t
    let uid: uid_t
    let startedAt: String
    /// argv 全量，argv[0] 为可执行文件路径（由内核 KERN_PROCARGS2 读出，参数含空格也保持原样）。
    let args: [String]
}

// MARK: - 停止结果

enum CodexAppServerStopStatus: Equatable {
    case stopped
    case surviving
    case failed
}

/// finished 表示停止流程正常走完：stopped 已退出，notStopped 为 surviving / failed 的 PID。
enum CodexAppServerRestartOutcome: Equatable {
    case finished(stopped: [pid_t], notStopped: [pid_t])
    case noneFound
    case unknownScan(String)
}

/// 当前用户是否存在可由 Codex 客户端持有的 app-server。
enum CodexAppServerPresence: Equatable {
    case running
    case none
    case unknown(String)
}

enum CodexAppServerRestartError: Error, LocalizedError {
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let message):
            return message
        }
    }
}

// MARK: - 内核 argv 读取（KERN_PROCARGS2）

/// 读取内核中进程的真实 argv，与 codex-cliproxy 的 readDarwinArgs 等价；
/// `ps` command 列按空白拼接会丢失参数边界，含空格的参数只有这里能取准。
enum DarwinProcessArguments {
    enum ReadError: Error {
        case unavailable
        case malformed
    }

    static func read(pid: pid_t) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let buffer = try readSysctlBuffer(mib: &mib)
        return try parseArguments(fromBuffer: buffer)
    }

    /// 探测长度后读取；目标进程 argv/env 恰在两次调用间变化会导致缓冲区不足，最多重试 3 次。
    private static func readSysctlBuffer(mib: inout [Int32]) throws -> [UInt8] {
        for _ in 0..<3 {
            var size: size_t = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
                  size >= 5, size <= 16 * 1024 * 1024 else {
                throw ReadError.unavailable
            }
            var buffer = [UInt8](repeating: 0, count: size)
            var length = size
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                return buffer
            }
        }
        throw ReadError.unavailable
    }

    /// KERN_PROCARGS2 缓冲区布局：argc（小端 Int32）、可执行文件路径、argv[0..argc-1]、envp……
    static func parseArguments(fromBuffer buffer: [UInt8]) throws -> [String] {
        guard buffer.count >= 5 else { throw ReadError.malformed }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        guard argc >= 1, argc <= 100_000 else { throw ReadError.malformed }

        guard let (_, afterPath) = readCString(buffer, from: 4) else { throw ReadError.malformed }
        var offset = afterPath
        while offset < buffer.count, buffer[offset] == 0 {
            offset += 1
        }

        var args: [String] = []
        while args.count < argc, offset < buffer.count {
            guard let (value, next) = readCString(buffer, from: offset) else { throw ReadError.malformed }
            args.append(value)
            offset = next
        }
        guard args.count == argc else { throw ReadError.malformed }
        return args
    }

    private static func readCString(_ buffer: [UInt8], from offset: Int) -> (String, Int)? {
        guard offset < buffer.count else { return nil }
        guard let end = buffer[offset...].firstIndex(of: 0) else { return nil }
        return (String(decoding: buffer[offset..<end], as: UTF8.self), end + 1)
    }
}

// MARK: - 停止服务

/// 移植 codex-cliproxy `stopCodexAppServers`：只停止当前用户的 Codex app-server
/// （`codex app-server` / `codex-code-mode-host`），不拉起替代进程，由 Codex 客户端自行重启。
/// 进程枚举同原实现：`ps` 取当前用户进程快照，再用 KERN_PROCARGS2 读精确 argv 做匹配与身份复核。
enum CodexAppServerRestartService {
    /// 可注入运行时；系统实现枚举当前用户进程、发 SIGTERM、Thread.sleep 等待退出。
    struct Runtime {
        let listProcesses: () throws -> [CodexAppServerProcessIdentity]
        let terminate: (pid_t) throws -> Void
        let wait: (TimeInterval) -> Void

        static let system = Runtime(
            listProcesses: { try CodexAppServerRestartService.listSystemProcesses() },
            terminate: { pid in
                // 仅 SIGTERM，绝不升级 SIGKILL；发送失败按 failed 处理。
                if kill(pid, SIGTERM) != 0 {
                    throw CodexAppServerRestartError.scanFailed(
                        "SIGTERM 发送失败（PID \(pid)，errno \(errno)）"
                    )
                }
            },
            wait: { seconds in Thread.sleep(forTimeInterval: seconds) }
        )
    }

    /// 发信号后等待进程退出的时间，与 codex-cliproxy 一致。
    static let settleInterval: TimeInterval = 2

    /// 只读检查当前用户是否有运行中的 Codex app-server，不会启动或停止任何进程。
    static func currentPresence(runtime: Runtime = .system) -> CodexAppServerPresence {
        switch scan(runtime: runtime) {
        case .ok(let processes):
            return processes.isEmpty ? .none : .running
        case .unknown(let message):
            return .unknown(message)
        }
    }

    static func stopAppServers(runtime: Runtime = .system) -> CodexAppServerRestartOutcome {
        let initial: [CodexAppServerProcessIdentity]
        switch scan(runtime: runtime) {
        case .unknown(let message): return .unknownScan(message)
        case .ok(let processes): initial = processes
        }
        guard !initial.isEmpty else { return .noneFound }

        // 二扫复核同一 PID 的身份（uid/lstart/argv 全等）后才发信号，防止 PID 复用误杀。
        let current: [CodexAppServerProcessIdentity]
        switch scan(runtime: runtime) {
        case .unknown(let message): return .unknownScan(message)
        case .ok(let processes): current = processes
        }

        let currentByPID = Dictionary(
            current.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var statuses: [pid_t: CodexAppServerStopStatus] = [:]
        var signaled: [CodexAppServerProcessIdentity] = []
        for candidate in initial {
            guard let revalidated = currentByPID[candidate.pid], revalidated == candidate else {
                statuses[candidate.pid] = .failed
                continue
            }
            do {
                try runtime.terminate(candidate.pid)
                signaled.append(candidate)
            } catch {
                statuses[candidate.pid] = .failed
            }
        }

        guard !signaled.isEmpty else {
            return .finished(stopped: [], notStopped: initial.map(\.pid))
        }

        runtime.wait(settleInterval)

        // 终扫：同 PID 同身份仍在 = surviving；PID 消失或身份已变（复用）= stopped。
        let final: [CodexAppServerProcessIdentity]
        switch scan(runtime: runtime) {
        case .unknown(let message): return .unknownScan(message)
        case .ok(let processes): final = processes
        }
        let finalByPID = Dictionary(
            final.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for candidate in signaled {
            if let survivor = finalByPID[candidate.pid], survivor == candidate {
                statuses[candidate.pid] = .surviving
            } else {
                statuses[candidate.pid] = .stopped
            }
        }

        let stopped = initial.filter { statuses[$0.pid] == .stopped }.map(\.pid)
        let notStopped = initial.filter { statuses[$0.pid] != .stopped }.map(\.pid)
        return .finished(stopped: stopped, notStopped: notStopped)
    }

    private enum ScanResult {
        case ok([CodexAppServerProcessIdentity])
        case unknown(String)
    }

    private static func scan(runtime: Runtime) -> ScanResult {
        do {
            return .ok(try runtime.listProcesses())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .unknown(message)
        }
    }

    /// 枚举当前用户的 Codex app-server 进程；`ps` 失败一律抛错（调用方报 unknownScan），不当作“无进程”。
    static func listSystemProcesses() throws -> [CodexAppServerProcessIdentity] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-axo", "pid=,ppid=,uid=,lstart=,command="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)
        guard process.terminationStatus == 0, let output else {
            throw CodexAppServerRestartError.scanFailed(
                "进程枚举失败（ps 退出码 \(process.terminationStatus)）"
            )
        }
        return parseProcessList(
            output,
            currentUID: getuid(),
            excludedParentPID: getpid(),
            argvReader: DarwinProcessArguments.read(pid:)
        )
    }

    /// 解析 `ps -ww -axo pid=,ppid=,uid=,lstart=,command=` 输出：
    /// 只保留当前用户、父进程不是本应用（自己 spawn 的用量读取进程）的行；
    /// command 列不参与解析，argv 由 argvReader 从内核读取后做精确匹配。
    static func parseProcessList(
        _ output: String,
        currentUID: uid_t,
        excludedParentPID: pid_t,
        argvReader: (pid_t) throws -> [String]
    ) -> [CodexAppServerProcessIdentity] {
        var processes: [CodexAppServerProcessIdentity] = []
        for rawLine in output.split(separator: "\n") {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // pid + ppid + uid + lstart 5 列；argv 内含空格时 command 列会被拆散，因此只信内核 argv
            guard fields.count >= 8,
                  let pid = pid_t(fields[0]),
                  let parentPID = pid_t(fields[1]),
                  let uid = uid_t(fields[2]) else { continue }
            guard uid == currentUID, parentPID != excludedParentPID else { continue }
            // 进程在 ps 快照与读取 argv 之间退出属正常竞态，跳过该行
            guard let args = try? argvReader(pid) else { continue }
            let identity = CodexAppServerProcessIdentity(
                pid: pid,
                uid: uid,
                startedAt: fields[3..<8].joined(separator: " "),
                args: args
            )
            guard isCodexAppServerProcess(identity) else { continue }
            processes.append(identity)
        }
        return processes
    }

    // MARK: 进程匹配（移植 codex-cliproxy isCodexAppServerProcess，刻意不用宽泛 *codex* 匹配）

    private static let globalOptionsWithValue: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
        "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox",
        "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
    ]

    private static let globalFlags: Set<String> = [
        "--strict-config", "--oss", "--approve-for-me",
        "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
        "--search", "--no-alt-screen", "-h", "--help", "-V", "--version",
    ]

    /// codex 官方 target-triple 发布名（如 codex-aarch64-apple-darwin）。
    private static let codexTargetTripleRegex = try? NSRegularExpression(
        pattern: "^codex-(aarch64|x86_64)-(apple-darwin|unknown-linux-(gnu|musl)|pc-windows-msvc)(\\.exe)?$"
    )

    static func isCodexAppServerProcess(_ process: CodexAppServerProcessIdentity) -> Bool {
        let executable = executableName(of: process.args.first ?? "")
        if executable == "codex-code-mode-host" || executable == "codex-code-mode-host.exe" {
            return true
        }
        guard isCodexExecutableName(executable), process.args.count >= 2 else { return false }

        var index = 1
        while index < process.args.count {
            let arg = process.args[index]
            if arg == "--" {
                let next = index + 1 < process.args.count ? process.args[index + 1] : nil
                return next == "app-server"
            }
            if !arg.hasPrefix("-") { return arg == "app-server" }
            if globalFlags.contains(arg) {
                index += 1
                continue
            }
            if globalOptionsWithValue.contains(arg) {
                index += 2  // 跳过选项与其值；值缺失时越界退出循环即判否
                continue
            }
            let option = arg.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? ""
            if arg.contains("="), globalOptionsWithValue.contains(option) {
                index += 1
                continue
            }
            if isAttachedShortOption(arg) {
                index += 1
                continue
            }
            return false
        }
        return false
    }

    /// argv[0] 的文件名（小写）；兼容 Windows 反斜杠路径分隔。
    static func executableName(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let last = normalized.split(separator: "/").last else { return "" }
        return last.lowercased()
    }

    private static func isCodexExecutableName(_ name: String) -> Bool {
        if name == "codex" || name == "codex.exe" || name == "codex.cmd" { return true }
        guard let regex = codexTargetTripleRegex else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// `-c<value>` 形式的附着短选项（-c/-m/-p/-s/-C/-a），如 `-mGPT5`。
    private static func isAttachedShortOption(_ arg: String) -> Bool {
        guard arg.hasPrefix("-"), arg.count >= 3 else { return false }
        let flag = arg[arg.index(arg.startIndex, offsetBy: 1)]
        return "cmpsCa".contains(flag)
    }
}
