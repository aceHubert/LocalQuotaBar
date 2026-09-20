# [2026-09-19 23:35 +0800] | 任务：ZAI 设置文件变更仅更新本地参数，不触发刷新

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> ZAI 会频繁刷新，是因为文件监控导致的吗？确认后修复：只认 credentials.json/setting.json 的变化并对比账号、domain、selection；文件变更时不刷新，只更新下一次要刷新的参数，手动刷新和切换 plan 才触发刷新。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/ZAIQuota.swift`、`Tests/LocalQuotaBarTests/`

**主要操作**：

- **诊断确认**：`ZAIQuotaStore.watchSettingsFiles()` 监听 `~/.zcode` 与 `~/.zcode/v2` 整个目录且掩码含 `.attrib/.extend`，目录里的 `tasks-index.sqlite-wal/-shm`（CLI 任务索引库连接开关时创建删除）、`telemetry-state.json`、`setting.json` 自身的 `recentProjects` 字段都会触发目录事件，每次事件经 1 秒防抖后无条件发起完整网络刷新。
- **新增过滤层**：`ZAISettingsFileStamp`（单文件 mtime+size）、`ZAISettingsFileIdentity`（账号身份 + 文件级 provider 选择）、`ZAISettingsChangeResolver`（纯函数决策：ignore / applySettingsChange）。
- **文件变更不再触发网络刷新**：目录事件 → 防抖 1 秒 → stamps 比对（目录噪声忽略）→ 语义摘要比对（token 轮换、recentProjects 重写忽略）→ 账号/渠道/套餐真的变了时仅更新本地状态：`applyCurrentDomainIfChanged()` 清掉旧上下文快照与 override、重读账号标签、`onChange` 通知 UI（含区块显隐）。不发任何网络请求。
- **刷新只由既有触发源驱动**：周期定时器（用户可配间隔）、手动刷新按钮、`refreshAfterPlanViewChange`（切换套餐视图）、`refreshAfterReset`。`fetchSnapshot()` 执行时现读 `resolveProviderSelection()`，天然使用最新文件参数。
- **收敛触发面**：监控掩码从 `[.write, .delete, .rename, .attrib, .extend]` 收窄为 `[.write, .delete, .rename]`；`ZAISettings.settingsFileURLs` 固定列出受监控文件清单。

### 设计动机

- 保留目录级监听而非改监听文件：zcode 原子替换文件会使 DispatchSource 绑定的旧 inode 失效，目录监听天然规避；噪声问题改由事件后的内容过滤解决。
- 语义摘要取"账号身份 + 文件级 selection"而非文件哈希：token 轮换和 `recentProjects` 更新是高频重写但与额度展示无关，哈希比对会继续误触发。
- 中间版本曾实现"冷却 5 分钟 + 冷却期内延后补刷"，按用户反馈改为彻底不刷新：文件变更只保证下次刷新（定时器/手动/切套餐）用新参数，避免文件路径产生任何网络请求；真实换号后旧渠道快照由 `applyCurrentDomainIfChanged` 立即清掉，不会挂错账号展示。
- 登出（账号身份变 nil）视为语义变化，同样只走本地更新；额度区块显隐由 `onChange → updateZAISectionVisibility` 跟随。

### 验证结果

- 命令与结果：`swift build` 成功；`swift test` 全量 199 个用例通过（含 `ZAISettingsChangeResolverTests` 5 个：目录噪声忽略、无关重写忽略、账号变化仅更新本地、切渠道仅更新本地、登出视为变化）。
- 手工验证及设备：未做运行时手工验证（需登录态与本机 zcode 活跃写入），逻辑由纯函数单测覆盖。
- 未覆盖场景：`handleSettingsFilesChange` 与真实 DispatchSource 事件的端到端联动未自动化测试；`readSettingsFileStamps/Identity` 直接读真实 home 目录，未做注入化。

### 变更统计

- **统计口径**：本次任务相对暂存区（index）的工作区差异；新增测试文件为未跟踪文件，按行数计入；不含历史记录自身与其他任务的既有改动。
- **变更文件数**：2
- **新增行数**：+181
- **删除行数**：-6

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | +108 | -6 |
| `Tests/LocalQuotaBarTests/ZAISettingsChangeResolverTests.swift` | +73 | -0 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Tests/LocalQuotaBarTests/ZAISettingsChangeResolverTests.swift`
