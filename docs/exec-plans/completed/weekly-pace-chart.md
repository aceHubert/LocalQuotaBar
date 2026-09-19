# 周限额配速图（剩余百分比点位图 + 对角线）

- 状态：已完成（2026-09-18 实现落地；真机 Touch Bar / 刘海屏项待用户复核，见"实际结果"）
- 创建日期：2026-09-15
- 最后更新：2026-09-18

## 目标

在有周限额的 provider 区块（Codex 周窗、Z.AI coding-plan 周限）新增一张"本周配速图"：一条从左上（100%）到右下（0%）的对角线表示理想的剩余额度消耗配速，每天根据（估算的）用量在图上落一个剩余百分比点位；点位偏离对角线的方向和距离表示用多了还是用少了，帮助控制每天的用量、避免周限额提前耗尽。

## 范围

- 包含：
  - 新视图 `ui/WeeklyPaceChartView.swift`：对角线 + 每日点位 + 细折线 + hover tooltip。
  - 周预算估算：纯函数推导层 + 持久化估算器（可单测）。
  - `ZCodeUsageDB` 新增精确时间窗聚合（Z.AI 侧消除日对齐误差）与**按渠道拆分的日聚合**（coding plan / 其他）。
  - 近 30 天图（Z.AI 侧）新增**叠加显示**模式：总量青 + coding plan 绿分段，tooltip 改为「日期 · coding plan · 总计」，"总量 / 叠加"两种显示可切换。
  - `ProviderPanelSection` 挂载新图（重置卡与近 30 天图之间），Codex / Z.AI 两路数据接线。
  - `Tests/LocalQuotaBarTests/WeeklyPaceChartTests.swift`：窗口切分、预算估算、点位计算的单元测试。
- 不包含：
  - Codex 侧 30 天图样式（账号级数据，无渠道拆分概念）。
  - 网络读取、`QuotaBucket` / `ZAILimit` 模型字段的改动。
  - 提醒链路（配速超支暂不触发提醒）。
  - 月限窗口（Codex free 账号）启用——算法泛化了，首期只开 7±1 天窗口。

## 背景

- 相关代码路径：
  - 周限数据：`Sources/LocalQuotaBar/main.swift:11`（`QuotaBucket`：`usedPercent`、`windowDurationMins`、`resetsAt`）、`Sources/LocalQuotaBar/zcode/ZAIQuota.swift:23`（`ZAILimit`：`unit == .weekly`、`number`、`usedPercent`、`nextResetTime`）。
  - 每日用量：`Sources/LocalQuotaBar/codex/CodexUsage.swift:147`（`CodexUsageSnapshot.last30Days`，账号级）、`Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift:11`（本机 SQLite 按天聚合，全渠道合计）。
  - 现有图表与挂载：`Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`、`ui/ProviderPanelSections.swift:52`（stack 顺序）、`main.swift:1911`（`applyCodexUsage` / `applyZAIUsage` 接线）。
