# 额度弹窗横向 Tab 化重构（含 DeepSeek / CodeBuddy 国际版与国内版接入）

- 状态：已完成
- 创建日期：2026-09-22
- 最后更新：2026-09-24

## 目标

把 open-design 项目已定稿的横向 Tab 版弹窗（tabs.html）落地为 AppKit 原生实现：provider 身份（logo / 套餐 tag / 状态点）与剩余额度进度环上移到 Tab 栏，弹窗一次只显示一个 provider 看板；顶栏刷新按钮只刷新当前 active tab。Codex 与 Z.AI 的看板内容区完全保持原样；新实现 DeepSeek 与 CodeBuddy 两个 provider 的数据接入、面板与端到端验证流程，其中 CodeBuddy 国际版（`www.codebuddy.ai`）与国内版（`www.codebuddy.cn`）各占一个独立 tab。

## 范围

- 包含：
  - Tab 外壳：Tab 栏（圆形 logo + 外圈进度环 + 下方百分比 + 套餐 tag + 状态点 + tooltip）、点击切换面板、底部 1px 分隔线、超宽横向滚动；弹窗从「纵向双区块」改为「Tab 栏 + 单面板容器」。
  - 刷新语义变更（用户指令）：顶栏刷新按钮只刷新当前 active tab 的 provider，不再全部刷新；60 秒冷却沿用现有 per-provider 逻辑；后台自动刷新行为不变（仍刷新全部已启用 provider）。
  - 面板头部精简：各 provider 面板头部去掉 logo / 名称 / plan tag / 独立刷新按钮，只留时间与刷新状态；错误文案移入头部（省略号 + tooltip 全文）+ 右侧红色「● 刷新失败」；底部错误横幅（ErrorBannerView）与重试按钮退场。
  - DeepSeek provider 全链路：Chrome localStorage `userToken` 导入、平台余额 / amount / cost 接口、快照模型、面板（两指标卡 + 近 30 天消费图）、错误态。
  - CodeBuddy 国际版 provider 全链路：`www.codebuddy.ai` Cookie 导入、当前统一资源接口 `get-user-resource`、快照模型、Credits 面板（套餐基础积分条 + 购买积分 + 奖励包展开列表）、错误态。
  - CodeBuddy 国内版 provider 全链路：`www.codebuddy.cn` Cookie 导入（复用国际版数据层，仅域名与错误文案按站点区分）、独立 store / 独立快照 / 独立 tab，与国际版共用面板与刷新语义。
  - popover 高度按 active 面板重算；五 tab 布局验证；顶栏相对时间与 tooltip 语义对齐 active tab。
- 不包含（红线与推迟）：
  - Codex / Z.AI 看板内容区的任何改动：胶囊网格（Codex 3 列 / Z.AI 2 列）、无限制空态、余额胶囊、重置卡 chip 与展开、周配速图、近 30 天图与叠加模式、API Key / startPlan 特殊态——全部原样，只允许随外壳做容器层接线。
  - CodeBuddy 每日 Credits 趋势图（`get-user-daily-usage`）：tabs.html 定稿的 CodeBuddy 面板无图表，首版不含。
  - DeepSeek 用量明细钻取、多币种切换 UI、Safari / Firefox / Edge 导入、API Key 配置入口（数据计划已排除项继续排除）。
  - 设置页结构、右键菜单、Touch Bar 条带、提醒链路（ReminderEvaluator / ReminderCenter）、菜单栏标题与刷新调度架构的改动。
  - CodeBuddy 两站的显式 profile 选择 UI（沿用现有「单候选自动使用、多候选取第一个」策略）与面板内区域切换控件（两站已拆为独立 tab，不需要区域切换）。
  - 把 DeepSeek token 或 CodeBuddy Cookie 落盘缓存（内存短时使用，重启后重新导入）。

## 背景

- 来源会话：sess_eda651bb（tabs.html 设计定稿：Tab 栏 / 面板头部精简 / 错误展示迁移 / CodeBuddy Credits 口径 / Codex 配速图面板内副本）。设计结论已并入本文档，执行时不需回读聊天记录。
- 设计稿（唯一编辑对象为只读参照，不再迭代）：`/Users/hubert/Desktop/projects/open-design/.od/projects/quota-popup-redesign-9319/tabs.html`；raw 预览 `http://127.0.0.1:5175/api/projects/quota-popup-redesign-9319/raw/tabs.html`。同目录 index.html / settings.html / blocks.html 为旧变体，不采用。
- 相关计划（数据层口径继续有效）：
  - [DeepSeek Chrome Web 会话用量接入](deepseek-chrome-web-session-usage.md)：localStorage `userToken` 机制、三个接口口径、多 profile 校验、风险与单测规格。
  - [CodeBuddy Chrome Cookie 额度接入](codebuddy-chrome-cookie-quota.md)：`session` / `session_2` Cookie、当前统一资源接口、官方卡片分组口径、Keychain 约束与单测规格。2026-09-22 Chrome CDP 复核已替换旧接口契约。
  - **口径仲裁**：两份数据计划的「UI 方案 / 面板口径」章节与 tabs.html 冲突处（如 DeepSeek 的三格额度 + 汇总行 vs tabs.html 的两指标卡 + 消费图），以 tabs.html 定稿为准；接口、解析、错误分类、单测规格仍以数据计划为准。
