## [2026-09-18 19:00 +0800] | 任务：修复 ManualRefreshTests 既有失败

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：a14d47f3-204c-4979-be58-fd77ef7f8b68/Atria-Dawn-Preview
- **Runtime**：macOS 25.6.0 arm64（darwin），Swift 工具链（测试需 `arch -arm64 /usr/bin/swift test`，默认工具链架构不匹配）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 归档复核时发现 `swift test` 有一项稳定失败（`testFailedRefreshAndErrorRetryPreserveCooldown`，103 项中唯一失败）。用户先问"这个失败是哪里失败"，确认根因后要求"改掉"。

### 变更概览

**影响范围**：`Tests/LocalQuotaBarTests/ManualRefreshTests.swift`、`docs/exec-plans/tech-debt-tracker.md`、`docs/exec-plans/completed/quota-popup-ui-redesign.md`（测试结果数字同步）

**主要操作**：

- **诊断**：逐步追踪调用链——header 刷新按钮 `onTap` → `ProviderPanelSection.requestRefresh()`（走 60 秒冷却）；错误横幅重试按钮（`QuotaPanelViews.swift:969-970` 的 target/action）→ `retryTapped()` → `onRetry` → `ProviderPanelSection.retryFromError()`（守卫 `canRetryRefresh`，**只做并发防重、不看冷却**，这是有意的設计，见 `QuotaPanelViews.swift:333` 与 `ProviderPanelSections.swift:83-84` 的注释）。测试在 `:122` `performClick` 之后又在 `:123` 手动调了一次 `onRetry?()`，两次都放行，加上初次刷新共 3 次，与期望 1 不符。
- **修复测试**：去掉重复的 `onRetry?()` 调用，期望改为 2（初次刷新 1 + 重试 1），保留 `XCTAssertFalse(header.canRequestRefresh)` 验证重试不清除/不延长 header 冷却，并加注释说明"错误横幅重试按设计绕过冷却"。
- **技术债追踪**：将该条目标记为已解决（2026-09-18 修复，附验证依据）。
- **计划文档**：`completed/quota-popup-ui-redesign.md` 的测试结果从"103 项中 102 通过"改为"103 项全部通过"。

### 设计动机

生产代码按设计工作——失败横幅的重试是用户失败后的明确意图，绕过 60 秒冷却只做并发防重；问题纯粹是测试预期停留在重试语义变更之前（旧测试名 `...PreserveCooldown` 假设重试被冷却挡住）。因此只改测试不改生产，把断言对齐到"重试真实触发一次、但 header 冷却仍生效"，这恰好覆盖了重试与冷却两条路径的边界。

### 验证结果

- 命令与结果：
  - `arch -arm64 /usr/bin/swift test --filter ManualRefreshTests`：8 项全部通过（0.62s）。
  - `arch -arm64 /usr/bin/swift test`（全量）：103 项全部通过，0 失败（5.66s）。
- 手工验证及设备：本机 macOS 25.6.0 arm64；纯测试断言修正，无 UI 行为变更，未做手测。
- 未覆盖场景：重试按钮在真实失败场景下的 UI 态（横幅清空、按钮隐藏）依赖 store 回调，单测以 `apply(..., isRefreshing: false, error:)` 模拟，未走真实网络失败路径。

### 变更统计

> 测试文件已暂存为新增（`A`），本次编辑的增量用 `git diff`（worktree vs 暂存）计为 +4/-2；技术债与计划文档为已跟踪/新增文档，按行内容区分本次改动。历史记录自身不计入。

- **统计口径**：本次任务 3 个文件；测试文件只计今日编辑增量（+4/-2），技术债 1 行改写、计划 1 行改写。
- **变更文件数**：3
- **新增行数**：+6
- **删除行数**：-4

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Tests/LocalQuotaBarTests/ManualRefreshTests.swift` | 4 | 2 |
| `docs/exec-plans/tech-debt-tracker.md` | 2 | 1 |
| `docs/exec-plans/completed/quota-popup-ui-redesign.md` | 1 | 1 |

### 修改文件

- `Tests/LocalQuotaBarTests/ManualRefreshTests.swift`
- `docs/exec-plans/tech-debt-tracker.md`
- `docs/exec-plans/completed/quota-popup-ui-redesign.md`