- 数据事实（决定设计的关键约束）：
  - 两边的周限都**只有百分比**（`usedPercent`），没有绝对 tokens；每日用量是 tokens。且**百分比与本地 tokens 不是同一计费口径**（服务端计数规则、取整粒度都不同），两者之间只能估算换算，不能当作精确等式。
  - **重置时刻不落在零点**，窗口边界与自然日桶不对齐：`dailyUsageBuckets` / 30 天日桶都是"当天 00:00 起"的整桶，直接按天求和会把窗口首日里属于上一周期的用量算进来。
  - 口径差异程度两边不同：Codex `usedPercent` 与 `dailyUsageBuckets` 都是账号级，估算自洽性较好；Z.AI `usedPercent` 是账号级（服务端），每日用量是**本机** SQLite 口径，多设备使用时估算会偏低（见风险）。
  - 粒度（2026-09-16 实测调研；重置时刻非整天/整点，周期内用量不能按整天推算）：
    - Z.AI / zcode：`model_usage` 为**单次请求级**——每行一条请求，`started_at` / `completed_at` 毫秒时间戳 + `computed_total_tokens`，可按任意时刻精确切窗（本机约 1.8 万行、~30 天滚动）。
    - Codex 官方（`account/usage/read` RPC）：**自然日桶**——`dailyUsageBuckets` 只有 `{startDate, tokens}`（180 天），另有 `summary` 账号级汇总与 `threadUsage`（常规为 null），无小时级。
    - Codex 本机 sessions（`~/.codex/sessions/**/rollout-*.jsonl`，2025-09 至今）：逐轮 `token_count` 事件（毫秒时间戳）且内嵌 `rate_limits` 快照，但经实测**排除作为数据源**：当前 config 以 `openai_base_url` 指向本地网关（127.0.0.1:8320），经网关的会话仍记 `model_provider:"openai"`、base_url 不落盘，订阅内外无法区分；网关透传的后端账号快照"看似有效"（实测经网关会话有 used_percent 94.0），不可归因；session 内无账号 ID，本机 10+ 个 `auth_*.json` 多账号无法归因。`~/.codex/sqlite/codex-dev.db` 无用量表。
  - **渠道口径**：`model_usage.provider_id` 区分渠道，权威 id 注册表来自 `~/.zcode/v2/config.json` 的 `provider` 块：`builtin:zai-coding-plan`、`builtin:bigmodel-coding-plan`、`builtin:zai-start-plan`、`builtin:bigmodel-start-plan`、`builtin:zai`、`builtin:bigmodel` 及 UUID 自定义渠道。**周限 `usedPercent` 只统计当前渠道 coding plan 的消耗**，配速图窗口用量必须同渠道过滤；现有 30 天日用量图刻意维持全渠道合计（含第三方），两者口径不同。索引 `model_usage_started_model_idx(started_at, provider_id, model_id)` 覆盖该过滤聚合。注意 `provider_id` 区分渠道**不区分账号**——同渠道切账号用量混记，而 `usedPercent` 属于当前账号。
  - 周窗口锚点：Codex `resetsAt - windowDurationMins`；Z.AI `nextResetTime - 7 × number 天`。两者都是精确时刻。

## 设计方案

### 方案 A（主案）：剩余百分比点位图（燃尽式）

Y 轴是剩余百分比（100% 在上、0% 在下），X 轴是**周限窗口实际覆盖的自然日**（跟随 W0，不是固定的日历周一~周日）。对角线从 (W0, 100%) 降到 (窗口结束, 0%)，是理想配速下剩余额度的下降路径；每天落一个"当天结束时剩余多少"的评估点位。

```
┌──────────────────────────────────────────────┐
│ 本周配速 · 第4/7天             日均可 ≈3.2M  │
│ ●╲ 100%   ← W0＝周二 13:00，线从真实时刻起降 │
│   ╲   ●                 ● 绿：配速内（剩得多）│
│    ╲    ↘●(红)          红：点在线下方，剩余  │
│ 50% ┈┈┈┈╲┈┈┈●┈┈┈┈┈        比理想少＝用多了   │
│           ╲     ◯ ← 今：服务端真实剩余%      │
│             ╲ ┈ ┈ ╲ ┈ ┈ ┈ ← 窗口未来段（虚线）│
│               ╲______╲______                │
│ 0%  二 三 四 五[今] 六 日 一 二          0%  │
└──────────────────────────────────────────────┘
```

语义与规则：