- 相关代码路径：
  - `Sources/LocalQuotaBar/main.swift`：`QuotaViewController`（:2172 起，`quotaPage` 纵向栈、`refreshAllButton` 顶栏、`codexSection` / `zaiSection` 双区块、`recordRefreshedAt` :2335、`canRefreshAll` :2483）、AppDelegate 编排（`onRefresh` :1159 同时强制拉官方日用量、`onZAIRefresh` :1164、`onRefreshIntervalChange` :1179 重建双 store 定时器）。
  - `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift`：`ProviderHeaderView`（:138，含 60 秒冷却 `beginRefreshCooldown`）、`ErrorBannerView`（:1086，退场对象）、`PanelFooterView`（:1185，不动）。
  - `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`：`ProviderPanelSection` / `CodexPanelSection` / `ZAIPanelSection`（内容区不动，头部精简）。
  - 新增 `Sources/LocalQuotaBar/deepseek/`、`Sources/LocalQuotaBar/codebuddy/`（数据层，按两份数据计划）与 `ui/PanelTabBarView.swift`、`ui/DeepSeekPanelSection.swift`、`ui/CodeBuddyPanelSection.swift`。
  - `Package.swift`：新增 SweetCookieKit 依赖（两份数据计划共同前置）。
- 已知约束：
  - 原生 AppKit、固定深色（`PanelTheme.appearance`），不引入 WKWebView；tooltip 用 NSView toolTip / NSTrackingArea（上一轮已验证的悬浮浮层先例在 `DailyUsageChartView`）。
  - main.swift 已超 2600 行，新视图一律独立文件。
  - popover 高度走 `onPreferredContentSizeChange` + `popover.contentSize` 双写机制，切 tab 时须重算。
  - ZAI 显隐仍由 `ZAISettings.isZAIDomain()` 决定；隐藏时 Tab 栏只出 Codex / DeepSeek / CodeBuddy。
  - DeepSeek token 读 Chrome localStorage（LevelDB 快照，无 Keychain）；CodeBuddy Cookie 解密需要 `Chrome Safe Storage` Keychain 授权，后台刷新必须禁 Keychain UI（详见 CodeBuddy 计划风险节）。

## 设计定稿规格（从 tabs.html 提取，执行以设计稿为准）

- 尺寸与色板：沿用 PanelTheme（内容宽 322、深色 #1A1A1C、阈值色绿 `#32d583` / 橙 `#ff9f0a` / 红 `#ff453a`）。阈值分级与 App 提醒阈值一致：剩余 >20% 绿、≤20% 橙、≤10% 红。
- Tab 栏（`.tabbar`）：位于顶栏下方、面板容器上方，底部 1px 分隔线；横向排列、超出宽度可横向滚动（隐藏滚动条）；tab 间距 2pt、内边距 8/8/6。
- Tab item（`.tab-item`）：36pt 进度环（track 2.5pt `#2c2c30`、fill 2.5pt 圆头、按阈值配色、`strokeEnd` = 剩余比例、起始角 -90°）内嵌 25pt 圆形 logo（圆底为品牌渐变背景填充，无边框，用户指令）；logo 右上角 tag（蓝色小胶囊，带底色与描边，DeepSeek 无 tag）；logo 右下角状态点（6.5pt 点体 + 呼吸灯光晕，绿 = 最近刷新成功 / 红 = 刷新失败）；环下方百分比文字（9.5pt 粗体、阈值配色）。active 态为图标风格液态玻璃选中态（炭黑对角渐变 + 左上 / 右下角部冷白微光 + 均匀描边 + 外投影，取代设计稿 `rgba(255,255,255,0.08)` 白底，见决策记录），hover 0.04。
- tag 口径：Codex / Z.AI 显示套餐名（如 `Pro`）；**CodeBuddy 显示站点区域标识 `INTL` / `CN`**（两站同名同 logo，角标是唯一区分手段，套餐名改在面板基础积分行与 tooltip 展示，见决策记录）。
- 进度环口径（哪家取哪个百分比）：
  - Codex = 周限额剩余；无周限窗口的账号退回 5 小时窗口；两者皆无则空轨。
  - Z.AI = 周限额剩余（5 小时剩余进 tooltip）；API Key 模式无百分比，空轨 + 余额口径。
  - CodeBuddy = 套餐基础积分剩余比例（示例 498.38 / 500 = 99.7%）。
  - DeepSeek = 无「剩余 / 总量」口径（沿用数据计划「不伪造剩余百分比」决策）：环不填充（空轨），百分比文字位置改显余额金额（如 `¥5.13`），颜色用主文字色（白色，用户指令）。
  - 环无法取值（数据缺失 / 刷新失败）时空轨 + 文字「--」。
