# 周限额配速图 + Z.AI 用量图叠加模式 · 实现 Handoff

- 生成日期：2026-09-16
- 状态：**设计已定稿、原型已截图验收通过，待实现**
- 权威设计文档：[weekly-pace-chart.md](weekly-pace-chart.md)（含全部调研结论与决策记录；本文件为实现交接摘要，与计划冲突时以计划为准）
- 交互原型：open-design 项目 `quota-popup-redesign-9319` 的 `index.html`
  - 本地路径：`/Users/hubert/Desktop/projects/open-design/.od/projects/quota-popup-redesign-9319/index.html`
  - 预览：http://127.0.0.1:7456/api/projects/quota-popup-redesign-9319/raw/index.html
  - 关注两处：弹窗 **Z.AI 区块的"近 30 天用量"叠加柱状图**（含「总量/叠加」切换与图例行）；**页面底部 `.draft` 卡片**（配速图设计稿，编号图例标注语义）
- 执行仓库：本仓库（LocalQuotaBar，SwiftPM macOS AppKit 应用，macOS 13+，Swift 5.9）；`Tests/LocalQuotaBarTests/` 测试目标已存在（`Package.swift` 已注册）

## 交付物 A：周限额配速图（新视图）

一句话：在有周限额的 provider 卡片内新增一张燃尽式点位图——对角线是理想剩余配速（左上 100% → 右下 0%），每天一个评估点位，点在线下＝用多了（红），线上＝配速内（绿）。

- 挂载：`ProviderPanelSection` 内 `resetCards` 与 `usageChart`（30 天图）之间，默认 hidden。
- **坐标**：Y 轴 0–100%（100 顶、0 底）；X 轴 = **周限窗口实际覆盖的自然日**（W0 所在日 → 窗口结束日；W0 非零点时首尾为部分天格共 8 格，恰在零点 7 格），**不是固定的日历周一~周日**。
- **对角线**：`line(t) = 100% × (1 − (t − W0) / 窗口时长)`，按真实时间戳定位（起点 x = W0 在首日格内的位置）；已过段实线（白 0.45 alpha、1.25pt），今天之后到窗口结束为虚线。线不依赖估算值。
- **每日点位**：`100 × (1 − cum(k) / E)`（cum = W0 起周期内累计 tokens；E = 周预算估算值），3pt 圆点，相邻点 1pt 折线相连（alpha 0.25）。`cum > E` 时点 clamp 在 0%，tooltip 显示真实负值。
- **今日点**：不用估算——直接 `100 − 服务端 usedPercent`，画在 x=now、空心加大样式；与线在 now 处的值比较定色。
- **着色**：点在线下方 = 红 `PanelTheme.red`（#FF453A）；线上方 = 绿 `PanelTheme.green`（#32D583）。
- **头部**：左 `本周配速 · 第 d/N 天`；右 `日均可 ≈X`（E ÷ 窗口天数，`formatTokenCount`，仅 E 可用时显示；宽度不足则省略右侧）。
- **刻度**：窗口实际自然日 + 星期几，今日绿色高亮"今"；窗口 >7 天（ZAI `number > 1`）改用 `M/d` 且每 1~2 天一个刻度；50% 处一条淡虚线网格线。
- **tooltip（每天）**：`M月d日 · 当日 +X · 剩余 ≈Y%（理想 Z%）· 超配速 Δ / 配速内`；今日追加"（今天）"并显示真实百分比；尾部附 `预算为按用量与百分比的估算值`。
- **视觉**：卡片对齐 `DailyUsageChartView`（圆角 9、hairline 边框、inset 8）；柱区高 44，整卡约 86pt；高度变化走现有 `onContentHeightChange` → `updatePreferredContentSize`。
- **降级阶梯**（逐级退化，非整图消失）：
  1. 有周限桶且 `resetsAt`/`nextResetTime` 存在 → 画对角线（永远可画）。
  2. 有 `usedPercent` → 叠加今日真实点位。
  3. E 可估 → 补全历史点位与"日均可 ≈"。
  4. 无周限桶（ZAI apiKey/startPlan、Codex 无 weekly）→ 整图隐藏。Z.AI 侧仅 `kind == .codingPlan` 且存在 weekly limit 时显示。

## 交付物 B：Z.AI 近 30 天图叠加显示（改造 `DailyUsageChartView`）

