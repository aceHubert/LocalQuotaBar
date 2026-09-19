# Z.AI 套餐用量服务端口径与按账号增量缓存

- 状态：已完成
- 创建日期：2026-09-19
- 最后更新：2026-09-19

## 目标

Z.AI/BigModel 套餐渠道的用量数据从本地 SQLite（只记本机、不区分账号）切换为服务端 `model-usage` 接口（账号维度、跨设备、计费真实 token），展示口径统一为「总用量 = 服务端套餐用量（全设备，已含本机套餐部分）+ 本机非套餐渠道用量」，两段不重叠、总计即账号全部消耗。服务端数据按账号分桶增量缓存，日常刷新只拉最近一两天，失败不动缓存，下次成功自动补齐，从而根治换账号后图表混入旧账号数据或缺数据的问题。周配速图与周预算 E 反推估算同步切换为服务端小时级数据：小时明细与日桶同存一份按日组织的账号缓存（同步逻辑相同，钳位 T-7），缓存建立后稳态刷新仅复用一次「近两天」请求，E 的两端——窗口 tokens 与 usedPercent——全部来自服务端计费口径，多设备 / 换账号不再干扰估算。

## 范围

- 包含：
  - 新增 `GET {api.z.ai | open.bigmodel.cn}/api/monitor/usage/model-usage` 请求构造与响应解析（复用现有 OAuth token 与团队上下文认证）。
  - 按账号（邮箱 + domain + 团队 org/project）分桶的统一缓存，UserDefaults JSON 存储，结构 `{ lastDailyFetchedAt, lastHourlyFetchedAt, daily: [{ date, usage, hourly[] }] }`：按日组织，日总量与小时明细同层，小时明细仅最近 ~8 天非空。
  - 统一增量同步规则：`queryStart = max(cacheLastDay ?? T-29, T-29)`，边界日重查、覆盖写、滚动淘汰 `< T-29` 的日桶。
  - 粒度无关合并：hourly / daily 响应一律按 `x_time` 本地日期聚合为日桶。
  - hourly 增量同步（同规则、钳位 T-7）：配速图周窗口 tokens 从小时明细按小时边界切窗求和，替代本地 provider_id 过滤；`WeeklyPaceEstimator` 的 E 反推输入（窗口 tokens）与 usedPercent 全部来自服务端计费口径。
  - 两次逻辑同步、按窗口合并请求：daily 与 hourly 各自按统一规则计算窗口并维护独立时间戳；两窗口一致或并集 ≤ 8 个自然日（响应必为 hourly）时合并为一次 GET 同喂两部分，否则各查各的。缓存建立后稳态两窗口均为 [昨天, 今天]，每刷新周期仅一次请求；长间隔补齐时 daily 全量与 hourly 短窗自然分为两次。
  - 30 天图与叠加图口径替换：totalTokens = 服务端套餐日桶 + 本机非套餐渠道日桶（不双计，最终定案口径）；channelTokens = 服务端套餐日桶。
  - 刷新挂在现有额度刷新周期（5 分钟冷却）之后，复用同一凭证捕获。
  - 单元测试：请求构造、增量窗口计算、粒度聚合、覆盖写防双计、账号分桶隔离。
- 不包含：
  - `start-plan`（体验套餐）与 API Key 模式（`builtin:zai` / `zai-api`）的服务端口径接入：monitor 接口是否涵盖未验证，仍按本地口径计入第三方。
  - `tool-usage`、`credit-usage/*`、`model-performance-day` 等其他 monitor 接口。
  - 修改 ZCode 或服务端行为；在仓库保存任何 Token/Key/Secret。
  - Codex 侧任何改动。

## 背景

- 相关文档：
  - `docs/PLANS_GUIDE.md`、`docs/exec-plans/templates/execution-plan.md`
  - `docs/exec-plans/completed/weekly-pace-chart.md`（配速图现状与 E 估算规则）
  - `docs/exec-plans/tech-debt-tracker.md` 2026-09-18「周预算 E 只能反推估算」条目：本计划落地后由 model-usage 绝对用量直接解决，归档时更新该表。