- 顶栏（`.top`）：`LocalQuotaBar`（13pt 粗体）+ 相对时间（次级色，跟随 active tab 最近一次成功刷新）+ 刷新图标按钮 + 设置图标按钮；刷新按钮 tooltip「刷新 <provider 名>」，禁用态沿用 60 秒冷却文案。
- 面板头部（`.p-head` 精简版）：正常态右侧显示该 provider 最近成功刷新时间（沿用 `formatFetchedAt` 口径）+ 绿点；失败态左侧错误文案（单行省略、tooltip 全文）+ 右侧红点「刷新失败」。不再有 logo / 名称 / tag / 刷新按钮 / 底部横幅。
- DeepSeek 面板：头部时间行 → 两张指标卡（`充值金额` ¥5.13 CNY / `累计消费金额` ¥4.92 CNY，tooltip 拆充值 / 赠送余额与 token 估算，多币种主币种 + tooltip 拆分）→ 近 30 天消费图（每日 ¥ 柱、今日高亮、均值线、图头「消费金额：¥0.21 · Tokens：0.16M」）。错误态（含 Keychain / 会话失效）在头部展示；「重新授权」语义 = 顶栏刷新触发可弹 Keychain 的手动路径。
- CodeBuddy 面板（国际版 / 国内版共用）：头部时间行 → 套餐基础积分行「83.05/100 积分（体验版）」+ 右侧「09-30 更新」（周期更新时间，次级色）+ 细进度条（6pt 高、无百分比文字）→ 购买积分 chip（无资源包时空态「购买积分 · 无资源包」且不渲染展开按钮；有包时 chip 计数，到期下放到单项「剩余/总量 积分 · MM-dd HH:mm」）→ 奖励包 chip「奖励包 ×3 · 剩余/总量」（无奖励包时不渲染该 chip）+ 展开列表。两站共用同一 `CodeBuddyPanelSection`，数据源不同。
- Tooltip：所有 tab 与顶栏按钮悬浮显示深色气泡，两行（第一行名称 + 套餐；第二行额度 / 金额摘要），如 `Codex · Pro` / `周限额剩余 64% · 4天3时后重置 · 余额 $40.68`。
- 底部 footer：阈值图例 + 低量提醒开关行，完全不动。
- Tab 顺序固定：Codex → Z.AI → DeepSeek → CodeBuddy（INTL）→ CodeBuddy（CN）；默认 active = Codex；**持久化上次选择**（`panel.activeTab`，弹窗重开恢复，命中不可见 tab 时回退 Codex）。

## 设计 → 代码映射

| # | 原型元素 | 现状代码锚点 | 目标改动 |
| --- | --- | --- | --- |
| 1 | Tab 栏 + tab item（环 / logo / tag / 状态点 / 百分比） | 无对应（现为纵向双区块） | 新 `ui/PanelTabBarView.swift`：CAShapeLayer 环（track + fill，strokeEnd 按口径表）+ logo 视图 + tag + 状态点 + pct 文字；数据入口为各 provider 汇总的 `TabStatus`（fraction、level、tag、isFailed、fallbackText） |
| 2 | Provider logo 资产（4 个品牌 SVG） | 顶部栏无 logo；`ProviderHeaderView` 现用文字 / 既有样式 | 从 tabs.html 提取 4 个 logo 的 SVG path；优先引入轻量 path→CGPath 转换做矢量渲染，备选经 `Tools/render-svg-icon.swift` 生成多倍率 PNG 入 Resources（阶段 1 定稿一种） |
| 3 | 面板容器 tab 化 | `quotaPage` 纵向栈 + `zaiBlock` 显隐（`buildSections` :2452） | `quotaPage` 改为「顶栏 + Tab 栏 + 面板容器 + footer」；五个 section 实例常驻、非 active 隐藏；切换时重算 `preferredContentSize`；Codex / ZAI section 复用现有实例，内容区零改动 |
| 4 | 顶栏刷新 = 仅 active tab（用户指令） | `refreshAllButton.onTap`（:2428）同时 `codexSection.requestRefresh()` + `zaiSection.requestRefresh()`；`canRefreshAll`（:2483） | onTap 改为只调 active section 的 `requestRefresh()`；按钮可用态 = active section 的 `canRequestRefresh`；tooltip「刷新 <名称>」；60 秒冷却仍由 section 内 `ProviderHeaderView.beginRefreshCooldown` 承担（按钮随 `onRefreshAvailabilityChange` 联动） |
| 5 | 顶栏相对时间跟随 active tab | `recordRefreshedAt`（:2335）取全 provider 的 max | 改 per-provider 记录 + 顶栏读取 active provider 的最近成功时刻；面板头部时间各自独立展示 |
| 6 | 面板头部精简（去 logo / 名称 / tag / 刷新按钮） | `ProviderHeaderView`（QuotaPanelViews.swift:138） | 增加 slim 模式：仅状态行（时间 / 错误文案 + 红点「刷新失败」）；冷却与可用性状态保留，刷新按钮 UI 删除；`CodexPanelSection` / `ZAIPanelSection` 内容区不动 |
| 7 | 错误横幅退场、错误进头部 | `ErrorBannerView`（QuotaPanelViews.swift:1086）及其测试 | 面板改用头部错误行（省略号 + tooltip 全文）；重试入口 = 顶栏刷新（当前 tab）；`ErrorBannerViewTests` 改写为头部错误态测试 |
| 8 | DeepSeek tab + 面板 | 无对应 | 新 `deepseek/` 数据层（按 DeepSeek 计划里程碑 1–3）+ `ui/DeepSeekPanelSection.swift`（两指标卡 + 消费图，图复用 `DailyUsageChartView` 的柱 / 均值线骨架，纵轴与 tooltip 改 ¥ 口径）+ AppDelegate 新 store 编排（定时器、onChange、错误保留缓存） |
| 9 | CodeBuddy tab + 面板（国际版） | 无对应 | 新 `codebuddy/` 数据层（当前接口为 `POST /billing/meter/get-user-resource`，解析 `data.Response.Data.Accounts`；Cookie 候选域名 `www.codebuddy.ai`）+ `ui/CodeBuddyPanelSection.swift`（细进度条 + chips + 展开列表复用 card-list 模式）+ store 编排；角标显示 `INTL` |
| 9b | CodeBuddy tab + 面板（国内版） | 无对应 | 复用 `codebuddy/` 数据层与 `CodeBuddyPanelSection`，新增 `codeBuddyCNStore`（`domain: www.codebuddy.cn`、独立快照与 Keychain 授权路径）与 `codeBuddyCN` tab（角标 `CN`）；`CodeBuddyAPIError.sessionExpired` 与 `ImportError` 文案按目标 host 区分，Cookie 导入复用同一套 host/path 过滤 |
| 10 | 自动刷新纳入新 provider | `onRefreshIntervalChange` 重建双 store 定时器（:1179） | 扩为五 store（Codex / Z.AI / DeepSeek / CodeBuddy INTL / CodeBuddy CN）；CodeBuddy 两站后台刷新走禁 Keychain UI 读取路径，失败保留缓存并在面板提示需手动刷新授权；DeepSeek localStorage 快照读取无此约束 |
| 11 | popover 高度随 active 面板变化 | `onPreferredContentSizeChange` 双写机制 | 切 tab、展开列表、设置页往返时逐 tab 验证不裁切 |
| 12 | Tab / 顶栏 tooltip 气泡 | 图表悬浮浮层先例（`DailyUsageChartView`） | 复用深色气泡样式：tab 两行（名称 + 套餐 / 额度摘要）、按钮单行，视口钳制 |
| 13 | ZAI 显隐 → tab 显隐 | `setZAISectionVisible`（:2287） | 判断条件不动，作用对象改为 ZAI tab 的显隐；隐藏时剩余 tab 顺序保持 |