- **对角线**：`line(t) = 100% × (1 − (t − W0) / 窗口时长)`，按**真实时间戳**定位而非按天序号——起点 x 落在首日格内的真实位置（如 W0 = 周二 13:00，起点就在周二格的 13/24 处），终点落在 `W0 + 窗口时长`。今天之后的段落虚线延伸到 0%。这直接消化了"重置点不在零点"的问题：线锚定重置时刻，刻度保持自然日。**线本身是纯百分比空间，不依赖估算值**。
- **每日点位**：第 k 天的点 = 该天结束时的剩余百分比 `100 × (1 − cum(k) / E)`（cum 为 W0 起的周期内累计 tokens，Codex 首日按时间比例折算；E 为周预算估算值）。相邻点之间用 1pt 低透明折线（alpha 0.25）相连，点为 3pt 圆点。
- **今日点**：不用估算，直接用服务端 `usedPercent` 换算的真实剩余 `100 − usedPercent`，在 x=now 处绘制、空心加大样式；与线在 now 处的值比较判定超支。历史点靠 E 重建、今日点锚定真实值——由于 E 本身就是用最新一次 (windowTokens, usedPercent) 定的，两者在最新刷新下自洽。
- **超支判定（着色）**：点在**对角线下方**＝剩余比理想少＝（截至那天）用多了 → 红色 `PanelTheme.red`；在线上方＝配速内 → 绿 `PanelTheme.green`。累计口径天然自带"周中省着用会自动回到线上方"的自我修正。
- **头部**：左 `本周配速 · 第 d/N 天`，右 `日均可 ≈X`（`E / 窗口天数`，`formatTokenCount`；仅在 E 可用时显示）。宽度不够时右侧省略（与 30 天图"日均"同样的退让规则）。
- **刻度（跟随窗口，不固定周一~周日）**：横轴 = 周限窗口实际覆盖的自然日，从 W0 所在日排到窗口结束日——W0 落在当天中间时首尾都是部分天格，共 8 格；恰在零点时 7 格。标签显示这些天的星期几（如 `二 三 四 五[今] 六 日 一 二`，按窗口实际日期生成），今日高亮"今"；窗口长于一周（ZAI `number > 1`）时改用 `M/d` 并每隔 1~2 天一个刻度。左侧 50% 处一条淡虚线网格线，顶底 100%/0% 由对角线端点示意。
- **tooltip（每天）**：`M月d日 · 当日 +X · 剩余 ≈Y%（理想 Z%）· 超配速 Δ`（配速内显示 `配速内`），今日显示真实百分比并追加"（今天）"；尾部附 `预算为按用量与百分比的估算值`。
- **视觉**：卡片样式对齐 `DailyUsageChartView`（圆角 9、hairline 边框、inset 8）；对角线 1.25pt 白色 0.45 alpha 实线（未来段虚线）；柱区高度 44，整卡约 86pt。
- **降级阶梯**（数据不全时逐级退化，而不是整图消失）：
  1. 有周限桶且 `resetsAt` / `nextResetTime` 存在 → 对角线永远画得出（不依赖任何估算）。
  2. 有 `usedPercent` → 叠加今日真实点位。
  3. E 可估（见下节）→ 补全历史点位与"日均可 ≈"。
  4. 连周限桶都没有（ZAI apiKey / startPlan、Codex 无 weekly）→ 整图隐藏，回落为现状。

### 方案 B（备选）：累计柱 + 上升对角线

方案 B（备选）：每日柱 + 水平预算线。柱子就是每天的用量，一条水平虚线 = `budget / 7`（日均预算），超线的柱整体红色。信息量大但读数不如点位图直观，且对角线高度直接依赖估算值 E。保留为备选：若实现后觉得点位图太空、缺少"每天用了多少"的量感，可回退（推导层完全复用）。

### 周预算估算（点位重建与"日均可"共用）

周限百分比与本地 tokens 不是同一计费口径，"预算 tokens"只能是一个**持续修正的估算值**；重置时刻不落在零点，"周期内用量"必须先解决对齐。估算分两步：

**第 1 步：周期内用量（两条实现路径）**

