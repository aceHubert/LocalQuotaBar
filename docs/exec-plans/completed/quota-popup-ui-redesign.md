# 额度弹窗与设置页 UI/UX 升级（原型落地）

- 状态：**已完成（已验收）**
- 创建日期：2026-09-15
- 最后更新：2026-09-18（验收归档）

## 目标

把 open-design 项目 `quota-popup-redesign-9319` 中已定稿的额度弹窗（index.html）与设置页（settings-lite.html，精简版）原型，落地为 AppKit 原生实现，替换 `QuotaViewController` 当前的列表式布局。只改 UI/UX：数据读取、提醒评估、账号切换等业务逻辑一律不动。

## 范围

- 包含：
  - 额度弹窗整体重构：顶部栏、provider 区块（Codex 3 列 / Z.AI 2 列胶囊网格）、阈值分级配色、无限制空态、重置卡面板内展开、刷新失败横幅、底部图例行。
  - 近 30 天每日用量图（新视图）：Codex 用官方 `account/usage/read`（新增只读 RPC 调用），Z.AI 用只读查询 zcode 本地 SQLite（详见调研结论章节）。
  - 面板内设置页（lite 版）：自动刷新、主动提醒开关、三项提醒条件下拉、恢复提醒、重置默认；齿轮图标进入、返回按钮退回。
  - 面板宽度从 460 调整为约 322 + 内边距，高度随内容自适应。
- 不包含（业务逻辑红线）：
  - `RateLimitStore` / `ZAIQuotaStore` / `CodexRateLimitClient` / `ZAIQuota.swift` 的读取、解析、刷新调度。
  - `ReminderEvaluator` / `ReminderCenter` / `ReminderChannels` / `DynamicNotchKitAlertChannel` 的评估与投递；阈值默认值（20% / 10% / 30 分钟 / 10 分钟）与档位列表不变。
  - `RefreshSettings` 的档位与默认值（[1,2,5,10,15,30,60] 分钟，默认 5）。
  - `CodexAuthManager` 账号切换、`SnapshotCache` / `AccountPlanCache` 读写。
  - Touch Bar 条带内容（`TouchBarQuotaView` / `TouchBarQuotaRowView`）与右键菜单结构（保留并存，见决策记录）。
  - 完整版设置页（settings.html 的开机自启/菜单栏显示/关于区块）——用户已确认采用 lite 版。

## 背景

- 来源会话：sess_c39e43fd（弹窗设计定稿 + App 落地映射）、sess_6ecce903（弹窗/设置页原型迭代 + 档位对齐代码）。两份会话结论已合并进本文档，执行时不需回读聊天记录。
- 设计稿（已全部截图验证通过）：
  - `/Users/hubert/Desktop/projects/open-design/.od/projects/quota-popup-redesign-9319/index.html`（额度弹窗）
  - 同目录 `settings-lite.html`（设置页，采用版本）、`settings.html`（完整版，不采用，仅留档）
  - 浏览预览：`http://127.0.0.1:7456/api/projects/quota-popup-redesign-9319/raw/index.html`
- 相关代码路径：
  - `Sources/LocalQuotaBar/main.swift`：全部现有 UI（`QuotaViewController`、`QuotaRowView`、`SegmentedBatteryBarView`、`makeSettingsView`、右键菜单）。
  - `Sources/LocalQuotaBar/ReminderModels.swift`：`ReminderLevel`（resetSoon=1/warning=2/critical=3）、`ReminderConfiguration.default`（warning 20%、critical 10%、resetSoon 30 分钟、cooldown 10 分钟）。
  - `Sources/LocalQuotaBar/RefreshSettings.swift`：`availableMinutes`、`defaultIntervalMinutes = 5`。
  - `Sources/LocalQuotaBar/ZAIQuota.swift`：`ZAIResetCreditCard.Kind`（fiveHour/week）。