## 风险

- 风险：main.swift 面板容器重构导致 Codex / Z.AI 行为回归（用户红线「看板完全保持原样」）。
  - 缓解：section 实例与 `apply` / `applyZAI` 签名不变，只改容器与显隐；阶段 1 完成后先做一轮「内容区对照验证」（现有 PanelRenderingTests 全绿 + 手动核对数值与交互）再进入新 provider 阶段。
- 风险：顶栏刷新语义从「全部」改为「active tab」，用户肌肉记忆与既有测试预期不符。
  - 缓解：tooltip 明示「刷新 <名称>」；`ManualRefreshTests` 按新语义改写（含「刷新 A 不影响 B 的 fetchedAt」断言）；自动刷新仍覆盖全部 provider，面板数据不会因不切 tab 而停滞。
- 风险：DeepSeek 进度环无百分比口径，强行造百分比违背数据计划决策。
  - 缓解：按口径表降级为空环 + 余额金额文字；`PanelTabBarViewTests` 固化该降级行为。
- 风险：CodeBuddy Cookie 解密触发 Keychain 授权弹窗，后台刷新无法响应。
  - 缓解：沿用 CodeBuddy 计划方案——手动刷新完成一次授权，后台周期只做禁 UI 读取，失败保留缓存并提示。
- 风险：新增 SweetCookieKit 依赖构建失败或 API 变化。
  - 缓解：阶段 0 先在独立分支验证依赖解析与最小读取示例；失败则回退评估替代实现（数据计划回滚方式：移除 provider 入口与依赖即可）。
- 风险：五 tab × 不同面板高度，切 tab 时 popover 跳变或裁切。
  - 缓解：复用双写尺寸机制，切换时同步重算；验证覆盖「最高面板（Codex 展开配速图）→ 最矮面板（CodeBuddy）」往返。
- 风险：DeepSeek / CodeBuddy 均为逆向 Web 接口，登录态或字段变化导致面板长期错误态。
  - 缓解：错误分类透出（会话失效 / 凭证不可读 / 接口失败），保留最后有效快照与时间；两份数据计划的单测规格兜底解析回归。
- 回滚方式：阶段 1（外壳）与阶段 2/3（新 provider）各自独立成提交；外壳回滚 revert 单个提交即回到纵向双区块；新 provider 回滚移除 tab 与数据层目录即可，不影响 Codex / Z.AI 链路。

## 里程碑

1. 阶段 0 · 依赖与口径对齐：确认两份数据计划状态；Package.swift 引入 SweetCookieKit 并验证构建；冻结 tabs.html 为只读参照；确定 logo 资产方案。
2. 阶段 1 · Tab 外壳与刷新语义（仅 Codex / Z.AI 两个 tab）：`PanelTabBarView` + 面板容器 tab 化 + 顶栏 active-tab 刷新 + 头部精简与错误迁移 + 相对时间 per-provider 化；`swift build` / `swift test` 通过；完成 Codex / Z.AI 内容区对照验证（红线检查）。
3. 阶段 2 · DeepSeek 接入：数据链路（token 导入 → 余额 / amount / cost → 解析与单测，按 DeepSeek 计划里程碑 1–2）→ 面板与 tab（里程碑 3）→ AppDelegate 编排与错误态。
4. 阶段 3 · CodeBuddy 国际版接入：数据链路（Cookie 导入 .ai → 当前统一资源接口 `get-user-resource` → `data.Response.Data.Accounts` 解析与单测，按 CodeBuddy 计划里程碑 1–2）→ Credits 面板与 tab（里程碑 3）→ 编排、Keychain 授权路径与错误态。
5. 阶段 3b · CodeBuddy 国内版接入：复用数据层与面板，新增 `codeBuddyCN` store / tab；Cookie 导入与错误文案按 `.cn` host 区分；401 / 403 归类为对应站点的会话失效；补 CN 专项单测（tab 可见性与角标、active-tab 刷新互不影响、请求契约 host、错误文案 host）。
6. 阶段 4 · 验证与收尾：全量验证（见下）、历史记录、计划移至 completed/。

## 验证方式

