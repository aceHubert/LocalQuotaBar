## [2026-10-20 14:26 +0800] | 任务：实施耗电优化——Codex 拉取常驻会话化与刷新错峰

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）`
- **Runtime**：`macOS 25.6.0 arm64 · SwiftPM · ZCode Desktop`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 开始实施计划（docs/exec-plans/active/energy-refresh-optimization.md：消除「使用大量能耗」主因——Codex 每次刷新 spawn app-server 子进程；5 个 store 定时刷新错峰加 tolerance）。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（codex 会话与两个客户端、5 个 store 定时器、AppDelegate 接线）、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **操作一**：新建 `codex/CodexAppServerSession.swift`（377 行）：自持常驻 stdio app-server 子进程。懒启动、initialize 握手一次、跨请求复用；EOF/进程退出/请求超时/auth.json 身份戳变化（fileNumber+size+mtime）时失效，下次请求透明重拉；连接性错误自动重试一轮；init 时忽略 SIGPIPE 防止向死管道写入杀死本应用；串行请求模型（NSLock 排队）。
- **操作二**：`CodexRateLimitClient`（main.swift）与 `CodexUsageClient`（CodexUsage.swift）全部方法改走注入会话（默认 `.shared`），删除两处每次 spawn 的实现与 `JSONLineResponseCollector`（main.swift 净删约 220 行）。请求 id 沿用旧惯例（initialize=1 / account=2 / rateLimits=3 / reset=4，usage=2）保持线协议不变。
- **操作三**：AppDelegate 接线：账号切换成功后显式 `invalidate()`（常驻进程持有旧凭证）；`applicationWillTerminate` 收尾子进程。
- **操作四**：新建 `RefreshPhasePlanner`（RefreshSettings.swift）：5 个 store 按固定相位错峰（Codex 0s / ZAI 45s / DeepSeek 90s / CodeBuddy 国际 135s / 国内 180s，按 interval 等比缩放），`Timer(fire:interval:)` + tolerance（≤10s）；各 store 持创建时刻锚点，改档位重建后相位保持。
- **操作五**：测试：改写 `CodexAppServerProtocolTests` 走会话注入并新增复用/断连重拉/auth 戳重拉/握手超时用例；新建 `CodexAuthStampTests`、`RefreshPhasePlannerTests`；修复 `SettingsPageViewTests` 两用例（档位表收缩后自动刷新与冷却下拉标题集合相同，改按视图顺序识别）。
- **操作六**：文档：执行计划补 M0/M3 实测结果、实施决策；技术债表登记 Chrome 导入缓存（第二阶段未做项）。

### 设计动机

见执行计划背景与决策记录：spawn 起停是耗电主因（默认档每天 288 次），常驻会话以最小改动面消除；M0 实测 app-server 空闲 35 分钟不断开，EOF 重拉保留为防御兜底；错峰消除 5 路对齐突发。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 287 个测试执行：284 通过、3 跳过、1 失败（`CodeBuddyParsingTests.testPanelRendersPlanBarAndPackageChips`，在 HEAD 干净 git worktree 上复现，属既有问题，与本任务无关）。新增 17 个测试全部通过。
- 手工验证及设备：本机（MacBook arm64）运行新调试构建 11 分钟：Codex 子进程仅 1 个且全程存活，两个 5 分钟刷新 tick 零 spawn（旧构建每 tick 必 spawn，实测 11:55/12:00 两次抓到）；新实例 CPU 采样全程 0.0%（旧实例基线周期性 10-11% 突发、日均约 60 CPU-分钟）。
- 部署：`make install` 已将 release 构建安装到 `/Applications/LocalQuotaBar.app`（二进制 mtime 2026-10-20 16:40），安装版已启动并正常拉起常驻会话子进程；图标确定性重建无 git 差异。调试实例与旧会话子进程已先行回收。
- 未覆盖场景：账号切换真机链路（会改写真实 `~/.codex/auth.json` 未执行，由显式 invalidate 调用点 + 戳变化重拉单测覆盖）；系统设置电池页「使用大量能耗」跨天复查待次日；手动刷新/重置卡/提醒链路未逐项人工点验。

### 变更统计

> 使用 `git diff HEAD --shortstat/--numstat`（工作区未提交）统计已跟踪文件；3 个新文件与 `/dev/null` 对比。`RefreshSettings.swift` 的 37/1 含同日另一任务（档位下限 5 分钟，见 20261020-1344 历史）的 1/1，本任务净增 36。排除历史记录自身。

- **统计口径**：基线 = HEAD（4e970da）+ 工作区；本任务全部代码与文档改动。
- **变更文件数**：11（已跟踪 8 + 新增 3）
- **新增行数**：+809（含新文件 493）
- **删除行数**：-444

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codex/CodexAppServerSession.swift`（新） | 377 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 43 | 261 |
| `Sources/LocalQuotaBar/codex/CodexUsage.swift` | 11 | 147 |
| `Sources/LocalQuotaBar/RefreshSettings.swift` | 37 | 1 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift` | 23 | 2 |
| `Sources/LocalQuotaBar/deepseek/DeepSeekStore.swift` | 19 | 1 |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | 19 | 1 |
| `Tests/LocalQuotaBarTests/CodexAppServerProtocolTests.swift` | 156 | 28 |
| `Tests/LocalQuotaBarTests/CodexAuthStampTests.swift`（新） | 58 | 0 |
| `Tests/LocalQuotaBarTests/RefreshPhasePlannerTests.swift`（新） | 58 | 0 |
| `Tests/LocalQuotaBarTests/SettingsPageViewTests.swift` | 8 | 3 |

### 迭代：2026-10-22 EOF 自旋回归修复

用户要求复查能耗后发现问题：10-20 安装版中会话子进程于 10-21 约 11:06 死亡，之后应用 >100% CPU 自旋约 22.5 小时（累计 2644 CPU-分钟）。`sample` 定位：两个 `com.apple.NSFileHandle.fd_monitoring` 线程满负荷——子进程退出后管道 EOF 使 fd 永久可读，`readabilityHandler` 未在 EOF 时自摘除，空数据无限回调。10-20 的 11 分钟观测窗口子进程始终存活，未暴露此路径。死因后查证：codex 于 10-21 11:02:45 例行刷新 token 重写 `~/.codex/auth.json`（mtime 实证，非更新、非账号切换），11:06:02 刷新 tick 上身份戳检测按设计 SIGTERM 旧进程并重拉——即进程由我们自己的换新逻辑终止，唯一缺陷是 teardown 不摘 handler 引发自旋。

- 修复（`CodexAppServerSession.swift`，+49 行）：stdout/stderr 的 EOF 分支在回调内自摘除 handler；`teardown()` 同步摘除（Child 保留两个读端句柄）；新增 EOF 回调计数观测口径。
- 回归测试：`testEOFRemovesReadabilityHandlerAndStopsCallbacks`（EOF 回调计数恒 ≤1 且不随时间增长；EOF 后仍可透明重拉）。`swift test` 288 个测试：唯一失败仍为 HEAD 既有的 CodeBuddyParsing 面板用例。
- 部署与验证：`make install` 重装 `/Applications`，重启后实测 CPU 稳态 0.0%、刷新瞬间短峰 ~6%、运行 2.5 分钟累计 CPU 2 秒；本机会话子进程 1 个无泄漏（其余 codex 进程经 ppid 核验属 ChatGPT.app / node_repl）。
- 变更统计增量：`CodexAppServerSession.swift` 377→426 行，`CodexAppServerProtocolTests.swift` +156→+179；合计新增行数 +809→+832。

### 修改文件

- `Sources/LocalQuotaBar/codex/CodexAppServerSession.swift`（新）
- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/codex/CodexUsage.swift`
- `Sources/LocalQuotaBar/RefreshSettings.swift`
- `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift`
- `Sources/LocalQuotaBar/deepseek/DeepSeekStore.swift`
- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Tests/LocalQuotaBarTests/CodexAppServerProtocolTests.swift`
- `Tests/LocalQuotaBarTests/CodexAuthStampTests.swift`（新）
- `Tests/LocalQuotaBarTests/RefreshPhasePlannerTests.swift`（新）
- `Tests/LocalQuotaBarTests/SettingsPageViewTests.swift`
- `docs/exec-plans/active/energy-refresh-optimization.md`、`docs/exec-plans/tech-debt-tracker.md`（文档，未跟踪/已跟踪各一）
