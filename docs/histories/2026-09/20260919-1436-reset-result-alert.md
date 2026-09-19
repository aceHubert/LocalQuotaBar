## [2026-09-19 14:36 +0800] | 任务：重置结果弹窗提示

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3`
- **Runtime**：ZCode Desktop（macOS）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 把重置调用后的结果弹出提示一下，调用成功提示重置成功，失败把错误内容打印出来，按纽 关闭。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/main.swift`。

**主要操作**：

- **新增结果弹窗**：`presentResetResultAlert(success:failureMessage:)` 成功显示"重置成功"（informational），失败显示"重置失败"并以 informativeText 展示具体原因（warning），仅有"关闭"一个按钮。
- **接入两个重置流程**：Codex 重置卡（`useCodexResetCredit`）与 ZAI 重置卡（`useZAIResetCard`）在 `use` 调用返回后弹窗；失败原因从对应 ResetService 的 `.failed(message)` 状态读取，无状态时回退为"重置未完成，请重试"。

### 设计动机

此前重置调用结束后没有任何结果反馈，用户只能通过按钮状态变化推断成败。两个 ResetService 的 `use` 已把失败原因写入 `.failed(String)` 状态，弹窗直接复用该状态取错误文案，不改动服务层；成功路径语义保持"返回 true 即已确认成功"（含记录落盘失败但上游已重置的场景），仍按成功提示并触发刷新。

### 验证结果

- 命令与结果：
  - `swift build`：Build complete!（2.50s）。
- 手工验证及设备：用户人工验收（成功/失败弹窗文案与"关闭"按钮）。
- 未覆盖场景：NSAlert 为运行时 UI，未做自动化测试。

### 变更统计

- **统计口径**：按本次 patch 手工统计，仅 `Sources/LocalQuotaBar/main.swift`；同工作区尚有其他任务的既有未提交改动，未混入本次数字。
- **变更文件数**：1
- **新增行数**：+32
- **删除行数**：-6

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | +32 | -6 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift`
