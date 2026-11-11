## [2026-11-01 18:27 +0800] | 任务：拆分 Z.AI 套餐视图的用量口径

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`account:zai-individual-coding-plan/GLM-5.3`
- **Runtime**：`ZCode Desktop（macOS 25.6.0 arm64）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> zcode 的用量好像查出来有问题，startup 查出来好像就是订阅的，是一样的数据。
> （追问确认数据可分后补充：coding plan 是不是也要区分 start plan 的？）

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/`

**主要操作**：

- **诊断**：体验套餐（start-plan）视图的用量图走 `ZCodeUsageDB.last30Days()`（本机全渠道、无 provider 过滤），把 2921M 的订阅用量混了进来——本机近 6 天 coding-plan 渠道占全渠道 65%~100%，因此两视图图表几乎逐日相同。
- **数据源确认**：`model_usage.provider_id` NOT NULL，全库仅 3 个带 `plan` 的 provider（`account:zai-start-plan` / `account:zai-individual-coding-plan` / `account:bigmodel-team-coding-plan`），订阅与体验逐行可分、无空值、无自定义渠道误匹配。
- **拆分口径**：`last30DaysExcludingCodingPlan()` 改名 `last30DaysThirdParty()`，同时排除 `%coding-plan` 与 `%start-plan`（订阅部分已含在服务端口径、体验部分属于其视图的套餐段，均不算"第三方"）；新增 `last30DaysStartPlan()`（`LIKE '%start-plan'`）；两者共用新抽出的 `last30DaysFiltered(_:)`。
- **接线分流**：`ZAIUsageStore` 按套餐视图查询（coding-plan → 第三方；start-plan → 体验套餐渠道；其余 → 全渠道）；`recomputeZAIUsage` 分流——coding-plan 维持"服务端套餐（绿）+ 本机第三方（橙）"叠加，start-plan 仅本机体验套餐渠道单色展示（不引入叠加，保持该视图原有形态），两个套餐视图互不混入对方用量。
- **注释同步**：更新 `DailyUsageChartView` 类文档/叠加段注释与 `ProviderPanelSections` 的口径注释。

### 设计动机

- 用户在体验套餐视图看到的用量被订阅用量主导，图表失去了"该套餐用了多少"的信息；对称地，coding-plan 视图的"第三方（本机）"橙段也在吞 449M 的体验套餐用量（标签失真）。
- 初版曾把 start-plan 视图也做成"套餐 + 第三方"叠加，用户反馈该视图原本是单色总量、不应引入叠加，已回退为仅本机体验套餐渠道的单色展示；第三方叠加只属于 coding-plan 视图。
- 体验套餐无服务端时序接口（billing/balance 只有剩余额度），图表只能本机 CLI 口径——与余额卡（服务端、账号级、全设备）口径天然不同：实测"ZCODE WEEKEND BUILD"周末包（500M、仅 GLM-5.3-Flash）服务端已用 5.79M，但本机库 10-30 起无 start-plan 行，图表当日为 0 属预期，已在注释中明示。
- 沿用既有 `%coding-plan` 宽松匹配风格（覆盖 `builtin:`/`account:` 双前缀）；已知边界：自定义渠道名含 "start-plan" 会被误归，与既有匹配同款风险，本机不存在。

### 验证结果

- 命令与结果：
  - `swift build` → `Build complete!`（无警告；修复过程中消掉一处 `case .apiKey, nil` 对非可选 `kind` 的死分支警告）。
  - 本机 db.sqlite 核对新口径：近 6 天 start-plan 视图仅 10-26 有 1.2M（此前该视图显示的是 90M+/天的订阅量）；10 月初高峰期（10-03 等）100M/天的体验套餐用量归位到其视图，coding-plan 视图橙段同步不再包含该部分。
  - `make install` + 重启（pid 87764）：切 start-plan 视图确认单色无叠加图例。
- 手工验证及设备：本机 darwin arm64；GUI 已重启待用户切换套餐视图复核两图数字。
- 未覆盖场景：其他设备/入口上体验套餐的用量（无服务端时序接口，图表无法覆盖，见设计动机中周末包案例）；自定义渠道名恰含 "start-plan" 的误归场景。

### 变更统计

- **统计口径**：工作区未提交 diff（基线 HEAD `533f2ca`），任务文件范围 `Sources/LocalQuotaBar/`（排除历史记录自身与用户此前未提交的 codebuddy 改动）。
- **变更文件数**：4
- **新增行数**：+86
- **删除行数**：-36

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 31 | 20 |
| `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift` | 50 | 13 |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | 2 | 2 |
| `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift` | 3 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`
- `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`