- 已知约束：
  - App 是原生 AppKit，不引入 WKWebView；原型中"动画全删、数值内联、JS 只做 hover"的教训不适用，但 hover 语义保留（用 NSView toolTip / NSTrackingArea）。
  - main.swift 已有 2665 行，新视图一律放独立文件，避免继续膨胀。
  - ZAI 区块显隐仍由 `ZAISettings.isZAIDomain()` 决定（`main.swift:1402`），只改样式不改条件。

## 日用量数据源调研结论（2026-09-15，已实测验证）

30 天用量图的数据获取方式已调研完毕，两条路径均已在本机端到端验证：

**Codex（首选官方 API，账号级口径）**

- `codex app-server` 存在未被现有代码使用的官方方法 **`account/usage/read`**（现有 `CodexRateLimitClient` 只调了 `initialize` / `account/read` / `account/rateLimits/read`）。
- 实测响应结构：`result.dailyUsageBuckets` = 179 天的 `{startDate: "2026-09-14", tokens: 751255}` 数组（无流水的日期跳过，从 2025-09-15 起）；`result.summary` 含 `lifetimeTokens` / `peakDailyTokens` / `currentStreakDays` / `longestStreakDays`；`result.threadUsage` 当前为 null。
- 语义：**账号级每日 token 用量**（绝对值，非百分比），可完整回填 30 天图表，无需本地采样。
- 备选（若需"5h 峰值 %"口径）：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 每条 `event_msg/token_count` 事件内嵌当时的完整 `rate_limits` 快照（`primary.used_percent` + `window_minutes` + `resets_at`）+ 时间戳，可重建每日 5h 窗口峰值百分比（实测近 30 天 22 天有数据）。仅覆盖本机 CLI 有活动的时刻。

**Z.AI / zcode（无官方历史端点，用本地 SQLite，本机口径）**

- 官方无用量历史接口：`api/monitor/usage/quota/limit` 只返回当前百分比；ZCode.app 的 asar 中全部相关端点为 `billing/balance`、`billing/current`、`reset`、`personal/overview`（实测 404）等，无历史用量。
- **官方佐证（用户截图 + asar 文案）**：ZCode 自带「设置 → 使用统计」页（应用用量 tab，含"累计 Token 数 / 峰值 Token 数 / 最长聊天时长 / 当前·最长连续天数"汇总卡 + 12 个月 Token 活动热力图），其 asar 文案自述"来自本地应用会话历史""粗略统计"，实现为本地聚合 hook（`useAppUsageStats`，错误文案"读取本地使用统计失败"）——即 ZCode 官方也没有服务端历史，本地聚合就是官方同款做法。截图中热力图仅最近 2-3 列有活动，与本机 DB 2026-08-17 建库、约 30 天数据的观察一致。
- **`~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表**：每次模型请求一行，含 `started_at`（unix ms）、`provider_id`（`builtin:zai-coding-plan` / `builtin:bigmodel-coding-plan`，可区分渠道）、`input_tokens` / `output_tokens` / `computed_total_tokens`、`raw_usage_json`；`turn_usage` 表另有按 turn 的聚合。
- 实测按天聚合（`GROUP BY date(started_at/1000,'unixepoch')`）覆盖 2026-08-17 至今约 30 天、11739 条请求；ZCode GUI（Electron）与 CLI 的请求都在内。WAL 模式，外部 `SQLITE_OPEN_READONLY` 并行读安全。
- 注意：为本机口径（其他设备 / 网页端的 coding plan 用量不计入）；且仅 coding-plan / start-plan 有记录，API Key 模式无图表。

**Codex 使用统计页佐证**：用户截图的五个汇总卡（累计 Token / 峰值 / 最长聊天时长 / 当前·最长连续天数）与 `account/usage/read` 响应字段一一对应（lifetimeTokens / peakDailyTokens / longestRunningTurnSec / currentStreakDays / longestStreakDays），`dailyUsageBuckets` 即热力图数据源——该 API 就是官方统计页后端，账号级数据可信。

**图表口径决策**：两家统一采用**每日 token 用量**（绝对值，显示为 "xx.xM"），而不是原型的"5h 峰值 %"——Codex 官方给的就是 tokens，Z.AI 本地只有 tokens 可回填；token 数在无额度活动的日子也有确定值（0），百分比峰值则无意义。详见决策记录。

## 设计定稿规格（从原型提取，执行以原型为准）

- 尺寸：内容宽 322px；圆角、区块间距按 index.html CSS（.provider 卡片、.qgrid 列间距 7px、.capsule 胶囊）。
- 色板（固定 sRGB，深色底）：
  - 正常绿 `#32d583`；预警橙 `#ff9f0a`；严重红 `#ff453a`；即将重置黄 `#ffd60a`；重置倒计时文字粉 `#ff85b0`（≤30 分钟变黄）；余额紫 `#a78bfa`。
  - 阈值分级与 App 提醒阈值一致：剩余 ≤20% 预警、≤10% 严重、距重置 ≤30 分钟倒计时变黄。