- 相关代码路径：
  - `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`（本地查询与 `ZAIUsageStore`）
  - `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`（`ZAIQuotaEndpoint` 请求构造、凭证加载）
  - `Sources/LocalQuotaBar/WeeklyPaceEstimator.swift`（`ZAIPaceChannel`、估算器）
  - `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`
  - `Sources/LocalQuotaBar/main.swift`（配速图接线）
- 官方调用链结论（从 ZCode.app `out/host/index.js` 还原 + 本机实测，2026-09-19）：
  1. URL 构造：与 `quota/limit` 同源，把额度 URL 的 `/quota/limit` 后缀替换为 `/model-usage`，查询参数 `startTime` / `endTime`，格式 `yyyy-MM-dd HH:mm:ss`（本地时区字符串）；团队上下文加 `type=2`（与额度接口一致）。
  2. 鉴权：与 `quota/limit` 完全一致——个人用 OAuth `authorization` 头；团队用项目 Key/Secret `authorization` + `bigmodel-organization` / `bigmodel-project` 头。
  3. 响应：`data.{x_time[], tokensUsage[], modelCallCount[], totalUsage.totalTokensUsage, modelDataList, modelSummaryList, granularity}`。
  4. 粒度规则（实测）：窗口 ≤ 7 天返回 `hourly`（`x_time` 形如 `2026-09-18 13:00`），≥ 10 天返回 `daily`（`2026-09-18`）；窗口 > 30 天被服务端拒绝（HTTP 500 "time range exceeds limit"）。
  5. 口径一致性（实测）：短窗口（昨天 0 点起）与 30 天全量接口对同一日期的日桶数值逐字节一致，增量合并不引入误差；日桶边界跟随 startTime 字符串所用时区（本地）。
  6. hourly 缓存规则：窗口 ≤ 8 个自然日必返回 hourly（实测 [T-6 00:00, 今天] 158 点、[T-7 00:00, 今天] 182 点均 hourly；≥ 10 个自然日为 daily），hourly 钳位 `T-7` 既保证窗口必为 hourly，也覆盖周窗口起点落在 T-7 当天的边界情形；配速窗口起点（上次重置时刻）落在小时内时按小时边界近似切窗，误差不超过 1 个小时桶的用量。
- 已知约束：
  - 本地 `model_usage` / `session` 表均无账号列，`provider_id` 只区分渠道形态，无法按账号过滤。
  - 服务端最大窗口 30 天，长期历史只能靠增量缓存维持；缓存缺失即回退为一次 30 天全量。
  - 服务端计费真实 token 与本地 `computed_total_tokens` 是混合口径，总量仅为展示用，不做对账。
  - 工作区已有其他未提交改动（weekly-pace-chart、team-coding-plan-quota 等），实现时只能修改本计划涉及的文件。

## 风险

- 风险：`model-usage` 为逆向还原的未公开契约，字段名 / 粒度规则可能随版本变化。
  - 缓解方式：防御式解析（缺失字段降级为空）；失败保持缓存不动；契约关键点（后缀替换、时间参数、粒度切换）用单测钉住，变更时测试先红。
- 风险：本地「排除套餐渠道」仍依赖 provider_id 前缀形态（`builtin:zai-coding-plan` / `account:zai-individual-coding-plan` 等），zcode 再改前缀会漏排除，导致套餐本机用量在总量中被双计（服务端已含本机）。
  - 缓解方式：排除集合采用域内宽松匹配 `LIKE '%coding-plan'`（显式排除 `-start-plan`），不逐枚举前缀；沿用 tech-debt 2026-09-18 provider_id 条目的观察机制。
- 风险：混合口径（服务端计费 + 本地 CLI 计算）可能让用户对不上旧图读数。
  - 缓解方式：叠加图图例明确「套餐（服务端）/ 第三方（本机）」来源；历史读数差异在历史记录中说明。