- 命令：每阶段 `swift build`；新增 / 改写测试后 `arch -arm64 swift test`（后台跑设 60 秒超时）。
- 单测：
  - Tab 外壳：环口径表（Codex 5h 优先退周限、ZAI 5h 优先退周限、CodeBuddy 积分、DeepSeek 空环金额、缺失空轨）、阈值配色（>20% / ≤20% / ≤10%）、tag 与状态点、active 切换、ZAI 隐藏时 tab 集。
  - CodeBuddy 两站：`codeBuddy` / `codeBuddyCN` 同时可见且角标分别为 `INTL` / `CN`；两站环各自独立取值；顶栏刷新只触发当前 active 的那一站（另一站计数不变）；`www.codebuddy.cn` 请求的 host / Referer / region 正确；401 / 403 归类为 `sessionExpired` 且文案含目标 host；Cookie 导入失败文案指向目标站点。
  - 刷新语义：顶栏刷新只触发 active section；冷却期按钮禁用；「刷新 A 后 B 的 fetchedAt 与 updatedLabel 不变」断言。
  - 头部精简：错误文案省略与 tooltip 全文、红点状态、ErrorBannerView 移除后的等价覆盖。
  - DeepSeek / CodeBuddy：按两份数据计划的单测规格全量执行（token 三形态、envelope 错误、多 profile、双域名候选、套餐分组、数值格式化等）。
- 手工检查：
  - Codex / Z.AI 红线对照：重构前后胶囊数值、重置卡展开、配速图、近 30 天图与叠加模式、API Key / startPlan 态一致（以重构前实测记录为基准）。
  - Tab 交互：五 tab 切换、默认 Codex、重开弹窗恢复上次 tab（不可见时回退 Codex）、tooltip 两行、状态点随刷新结果变色、超宽滚动（缩小窗口宽度模拟）。
  - 顶栏刷新：active-tab-only 语义（切到 Z.AI 点刷新，Codex 更新时间不变）；CodeBuddy 两站互不影响；60 秒冷却与恢复；自动刷新（5 分钟档）五 provider 均更新。
  - DeepSeek 真实登录态：已登录 Chrome profile 导入 token 成功；面板余额与 `https://platform.deepseek.com` 钱包页一致；近 30 天消费与平台用量页一致；退出登录后显示会话过期并保留旧快照。
  - CodeBuddy 国际版真实登录态：首次手动刷新完成 Keychain 授权；面板数值与 `https://www.codebuddy.ai/profile/plans-usage` 一致（重点核对剩余 / 总量与周期更新时间）；后台周期不重复弹授权；退出登录后显示会话失效不清空快照。
  - CodeBuddy 国内版真实登录态：与 `.ai` 同流程核对 `https://www.codebuddy.cn/profile/plans-usage`；两站登录态可同时存在且互不干扰；某一站未登录时该 tab 报对应站点的错误文案，另一站不受影响。
  - 错误态：Codex（关 ChatGPT.app / 断网）、DeepSeek（无 token / 会话过期）、CodeBuddy（Keychain 拒绝 / Cookie 失效）各自头部错误行正确，重试可恢复。
  - popover 高度：逐 tab 打开、展开收起列表、设置页往返不裁切不跳闪。
- 观测检查：token / Cookie 不出现在日志、错误详情与调试输出；切 tab 不触发数据请求（纯 UI 切换）；刷新失败不清空卡片。
- 实际结果与未覆盖场景（2026-09-22 实施轮）：
  - 编译：`swift build`、`swift build -c release` 均通过（Apple Swift 6.3.3，arm64）。
  - 测试：阶段验收时 `arch -arm64 swift test` 237 项通过、0 失败；收尾轮扩展到 253 项并保持全绿（2 项 live 探针默认 skip；DeepSeek live 探针在 `LOCALQUOTABAR_DEEPSEEK_LIVE=1` 下已实跑通过）。
  - DeepSeek 真实登录态：本机 Chrome Default profile `userToken` 导入成功；summary / amount / cost 三接口真实请求成功。实测修正三处口径：① bucket 时间字段为 `time`（非 timestamp）；② cost 金额字段为 `cost`；③ 窗口必须对齐自然日（end=明天 0 点，传当前时刻返回 INVALID_PARAM）。快照实测：充值 ¥4.3042 / 累计消费 ¥10.6958 / 近 30 天消费 ¥6.0988（16.37M tokens、9 个有数据日）。
  - CodeBuddy 国际版（2026-09-22 Chrome CDP + URLSession 复核）：已登录的 `https://www.codebuddy.ai/profile/plans-usage` 页面套餐与额度正常显示，Chrome 的资源接口返回 200。分支实现已迁移到 `get-user-resource`，请求体、`X-Client-Platform: web`、正确 Referer、浏览器上下文头以及按目标 host/path 过滤去重的有效 Cookie jar 均已补齐；响应解析改为 `data.Response.Data.Accounts[]`。真实 `LOCALQUOTABAR_CODEBUDDY_LIVE=1 swift test --filter CodeBuddyLiveProbeTests` 已通过，解析到体验版 100 总量 / 83.05 剩余和 3 个奖励包。此前 APISIX 401 的根因是旧接口、请求头不足和 Cookie 集合不完整的组合，不是 Chrome 会话过期，也不是必须改用浏览器中转。
  - CodeBuddy 国内版（2026-09-22 复核轮）：新增 `codeBuddyCN` store / tab，复用国际版数据层与面板；`CodeBuddyAPIError.sessionExpired(host:detail:)` 与 `ImportError.chromeNotFound(host:)` / `cookieNotFound(host:)` 按目标站点出文案，修正此前「国内版未登录却提示去 `.ai` 登录」以及 401 被误报为「请稍后重试」两个验收阻断项；补 CN 专项单测（tab 可见性与角标、active-tab 刷新互不影响、请求契约 host / region、401 分类与错误文案）。国内版真实登录态端到端验证已由用户确认通过。
  - UI 验收微调轮（2026-09-22，每轮 `make app` 重启应用由用户目检）：tag 胶囊底与位置收紧、状态点光晕增强为呼吸灯、头部时间右对齐、DeepSeek 消费图补日期刻度与 tooltip 屏幕坐标锚点、首刷失败无历史数据时隐藏内容区、恢复上次 tab、logo 改渐变背景填充、环口径 5h 优先、INTL/CN 角标、Credits 统一 `<剩余>/<总量>` 口径、popover 锁 `vibrantDark` + rootView 实色化、液态玻璃选中态（三轮调校：光晕溢出 → clip 修复 → 移除中间与四角光影只留左上 / 右下角部微光）、DeepSeek tab 金额白色。全程 253 项测试保持全绿。
  - Codex 审查验收轮（2026-09-22）：对 Codex 审查的 9 项问题复核——错误文案 host 参数化、文档与口径同步、timer 祖先隐藏停表、`.cn` 请求契约测试均已落实；「国内版应分叉旧三接口」的判定被双站实测推翻（`.cn` 网关接受 `get-user-resource`）。本轮补 idle 三态状态点与 live 探针站点参数化，`.ai` 与 `.cn` 双站 live probe 均通过（CN 实测：`CodeBuddy个人体验版` 500 总量 / 162.92 剩余、9 个奖励包、`other` 分组为空，两站分类零残留）；Profile fallback 登记技术债；全量 253 项测试通过（此前记录的 ResetCard 布局既有失败已由并行修复轮消除）。
  - Codex / Z.AI 红线对照：既有 PanelRendering / ZAIUsagePresentation / ResetCard* / Chart* 等测试全绿；胶囊网格、重置卡、配速图、用量图与叠加模式代码路径零改动。
  - 历史未形成独立截图 / 实录证据：五 tab UI 目检（popover 逐 tab 高度、展开列表、设置页往返）、CodeBuddy Keychain 授权弹窗走查、DeepSeek 会话过期态、Touch Bar / 刘海屏通道。归档复核时用户确认本计划所列功能与复核项均已完成；Touch Bar / 刘海屏不在本计划改动范围内。
  - 归档复核（2026-09-24）：以 worktree `161199b` 已被 `main@22c71fb` 合并的五 tab 版本为基线，清除主工作区从 stash 恢复出的四 tab 旧稿；当前主工作区重新执行 `swift build` 通过，`swift test` 255 项、0 失败（2 项 live 探针按默认配置跳过）。

