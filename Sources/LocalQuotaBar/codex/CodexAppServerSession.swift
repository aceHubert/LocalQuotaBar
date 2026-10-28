import Foundation

// MARK: - 自持常驻 app-server 会话
//
// 背景：旧实现每次刷新都 spawn 一个 codex app-server 进程（shell 包装 → 65MB 二进制 →
// initialize → 实时网络请求 → SIGTERM），默认 5 分钟档位下每天 288 次起停，是应用被
// macOS 判定「使用大量能耗」的主因（见 docs/exec-plans/active/energy-refresh-optimization.md）。
// 本会话把进程生命周期拉长为「懒启动 + 跨请求复用」：
// - EOF / 进程退出 / 请求超时 / auth.json 变化 / 主动 invalidate 时失效，
//   下一次请求透明重拉（连接性错误自动重试一轮）。
// - 串行请求模型：同一时刻仅一个在途请求（额度/用量/重置本就低频，无需并发分发）；
//   并发调用方在 requestLock 上排队，最长等前一个请求的超时时长。
// - 公开方法为阻塞式，供 Task.detached 调用；可在任意线程使用。

/// `~/.codex/auth.json` 的身份戳。app-server 启动时读取一次 auth 后不再重读，
/// 常驻进程因此在凭证变化（本应用切换账号、codex CLI 重新登录）后必须换新。
/// 原子替换（rename）会换 inode，fileNumber 随之变化，比单纯比对 mtime 可靠。
struct CodexAuthStamp: Equatable {
    static let missing = CodexAuthStamp(fileNumber: nil, size: nil, modificationDate: nil)

    let fileNumber: Int?
    let size: Int?
    let modificationDate: Date?