- 顶部栏：标题"额度" + 相对时间（"刚刚 / 1 分钟前"，可用 `RelativeDateTimeFormatter`）+ 全部刷新图标按钮 + 齿轮（进入设置页）。
- provider 头（p-head）：logo（含状态点）/ 名称 / plan tag（Pro/Lite…）/ 状态文字（相对时间或红色"刷新失败"）/ 单独刷新图标按钮（保留 60 秒防重禁用逻辑）。
- 胶囊网格：
  - Codex 3 列（5小时 | 周限额 | 余额）；Z.AI 2 列（5小时 | 周限额）。
  - 每格：标题行（左标题 + 右重置倒计时，粉色，≤30 分钟变黄）+ 胶囊条（连续填充、居中百分比，按阈值分级配色）。
  - 余额格：紫色胶囊显示 `$40.68`（`creditBalance / 25`，tooltip 显示积分与换算），不参与阈值分级。
  - 无限制空态：Codex 无 5h 窗口（`snapshot.fiveHour == nil` 且有 weekly）时该格渲染虚线空胶囊 + 灰字"无限制"，保持 3 列对齐，不加新 provider。
- 重置卡：p-meta 区 chip（如"重置卡 ×3 · 最早 9/20"，ZAI 分"5h 重置 ×2 · 9/18""周重置 ×1 · 9/20"两枚）+ chevron 展开按钮；点击 chip 或 chevron 展开卡列表（#N / 类型 / 到期时间 / "N天后到期"badge），7 天内到期标红；默认收起。
- 近 30 天用量图（每个 provider 一张）：30 根细柱（口径为**每日 token 用量**，见调研结论）、今日列高亮 + 柱顶数值、均值虚线 + 数值（"日均 xxM"）、间隔周刻度（8/16 8/23 8/30 9/6 今）、hover 显示"M月d日 · xx.xM tokens"。
- 刷新失败横幅（provider 底部）：警告图标 + 红色粗体"刷新失败，显示 HH:mm:ss 数据" + 灰色详情（2 行截断）+ 重试按钮；同时该 provider 头部状态点/文字变红"刷新失败"。
- 底部 footer：阈值图例行（正常 / 预警 ≤20% / 严重 ≤10% / 即将重置 ≤30分）+ 低量提醒说明行与开关。
- 设置页（lite）：顶部返回按钮 + "设置" + 版本号（App 用真实 bundle version）；「通用」区仅自动刷新下拉；「低量提醒」区：主动提醒开关、额度低于（50/40/30/20/10%，默认 20%）、重置还剩（50/40/30/20/10 分钟 + 关闭，默认 30）、提醒间隔（5/10/15/30/60 分钟，默认 10）、已静音提醒 + 恢复提醒按钮、重置默认按钮（恢复 20%/30 分/10 分）。档位与默认值已核对与代码一致。