## 进度记录

- [x] 确认范围和约束（2026-09-22，含用户四点指令：active-tab 刷新、Codex / Z.AI 看板原样、DeepSeek / CodeBuddy 实现并验证、CodeBuddy 国际版先行）。
- [x] 完成阶段 0（SweetCookieKit 0.5.3 依赖引入，95178d1）。
- [x] 完成阶段 1（Tab 外壳与刷新语义，219 项测试全过 + 启动冒烟，0faf6cd）。
- [x] 完成阶段 2（DeepSeek 全链路 + 真实登录态端到端验证通过，3e91c5e）。
- [x] 完成阶段 3 首版实现（CodeBuddy 国际版，`b4a4d4c`；基于当时逆向得到的旧接口契约）。
- [x] 修正阶段 3 数据链路：迁移到当前 `get-user-resource` 接口，更新请求头 / 请求体 / envelope / fixture，并完成真实登录态端到端验证。
- [x] 完成阶段 3b 国内版接入（`codeBuddyCN` store / tab、错误文案与 401 分类按站点区分、CN 专项单测）。
- [x] 完成阶段 4 自动化部分（253 项测试、debug 构建通过、五 store 编排、历史记录）。
- [x] CodeBuddy 国内版真实登录态端到端验证（用户确认通过）。
- [x] 完成多轮 UI 验收微调（呼吸灯 / 液态玻璃 / popover 实色化 / Credits 剩余总量口径统一，见决策记录）。
- [x] Codex 审查问题修复轮（idle 三态状态点、live 探针站点参数化、Profile fallback 登记技术债）。
- [x] 用户复核项：完成五 tab UI 目检（含 popover 高度与 Keychain 授权路径；2026-09-24 用户确认）。
- [x] 补齐归档复核结果并移至 `completed/`（2026-09-24）。

分支：`quota-popup-tabs-redesign`（worktree `../LocalQuotaBar-tabs`，已合并至 `main@22c71fb`）。

## 决策记录