- 风险：双粒度缓存（30 天日条目 + ~8 天小时明细）状态同步复杂度，两部分不一致会造成图表与配速图读数互相矛盾。
  - 缓解方式：单一 JSON 存储、按日条目是唯一事实源，`usage` 与 `hourly[]` 各自随所属同步覆盖写；同日 `usage` 与 `sum(hourly)` 至多相差一个刷新周期的服务端增量，自然收敛；请求合并判定是纯函数（窗口一致或并集 ≤ 8 个自然日）并由单测钉住；重建以 daily 全量为准。
- 风险：账号切换瞬间异步响应写入旧账号分桶。
  - 缓解方式：发起请求时捕获完整 selection + 凭证，响应写回前校验分桶标识；与 `fetchCodingPlanSnapshot` 现有做法一致。
- 回滚方式：回退本计划涉及的源文件与测试文件；缓存 key 独立命名（含 `serverPlanUsage` 前缀），回滚后旧缓存残留无害，本地全渠道查询函数保留不删。

## 里程碑

1. 调研与方案收敛：官方调用链还原、接口实测、口径与缓存设计（已完成，见决策记录）。
2. 数据层：`model-usage` 请求构造、响应解析、日桶聚合（含单测）。
3. 缓存层：账号分桶、统一增量同步规则与请求合并、按日组织的双粒度缓存与滚动淘汰（含单测）。
4. 接线层：`ZAIUsageStore` 数据源切换、30 天图 / 叠加图 / 配速图与 E 反推输入的口径替换、UI 图例标注。
5. 验证、交付与收尾：`swift build` / `swift test`、真实账号刷新与账号切换手工验证、更新技术债表、历史记录归档。

## 验证方式

- 命令：
  - `swift build`
  - `swift test`（后台执行，超时 60 秒）。
- 自动化测试：
  - URL 构造：`/quota/limit` → `/model-usage` 后缀替换、`startTime` / `endTime` 编码、团队 `type=2` 与 org/project 头、个人不带团队头。
  - 增量窗口：首次（无缓存）查 30 天；日常（缓存止于昨天）查 `[昨天, 今天]`；间隔 10 天补 11 天；缓存全部滑出窗口等价 30 天全量。
  - 聚合：hourly 与 daily 两种响应聚合成同一日桶；同日桶覆盖写不双计。
  - hourly 同步：钳位 T-7、窗口恒 ≤ 8 个自然日（必返回 hourly）；请求合并：两窗口一致或并集 ≤ 8 个自然日时仅一次 GET 且两个时间戳同时前进，否则两次 GET 各自独立；周窗口按小时边界切窗求和。
  - E 反推：窗口 tokens 取自小时明细求和；本机无用量但服务端有用量时 E 仍可更新；`windowTokens ≤ 0 不更新` 守卫保持。
  - 分桶：不同邮箱 / domain / 团队上下文读写互相隔离；切换账号不串数据。
  - 缓存结构：JSON 编解码兼容字段缺失（`hourly` 用 decodeIfPresent）；`< T-29` 日条目淘汰、`< T-7` 小时明细淘汰。
  - 排除集合：`%coding-plan` 宽松匹配命中双前缀形态且不含 `-start-plan`。
- 手工检查：
  - 真实账号刷新后，30 天图套餐部分与 ZCode 官方「使用统计 → 个人套餐」逐日数值一致。
  - 叠加图总量 = 套餐（服务端）+ 第三方（本机），与前一日读数衔接无跳变。
  - 配速图历史点位与官方「个人套餐」统计一致；本机无用量但服务端有用量（其他设备消耗）时配速图与 E 估算仍正常工作。
  - 换一个未在本机使用过的账号：图表为空或仅含该账号服务端数据，不残留旧账号记录；切回旧账号命中其缓存。
  - 断网 / 服务端失败：缓存与图表不变，恢复后下一次刷新自动补齐缺口。