    /// 文件不存在时返回 `.missing`（稳定的比较值：文件后来出现同样视为变化）。
    init(path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        self.init(
            fileNumber: attributes?[.systemFileNumber] as? Int,
            size: attributes?[.size] as? Int,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    init(fileNumber: Int?, size: Int?, modificationDate: Date?) {
        self.fileNumber = fileNumber
        self.size = size
        self.modificationDate = modificationDate
    }
}

final class CodexAppServerSession {
    /// 全应用共享的默认会话；测试与定制路径用独立 init 构造，互不影响。
    static let shared = CodexAppServerSession()

    private let executablePath: String
    let authJSONPath: String
    private let requestTimeout: TimeInterval

    /// 串行化公开请求（send / invalidate 以外的入口）。
    private let requestLock = NSLock()
    /// 保护 currentChild 指针（invalidate 可能来自主线程，与后台请求并发）。
    private let stateLock = NSLock()
    private var currentChild: Child?

    /// 忽略 SIGPIPE：会话可能向刚退出的子进程写管道（EPIPE），必须让写失败
    /// 以 Swift 错误返回（connectionDropped 重试路径），而不是杀死本进程。
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(
        executablePath: String = CodexAppServerLocator.defaultExecutablePath(),
        authJSONPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path,
        requestTimeout: TimeInterval = 30
    ) {
        Self.ignoreSIGPIPE
        self.executablePath = executablePath
        self.authJSONPath = authJSONPath
        self.requestTimeout = requestTimeout
    }

    deinit {
        invalidate()
    }

    /// 发送一个 JSON-RPC 请求并阻塞等待响应。
    /// - Parameters:
    ///   - id: 请求 id，沿用旧实现的固定惯例（initialize=1、account/read=2、
    ///     rateLimits/read=3、reset consume=4），保持线格式与既有假服务器测试兼容。
    ///   - method / params: JSON-RPC 方法与参数。
    /// - Throws: `CodexRateLimitError`。连接中断自动换新进程重试一轮；
    ///   请求超时不重试（避免慢后端翻倍等待），但会丢弃疑似卡死的进程。
    func send(id: Int, method: String, params: Any) throws -> [String: Any] {
        requestLock.lock()
        defer { requestLock.unlock() }

        var lastError: Error = CodexRateLimitError.connectionDropped
        for _ in 0..<2 {
            let child: Child
            do {
                child = try ensureChild()
            } catch {
                // 启动阶段（spawn / initialize 握手）失败换新进程重试一轮，
                // 与旧的「每次请求全新进程」容错粒度对齐。
                lastError = error
                continue
            }
            do {
                let response = try request(child: child, id: id, method: method, params: params)
                return try Self.validatedResult(from: response)
            } catch CodexRateLimitError.connectionDropped {
                discardChildIfCurrent(child)
                lastError = CodexRateLimitError.connectionDropped
                continue
            } catch CodexRateLimitError.timeout {
                discardChildIfCurrent(child)
                throw CodexRateLimitError.timeout
            }
        }
        throw lastError
    }

    /// 立即失效当前子进程（SIGTERM），下一次请求重新拉起。
    /// 账号切换、用户主动「立即重启 Codex」、应用退出时调用；幂等。
    func invalidate() {
        stateLock.lock()
        let child = currentChild
        currentChild = nil
        stateLock.unlock()
        child?.teardown()
    }

    /// 回归观测：当前子进程的 stdout EOF 回调次数（无子进程为 nil）。
    /// handler 自摘除后恒为 1；随时间持续增长即 EOF 空回调自旋回归。
    var currentChildEOFCountForTesting: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentChild?.stdoutEOFCount
    }

    // MARK: - 子进程管理

    private func ensureChild() throws -> Child {
        let stamp = CodexAuthStamp(path: authJSONPath)
        stateLock.lock()
        if let child = currentChild, !child.isDropped, child.authStamp == stamp {
            stateLock.unlock()
            return child
        }
        let stale = currentChild
        currentChild = nil
        stateLock.unlock()
        stale?.teardown()

        let child = try spawnChild(authStamp: stamp)

        stateLock.lock()
        if let existing = currentChild {
            // 理论上 perform 已被 requestLock 串行化，这里只在 invalidate 与本函数
            // 极端交错时防御：保留先到的会话，丢弃自己。
            stateLock.unlock()
            child.teardown()
            return existing
        }
        currentChild = child
        stateLock.unlock()
        return child
    }

    private func spawnChild(authStamp: CodexAuthStamp) throws -> Child {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexRateLimitError.appServerNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--listen", "stdio://"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let child = Child(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdoutRead: stdoutPipe.fileHandleForReading,
            stderrRead: stderrPipe.fileHandleForReading,
            authStamp: authStamp
        )

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF 使 fd 永久处于可读态，不摘除 handler 会以空数据无限回调，
                // 烧满两个 fd_monitoring 线程（2026-10-22 实测回归）。必须在回调内自摘除。
                handle.readabilityHandler = nil
                child.queue.async {
                    child.recordEOFLocked()
                    child.markDroppedLocked()
                }
                return
            }
            child.queue.async {
                child.buffer.append(data)
                child.parseLinesLocked()
            }
        }
        // 排空 stderr，避免子进程日志写满管道阻塞；EOF 同样必须自摘除
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexRateLimitError.processLaunchFailed(error.localizedDescription)
        }

        // app-server 要求先完成 initialize 握手（响应到达后再发 initialized 通知与业务请求），
        // 否则启动稍慢时业务请求会被服务端拒绝（旧实现验证过的协议顺序）。
        do {
            let initialized = try handshake(child: child)
            _ = try Self.validatedResult(from: initialized)
            child.queue.sync {
                child.writeLineLocked(Self.notificationLine(method: "initialized", params: [:]))
            }
        } catch {
            child.teardown()
            throw error
        }
        return child
    }

    /// initialize 握手：写入 initialize 请求并等待其响应（复用请求等待机制）。
    private func handshake(child: Child) throws -> [String: Any] {
        try child.enqueueAndAwait(id: 1, method: "initialize", params: [
            "clientInfo": [
                "name": "codex_touchbar_quota",
                "title": "Codex Touch Bar Quota",
                "version": "1.0.0"
            ]
        ], timeout: requestTimeout)
    }

    private func request(child: Child, id: Int, method: String, params: Any) throws -> [String: Any] {
        try child.enqueueAndAwait(id: id, method: method, params: params, timeout: requestTimeout)
    }

    private func discardChildIfCurrent(_ child: Child) {
        stateLock.lock()
        let isCurrent = currentChild === child
        if isCurrent { currentChild = nil }
        stateLock.unlock()
        if isCurrent {
            child.teardown()
        } else {
            child.markDropped()
        }
    }

    /// 响应统一校验：error 对象 → serverError；result 不是字典 → malformedResponse。
    static func validatedResult(from response: [String: Any]) throws -> [String: Any] {
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

    private static func requestLine(id: Int, method: String, params: Any) throws -> Data {
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let json = try JSONSerialization.data(withJSONObject: message, options: [])
        return json + Data("\n".utf8)
    }

    private static func notificationLine(method: String, params: [String: Any]) -> Data {
        let message: [String: Any] = ["method": method, "params": params]
        let json = (try? JSONSerialization.data(withJSONObject: message, options: [])) ?? Data()
        return json + Data("\n".utf8)
    }

    // MARK: - 子进程封装

    /// 一个子进程实例的全部 IO 状态。所有可变状态都只在 `queue` 上触碰
    /// （写 stdin、解析响应行、pending/dropped 标记），天然免锁竞争。
    private final class Child {
        let process: Process
        let stdin: FileHandle
        /// 读端句柄保留在 Child 上，teardown / EOF 时负责摘除 readabilityHandler。
        let stdoutRead: FileHandle
        let stderrRead: FileHandle
        let authStamp: CodexAuthStamp
        /// 串行队列：本子进程全部 IO 与状态的唯一所有权域。
        let queue = DispatchQueue(label: "local.codex.touchbar.quota.appserver-session")

        // 以下成员仅在 queue 上访问
        var buffer = Data()
        var dropped = false
        var pending: Pending?
        /// stdout EOF 次数（回归观测：handler 自摘除后应恒为 1，持续增长即自旋）
        private(set) var eofCount = 0

        final class Pending {
            let id: Int
            let semaphore = DispatchSemaphore(value: 0)
            // 仅在 queue 上写、在信号量唤醒后于 queue 上读
            var response: [String: Any]?

            init(id: Int) {
                self.id = id
            }
        }

        init(
            process: Process,
            stdin: FileHandle,
            stdoutRead: FileHandle,
            stderrRead: FileHandle,
            authStamp: CodexAuthStamp
        ) {
            self.process = process
            self.stdin = stdin
            self.stdoutRead = stdoutRead
            self.stderrRead = stderrRead
            self.authStamp = authStamp
        }

        var isDropped: Bool {
            queue.sync { dropped }
        }

        var stdoutEOFCount: Int {
            queue.sync { eofCount }
        }

        /// 仅在 queue 上调用。
        func recordEOFLocked() {
            eofCount += 1
        }

        /// 注册 pending → 写请求行 → 阻塞等响应 → 校验并返回响应。
        /// 调用方负责串行化（session.requestLock）。
        func enqueueAndAwait(id: Int, method: String, params: Any, timeout: TimeInterval) throws -> [String: Any] {
            // 请求行先于 pending 注册构造：序列化失败时不在子进程里留悬挂状态
            let line = try CodexAppServerSession.requestLine(id: id, method: method, params: params)
            let pending = Pending(id: id)
            queue.sync {
                self.pending = pending
                if dropped {
                    // 连接已断开：立即唤醒走 connectionDropped 路径，不空等超时
                    pending.semaphore.signal()
                } else {
                    writeLineLocked(line)
                }
            }

            guard pending.semaphore.wait(timeout: .now() + timeout) == .success else {
                queue.sync { self.pending = nil }
                markDropped()
                throw CodexRateLimitError.timeout
            }

            var response: [String: Any]?
            queue.sync {
                response = pending.response
                self.pending = nil
            }
            guard let response else {
                throw CodexRateLimitError.connectionDropped
            }
            return response
        }

        /// 仅在 queue 上调用。
        func writeLineLocked(_ line: Data) {
            do {
                try stdin.write(contentsOf: line)
            } catch {
                markDroppedLocked()
            }
        }

        /// 仅在 queue 上调用：按行解析响应，命中 pending.id 时存储并唤醒。
        func parseLinesLocked() {
            while let newlineRange = buffer.firstRange(of: Data("\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line, options: []),
                      let message = object as? [String: Any]
                else { continue }
                if let id = (message["id"] as? NSNumber)?.intValue, id == pending?.id {
                    pending?.response = message
                    pending?.semaphore.signal()
                }
            }
        }

        /// 仅在 queue 上调用。
        func markDroppedLocked() {
            dropped = true
            pending?.semaphore.signal()
        }

        func markDropped() {
            queue.async { self.markDroppedLocked() }
        }

        /// SIGTERM 子进程并标记断开；幂等。同步摘除两个 readabilityHandler：
        /// 子进程退出后管道 EOF 使 fd 永久可读，留着的 handler 会以空数据无限自旋
        /// （旧实现的进程生命周期与请求严格同步、用完即摘，不存在此问题；常驻化后
        /// 必须在每个退出路径上显式摘除，2026-10-22 跨天观测踩中）。
        func teardown() {
            stdoutRead.readabilityHandler = nil
            stderrRead.readabilityHandler = nil
            markDropped()
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