- 2026-09-22：顶栏刷新从「全部刷新」改为「只刷新当前 active tab」（用户指令）。理由：四 provider 时代全量刷新代价高且违背查看意图。影响：`ManualRefreshTests` 等按新语义改写；自动刷新保持全量不变，面板数据不因不切 tab 停滞。
- 2026-09-22：Codex / Z.AI 看板内容区完全保持原样（用户指令），本计划对其只做容器层接线与头部精简。理由：保护已验收的两条数据链路与交互。影响：阶段 1 增加红线对照验证关卡，未通过不进入新 provider 阶段。
- 2026-09-22：DeepSeek 进度环不伪造百分比，空轨 + 余额金额文字。理由：余额型 provider 无「剩余 / 总量」口径，沿用 DeepSeek 计划「不伪造剩余百分比」决策。影响：`PanelTabBarView` 需支持 fallbackText 形态。
- 2026-09-22：CodeBuddy 首版只做国际版 `www.codebuddy.ai`，Cookie 候选域名首版固定 `.ai`（用户指令）；国内版 `.cn` 留待后续评估。（**已被 2026-09-22「国内版独立 tab」决策取代**）
- 2026-09-22：DeepSeek / CodeBuddy 面板展示层以 tabs.html 定稿为准，两份数据计划的 UI 章节仅作数据口径参考（冲突仲裁规则写入「背景」）。理由：tabs.html 是用户在来源会话逐项确认的最新定稿。
- 2026-09-22：CodeBuddy 每日 Credits 趋势图不入首版。理由：tabs.html 定稿的 CodeBuddy 面板无图表；趋势接口为可选项，待有展示需求再评估。
- 2026-09-22：Tab 顺序固定、默认 Codex、不持久化选择。（**持久化选择部分已被 2026-09-22「恢复上次 tab」决策取代**）
- 2026-09-22（实施）：凭证读取基础设施采用 `steipete/SweetCookieKit` 0.5.3（CodexBar 同源），同时覆盖 localStorage LevelDB（DeepSeek token）与 Cookie Keychain 解密（CodeBuddy），自带 `withUserInteractionDisallowed` 满足后台禁 UI 需求。
- 2026-09-22（实施）：DeepSeek 多 Chrome profile 场景首版自动选择 leveldb 修改时间最新者，并在面板提示「检测到 N 个登录态」；显式 profile 选择菜单（右键菜单）推迟。理由：本机实测仅 Default 一个候选，先保证单候选路径零交互可用。profile 标识持久化结构已预留（DeepSeekStore.preferredProfileID）。
- 2026-09-22（实施）：错误重试语义随横幅删除而变化——失败后的重试入口即顶栏刷新（当前 tab），遵守同一 60 秒冷却（旧横幅重试可绕过冷却）。理由：tabs.html 定稿已删除横幅与重试按钮；顶栏刷新语义统一。
- 2026-09-22（实施）：DeepSeek 用量窗口按实测对齐自然日（start=今天-29 天 0 点、end=明天 0 点）；解析按本地自然日聚合、窗口外桶丢弃。
- 2026-09-22（CodeBuddy 复核）：Web 平台无 Bearer，当前成功请求使用 `X-Client-Platform: web`；现有正式客户端并未保留该请求头。Chrome 当前页面进一步确认资源接口已迁移为 `get-user-resource`，旧三端点契约废止。理由：真实网络请求与响应为最高优先级证据。影响：阶段 3 从“实现完成、等待复核”改为“旧版实现完成、当前接口迁移待办”，撤销会话过期 / 浏览器指纹判断。
- 2026-09-22（CodeBuddy 修复完成）：URLSession 需要完整目标 Cookie jar 与浏览器上下文头；补齐后 live probe 成功。理由：仅 Cookie 或仅 `X-Client-Platform` 仍被 APISIX 401，完整对齐 Chrome 非凭证请求上下文后通过。影响：Cookie 按 host/path 过滤去重且不落盘，阶段 3 当前接口适配与真实验证完成。
- 2026-09-22（国内版独立 tab）：CodeBuddy 国内版 `.cn` 采用**独立第二个 tab**（推迟项方案 A），而非单 tab 内区域切换（方案 B）。理由：`.cn` 与 `.ai` 是不同登录态、不同账号，独立 tab 可各自持有快照与刷新状态，互不影响；区域切换需要在一个面板内维护两套数据源与切换态，复杂度更高。影响：`QuotaTabID` 增 `codeBuddyCN`，`AppDelegate` 增 `codeBuddyCNStore`，自动刷新扩为五 store。
- 2026-09-22（CodeBuddy 角标口径，用户确认）：CodeBuddy 两个 tab 的角标显示**站点区域标识 `INTL` / `CN`**，不显示套餐名；套餐名改在面板基础积分行「83.05/100 积分（体验版）」与 tab tooltip 摘要中展示。理由：两站 `displayName` 同为 `CodeBuddy`、logo 与品牌渐变也相同，若角标再显示套餐名（实测两站均为「体验版」），两个 tab 在视觉上无法区分。影响：覆盖设计定稿「tag = 套餐名」一条；Codex / Z.AI 的 tag 语义不变，仍为套餐名。
- 2026-09-22（401 分类修正）：当前 `get-user-resource` 接口在有效登录态下不会返回 401，因此 HTTP 401 / 403 归类为 `sessionExpired` 并提示重新登录目标站点；非 2xx 其它状态码仍归 `http(status)`。理由：此前 401 抛 `requestRejected`（文案「请稍后重试」），用户真正退出登录时会拿到误导性提示，而验收要求显示会话失效；`sessionExpired` 此前是未被任何代码构造的死分支。影响：`CodeBuddyAPIError.sessionExpired` 由 `(String)` 改为 `(host:detail:)`，`requestRejected` 移除。
- 2026-09-22（错误文案按站点参数化）：`ImportError.chromeNotFound` / `cookieNotFound` 带 `host` 参数，`sessionExpired` 文案用目标 host 拼装。理由：此前文案硬编码 `www.codebuddy.ai`，国内版读不到 Cookie 时会让用户去国际站登录。影响：`CodeBuddyStore` 暴露 `requestHost`（含 `www.` 前缀）供导入与错误文案共用。
- 2026-09-22（恢复上次 tab）：弹窗重开时恢复上次选择的 tab（`UserDefaults` 键 `panel.activeTab`），命中不可见 tab（如 Z.AI 被隐藏）时回退 Codex。理由：五 tab 后每次重开都回到 Codex 会增加反复切换成本。影响：取代此前「不持久化选择」决策；测试统一改用 `QuotaViewController.makeForTesting()` 注入独立 defaults suite，避免用例互相污染。
- 2026-09-22（状态点呼吸灯）：状态点光晕改为呼吸灯——`PanelStatusDotView` 以 30fps Timer 手绘径向渐变，强度按余弦在 0.3…1 往返（周期 3.2s），仅挂窗且可见时运行。理由：CALayer shadowOpacity 会被 AppKit 重置，CAGradientLayer 径向渐变在 layer-backed 视图上渲染成方形且动画不跑（两种方案实测失败）。影响：点体参数化（tab 6.5pt / 头部 mini 5pt），画布加大并禁边界裁剪防光晕被切。
- 2026-09-22（液态玻璃选中态，用户指令）：active tab 背景改为图标风格液态玻璃：135° 炭黑渐变（#2A2A2F→#1A1A1C 48%→#141416）+ 左上 / 右下角部冷白微光（0xE9F7FF 峰值 0.07 / 0xC5E9FF 峰值 0.05）+ 顶部 1px 内高光 + 均匀描边（0xF4FCFF 16%）+ 外投影（0 4px 14px 黑 35%，仅 active 时开）。所有绘制先 clip 在圆角底内，`draw(_:)` 开头再整体 `addClip` 防光晕溢出弹窗。理由：取代 tabs.html 的 rgba 白底；中间与四角光影经用户确认移除，只保留对角角部微光；参数取自应用图标 SVG 定义。影响：`PanelTabItemView.drawLiquidGlassSelection`。
- 2026-09-22（popover 实色化，用户指令）：弹窗去除所有透明度——`popover.appearance` 锁 `vibrantDark`，`TouchBarHostingVisualEffectView` 改继承 `NSView` 用纯实色背景（#1A1A1C）。理由：浅色系统下 popover 边框的浅色半透明材质与毛玻璃 rootView 叠加导致整体发灰，单纯调背景色无法根治。
- 2026-09-22（Credits 口径统一，用户指令）：CodeBuddy 面板所有积分展示统一 `<剩余>/<总量> 积分`，不再并列「已用」「剩余」（322pt 窄面板放不下且信息重复）；到期时间下放到资源包单项（`MM-dd HH:mm`），不进 chip 总标题；无资源包的购买积分 chip 不渲染展开按钮，无奖励包时不渲染奖励包 chip；tooltip 与顶栏摘要不显示 Chrome profile 标识。影响：`CodeBuddyPanelSection` 与 `PanelTabStatus.summary`。
- 2026-09-22（DeepSeek 金额白色，用户指令）：tab 环下方余额金额用主文字色（白），与 INTL tab 的可读性对齐。影响：`PanelTabStatus.valueColor` 的 `.text` 分支改 `PanelTheme.primaryText`。
- 2026-09-22（首刷空态，用户指令）：DeepSeek / CodeBuddy 首次刷新成功前（含首刷失败）无任何历史数据时只显示头部状态行，不渲染指标卡 / 图表 / chips 占位。影响：两面板 `apply` 中 `snapshot == nil` 分支整体隐藏内容区。
- 2026-09-22（idle 状态点，Codex 审查项）：tab 状态点增加 idle 三态——无快照且无错误（首次刷新未完成）时点体置灰（tertiaryText）且不做呼吸，绿 / 红仍分别表示最近刷新成功 / 失败。理由：原二态把「从未刷出数据」显示为正常绿点，与面板头部 mini 点的 idle 口径（灰）不一致且误导。影响：`PanelTabStatus.isIdle` + `PanelStatusDotView.isIdle`（idle 时 timer 停跑、光晕不画），五个 provider 的 `tabStatuses()` 接线；`PanelTabBarViewTests` 补 idle 断言。
- 2026-09-22（live 探针参数化，Codex 审查项）：CodeBuddy live 探针支持 `LOCALQUOTABAR_CODEBUDDY_LIVE_HOST` 指定目标站点（默认 `www.codebuddy.ai`），国内版链路可随时用真实登录态复核，不再只有一次性人工确认。理由：Codex 审查指出 `.cn` 缺少自动化验证；实测两站 `get-user-resource` 契约一致，仅 host / Referer / region 不同，参数化优于写第二个探针。影响：`CodeBuddyLiveProbeTests`；多 Chrome Profile fallback 因无法真实验证登记技术债（tech-debt-tracker）。

## 已落地：CodeBuddy 国内版看板（阶段 3b）

> 原「推迟项」已实施。形态采用方案 A（独立第二个 tab）。

- 形态：`codeBuddyCN` 独立 tab，角标 `CN`；国际版角标 `INTL`。两站各自持有 `CodeBuddyStore` 实例（`domain` 分别为 `codebuddy.ai` / `codebuddy.cn`），快照、刷新状态、错误态与 60 秒冷却互相独立。
- 数据层：Cookie 候选机制按 `domain` 参数化（`importCandidates(domain:allowKeychainUI:)`），请求路径两站相同（`/billing/meter/get-user-resource`），仅 origin / Referer / host 相关字段不同；`CodeBuddyClient.Endpoints.region` 产出 `international` / `domestic`。
- 错误态：HTTP 401 / 403 → `sessionExpired(host:detail:)`，文案指向该站点；Cookie 未找到 / Chrome 未安装同样带目标 host。
- 后续可选项（未实现，无当前需求）：面板内区域切换控件（两站已拆 tab，暂不需要）、两站显式 Chrome profile 选择 UI（当前沿用「单候选自动使用、多候选取第一个」）。