- 观测检查：
  - 稳态下每个刷新周期 `model-usage` 仅一次请求；`lastDailyFetchedAt` / `lastHourlyFetchedAt` 随各自成功同步前进，失败不变。
  - 调试日志只记录账号标识、窗口起止与点数，不记录 Token/Key。
- 实际结果与未覆盖场景：
  - `swift build`：0 error / 0 warning。
  - `swift test`：157/157 通过（新增 `ZAIServerUsageTests` 16 个：请求构造、hourly/daily 解析、增量规划五场景、覆盖写与双淘汰、小时边界切窗、分桶标识）。
  - 服务端请求形态已在本任务调研阶段用真实账号实测（短窗 / 30 天窗口均 200，口径逐字节一致）；Swift 侧 URL 结构由单测钉住。
  - 真实账号 GUI 链路验证（2026-09-19 14:15，个人 zai 套餐）：`make app` 重启应用后，首个刷新周期即完成同步——UserDefaults 缓存分桶 `zai-coding-plan|<email>`，30 个日条目（08-21 ~ 09-19），昨日 usage 与接口实测值逐字节一致（110.70M），今日小时点数与当时时刻吻合，30 天合计 1975M tokens；`lastDailyFetchedAt` / `lastHourlyFetchedAt` 同步前进。
  - 未覆盖（用户验收后接受为已知边界）：换账号 GUI 实测（分桶切换逻辑由单测覆盖）、断网恢复 GUI 实测（会话期间 api.z.ai 抖动已实际触发同步失败，缓存未动、恢复后自动补齐，行为符合设计）、团队套餐（bigmodel）联调、Touch Bar / 刘海屏展示。
- 验收结论（2026-09-19 15:00 用户确认）：
  - 稳态多周期同步正常：启动首查全量后每次仅短窗增量，`lastDailyFetchedAt` / `lastHourlyFetchedAt` 持续前进（14:14 → 14:22 → 14:54），今日值随结算持续收敛（7192 → 7668 → 9498 万），昨日值稳定 11070.0 万。
  - 口径经 GUI 对账三轮收敛定案（见决策记录"最终定案"）：绿段套餐（全设备）+ 橙段本机非套餐，总计无重叠；ZCode 应用用量与本图橙段之差 = 本机套餐部分，属预期。
  - 小时级对账证据：本机 01:00 桶 613.9 万 ≈ 服务端 614.1 万，证明本机套餐消耗已含在服务端口径内，不双计口径成立。

## 进度记录

- [x] 调研与方案收敛（接口还原 + 实测 + 口径设计）。
- [x] 数据层：model-usage 请求与解析（`ZAIServerUsage.swift`）。
- [x] 缓存层：账号分桶与增量同步（按日组织缓存 + 请求合并 + 滚动淘汰）。
- [x] 接线层：图表与配速图口径替换（30 天图 / 叠加图 / E 反推 / 图例标注）。
- [x] 完成验证并记录结果（自动化全绿 + GUI 实测对账 + 口径定案）。
- [x] 真实账号 GUI 手工验证完成，技术债表已更新（周预算 E 反推估算条目解决），归档至 completed/。

## 决策记录