## 设计 → 代码映射（核心 handoff 表）

| # | 原型元素 | 现状代码锚点（main.swift） | 目标改动 |
| --- | --- | --- | --- |
| 1 | 面板宽度 322 / 深色卡片 | `quotaContentSize`（:1765，宽 460）；散落的 424 宽约束（:1734、:1848、:2181 等） | 集中为单一宽度常量（新文件 PanelTheme.swift）；`TouchBarHostingVisualEffectView` 根视图建议设 `appearance = NSAppearance(named: .vibrantDark)` 固定深色（见决策记录） |
| 2 | 顶部栏（标题/相对时间/全部刷新/齿轮） | `configureSubviews`（:1654）的 header（titleLabel+accountLabel+accountPlanTag+statusLabel+refreshButton） | 新 header 视图；"全部刷新"= 同时触发 `onRefresh` + `onZAIRefresh`（新增组合回调或复用两个既有回调）；齿轮切换到设置页容器 |
| 3 | provider 头（logo+状态点/名称/plan tag/状态文字/刷新按钮） | Codex 无独立 provider 头；ZAI 头在 `makeZAISection`（:1781）；plan tag 现为 `accountPlanTag`（:1419）/`zaiLevelTag` | 新 `ProviderHeaderView`；状态文字复用 isRefreshing/error/snapshot 三态；相对时间用 `RelativeDateTimeFormatter` |
| 4 | 胶囊条（连续填充+居中百分比+阈值配色） | `QuotaRowView`（:2240）+ `SegmentedBatteryBarView`（:2545，28 段电池条，配色 0-20 红/20-50 黄/其余绿，:2601） | 新 `CapsuleBarView`（连续胶囊）；配色改按提醒阈值：≤20% 橙、≤10% 红、其余绿（旧色阶仅在 Touch Bar 视图保留） |
| 5 | 重置倒计时（粉色，≤30 分变黄） | `QuotaRowView.detailLabel`（"--% · HH:mm" 格式，:2284） | 倒计时独立小视图；配色按 `resetsAt` 与当前时间差 ≤30 分钟判黄（只读展示，不引入 ReminderEvaluator 依赖，简单时间比较即可） |
| 6 | 无限制空态 | `fiveHourRow.update(bucket: nil)` 显示"--% · --"+0% 条（:2271） | `snapshot.fiveHour == nil` 且 weekly 存在时渲染虚线空胶囊 + 灰字"无限制" |
| 7 | 余额胶囊（紫，$xx.xx） | `creditBalanceLabel`（:1446，`$%.2f`，/25 换算 :1902） | 移入 Codex 第 3 列胶囊格；tooltip 保留积分说明文案 |
| 8 | 重置卡 chip + 展开 | `resetCreditsValueLabel` + `resetCreditsExpirationButton`（弹出 NSAlert :1608/:2064）| chip + chevron，面板内展开卡列表（NSStackView isHidden 切换 + `updatePreferredContentSize`），替代两处 NSAlert；7 天红=沿用 `warningInterval 7d`（:1963） |
| 9 | ZAI 重置卡两枚 chip（5h/周） | `makeZAIResetCreditsRow`（:1925）单行 + NSAlert（:1948，`makeZAIResetCreditExpirationList` :1961 已按 `card.kind` 分组能力存在） | 按 `ZAIResetCreditCard.Kind`（fiveHour/week）拆两枚 chip，各自展开 |
| 10 | 刷新失败横幅 | Codex `statusLabel` 文案（:1635-1651）；ZAI `zaiStatusLabel` 文案（:1557-1569）；时间格式 `formatFetchedAt`（:2040） | 新 `ErrorBannerView`：标题用 `snapshot.fetchedAt`（formatFetchedAt）、详情用 error（2 行截断）+ 重试按钮（触发对应 onRefresh/onZAIRefresh，复用 60 秒防重）；头部状态点变红 |
| 11 | 近 30 天用量图 | 无对应（现仅当前窗口快照） | 新 `DailyUsageChartView`；数据源见"日用量数据源调研结论"（Codex 官方 `account/usage/read` + Z.AI 本地 SQLite 只读聚合），不依赖快照采样 |
| 12 | 底部图例行 + 低量提醒开关 | `makeSettingsView`（:2141）只读设置区 + "在状态栏右键菜单中修改"提示 | 替换为图例行 + 开关行；`reminderEnabledButton`（:1452）改为 footer 开关，仍只写 `isEnabled`（`currentReminderConfiguration` :2209 语义不变）；只读数值行（warningValueLabel 等）移除，编辑入口改为齿轮设置页 |
| 13 | 设置页（lite） | 右键菜单 `makeReminderSubmenu`（:1203）+ `makeRefreshIntervalSubmenu`（:1184）为唯一编辑入口 | 新 `SettingsPageView`（独立文件）：NSSwitch + NSPopUpButton（档位、默认值、selected 逻辑照抄菜单）；写入走既有链：提醒改动→`onReminderConfigurationChange`（已接 `reminderCenter.updateConfiguration` + `refreshReminderUI`，:1038）；刷新频率→新增 `onRefreshIntervalChange` 回调，AppDelegate 内复用 `refreshIntervalSelected`（:1357）的逻辑体（持久化 + 双 store 重建定时器 + 同步展示）；"恢复提醒"复用 `onUnmuteAll`/`canRestore`（:1490）；"重置默认"复用 `.default` 配置 |
| 14 | ZAI 区块显隐 | `setZAISectionVisible(ZAISettings.isZAIDomain())`（:1402） | 保留判断不动，只适配新布局（ZAI 隐藏时 Codex 独占） |
| 15 | API Key / startPlan / 待生效等特殊态 | `applyZAI`（:1501）分支 + `startPlanPendingText`（:1575） | 交互结构不变：API Key 态隐藏额度格与图、startPlan 用余额格（token 数）与待生效格（灰胶囊），文案逻辑照搬 |

