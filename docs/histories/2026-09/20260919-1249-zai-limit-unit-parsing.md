## [2026-09-19 12:49 +0800] | 任务：修正 ZAI 限额窗口解析

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-5`
- **Runtime**：Codex Desktop（macOS）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 个人 Coding Plan 返回 `TIME_LIMIT + unit=5` 时不应生成周限；不要按类型或数量推断 fallback，没有值就按没有值处理，并沿用无限制展示。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Sources/LocalQuotaBar/ui/`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/active/`。

**主要操作**：

- **删除 fallback 推断**：限额只在 `unit` 明确为可识别编码时建桶；`unit=5` 或缺失 `unit` 直接丢弃。
- **修正 UI 空态**：ZAI 周限缺失显示虚线“无限制”；5 小时缺失仍显示 "--"。
- **补充回归测试**：覆盖当前个人账号真实返回中的 `TIME_LIMIT + unit=5`，确认仅保留 `TOKENS_LIMIT + unit=3`。
- **更新执行计划**：记录“不做窗口推断”的决策与验证项。

### 设计动机

服务端返回的 `unit=5` 是另一类工具/时间限制，不是周限。此前代码在无法识别 `unit` 时退回按 `number` 推断，把 `number=1` 误当成周限，导致个人账号显示 `0%`。限额语义必须以服务端显式窗口为准，未知或缺失窗口不能被补造。

### 验证结果

- 命令与结果：
  - `swift test --disable-sandbox --filter ZAIQuotaEndpointTests`：11/11 通过。
  - `swift build -c release --disable-sandbox`：通过。
  - `git diff --check`：通过。
- 手工验证及设备：
  - 重启 `LocalQuotaBar-verify.app` 后，新个人账号快照仅剩 `unit=3` 的 5 小时限额，`unit=6` 周限消失。
  - 新进程 PID：`56237`。
- 未覆盖场景：
  - 未自动化检查 AppKit 胶囊渲染像素；已通过代码分支与刷新后的快照验证。

### 变更统计

- **统计口径**：按本次解析修正 patch 手工统计；同工作区还存在团队套餐接入的既有未提交改动，未混入本次数字。
- **变更文件数**：4
- **新增行数**：+13
- **删除行数**：-8

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | 0 | 7 |
| `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift` | 1 | 1 |
| `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift` | 10 | 0 |
| `docs/exec-plans/active/team-coding-plan-quota.md` | 2 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`
- `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift`
- `docs/exec-plans/active/team-coding-plan-quota.md`
