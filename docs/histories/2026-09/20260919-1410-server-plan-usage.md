## [2026-09-19 14:10 +0800] | 任务：套餐用量切换服务端口径并按账号增量缓存

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）
- **Runtime**：macOS 25.6.0 arm64 + SwiftPM
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 排查 zcode 套餐用量如何查询：本地 SQL 只有本机记录、换账号查不到，而 ZCode 官方统计里有套餐数据。随后确认口径应为"总用量 = 服务端套餐 + 本地第三方"，服务端数据（含周预算 E 反推输入）按账号做增量缓存（30 天日桶钳位 T-29、7 天小时明细钳位 T-7、两次逻辑同步按窗口合并请求、失败不动缓存），并按执行计划 `docs/exec-plans/active/server-plan-usage.md` 实施。GUI 验收期间口径经两次用户决策调整，最终定案：总计 = 服务端套餐（全设备，已含本机套餐部分）+ 本机非套餐渠道，不双计。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **新增 `ZAIServerUsage.swift`**：model-usage 请求构造（quota/limit 同源认证、团队 type=2 与 org/project 头）、防御式响应解析（hourly/daily 粒度无关聚合）、按日组织缓存（`{lastDailyFetchedAt, lastHourlyFetchedAt, daily:[{date, usage, hourly[]}]}`）、统一增量同步规划（请求合并纯函数、覆盖写、双粒度滚动淘汰、小时边界切窗）与 `ZAIServerUsageStore`（额度刷新成功后增量同步、分桶校验、启动 preload）。
- **`ZAIQuota.swift`**：coding-plan 额度刷新成功后通过 `onUsageSyncContext` 回调携带已捕获凭证上下文（个人 OAuth / 团队项目 Key），避免用量同步重复走团队 Key 换取链路。
- **`ZCodeUsageDB.swift`**：新增 `last30DaysExcludingCodingPlan()`（`provider_id NOT LIKE '%coding-plan'`，不误伤 start-plan）；`ZAIUsageStore` coding-plan 模式查本机非套餐、其余模式查全渠道。
- **`main.swift`**：`recomputeZAIUsage()` 组合"服务端套餐（全设备）+ 本机非套餐"口径（不双计；服务端缓存未建立时展示空图不回落）；配速图改为服务端小时明细同步切窗求和，E 反推与 usedPercent 两端同源；服务端缓存更新后自动重算图表。
- **`DailyUsageChartView.swift`**：叠加图图例「套餐（服务端）/ 第三方（本机）」，tooltip 列「套餐 / 第三方 / 总计」三项（总计 = 两段之和，无重叠）。
- **测试**：新增 `ZAIServerUsageTests` 16 个用例；执行计划补记实现期决策与验证结果。

### 设计动机

本地 `model_usage` 表无账号维度（provider_id 只区分渠道形态），换账号后图表混入旧账号记录或缺数据；服务端 `api/monitor/usage/model-usage` 是账号维度、跨设备的计费真实 token（从 ZCode host 包逆向还原并实测：≤8 自然日窗口返回 hourly、>30 天被拒、短窗与全量口径逐字节一致）。增量缓存以时间戳判进度（单测暴露按条目日期推导会让 daily 缺口永久残留）、边界日重查吸收延迟上报、同日桶覆盖写防双计；daily/hourly 两次逻辑独立、请求层按窗口合并，稳态每刷新周期仅一次「近两天」GET。口径经 GUI 对账收敛：小时级对齐证明本机套餐消耗已含在服务端套餐数内（01:00 桶 613.9 万 vs 614.1 万），故最终采用不双计口径——绿段套餐（全设备）+ 橙段本机非套餐，总计 = 账号全部消耗；ZCode 应用用量与本图橙段的差即本机套餐部分，属预期。

### 验证结果

- 命令与结果：`swift build` 0 error / 0 warning；`swift test` 157/157 通过（含新增 16 个；口径调整后复跑仍全绿）。
- 接口实测（调研阶段，真实账号只读 GET）：短窗 [昨天 0 点, 今天] 与 30 天全量对同日日桶数值一致；[T-7 00:00, 今天] 仍为 hourly（182 点），T-7 钳位覆盖周窗口起点边界。
- GUI 实测（2026-09-19，个人 zai 套餐）：重启后首个刷新周期完成同步，昨日 usage 与接口实测逐字节一致（110.70M）；今日小时点数与时刻吻合；与应用用量对数确认——本机全渠道 3318.0 万 = ZCode 应用用量 3318 万（模型分解 GLM-5.3 3315.8 万 + GLM-5.3-Flash 2.2 万）；服务端套餐 7668.6 万与本机套餐 3318 万之差 4350 万为跨设备消耗，用户确认当日确有外部使用；API Key 平台消耗不占套餐额度、不进任何统计段（已记技术债）。
- 未覆盖场景：换账号实测、断网失败保持缓存实测、团队套餐（bigmodel）联调、Touch Bar / 刘海屏展示。

### 变更统计

- **统计口径**：`git diff HEAD -- <任务文件>`（含任务开始前工作区已有未提交改动，无法拆分，如实计入）+ 新增文件 `--no-index /dev/null` 对比；历史记录与执行计划文档不计入。
- **变更文件数**：6
- **新增行数**：+1727
- **删除行数**：-98

| 文件 | 新增 | 删除 |
| --- | ---: | --- |
| `Sources/LocalQuotaBar/zcode/ZAIServerUsage.swift`（新增） | 451 | 0 |
| `Tests/LocalQuotaBarTests/ZAIServerUsageTests.swift`（新增） | 292 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 176 | 7 |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | 291 | 48 |
| `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift` | 234 | 6 |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | 283 | 37 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIServerUsage.swift`（新增）
- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`
- `Tests/LocalQuotaBarTests/ZAIServerUsageTests.swift`（新增）
- `docs/exec-plans/active/server-plan-usage.md`（计划创建与进度更新，不计入统计）