## 里程碑（分阶段实现，每阶段 `swift build` 通过再进下一阶段）

1. **阶段 0 · 设计 token 与骨架**：新建 `PanelTheme.swift`（宽度/色板/间距常量、hex→NSColor 扩展）；确定面板外观（深色固定 vs 跟随系统，见决策记录）；`QuotaViewController` 内容栈改为"顶部栏 + provider 容器 + footer"骨架，暂用旧控件填充，保证行为不回退。
2. **阶段 1 · provider 区块与胶囊网格**：新 `ProviderBlockView`（header + qgrid），Codex 3 列 / ZAI 2 列；`CapsuleBarView` 阈值配色；无限制空态；余额胶囊；重置倒计时配色。`apply` / `applyZAI` 签名与数据流不变，仅重写内部填充。
3. **阶段 2 · 状态与展开交互**：`ErrorBannerView`（替换两处 statusLabel 失败文案）+ 头部状态点；重置卡 chip 面板内展开（替换两处 NSAlert）；底部图例行 + 低量提醒开关行；高度自适应验证。
4. **阶段 3 · 30 天用量图（数据源已调研定稿）**：
   - Codex：`CodexRateLimitClient` 新增 `readUsage()` —— 在同一次 app-server 进程会话里捎带 `account/usage/read`（`readAppServerResultsBlocking` 已支持多方法，新增 target id 即可），解析 `dailyUsageBuckets`（取近 30 天）与 `summary`；解析失败单独容错（照 `resetCreditCards` 先例），不影响主额度。产出 `CodexUsageSnapshot`，随刷新更新，可 UserDefaults 缓存避免弹窗打开时重查。
   - Z.AI：新文件 `ZCodeUsageDB`（`import SQLite3` 系统库，零第三方依赖）—— 以 `SQLITE_OPEN_READONLY` + 短 `busy_timeout` 打开 `~/.zcode/cli/db/db.sqlite`，按当前 provider（`ZAISettings.resolveProviderSelection()` 对应的 `builtin:<domain>-coding-plan`）聚合 `model_usage` 近 30 天每日 `SUM(computed_total_tokens)`；DB 缺失 / 加锁失败时返回空数据并显示"暂无本机用量记录"，不影响主流程。start-plan provider 同样适用（按其 provider id 过滤）；API Key 模式不显示图。
   - 新 `DailyUsageChartView`（独立文件）：柱、均值线、周刻度、今日高亮、hover toolTip；空数据日渲染零高度柱。
