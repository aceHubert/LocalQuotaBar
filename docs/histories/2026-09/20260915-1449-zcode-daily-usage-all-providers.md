## [2026-09-15 14:49 +0800] | 任务：修复 ZCode 每日用量少算（改为全渠道聚合）

### 执行上下文

- **Agent ID**：zai-coding-plan/GLM-5.3
- **Base Model**：builtin:zai-coding-plan/GLM-5.3
- **Runtime**：ZCode 桌面应用，macOS，当前主会话
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 每日用量不对，你是从哪里获取的，这是 zcode 中显示的数据，每天都少 1-2000w

用户提供 ZCode 官方"使用统计"热力图截图：2026-09-14 为 8883.9万 tokens、47 轮消息，而应用面板同日明显偏小。

### 排查结论

数据源为 `~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表，按天 `SUM(computed_total_tokens)`。原查询带 `WHERE provider_id = ?`（当前选中的 `builtin:zai-coding-plan`），而官方统计页是**全渠道合计**：

- 2026-09-14 全渠道合计 88,839,193 tokens ≈ 8883.9万，与官方 tooltip 完全一致；其中 coding-plan 87,179,830、自定义渠道（UUID provider）1,439,735、`builtin:zai` 219,628。
- 官方"47 轮消息"与 `turn_usage` 当日 turn 数一致。
- 近 8 天单渠道与全渠道每日差异从 166 万到 1.79 亿 tokens 不等，与用户"每天少 1-2000w"描述吻合（部分天差异更大）。

### 变更概览

**影响范围**：Z.AI 面板每日用量图表取数逻辑。

- `ZCodeUsageDB.last30Days()`：去掉 `provider_id` 过滤与参数，SQL 仅按时间过滤，全渠道聚合（对齐官方口径）。
- `ZAIUsageStore.refresh(providerID:)`：保留 providerID 作为"是否展示图表"的开关（API Key 模式清空图表），数据查询不再按渠道过滤。
- `ZAIUsageProviderID` 注释同步更新为"是否展示"语义。

### 验证结果

- `swift build`：通过。
- 直接对 db.sqlite 执行新口径 SQL：2026-09-14 = 88,839,193 → 8883.9万，与官方统计页一致；2026-09-13 = 190,290,733，2026-09-15 = 82,589,906。
- 未覆盖：未重新打包运行 `.app` 做面板实测（构建已通过，查询口径已用 SQL 等价验证）。

### 变更统计

- **统计口径**：`ZCodeUsageDB.swift` 为未跟踪新文件（20260915-1222 改版任务创建），git diff 不可用；与任务前快照内容做 `git diff --no-index` 比较。历史记录自身不计入。
- **变更文件数**：1
- **新增行数**：+9
- **删除行数**：-8

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| Sources/LocalQuotaBar/ZCodeUsageDB.swift | 9 | 8 |

### 修改文件

- Sources/LocalQuotaBar/ZCodeUsageDB.swift
