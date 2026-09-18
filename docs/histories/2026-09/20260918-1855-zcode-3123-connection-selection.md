## [2026-09-18 18:55 +0800] | 任务：跟随 ZCode 3.12.3 的套餐切换持久化

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：Atria-Dawn-Preview
- **Runtime**：zcode CLI（macOS 15，arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> zcode 切到了 start plan，怎么 z.ai 没有更新逻辑呢？（并指出 codex-cliproxy-zcode3123 项目的最后更新应为同一问题。）

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **解析新字段**：`ZAISettings.resolveProviderSelection()` 优先读 `providerFamilyConnectionSelections[domain].kind` 并归一化（start-plan → `.startPlan`；individual/team-coding-plan → `.codingPlan`），缺失或非法时回退原 `modelProviderFamilySelectedKeys` 路径。
- **可测性**：拆出纯解析入口 `resolveProviderSelection(object:)`，文件 IO 仍走原入口，单测直接注入 setting.json 字典。
- **团队版判定**：`ZAIResetContextResolver` 的 team 排除改为先看 `connectionKind`（新格式不写 selectedKey），legacy 路径仍看 selectedKey。
- **测试**：新增 `ZAIProviderSelectionTests`（6 例），`ZAIResetIntegrationTests` 补 team / individual 连接类型的放行与拒绝。

### 设计动机

ZCode 3.12.3 起切换套餐只写 `providerFamilyConnectionSelections[domain].kind`，`modelProviderFamilySelectedKeys` 冻结在旧值。用户切到 start-plan 后，本机磁盘上连接选择是 `start-plan`、selectedKey 仍是 `coding-plan:builtin:zai-coding-plan`，App 按旧字段解析为 coding-plan，去查 `api.z.ai` 的 5 小时/周限额，看起来像「没更新」，实际是跟错了套餐。kind 取值取自 `zcode.cjs` 的 schema（仅 start-plan / individual-coding-plan / team-coding-plan），api-key 模式不写连接选择，仍由 legacy key 表达，所以保留回退。未知 kind 也回退，而不是报错——菜单栏应用优先展示 legacy 可用数据，避免静默空面板。

### 验证结果

- 命令与结果：
  - `swift build`：Build complete。
  - `swift test --filter ZAIProviderSelectionTests|ZAIResetIntegrationTests`：10 例全部通过。
  - `swift test` 全量：103 例，1 例失败 `ManualRefreshTests/testFailedRefreshAndErrorRetryPreserveCooldown`（`("3") is not equal to ("1")`）。已通过临时还原本次改动复现同一失败，确认为本次改动之前就存在的既有失败，与本次无关。
- 手工验证及设备：解析逻辑用本机真实 `~/.zcode/v2/setting.json`（连接选择 `zai: start-plan`、selectedKey 冻结在 coding-plan）核对，归一化后为 `.startPlan`；coding-plan / bigmodel / api-key / team 各分支由单测覆盖。
- 未覆盖场景：start-plan 余额的实际网络拉取未实跑——当天 host 日志没有 `billing/balance 请求完成` 条目（3.12.3 可能改了日志标记或尚未触发请求），代码会回退到 provider 自身 baseURL + config.json 明文 JWT 的网络路径。既有 `ManualRefreshTests` 失败未修复。

### 变更统计

- **统计口径**：基线为改动前工作区（zcode/ 与 Tests/ 均未跟踪，按新增计），任务文件范围为四个改动文件，排除历史记录自身。
- **变更文件数**：4
- **新增行数**：+152
- **删除行数**：-8

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | +47 | -1 |
| `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift` | +11 | -1 |
| `Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift` | +77 | 0 |
| `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift` | +17 | -6 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift`
- `Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`
- `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift`