5. **阶段 4 · 设置页（lite）**：`SettingsPageView` 独立文件；齿轮进入/返回退出（容器视图切换 + contentSize 更新）；各控件写入走既有链（见映射 #13）；版本号读 bundle。
6. **阶段 5 · 验证与收尾**：按下方验证方式全量手测 + 截图留档；清理死代码（被替换的 `QuotaRowView` 面板用法、`makeSettingsView` 等；`SegmentedBatteryBarView` 若 Touch Bar 仍用则保留）；登记技术债；按 HISTORY_GUIDE 写历史记录；本计划移至 completed/。

## 风险

- 风险：main.swift 单文件大改易引入行为回归。
  - 缓解：新视图全部放独立文件；`QuotaViewController` 对外 API（apply/applyZAI/各回调）保持不变；每阶段编译 + 手测。
- 风险：深色固定外观与系统浅色模式混搭（弹窗深色、菜单浅色）观感割裂。
  - 缓解：执行阶段 0 时两种方案各截一张图定稿（见决策记录）。
- 风险：卡片展开/设置页切换导致 popover 高度跳变或底部裁切。
  - 缓解：沿用 `onPreferredContentSizeChange` + `popover.contentSize` 双写机制（:1015/:1396 已有注释说明 NSPopover 会二次取 size）。
- 风险：新增数据源读取被误扩展成业务逻辑变更。
  - 缓解：限定为只读——`account/usage/read` 仅新增 RPC 请求与解析（不动 `readRateLimits` 现有路径）；SQLite 以只读 flag 打开；两者失败均不影响主额度与提醒链路。
- 风险：zcode 正在写入时 SQLite 读取冲突，或 `account/usage/read` 在部分账号/版本不可用（返回错误或空）。
  - 缓解：只读连接 + `busy_timeout`（500ms 级）+ 失败降级为空图；usage/read 失败单独容错并回退"暂无数据"，不抛错到主流程。
- 回滚方式：纯 UI 改动，`git revert` 对应提交即可；usage 数据缓存只新增 UserDefaults key，回滚后残留数据无副作用。

## 验证方式

- 命令：每阶段 `swift build`（提交前必过）。
- 手工检查（对齐 AGENTS.md）：
  - 额度刷新（手动按钮 + 60 秒防重）、刷新失败后旧数据保留（拔网络/关 ChatGPT.app 模拟，确认横幅显示 fetchedAt 与错误详情、重试可恢复）、自动刷新频率切换（1/5/30 分钟各观察一次）。
  - 右键菜单"切换账号 / 提醒设置 / 刷新频率 / 测试提醒 / 退出"全部仍可用；面板内设置页改动与右键菜单勾选态互相同步。
  - 提醒：阈值（改 50% 便于触发）、冷却、静音后"恢复提醒"按钮出现与生效；Touch Bar 设备与刘海屏（灵动岛）通道各实际验证一次并记录设备。
  - 重置卡：7 天内到期红 badge；Codex 与 ZAI 两个展开区独立工作。
  - 无限制空态：Pro 账号（无 5h 窗口）3 列对齐；Z.AI API Key / startPlan 待生效态展示。
  - 观测检查：popover 高度在展开/收起/切页时不裁切；Codex 30 天图与 `account/usage/read` 返回一致（首日/末日/今日柱数值抽查）；Z.AI 30 天图与 `sqlite3 ~/.zcode/cli/db/db.sqlite` 手工聚合一致；zcode 运行中打开面板不报错、不卡顿。