- **路径一 Z.AI：本地 SQLite 精确聚合**。`model_usage` 逐条毫秒明细，按精确时间窗 + **当前渠道**过滤，零对齐误差、与该渠道 `usedPercent` 同口径（第三方 / start-plan / API Key 用量不计入，否则 E 被污染）。**渠道 id 不硬编码**，动态取自 `ZAISettings.resolveProviderSelection()` 已解析的 `selectedKey` 冒号后段（setting.json 实测：`"coding-plan:builtin:zai-coding-plan"` / `"coding-plan:builtin:bigmodel-coding-plan"`，随 `providerFamilyDomain` 切换），兜底 `builtin:\(domain)-coding-plan` 拼接。`ZCodeUsageDB` 新增只读查询（30 天日桶保持全渠道不动）；`GROUP BY day` 出逐日桶用于画点位，首日精度由毫秒下界保证、**无需按整天折算**：
  ```sql
  SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
         SUM(computed_total_tokens) AS tokens
  FROM model_usage
  WHERE started_at >= :windowStartMs      -- W0 的毫秒时间戳
    AND started_at <= :nowMs
    AND provider_id = :providerID         -- 当前渠道 coding-plan，动态传入
  GROUP BY day
  ```
  解析不到渠道 id 或查询无数据 → 按降级阶梯退化为"只画线 + 今日点"。
- **路径二 Codex：app-server 日桶 + 首日折算**。官方数据只到自然日（180 天 `dailyUsageBuckets`），本地 sessions 已被调研排除（见背景"粒度"），app-server 是唯一自洽数据面——`usedPercent` 与日桶同后端，`openai_base_url` 网关配置下两者同经网关、口径天然一致（网关后端换账号时两者同步跳变，由估算器"新窗口首个可信观测直接采用"规则吸收，单测覆盖该用例）。首日按时间比例折算：
  `windowTokens = 首日桶 × (首日24点 − W0)/24h + 其间整天桶 + 今日桶`。
  误差以首日用量为上界（工作时段集中时偏高/偏低），tooltip 已明示估算。

**第 2 步：按使用与剩余百分比估出预算值**

```
W0   = resetsAt − 窗口时长（Codex）/ nextResetTime − 7×number 天（Z.AI），精确到时刻
p    = usedPercent / 100          // 已用比例，即 1 − 剩余百分比
E    = windowTokens ÷ p           // 周预算估算值（tokens）
```

可信度与兜底：

- `usedPercent < 5%`：百分比取整粒度下单点估算方差太大，**不用它更新估算**；沿用上次持久化的 E 继续重建点位；没有历史值则只画线 + 今日点（降级阶梯第 2 级）。
- `usedPercent ≥ 5%`：用本次 E 更新持久化值。同一窗口内多次观测做 EMA 平滑（α=0.5）；**新窗口的第一个可信观测直接采用**，不与旧窗口混合，避免跨窗口拖尾。
- 持久化按渠道 + 账号邮箱分桶存放（UserDefaults，风格同 `SnapshotCache`；邮箱来自 `loadAccount()`），账号 / 套餐 / 渠道切换自然失效。
- 所有由 E 推出的展示值（历史点位、日均可、tooltip 预算）一律带 `≈`；对角线与今日点不依赖 E。

### 数据流与文件划分

- `ui/WeeklyPaceChartView.swift`：视图 + `WeeklyPaceSnapshot` 推导（纯函数 `make(...)`：输入窗口锚点、周期内每日累计用量、E、服务端 usedPercent，输出每个点位的 `x / y / 颜色 / tooltip 数据`，view 只管画）。
- `zcode/ZCodeUsageDB.swift`：新增 `codingPlanDailyUsage(since:until:providerID:)` 精确窗口逐日聚合（渠道 id 由调用方从 `resolveProviderSelection()` 解析传入；只读，同现有连接与 busy_timeout 策略；现有 `last30Days()` 全渠道口径保持不动）。
- 估算器 `WeeklyPaceEstimator`：持有持久化 E（UserDefaults，按渠道 + 账号邮箱分桶，同渠道切账号不串值），实现"`usedPercent ≥ 5%` 才更新、同窗口 EMA、新窗口直接采用"的规则；纯逻辑，可单测。
- `ProviderPanelSection` 在 `resetCards` 与 `usageChart` 之间插入 `paceChart`，默认 hidden。
- `main.swift` 现有 `applyCodexUsage` / `applyZAIUsage` 处同时传周期内用量与当前快照的周限桶，经估算器产出 E 后重算 `WeeklyPaceSnapshot`；额度刷新与用量刷新任一到达都触发重算。
- Z.AI 侧只在 `kind == .codingPlan` 且存在 weekly limit 时显示。

