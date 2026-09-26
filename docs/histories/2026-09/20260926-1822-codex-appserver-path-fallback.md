## [2026-09-26 18:22 +0800] | 任务：修复 ChatGPT.app 更新后 codex 可执行文件路径失效

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3 (account:zai-individual-coding-plan)`
- **Runtime**：ZCode CLI（macOS 26.6.2, arm64）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 菜单栏弹出报错「找不到 ChatGPT.app 内置的 Codex 可执行文件：/Ap…」。诊断确认：ChatGPT.app 2026-09-26 18:04 左右自动更新，内置 codex 从 `Contents/Resources/codex` 迁移到 `Contents/Resources/codex-cli/bin/codex`（shell 包装脚本，转发到 `codex-cli/CodexCLI.app/Contents/MacOS/codex`），应用两处硬编码旧路径导致启动检查即抛 `appServerNotFound`。用户要求修复，并编译安装到 /Applications 重启验证。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/codex/`、`Sources/LocalQuotaBar/main.swift`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **操作一**：新增 `CodexAppServerLocator`（`codex/CodexAppServerLocator.swift`），按「新路径优先、旧路径回退」探测候选路径；都不存在时返回首个候选，让报错指向当前期望位置。
- **操作二**：`main.swift`（`CodexRateLimitClient` 默认参数）与 `codex/CodexUsage.swift`（`CodexUsageClient` 默认参数）的硬编码路径替换为 `CodexAppServerLocator.defaultExecutablePath()`。
- **操作三**：新增 `Tests/LocalQuotaBarTests/CodexAppServerLocatorTests.swift`（4 个用例：候选顺序优先级、跳过缺失候选、忽略不可执行文件、候选表覆盖新旧位置且无重复）。

### 设计动机

ChatGPT.app 自动更新不可控，简单替换成新路径会在旧版本上再次失效；探测式回退同时兼容新旧版本。定位逻辑独立成 `CodexAppServerLocator` 并把「候选列表」与「可执行探测」拆开（`firstExecutablePath(in:)` 接受任意候选列表），避免为测试 mock `FileManager`。两个客户端各自保留 `appServerExecutablePath` 注入口，默认值统一指向定位器，不改变既有调用方式与错误类型（`appServerNotFound` 文案不变）。

### 验证结果

- 命令与结果：
  - `swift build`：通过（7.61s）。
  - `swift test --filter "CodexAppServerLocatorTests|CodexAppServerProtocolTests"`：6 个用例全部通过（含未提交的协议握手测试）。
  - 真实二进制探测：`printf '<initialize 请求>' | /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex app-server --listen stdio://` 返回 `{"id":1,"result":{...codexHome...}}`，新路径下 initialize 握手正常（版本 0.158.0-alpha.2.1）。
  - `make install` 安装到 `/Applications/LocalQuotaBar.app`，`pkill -x LocalQuotaBar && open /Applications/LocalQuotaBar.app` 重启成功（PID 30981）。
- 手工验证及设备：本机（macOS 26.6.2, arm64）。重启后读取 UserDefaults `local.quota.bar` 域的 `local.codex.touchbar.quota.lastSnapshot`：`fetchedAt` 为 2026-09-26 18:20:54 +0800（即重启后立即完成），带回新数据（fiveHour 53%、weekly 34%、planType plus），证明启动刷新走通了新路径，未再出现报错。
- 未覆盖场景：ChatGPT.app 完全卸载（两个候选都不存在）时仍会报错，但报错路径已指向新版期望位置；新版二进制协议若后续再变更，属协议适配问题而非路径问题。

### 变更统计

> 统计口径：本次任务 = 新增 2 个文件 + 2 个文件各 1 行默认参数替换。注意 `main.swift` 与 `CodexUsage.swift` 工作区差异中还包含上一任务（2026-09-24 app-server 初始化握手，见 `20260924-1418-codex-refresh-initialization.md`）的未提交改动（合计 +91/-55），不计入本任务。排除历史记录自身。

- **统计文件数**：4（新增 2、修改 2）
- **新增行数**：+98（含新文件 +96，两处默认参数替换各 +1）
- **删除行数**：-2（两处旧硬编码路径）

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codex/CodexAppServerLocator.swift`（新增） | 27 | 0 |
| `Tests/LocalQuotaBarTests/CodexAppServerLocatorTests.swift`（新增） | 69 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 1 | 1 |
| `Sources/LocalQuotaBar/codex/CodexUsage.swift` | 1 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/codex/CodexAppServerLocator.swift`（新增）
- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/codex/CodexUsage.swift`
- `Tests/LocalQuotaBarTests/CodexAppServerLocatorTests.swift`（新增）