- 实际结果与未覆盖场景：
  - 机型：本机 macOS 25.6.0 arm64（Apple Silicon）。
  - 编译：`swift build` 通过（归档复核 0.11s）；`make build`（release）通过。
  - 测试：`arch -arm64 swift test` 103 项全部通过（2026-09-18 归档复核时有一项 `ManualRefreshTests` 既有失败，已于当日修复，详见 [历史记录](../histories/2026-09/20260918-1900-manual-refresh-test-fix.md)）。
  - 已实测：状态栏标题随刷新更新；`account/usage/read` 179 天 buckets 端到端拉取并缓存；popover 以 322pt 内容宽（含边框 348×526）正确打开；重置卡三次展开/收起弹窗尺寸 348×553 → 348×477 无裁切；设置开关 1→0→1 往返后主面板状态一致；手动刷新 60 秒防重全局生效、冷却后按钮恢复；重置卡 5h/周两枚按钮与 Codex 逐卡按钮同时显示；柱状图悬停提示即时浮层验收通过。
  - 未覆盖：Touch Bar / 刘海屏（灵动岛）通道在本任务期间未做实机投递验证（无对应硬件记录），沿用既有通道渲染链路；真实失败时缓存保留与长时间自动刷新未重新验证；整页截图未取得（无屏幕录制/辅助功能权限，部分轮次通过系统辅助功能只读核对代替）；多屏边界钳制、深浅色外观切换（面板固定深色）、辅助功能下浮层可读性未单独验证。

## 进度记录

- [x] 确认范围和约束（2026-09-15，含用户确认设置页采用 lite 版）。
- [x] 日用量数据源调研定稿（2026-09-15）：Codex 官方 `account/usage/read` + Z.AI 本地 SQLite，废弃 UsageHistoryStore 采样方案；图表口径改为每日 token 用量。
- [x] 阶段 0：设计 token 与骨架（2026-09-15，`PanelTheme.swift`；固定深色 vibrantDark 定稿）。
- [x] 阶段 1：provider 区块与胶囊网格（2026-09-15，`QuotaPanelViews.swift` + `ProviderPanelSections.swift`）。
- [x] 阶段 2：错误横幅、重置卡展开、图例与开关（2026-09-15，同上；NSAlert 列表已删）。
- [x] 阶段 3：30 天用量图 + 官方 API / SQLite 数据源（2026-09-15，`DailyUsageChartView.swift` + `CodexUsage.swift` + `ZCodeUsageDB.swift`；实施时改为独立 `CodexUsageClient` 单独拉起进程，未并入 rateLimits 会话，保持现有读取路径零改动）。
- [x] 阶段 4：设置页（lite）（2026-09-15，`SettingsPageView.swift`，齿轮切换、popover 重开回额度页）。
- [x] 编译与运行冒烟（2026-09-15）：`swift build` 通过；实测额度刷新、官方用量 179 天端到端拉取并缓存、popover 以 322pt 内容宽正确打开。详见 [历史记录](../histories/2026-09/20260915-1222-quota-popup-ui-redesign.md)。
- [x] 人工验证（2026-09-15 ~ 2026-09-18 分轮完成，详见"实际结果与未覆盖场景"）：弹窗内交互（重置卡展开/收起、设置页开关往返、手动刷新防重、错误横幅重试按钮渲染）、柱状图悬停浮层实机验收通过；Z.AI 用量图数据口径已用 SQL 等价核对（2026-09-14 = 88,839,193 与官方统计页一致）。截图未取得（无屏幕录制权限），以系统辅助功能只读核对 + 像素级单元测试代替目检。
- [x] 技术债复核、归档到 completed/（2026-09-18）：本计划范围新增 3 条技术债（图表 tooltip 第二指标、两家数据口径差异、完整版设置页）；验收复核发现的既有失败测试 `ManualRefreshTests.testFailedRefreshAndErrorRetryPreserveCooldown` 已于当日修复（详见 [历史记录](../histories/2026-09/20260918-1900-manual-refresh-test-fix.md)），不再登记。见 [技术债追踪](../tech-debt-tracker.md)。