## 风险

- 风险：Z.AI 预算估算偏低（`usedPercent` 账号级 vs 每日用量本机级），多设备用户的历史点位会整体偏低、更早显示"用多了"；同渠道切换账号时用量混记（`provider_id` 不含账号）同样污染估算。
  缓解：今日点锚定服务端真实百分比（不受估算影响）；tooltip 注明"按本机用量估算"；E 持久化按渠道 + 账号邮箱分桶避免跨账号串值；技术债登记"monitor 接口若可取绝对用量则替换估算"。
- 风险：渠道 id 解析依赖 setting.json 的 `modelProviderFamilySelectedKeys` 结构，zcode CLI 未来改格式会让过滤失效。
  缓解：兜底 `builtin:\(domain)-coding-plan` 拼接；查询无数据时按降级阶梯退化为"只画线 + 今日点"，不影响其他展示。
- 风险：`resetsAt` 非零点与自然日桶错位，Codex 首日折算引入最多一天用量的误差。
  缓解：Z.AI 逐条明细精确聚合无此问题；Codex 官方只有日桶（本地 sessions 判据已被网关配置推翻，见背景），明示近似并记录。
- 风险：Codex 在 `openai_base_url` 网关配置下，后端换账号会使 `usedPercent` 跳变。
  缓解：估算器"新窗口首个可信观测直接采用"规则吸收跳变；单测覆盖换账号用例。
- 风险：面板高度增加约 86pt。
  缓解：走现有 `onContentHeightChange` → `updatePreferredContentSize` 自适应；无周限的 provider 不占空间。
- 回滚方式：新图独立文件 + 默认 hidden，回滚只需移除挂载点，无数据链路改动。

## 里程碑

1. 推导层 + 估算器 + 单测（窗口切分、渠道 id 解析、首日折算、E 估算与门槛/EMA、点位计算、降级阶梯、换渠道/换账号用例）。
2. `WeeklyPaceChartView` 绘制 + `ProviderPanelSection` 挂载 + main.swift 双路接线。
3. 验证：构建、单测、真机双 provider 查看；各降级级别回落确认。

## 验证方式

- 命令：`swift build`；`swift test --filter WeeklyPaceChart`。
- 手工检查：对角线两端锚定 W0 与窗口结束的真实时刻；今日点与周限格的剩余百分比一致；点位随刷新更新；hover tooltip 明细。
- 观测检查：无周限 provider（apiKey 模式）不显示新图；新账号 `usedPercent < 5%` 时只显示线 + 今日点；Z.AI coding-plan 窗口聚合 ≤ 全渠道 30 天日桶对应日之和，且第三方用量大的日子两者差值明显（两条口径并存的直接证据）。
- 边界用例（单测 + 手工）：zai ↔ bigmodel 切渠道后 provider 过滤与 monitor 口径同步跟随；Codex 网关后端换账号的 `usedPercent` 跳变被"新窗口直接采用"吸收；同渠道切换账号后 E 持久化分桶不串值。
- 实际结果与未覆盖场景：（2026-09-18 实现会话填写）
  - 已验证：`swift build`（debug 与 release 均 0 警告 0 错误）；`swift test` 131 用例全部通过（含新增 `WeeklyPaceChartTests` 25 项：窗口切分 8/7 格、Codex 首日折算、E 估算门槛/EMA/新窗口/分桶、压线着色与 clamp、渠道 id 解析、降级阶梯、tooltip 文案）；配速图与叠加图离屏渲染 4x PNG 经视觉核验（对角线单一直线且虚实分段、红绿点分布、空心今日点、图例、切换胶囊、叠加柱两段等宽）；三个新 SQL 查询对本机 `~/.zcode/cli/db/db.sqlite` 只读冒烟通过（coding-plan 渠道过滤在 2026-09-16 前后两种 provider_id 前缀下均能取到数据）。
  - 实现期发现：ZCode 3.12.3+ 将 coding-plan 用量的 `provider_id` 从 `builtin:zai-coding-plan` 迁移为 `account:zai-individual-coding-plan`（setting.json 的 selectedKey 仍冻结在旧值）；渠道解析按双前缀集合过滤，E 持久化分桶改用 `domain-coding-plan|邮箱` 规避 id 迁移导致的估算历史断裂。
  - 未覆盖（待用户真机复核）：Codex / Z.AI 真实额度刷新链路下的配速图展示与降级回落、hover tooltip 实机表现、叠加/总量切换持久化在重启后的生效、Touch Bar / 刘海屏设备项。

