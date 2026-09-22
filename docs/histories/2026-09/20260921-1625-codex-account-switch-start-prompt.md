## [2026-09-21 16:25 +0800] | 任务：切换账号后按 app-server 状态提示启动 Codex

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-5`
- **Runtime**：`Codex Desktop（macOS）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 切换 Codex 账号后，先判断 Codex 是否启动；未启动时不弹立即重启窗口，提示“账号已切换到 xxx，请启动 Codex”。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **新增只读状态判断**：复用已有的 app-server 进程扫描，区分运行中、未运行和扫描失败，不启动或停止任何进程。
- **调整账号切换流程**：未发现 app-server 时跳过重启确认，提示账号已切换并请用户启动 Codex；扫描失败时保守保留原确认流程。
- **补充单元测试**：覆盖三种进程状态。

### 设计动机

不能通过 app-server RPC 判断是否已启动，因为 RPC 检测本身会拉起新的 stdio app-server。复用已有的精确进程识别逻辑可以避免误判，并继续过滤 LocalQuotaBar 自己启动的读取子进程。

### 验证结果

- 命令与结果：`swift test` 通过，221 个测试全部通过；`swift build` 通过；`git diff --check` 通过。
- 手工验证及设备：未执行 UI 手工切换验证。
- 未覆盖场景：进程扫描与用户随后启动/退出 Codex 之间存在正常竞态。

### 变更统计

> 仅统计本次任务文件，排除本历史记录及工作区中既有的图标、草稿和执行计划改动。

- **统计口径**：工作区基线到本次任务完成；仅统计 3 个任务源码/测试文件。
- **变更文件数**：3
- **新增行数**：+67
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift` | 17 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 21 | 0 |
| `Tests/LocalQuotaBarTests/CodexAppServerRestartServiceTests.swift` | 29 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Tests/LocalQuotaBarTests/CodexAppServerRestartServiceTests.swift`
