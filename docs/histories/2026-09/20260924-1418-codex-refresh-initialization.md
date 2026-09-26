## [2026-09-24 14:18 +0800] | 任务：修复 Codex 刷新初始化时序

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`未知（当前 Codex 会话未提供可确认型号）`
- **Runtime**：`Codex Desktop，macOS arm64`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> Codex 刷新一直失败，但 Codex 内部余额实际上会更新。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/main.swift`、
`Sources/LocalQuotaBar/codex/CodexUsage.swift`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **额度客户端协议时序**：先单独发送 `initialize`，等待并校验响应后，再发送
  `initialized` 与 `account/read`、`account/rateLimits/read` 等业务请求。
- **日用量客户端协议时序**：对 `account/usage/read` 应用相同的初始化握手，避免
  附加用量读取静默失败。
- **回归测试**：新增可控假 app-server，验证两条客户端路径在初始化响应前不会
  提前发送业务请求，并覆盖余额与日用量响应解析。

### 设计动机

直接复现 ChatGPT 内置 app-server 后确认：一次性写入初始化、初始化完成通知和
额度请求时，服务端可能返回 `failed to fetch codex rate limits`；等待初始化响应后
再发送业务请求即可正常返回额度与 credits 余额。因此根因是 JSON-RPC 初始化时序，
不是余额数据本身没有更新。两条只读链路都遵循同一协议约束，避免额度面板修复后
日用量仍因同样的竞态失败。

### 验证结果

- `swift build` ✅
- `swift test --filter CodexAppServerProtocolTests` ✅ 2 个测试通过。
- `swift test` ✅ 223 个测试通过，0 失败。
- `git diff --check` ✅。
- 手工复现 app-server：初始化响应前发送额度请求可复现失败；按新顺序发送可读到
  额度窗口与 credits 余额。
- 未覆盖 GUI 菜单栏刷新按钮实机点击；协议级测试已覆盖本次竞态。

### 变更统计

> 工作区未提交；统计本任务触碰的 3 个文件，历史记录自身不计入。

- **统计口径**：`git diff --numstat` 统计两个已跟踪源文件，新增测试按
  `/dev/null` 对比；排除任务开始前已有的未跟踪文件。
- **变更文件数**：3
- **新增行数**：+162
- **删除行数**：-53

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | +26 | -24 |
| `Sources/LocalQuotaBar/codex/CodexUsage.swift` | +63 | -29 |
| `Tests/LocalQuotaBarTests/CodexAppServerProtocolTests.swift` | +73 | -0 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/codex/CodexUsage.swift`
- `Tests/LocalQuotaBarTests/CodexAppServerProtocolTests.swift`
