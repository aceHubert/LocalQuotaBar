## [2026-09-15 20:05 +0800] | 任务：重置卡到期接入提醒推送

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3`
- **Runtime**：`ZCode 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 重置快到时间了也应该添加到提醒中去；现在判断的是 5h/1w 的重置时间，不是重置卡的重置时间，如果不点就浪费了。只需要把 description 推送修改一下："你有一张重置卡将于 xx小时/xx分钟后过期"。固定 30 分钟，每 5 分钟提示一次，不需要根据设置来处理。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/` 提醒模型、评估器、提醒中心与两个供应商的快照映射；`Tests/LocalQuotaBarTests/` 新增测试。

- **统一提醒桶**：`ReminderBucket` 新增 `kind`（quota / resetCard）与 `cardCount`；Codex 快照把可用重置卡（状态为空或 available 且未过期）合成一个桶取最早到期，ZAI coding-plan 按种类（5小时/周额度）各合成一个桶。
- **固定触发规则**：`ReminderConfiguration` 新增固定常量——到期前 30 分钟窗口、每 5 分钟重复；评估器对重置卡桶跳过"百分比未变去重"并使用固定重复间隔，不受"重置还剩""提醒间隔"设置影响，仍受总开关与"不再提醒"静音约束。
- **推送文案**：`ReminderCenter.describe` 重置卡分支输出"你有一张重置卡将于20分钟后过期"（多张为"你有N张重置卡…"）；灵动岛触发摘要改为"重置卡快过期了"；右键"测试提醒"与真实数据的级别判定同步适配。

### 设计动机

重置卡到期作废是刚性损失，提醒价值随临近递增，因此不走"额度没动不重复打扰"的百分比去重，也排除用户把"重置还剩"调成关闭/长间隔的干扰，直接用固定 30 分钟窗口 + 5 分钟重复（默认自动刷新恰为 5 分钟，评估随刷新进行）。文案按用户模板输出小时/分钟粒度倒计时，剩余百分比恒按 100 展示，进度条呈满格绿色，与"卡本身未消耗"语义一致。

### 验证结果

- `swift build`：通过。
- `swift test`：90 个测试全部通过，含本轮新增 11 个（`ReminderEvaluatorTests` 6 个、`ResetCardReminderTests` 5 个）。
- 测试覆盖：固定窗口触发（"重置还剩"关闭时仍触发）、窗口外不触发、5 分钟固定重复（百分比恒定且提醒间隔设为 1 小时仍重复）、静音后停止、总开关关闭静默、额度桶百分比去重回归、两侧快照映射（最早到期/状态过滤/按种类分组）、推送文案与到期短语格式化。
- 未覆盖场景：Touch Bar / 刘海屏真实投递未在本机演示（无相关硬件记录），依赖现有通道渲染链路；重置卡重复提醒的实际节奏取决于自动刷新档位（默认 5 分钟对齐，更长档位下按刷新节奏稀释）。

### 变更统计

- **统计口径**：本轮修改前的三个含早期未提交改动文件（ReminderModels / main / ZAIQuota）按"逆向回滚本轮编辑的前置副本"做 `git diff --no-index`；本轮前干净文件用 `git diff HEAD --`；新增测试文件与 `/dev/null` 对比。不含历史记录自身。
- **变更文件数**：8
- **新增行数**：+343
- **删除行数**：-9

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ReminderModels.swift` | 31 | 1 |
| `Sources/LocalQuotaBar/ReminderEvaluator.swift` | 23 | 6 |
| `Sources/LocalQuotaBar/ReminderCenter.swift` | 20 | 1 |
| `Sources/LocalQuotaBar/main.swift` | 22 | 0 |
| `Sources/LocalQuotaBar/ZAIQuota.swift` | 34 | 1 |
| `Sources/LocalQuotaBar/DynamicNotchKitAlertChannel.swift` | 4 | 0 |
| `Tests/LocalQuotaBarTests/ReminderEvaluatorTests.swift` | 102 | 0 |
| `Tests/LocalQuotaBarTests/ResetCardReminderTests.swift` | 107 | 0 |

### 修改文件

- 上表八个文件及本历史记录。