## 进度记录

- [x] 设计草稿 v1：累计柱 + 上升对角线。
- [x] 按反馈修订估算：百分比与 tokens 非同一口径，改为估算值 + 精确窗口对齐。
- [x] 按反馈改为剩余百分比点位图（左上 100% → 右下 0% 下降对角线 + 每日点位）。
- [x] 超支判定方向已确认：剩余百分比口径，点在线下方＝用多了。
- [x] 横轴改为跟随周限窗口；Z.AI 配速图用量只统计 coding plan 渠道（30 天图维持全渠道合计）。
- [x] 设计稿已在 open-design 项目 `quota-popup-redesign-9319` 首页（index.html）弹窗下方空白区绘出（编号图例标注各元素含义，截图验收通过）；未改动弹窗卡片本体。
- [x] 设计稿超配速点改红色（用户确认），计划文档同步。
- [x] 颗粒度与口径调研（2026-09-16）：zcode 请求级毫秒；Codex 官方仅日桶、本地 sessions 因 openai_base_url 网关与账号归因问题排除；provider_id 按 zai/bigmodel 渠道动态区分。
- [x] 两条实现路径（zcode 精确聚合 / Codex 日桶折算）连同调研依据落盘至本文档。
- [x] Z.AI 30 天图叠加显示模式（coding plan 绿 / 其他渠道橙，tooltip = 日期 · coding plan · 总计）已画入 open-design 设计稿并同步本计划；配色经紫→青→橙三轮确认定稿，截图验收通过。
- [x] 实现 handoff 文件已生成：[weekly-pace-chart-handoff.md](weekly-pace-chart-handoff.md)（自包含实现交接，含规格、文件清单、单测清单、执行步骤）。
- [x] Handoff 增补（2026-09-16 用户确认）：配速图组件按"独立可复用"封装（视图/推导/估算器三层不耦合 provider 类型，适配在接线层）；Codex 与 Z.AI 共用同一视图，**Codex 首先接入作为首个真机验证对象**（当前账号有周限额可测）。
- [x] 确认整体方案后进入实现。
- [x] 推导层 + 估算器 + 单测。（2026-09-18：`WeeklyPaceSnapshot.make` 纯函数推导 + `WeeklyPaceEstimator` + 25 个单测；横轴按等宽自然日格实现，对角线锚定 W0 真实时刻）
- [x] 视图与接线，完成验证。（2026-09-18：`WeeklyPaceChartView` 绘制、`DailyUsageChartView` 叠加模式、`ProviderPanelSections` 挂载、main.swift 双路接线；`swift build`（debug/release）与 `swift test` 131 用例全绿；配速图/叠加图离屏渲染 4x PNG 经视觉核验；真实 zcode SQLite 三查询冒烟通过）
- [x] 技术债登记（ZAI 估算口径、月限窗口放开、渠道 id 前缀迁移监测）并归档。

## 决策记录