- 2026-09-19：总口径定为「服务端套餐（model-usage）+ 本地第三方（排除套餐渠道）」。服务端部分账号维度、跨设备、计费真实 token，跟随当前登录账号；第三方渠道配置只存在于本机 config.json，本地库即其完备来源。该口径同时根治换账号混数据与缺数据两个问题。
- 2026-09-19：增量同步统一为一条规则 `queryStart = max(cacheLastDay ?? T-29, T-29)`，不区分首次 / 日常 / 久未启动三种场景；边界日重查以吸收其他设备延迟上报；同日桶必须覆盖写（replace，非 sum），防止窗口重叠双计。
- 2026-09-19：刷新失败不做降级路径——缓存即展示源，失败什么都不动，下次成功由增量规则自动补齐任意间隔；首次无缓存且首查失败时展示空图等下个周期重试，不回落本地全渠道，避免口径在两套来源间闪切。
- 2026-09-19：本地排除集合采用域内宽松匹配 `%coding-plan`（显式排除 `-start-plan`），不再逐枚举 provider_id 前缀；`start-plan` 与 API Key 模式（`builtin:zai` / `zai-api`）暂计第三方（monitor 覆盖范围未验证，见范围-不包含）。
- 2026-09-19：周预算 E 反推估算与配速图一并纳入本计划：小时明细与日桶同存一份按日组织的 JSON 缓存（`{ lastDailyFetchedAt, lastHourlyFetchedAt, daily: [{ date, usage, hourly[] }] }`），同步规则、账号分桶与覆盖写语义一致，仅钳位不同（daily T-29 / hourly T-7；实测 8 个自然日窗口仍返回 hourly，T-7 钳位覆盖周窗口起点落在 T-7 当天的边界）。E = windowTokens ÷ p 的两端（hourly 切窗求和、usedPercent）均为服务端计费口径，估算不再受多设备 / 换账号干扰，同时解决 tech-debt 2026-09-18「周预算 E 反推估算」条目。
- 2026-09-19：daily 与 hourly 设计为两次逻辑同步（独立窗口计算、独立 `lastDailyFetchedAt` / `lastHourlyFetchedAt`、独立失败语义），请求层按窗口合并：两窗口一致或并集 ≤ 8 个自然日时复用一次 GET。理由：缓存建立后稳态两窗口均为 [昨天, 今天]，每周期一次请求即可；单侧失败或长间隔补齐导致窗口分叉时自然退化为两次，不引入共享状态。
- 2026-09-19：配速窗口起点（上次重置时刻）按小时边界近似切窗（误差 ≤ 1 个小时桶），不追求毫秒级精度；本地 SQLite 按毫秒切窗的旧路径在回滚前保留。
- 2026-09-19：缓存存储用 UserDefaults JSON（30 个日条目 + 最近 ~8 天小时明细量级），key 含账号邮箱 + domain + 团队上下文，与 `WeeklyPaceEstimator` 分桶思路一致；换账号天然切桶、旧账号缓存保留可回切。
- 2026-09-19（实现）：同步进度以 `lastDailyFetchedAt` / `lastHourlyFetchedAt` 时间戳为准，不按最大日条目日期推导——单测暴露的反例：hourly 同步会先行创建今天的日条目（usage = sum(hourly)），按条目日期推导会让 daily 的历史缺口（如 T-9/T-8）永久留在缓存里。
- 2026-09-19（实现）：启动时按当前账号 preload 已持久化缓存（只读不请求），首次网络同步到达前 30 天图先有昨日读数，避免启动瞬间空白；额度刷新成功后再走增量同步。
- 2026-09-19（实现）：coding-plan 模式下服务端缓存未建立时 30 天图展示空图（不回落本地全渠道）；本地全渠道查询（`last30Days` / `last30DaysSplit`）与 `refreshPace` 读库路径保留不删，作为回滚窗口。
- 2026-09-19（验收调整，已被最终定案取代）：曾按用户初步反馈短期改为"橙段 = 本机全渠道直接叠加（接受与本机套餐部分重叠）"；经小时级对账证明本机套餐消耗已含在服务端套餐数内（01:00 桶 613.9 万 vs 614.1 万精确匹配），双计口径会让总计虚高（当日多 3318 万）。用户对比两种口径的实际数值后定案回到不双计口径。
- 2026-09-19（最终定案）：总计 = 服务端套餐（全设备，已含本机套餐部分）+ 本机非套餐渠道（`NOT LIKE '%coding-plan'`）；两段不重叠，总计 = 账号全部消耗。图例「套餐（服务端）/ 第三方（本机）」；tooltip 列「套餐 / 第三方 / 总计」三项。ZCode 应用用量（本机全渠道）与本图橙段的差 = 本机套餐部分，属预期。