- 仅 Z.AI 实例启用；Codex 实例维持现状（账号级数据，无渠道概念）。
- **叠加模式**：每根柱两段——下段 coding plan 用量（绿），上段其他渠道用量（**橙，定稿配色**）。原型参照色：绿 `#3FD98D→#1D9A5F` 渐变；其他渠道橙 `#FFB340→#F08C00` 渐变；今天亮绿 `#6CF0AC→#2BCF7D`、亮橙 `#FFD27A→#FFA726` 带光晕。Swift 侧映射到 `PanelTheme.green` / `PanelTheme.orange` 及其 highlight 变体即可，渐变不必逐像素复刻。
- **切换**：「总量 / 叠加」两种显示方式，默认**叠加**；偏好持久化（UserDefaults，建议 key `local.codex.touchbar.quota.zaiUsageDisplayMode`，值 "total"/"stacked"）。切换入口建议放在图卡头部（参照原型的 mode-chips）。
- **tooltip**：`M月d日 · coding plan X · 总计 Y`（`formatTokenCount`）；今日追加"（今天）"。
- **图例**：叠加模式下显示"■ coding plan / ■ 其他渠道（含第三方）"小图例行；总量模式隐藏。
- **日均线**：保持总量口径的日均（叠加模式不变位置与算法，仅数值单位随 tooltip 用 token 口径）。
- 数据来源见数据层第 3 条；叠加模式仅改渲染与数据传入，不改 30 天日桶的现有查询。

## 数据层规格

1. **渠道 id 动态解析（Z.AI）**：不硬编码。从 `ZAISettings.resolveProviderSelection()` 已解析的 `selectedKey` 取冒号后段（实测 setting.json：`"coding-plan:builtin:zai-coding-plan"` / `"coding-plan:builtin:bigmodel-coding-plan"`，随 `providerFamilyDomain` 切换）；解析不到时兜底 `builtin:\(domain)-coding-plan`；再解析失败 → 走降级阶梯。
2. **周窗口锚点**：Codex `resetsAt − windowDurationMins`；Z.AI `nextResetTime − 7 × number 天`。均为精确时刻（不落零点）。
3. **`ZCodeUsageDB` 新增三个只读查询**（沿用现有连接与 busy_timeout 策略；现有 `last30Days()` 全渠道口径保持不动）：
   - 周期内逐日聚合（配速图历史点位）：
     ```sql
     SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
            SUM(computed_total_tokens) AS tokens
     FROM model_usage
     WHERE started_at >= :windowStartMs AND started_at <= :nowMs
       AND provider_id = :providerID        -- 当前渠道 coding-plan，动态传入
     GROUP BY day
     ```
   - 周期内总量（预算估算用）：同上去掉 `GROUP BY` 取单个 SUM。
   - 30 天按渠道拆分日聚合（叠加柱状图）：按天 `SUM(computed_total_tokens)` 全渠道 + `SUM(... ) FILTER (provider_id = :providerID)`（或两条 SUM）各一列。
   - 注意：`provider_id` 区分渠道**不区分账号**（同渠道切账号用量混记）；索引 `model_usage_started_model_idx(started_at, provider_id, model_id)` 覆盖上述查询。
4. **Codex 路径**：官方 `dailyUsageBuckets` 只有自然日桶（180 天），本地 sessions 数据源已调研排除（`openai_base_url` 网关导致无法归因，详见计划"背景"）。首日按时间比例折算：
   `windowTokens = 首日桶 × (首日24点 − W0)/24h + 其间整天桶 + 今日桶`，配速图历史点位的每日累计同样按此口径（首日折算值）。
5. **周预算估算器 `WeeklyPaceEstimator`**（纯逻辑，可单测）：
   - `E = windowTokens ÷ (usedPercent / 100)`；`usedPercent ≥ 100%` 时 `E = windowTokens`。
   - `usedPercent < 5%`：**不更新**估算（整数百分比粒度方差大），沿用持久化旧值；无旧值则走降级阶梯第 2 级。
   - 同一窗口内多次观测 EMA 平滑（α = 0.5）；**新窗口第一个可信观测直接采用**（不与旧窗口混合，吸收网关换账号导致的 usedPercent 跳变）。
   - 持久化 UserDefaults，**按渠道 + 账号邮箱分桶**（邮箱来自 `loadAccount()`），账号/套餐/渠道切换自然失效。
   - 所有由 E 推出的展示值一律带 `≈`；对角线与今日点不依赖 E。

## 文件清单

新建：

- `Sources/LocalQuotaBar/ui/WeeklyPaceChartView.swift` — 视图 + `WeeklyPaceSnapshot` 纯函数推导（`make(...)` 输入窗口锚点/周期内每日累计/E/usedPercent，输出每个点位的 x、y、颜色、tooltip 数据；view 只管画）。
- `Sources/LocalQuotaBar/WeeklyPaceEstimator.swift` — 估算器（建议放根目录，与 `RefreshSettings.swift` 同级先例；实现者可与推导层合并到同一文件，保持纯逻辑可单测即可）。
- `Tests/LocalQuotaBarTests/WeeklyPaceChartTests.swift` — 单测（见下）。

