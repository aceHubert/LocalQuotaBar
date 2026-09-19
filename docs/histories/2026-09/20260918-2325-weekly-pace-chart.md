## [2026-09-18 23:25 +0800] | 任务：实现周限额配速图与 Z.AI 用量叠加显示

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）`
- **Runtime**：`ZCode CLI，macOS 25.6.0 arm64`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 实施 weekly-pace-chart-handoff.md 的修改。

按 [weekly-pace-chart-handoff.md](../../exec-plans/completed/weekly-pace-chart-handoff.md)（权威设计 [weekly-pace-chart.md](../../exec-plans/completed/weekly-pace-chart.md)）完成两个交付物：周限额配速图（新视图）与 Z.AI 近 30 天图的叠加显示模式，含数据层三个新查询、周预算估算器、单测与双 provider 接线。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（新组件 + 图表改造 + 接线）、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **操作一（数据层）**：`ZCodeUsageDB` 新增三个只读查询——周期内逐日聚合、周期内总量（均按渠道 id 集合 + 毫秒精确窗口过滤）、30 天全渠道/当前渠道拆分日聚合；`ZAIUsageStore` 扩展 `splitDays` 与 `refreshPace(windowStart:windowEnd:providerIDs:)`。
- **操作二（纯逻辑层）**：`WeeklyPaceEstimator.swift` 落地估算器（E 反推、`usedPercent < 5%` 不更新、同窗口 EMA α=0.5、新窗口首个可信观测直接采用、按渠道+账号分桶持久化）、`ZAIPaceChannel` 渠道 id 解析、`WeeklyPaceCodexBridge` Codex 首日时间比例折算。
- **操作三（组件层）**：`ui/WeeklyPaceChartView.swift` = `WeeklyPaceSnapshot.make` 纯函数推导（等宽自然日格横轴、对角线锚定 W0 真实时刻、历史点位/今日真实点、降级阶梯、tooltip 文案）+ 绘制视图（对角线虚实分段、红绿点、空心今日点、50% 网格、星期/M/d 刻度、即时悬停浮层）。
- **操作四（叠加显示）**：`DailyUsageChartView` 支持「总量/叠加」切换（头部胶囊、UserDefaults 持久化、默认叠加）、下绿上橙两段柱、图例行、三段式 tooltip；`ChartTooltipWindow` 提为内部共享并支持尾注行。
- **操作五（挂载与接线）**：`ProviderPanelSection` 在重置卡与 30 天图之间挂载配速图（默认隐藏）；`main.swift` `refreshCodexPaceChart` / `refreshZAIPaceChart`（额度与用量刷新任一到达都重算），Codex 侧 7±1 天周窗门控、ZAI 侧仅 coding-plan + 周限。
- **操作六（文档）**：技术债登记三条；计划与 handoff 填写实际结果后归档至 `completed/`。

### 设计动机

- 独立组件封装（handoff 增补要求）：视图与推导层只依赖 `WeeklyPaceSnapshot`/`DayUsage`/`PanelTheme`，不感知 `QuotaBucket`/`ZAILimit`/SQLite；provider 适配（窗口锚点、数据源、渠道过滤、估算器实例）全部在 `main.swift` 接线层完成，后续月限窗口等新配额源只加适配映射。
- 横轴按**等宽自然日格**实现（对齐原型）：时间戳在格内按当日比例定位，W0 非零点时对角线起点落在首日格 13/24 处、终点在末格中间——而非窗口时间等比轴（那会把首日部分格压窄，与设计稿不符）。
- 实现期实测发现 ZCode 3.12.3+ 把 coding-plan 用量的 `provider_id` 从 `builtin:zai-coding-plan` 迁移为 `account:zai-individual-coding-plan`（setting.json selectedKey 冻结在旧值）：渠道过滤改为双前缀 id 集合；E 分桶键用 `domain-coding-plan|邮箱` 而非具体 provider id，避免 CLI id 迁移打断估算历史。
- 渲染期间通过离屏渲染 PNG + 视觉核验发现并修复 `plotY` 在 AppKit 上行坐标系中方向写反的 bug（百分比点上下镜像、对角线在 now 处折弯）；叠加柱改用整柱胶囊 + 上下裁剪着色，替代手写混合圆角弧线。

### 验证结果

- 命令与结果：`swift build`（debug 与 release 均 0 错误 0 警告）；`swift test` 131 用例全部通过，其中新增 `WeeklyPaceChartTests` 25 项（窗口切分 8/7 格、首日折算、E 估算门槛/EMA/新窗口/分桶隔离、恰好压线着色、cum>E clamp、渠道 id 解析、降级阶梯各级、tooltip 文案）。
- 数据冒烟：三个新 SQL 查询对本机 `~/.zcode/cli/db/db.sqlite` 只读执行通过，coding-plan 渠道过滤在 2026-09-16 前后的两种 provider_id 前缀下均取到数据（合并口径含 09-18 当日用量）。
- 视觉核验：配速图与叠加图离屏渲染 4x PNG 逐项检查（对角线单一直线且虚实分段共线、4 红 1 绿点位与折线下降走势、空心今日环低位红描边、8 格星期刻度无缺字、图例/胶囊激活态、叠加柱两段等宽无"蘑菇头"）；今日环与对角线的间隙为超配速语义（真实 12% vs 此刻理想 28.6%），非渲染缺陷。
- 手工验证及设备：真机项未执行（无 GUI 交互环境）——Codex/Z.AI 真实刷新链路下的配速图与降级回落、hover tooltip 实机表现、切换持久化重启生效、Touch Bar / 刘海屏，待用户复核。
- 未覆盖场景：见上与计划文档"实际结果与未覆盖场景"。

### 变更统计

> `git diff --cached --shortstat` / `--numstat`（基线 HEAD，排除历史记录自身与他人未提交的 `Tools/`、`canvas/` 改动）。

- **统计口径**：本次任务暂存的 10 个文件（Sources 5、Tests 1、docs 4，含计划归档移动）
- **变更文件数**：10
- **新增行数**：+1707
- **删除行数**：-57

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/WeeklyPaceEstimator.swift` | 118 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 107 | 5 |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | 254 | 32 |
| `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift` | 30 | 3 |
| `Sources/LocalQuotaBar/ui/WeeklyPaceChartView.swift` | 572 | 0 |
| `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift` | 198 | 4 |
| `Tests/LocalQuotaBarTests/WeeklyPaceChartTests.swift` | 394 | 0 |
| `docs/exec-plans/completed/weekly-pace-chart-handoff.md`（自 active/ 移动+修订） | 19 | 6 |
| `docs/exec-plans/completed/weekly-pace-chart.md`（自 active/ 移动+修订） | 12 | 7 |
| `docs/exec-plans/tech-debt-tracker.md` | 3 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/WeeklyPaceEstimator.swift`（新建）
- `Sources/LocalQuotaBar/ui/WeeklyPaceChartView.swift`（新建）
- `Tests/LocalQuotaBarTests/WeeklyPaceChartTests.swift`（新建）
- `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`
- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`
- `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`
- `Sources/LocalQuotaBar/main.swift`
- `docs/exec-plans/tech-debt-tracker.md`
- `docs/exec-plans/completed/weekly-pace-chart.md`（含并行增补的组件封装要求，随归档一并提交）
- `docs/exec-plans/completed/weekly-pace-chart-handoff.md`（同上）