- 2026-09-15：图表几何按用户指定：左上（100%）到右下（0%）的下降对角线 + 每天一个百分比点位，替代 v1 的累计柱直方图。降级阶梯让"只有线 / 线+今日点 / 全量点位"都能成图。
- 2026-09-15：超支判定方向已与用户确认为**剩余百分比口径**：对角线左上 100% → 右下 0% 下降，点在线**下方**＝用多了（剩余比理想少）。
- 2026-09-15：横轴刻度**跟随周限窗口**（W0 所在日 → 窗口结束日的实际自然日，首尾可为部分天），不使用固定的日历周一~周日。
- 2026-09-15：Z.AI 渠道口径按用户确认拆分：**配速图的窗口用量只统计 `provider_id = 'builtin:zai-coding-plan'`**（与周限 `usedPercent` 同口径，第三方 / start-plan / API Key 不计入）；现有 30 天日用量图维持全渠道合计（含第三方），两图口径刻意不同。
- 2026-09-16：超配速着色由橙改为**红**（`PanelTheme.red` / #ff453a），设计稿与图例已同步——红色与"超支/严重"语义更直接，避免与额度胶囊"预警 ≤20% 橙"混淆。
- 2026-09-16：按用户确认扩展范围——Z.AI 近 30 天图新增**叠加显示**模式：柱状图总量为橙色，其中 coding plan 部分用绿色叠在柱子下方（正是配速图统计的那部分用量），tooltip 改为「日期 · coding plan · 总计」三段式（替换原"5h 峰值"占位文案），"总量 / 叠加"两种显示可切换。`ZCodeUsageDB` 相应增加按渠道拆分的日聚合（总渠道 + coding plan 两条 SUM）；Codex 侧数据为账号级、无渠道概念，维持现状。其他渠道段配色经三轮确认定稿：紫 → 青（对比度不足）→ **橙**（#ffb340→#f08c00 渐变，今天亮橙 #ffd27a→#ffa726；与预警胶囊同族暖色、深底对比明显）。
- 2026-09-16：Z.AI 渠道过滤**动态取自 setting.json**：provider_id = `modelProviderFamilySelectedKeys[providerFamilyDomain]` 冒号后段（zai / bigmodel 双渠道实测确认，修正 09-15 硬编码 zai 渠道的决策）；`provider_id` 区分渠道不区分账号，E 持久化按渠道 + 账号邮箱分桶。
- 2026-09-16：Codex **排除本地 sessions 数据源**——`openai_base_url` 网关使 `model_provider` / base_url 失去判别力、网关透传快照不可归因、session 无账号 ID；v1 维持 app-server 日桶 + 首日折算，为唯一自洽口径，网关换账号跳变由估算器新窗口规则吸收。
- 2026-09-16：颗粒度结论：zcode 单请求级毫秒可精确切窗（周期内用量不按整天推算，在 Z.AI 侧可行）；Codex 官方最细为自然日（180 天），只能首日折算近似。
- 2026-09-15：今日点用服务端 `usedPercent` 锚定真实值，历史点用 E 重建；E 变化时历史点整体重算，保证与最新刷新自洽。
- 2026-09-15：周预算是持续修正的估算值（同窗口 EMA、新窗口首个可信观测直接采用、`usedPercent < 5%` 不更新），而非瞬时比值；展示一律带 `≈`。
- 2026-09-15：首期仅启用 7±1 天窗口；算法按 `windowDays` 泛化，月限窗口后续放开。
- 2026-09-18（实现期实测）：ZCode 3.12.3+ 把 coding-plan 用量的 `provider_id` 前缀从 `builtin:` 迁移为 `account:<domain>-<connection>-coding-plan`（本机 2026-09-16 起新行均为新前缀，setting.json selectedKey 冻结在旧值）；渠道过滤改为双前缀 id 集合（builtin 兜底 + individual/team 两种 account 形态 + selectedKey 后段），E 分桶键用 `domain-coding-plan|邮箱` 而非具体 provider_id，避免 CLI id 迁移打断估算历史。