修改：

- `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift` — 上述三个新查询。
- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` — 叠加模式渲染、切换入口、新 tooltip 与图例（仅 Z.AI 实例启用，经 configure 参数区分）。
- `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift` — 挂载 `paceChart`；Z.AI 侧传拆分数据与模式。
- `Sources/LocalQuotaBar/main.swift` — `applyCodexUsage` / `applyZAIUsage`（约 1911 行）接线：传周期内用量 + 当前快照周限桶 + 渠道 id，经估算器重算 `WeeklyPaceSnapshot`；额度刷新与用量刷新任一到达都重算。

## 单测清单（`WeeklyPaceChartTests.swift`，XCTest，`test<行为>` 命名，后台用例 60s 超时）

- 窗口切分：W0 非零点 → 首日部分天、8 格；恰零点 → 7 格。
- Codex 首日折算比例计算。
- E 估算：正常反推；`usedPercent < 5%` 不更新沿用旧值；`≥ 100%` 取 windowTokens；同窗口 EMA；**新窗口首个可信观测直接采用**；换渠道/换账号分桶不串值。
- 点位：线上/线下着色边界（含恰好压线）；`cum > E` clamp 0%。
- 渠道 id 解析：`selectedKey` 冒号后段提取；解析失败兜底拼接；最终失败 → 降级阶梯。
- 降级阶梯各级输出（只有线 / 线+今日点 / 全量点位 / 隐藏）。

## 验证方式

- 命令：`swift build`；`swift test --filter WeeklyPaceChart`。
- 手工：Codex 周窗与 Z.AI coding-plan 周窗的真机查看（对角线两端锚定真实时刻；今日点与周限格剩余百分比一致；点位随刷新更新；tooltip 明细；叠加/总量切换与持久化）。
- 观测：apiKey 模式不显示配速图；新账号 `usedPercent < 5%` 只显示线 + 今日点；Z.AI coding-plan 窗口聚合 ≤ 全渠道 30 天日桶对应日之和（第三方用量大的日子差值明显）。
- 设备项：按 AGENTS.md 记录 Touch Bar / 刘海屏实际验证情况。

## 红线（不做）

- 提醒链路（`ReminderEvaluator` / `ReminderCenter` / 通道）不动；配速超支不触发提醒。
- 网络读取与刷新调度（`RateLimitStore` / `ZAIQuotaStore` / `CodexRateLimitClient` / `ZAIQuota.swift` 解析）不动；`QuotaBucket` / `ZAILimit` 字段不改。
- Codex 侧 30 天图样式不改；现有 `last30Days()` 全渠道查询不改。
- 月限窗口（Codex free）不启用——算法按 `windowDays` 泛化即可。
- 不提交凭证/令牌；避免把 open-design 原型文件混入本仓库提交。

## 执行步骤（给实现会话）

1. 通读本文件 + [weekly-pace-chart.md](weekly-pace-chart.md)（重点"背景"的调研结论与"决策记录"）；打开原型 index.html 对照两处设计。
2. `ZCodeUsageDB` 三个查询 → `WeeklyPaceSnapshot` 推导与 `WeeklyPaceEstimator` → 单测（先红后绿）。
3. `WeeklyPaceChartView` 绘制 → `DailyUsageChartView` 叠加模式与切换 → `ProviderPanelSections` 挂载 → `main.swift` 接线。
4. `swift build` + `swift test`；按"验证方式"真机检查。
5. 收尾：按 `docs/histories/` 规范写历史记录（`git diff --shortstat` / `--numstat`）；技术债登记到 `docs/exec-plans/tech-debt-tracker.md`（Z.AI 估算口径、月限窗口放开）；计划文档状态更新并移入 `completed/`；提交信息用 `feat(quota): ...` 风格、单一目的。

## 已定决策摘要（详见计划"决策记录"）

- 点位图几何（剩余百分比口径，线下方＝用多了）——2026-09-15 用户确认。
- 横轴跟随周限窗口，非固定周一~周日。
- 预算是持续修正的估算值（EMA + 5% 门槛 + 新窗口重置），展示带 `≈`；今日点锚定服务端真实百分比。
- Z.AI 配速图用量只统计当前渠道 coding-plan（动态解析 provider_id）；30 天图总量仍为全渠道。
- 超配速点红色；叠加图"其他渠道"段橙色（紫→青→橙三轮定稿，2026-09-16）。
- 原型演示数据中"今天"柱其他渠道占比人为放大，仅为展示高亮橙帽，非真实数据口径。