### 实施记录（2026-09-15）

- 已按计划完成阶段 0–4 + 编译冒烟；`QuotaViewController` 重写为两页容器，删除旧 `QuotaRowView`、NSAlert 重置卡列表、只读设置区。
- 业务逻辑零改动核对：`RateLimitStore` / `ZAIQuotaStore` / `ReminderEvaluator` / `ReminderCenter` / `ReminderChannels` / `CodexAuthManager` / `RefreshSettings` / Touch Bar 条带均未修改；新增仅为只读数据源（CodexUsageClient、ZCodeUsageDB）与 UI 接线。
- 待人工项集中在无屏录权限下的弹窗交互目检；`/Applications` 旧版仍在运行，需 `make app` 重装后体验新版。

### 验收记录（2026-09-18）

- 用户确认"已验收完成"，计划归档至 `completed/`。
- 验收依据：阶段 0–4 全部完成，`swift build` / `make build` 通过，分轮人工验证与单元测试覆盖见"验证方式 · 实际结果"；遗留项为既有失败测试与无硬件通道，均已登记技术债而非阻塞验收。
- 后续衍生的独立计划（周限额配速图 + Z.AI 用量叠加模式）已在 `active/weekly-pace-chart.md` 与 `active/weekly-pace-chart-handoff.md` 单独立项，不在本计划范围内继续。

## 决策记录

- 2026-09-15：设置页采用精简版 settings-lite.html（用户确认）。完整版的"开机自启/菜单栏显示/关于"不实现；开机自启属新业务能力（SMAppService），已登记技术债。
- 2026-09-15：胶囊配色对齐提醒阈值（≤20% 橙 / ≤10% 红 / 距重置 ≤30 分钟黄），替代旧面板电池条色阶（<20 红 / <50 黄）；Touch Bar 条带配色不在本次范围，维持现状。
- 2026-09-15：30 天图数据源定为官方/本地只读（详见调研结论章节）：Codex 用 `account/usage/read`（账号级，179 天可回填），Z.AI 用 zcode 本地 SQLite（本机级，约 30 天）。原"UsageHistoryStore 快照采样"方案废弃——两家都有更好的现成数据源，无需自建历史记录。调用 `account/usage/read` 与 SQLite 只读查询是"不动业务逻辑"约束下允许的新增只读数据源，与被废弃方案同级。
- 2026-09-15：图表口径从原型的"5h 峰值 %"改为**每日 token 用量**：Codex 官方数据即 tokens，Z.AI 本地仅 tokens 可回填；百分比峰值在无活动日无意义。原型图表布局不变，仅纵轴与 tooltip 含义调整。若坚持"峰值 %"口径，Codex 可改用 rollout 回填（见调研结论），Z.AI 无法回填、只能部署日起采样——不推荐。
- 2026-09-15：右键菜单保留并与设置页并存，两者写同一配置链，避免双入口状态漂移。
- 2026-09-15（阶段 0 定稿）：面板外观**固定深色**（`PanelTheme.appearance = NSAppearance(named: .vibrantDark)`，贴近原型 #141416），不跟随系统双模式——原型即深色、工作量小，且避免与浅色菜单混搭割裂。
- 2026-09-15（阶段 4 定稿）：lite 设置页"已静音提醒"文案**去掉数字**，采用"有额度处于静音期"（`SettingsPageView.swift` 静音标签），零逻辑改动，不扩展 ReminderCenter 计数接口。
