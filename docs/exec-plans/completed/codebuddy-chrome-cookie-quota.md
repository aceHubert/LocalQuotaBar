# CodeBuddy Chrome Cookie 额度接入

- 状态：已完成
- 创建日期：2026-09-20
- 最后更新：2026-09-24

## 目标

从本机已登录 Chrome 导入 CodeBuddy 个人中心会话 Cookie，调用个人中心统一资源接口，在 LocalQuotaBar 中按官方「套餐与用量」页的结构展示 CodeBuddy Credits 卡片：主套餐用量、购买积分、平台奖励积分，展示口径统一为 `<剩余>/<总量> 积分` 并带周期 / 到期信息；国际版与国内版各占一个独立 tab。凭证只在内存中短时使用，不写入日志或本地持久化存储。

## 范围

- 包含：Chrome profile 发现、`session` / `session_2` Cookie 读取与候选校验、`www.codebuddy.ai`（国际版）与 `www.codebuddy.cn`（国内版）两个站点分别接入、统一资源接口解析、CodeBuddy provider 面板与手动刷新。
- 包含：官方卡片结构适配——主套餐卡、购买积分分组、平台奖励积分分组；每张用量卡统一 <剩余>/<总量> 积分 口径，含使用中状态、进度条与到期或重置时间。
- 包含：可选的近 7 天每日 Credits 聚合趋势；该接口按日返回 `date` / `credit`，不展开请求明细。
- 包含：接入 SweetCookieKit 作为 Chrome Cookie 与解密基础设施，并补充解析与网络请求单测。
- 不包含：Safari / Firefox / Edge 导入、CodeBuddy CLI token 登录、余额购买入口、企业额度管理、独立资源包明细页与官方 API 等待方案。
- 不包含：「升级套餐」「去升级」「购买积分」「查看全部」等站外或购买动作；首版只展示数据，不在应用内触发账号变更操作。
- 不包含：`get-user-request-usage` 请求级消耗明细。30 天请求记录量大且需要分页 / 导出游标，不适合菜单栏常驻刷新；仅在后续单独设计明细页时评估。
- 不包含：把 Cookie 或解密后的会话值落盘缓存；如后续确需缓存，必须另立决策并加密。

## 背景

- 相关文档：面板展示层以 [额度弹窗横向 Tab 化重构](quota-popup-tabs-redesign.md)（tabs.html 定稿）为准。国际版（`www.codebuddy.ai`）与国内版（`www.codebuddy.cn`）均已接入，各占一个独立 tab；本计划的接口、解析与「面板口径」章节两站共用，仅域名与错误文案按站点区分（见该计划「已落地：CodeBuddy 国内版看板」）。
- 相关代码路径：
  - `Package.swift`：新增 SweetCookieKit 依赖。
  - 新增 `Sources/LocalQuotaBar/codebuddy/`：Cookie 导入、接口请求、响应模型与快照组装。
  - `Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`：provider 编排与面板展示。
  - `Tests/LocalQuotaBarTests/`：解析、请求头、候选 profile 与 UI 口径测试。
- 相关调研：
  - CodeBuddy CLI `/cost` 只统计当前会话 Token，不是账号余额；现有 CLI access token 请求 `/cost` / `/status` 返回 401。
  - 个人中心前端使用 `withCredentials: true`，普通 Web 登录不携带 Bearer token。
  - 本机 Chrome `Default` profile 已存在 `www.codebuddy.cn` 与 `www.codebuddy.ai` 的 `session`、`session_2`，均为 HttpOnly 加密 Cookie；`Profile 1` / `Profile 2` 当前没有 CodeBuddy Cookie。
  - 2026-09-22 使用 Chrome CDP 在已登录的国际版「套餐与用量」页重新抓包：页面登录态有效，套餐与额度正常显示；`GET /console/accounts`、`POST /billing/meter/get-user-resource`、`POST /billing/pay/get-sign-info`、`POST /billing/meter/get-user-request-usage` 均返回 HTTP 200。此前把旧资源接口的 APISIX 401 解释为会话过期或浏览器指纹限制，已被本次实测推翻。
- 接口口径：
  - 当前资源请求：`POST https://www.codebuddy.ai/billing/meter/get-user-resource`。2026-09-22 的国际版前端不再调用先前调研得到的 `get-user-resource-summary`、`get-user-resource-paid-packages`、`get-user-resource-free-packages`；旧接口会被 APISIX 返回 401，不能据此判定 Cookie 失效。
  - 当前请求头：`Content-Type: application/json`、`Accept: application/json, text/plain, */*`、`X-Client-Platform: web`、`Referer: https://www.codebuddy.ai/profile/plans-usage`，以及目标域名 Cookie。Web 平台没有 Bearer；Bearer 仅属于前端的小程序分支。
  - 当前请求体包含 `PageNumber`、`PageSize`、`ProductCode: p_tcaca`、`Status: [0, 3]`、`OnlyValidPeriod: true`、`PackageCodes`、`SlicePeriodStartTime`、`SlicePeriodEndTime`。时间窗口按个人中心当前自然日传递；套餐代码列表来自前端当前配置，不能继续发送旧接口使用的空 `{}` 或 `NeedRenewInfo` 请求体。
  - 当前响应 envelope 为 `data.Response.Data`；资源数组位于 `data.Response.Data.Accounts[]`，同时返回 `TotalCount`、`TotalDosage`。`data.Response.ProTrialStatus` 与 `data.Response.RequestId` 属于响应元数据。
  - `Accounts[]` 同时包含主套餐和奖励包，字段包括 `PackageCode`、`PackageName`、`PackageType`、`SubProductCode`、`ResourceId`、`Status`、`CapacityUnit`、`CycleCapacitySizePrecise`、`CycleCapacityRemainPrecise`、`CycleCapacityUsedPrecise`、`CycleStartTime`、`CycleEndTime`、`DeductionEndTime`、`AutoRenewFlag` 等。主套餐实测为 `Free Plan Subscription`，奖励包实测为 `Bonus Pack`；分组应综合套餐代码、名称、子产品代码与容量单位，不再依赖三个旧端点天然分组。
  - 当前页面还调用 `POST /billing/meter/get-user-request-usage` 获取请求级消耗明细；该接口已确认可用，但仍不进入菜单栏常驻刷新范围。
  - `get-user-daily-usage` 未在本次当前页面请求中出现，原“近 7 天每日 Credits 聚合”口径尚未重新验证，继续列为可选且未实施项。
- 面板口径（展示形态以 tabs 计划定稿为准；2026-09-22 用户指令统一为「剩余/总量」口径）：
  - 主套餐行：`<剩余>/<总量> 积分（套餐名）` + 右侧 `MM-dd 更新`（下次权益周期更新时间，次级色）+ 6pt 细进度条（无百分比文字）；不再并列「已用」「剩余」，套餐名取代「套餐基础积分」后缀。
  - 购买积分分组：无资源包时 chip 空态「购买积分 · 无资源包」，不渲染展开按钮；有资源包时 chip 总标题 `购买积分 ×N · <剩余>/<总量>`（到期不进总标题），展开单项 `<剩余>/<总量> 积分 · MM-dd HH:mm`，使用中的包追加「使用中」。
  - 平台奖励积分分组：chip 总标题 `奖励包 ×N · <剩余>/<总量>`，单项口径同上；不合并不同到期时间的奖励包；无奖励包时不渲染该 chip。
  - 卡片排序：主套餐固定在首位；购买积分与平台奖励积分按到期时间升序，未到期优先；同一到期时间按 `ResourceId` 稳定排序。
  - 数值精度：Credits 保留两位小数，去除多余的末尾零；`0` 与缺失必须区分，缺失显示 `--` 或「数据不完整」。
- 已知约束：这是个人中心逆向接口，没有官方稳定性承诺；接口路径、字段或 Cookie 语义变化时应降级为明确错误并保留最后一次有效快照。

## 风险

- 风险：Chrome Cookie 解密需要访问 `Chrome Safe Storage` Keychain 项，首次读取可能触发系统授权，后台刷新时无法响应弹窗。
  - 缓解方式：手动刷新时完成一次授权；后台周期只做禁止 Keychain UI 的读取，失败时保留缓存并提示需要在面板手动刷新。
- 风险：Chrome Cookie SQLite 被浏览器锁定或 schema 变化。
  - 缓解方式：使用 SweetCookieKit 的只读导入能力；导入失败视为浏览器凭证不可用，不复制或修改 Chrome 数据文件。
- 风险：`.cn` 与 `.ai` 是不同站点登录态，用户可能只在其中一个域名有效。
  - 缓解方式：两站为独立 tab / 独立 store，各自校验本站登录态；某站 401 / 403 只影响该站 tab（会话失效文案含目标 host），不做自动登录。
- 风险：统一资源接口的 `Accounts[]` 同时混合主套餐、加量包与赠送包，直接求和会破坏官方卡片口径。
  - 缓解方式：综合 `PackageCode`、`PackageName`、`PackageType`、`SubProductCode` 与 `CapacityUnit` 分组；主套餐只取当前订阅基础积分，购买积分与平台奖励积分分别列卡，不做跨组求和。
- 风险：前端配置中的 `PackageCodes` 枚举变化导致查询或分组不完整。
  - 缓解方式：把套餐代码来源与请求构造集中管理；未知代码保留原名称并归入「其他积分」，单测覆盖前端已知代码与未知代码，不静默丢弃数据。
- 风险：逆向接口变更或风控。
  - 缓解方式：请求失败时保留上一次快照并展示错误时间；同时把接口版本、状态码、脱敏错误写入应用内状态，不记录 Cookie。
- 风险：误用 `get-user-request-usage` 拉取 30 天请求级明细，导致响应数据量、刷新耗时和内存占用不可控。
  - 缓解方式：常驻刷新只允许资源摘要与按日聚合接口；请求级明细列为非目标，不在定时任务中调用。
- 回滚方式：移除 CodeBuddy provider 入口与依赖即可，不影响 Codex / Z.AI 现有数据链路；新增文件可按提交整体还原。

## 里程碑

1. 基础设施：引入 SweetCookieKit，实现 Chrome profile 枚举、域名与 Cookie 名过滤、Keychain 禁 UI 导入路径。
2. 数据链路：实现当前统一资源接口 `get-user-resource`、双域名候选校验、`data.Response.Data.Accounts` 解析、套餐代码分类与错误分类；可选接入重新验证后的每日聚合。
3. 应用集成：新增 CodeBuddy 快照模型、定时 / 手动刷新、主套餐卡 / 购买积分 / 平台奖励积分卡片、失败保留缓存行为；趋势图只消费按日聚合数据。
4. 验证与收尾：单测、构建、真实 Chrome 登录态验证、权限提示走查、文档归档。

## 验证方式

- 命令：`swift build`、`swift test`。
- 单测：
  - Cookie 候选只接受 CodeBuddy 域名下的 `session` / `session_2`。
  - 请求只发送到目标域名，Cookie 不进入描述、错误或日志模型。
  - `data.Response.Data.Accounts` 正常、空数组、字段缺失、非数字、401、403、5xx 的解析与错误分类。
  - `Accounts` 的套餐基础积分、购买积分、平台奖励积分、未知 `PackageCode`、过期 / 用完 / 使用中状态、到期时间排序与数值格式化。
  - 请求路径固定为 `get-user-resource`，请求包含 `X-Client-Platform: web`、正确 Referer、产品代码、状态、有效期过滤与自然日窗口；不得回退到三个旧端点。
  - 每日聚合日期窗口固定为近 7 天，响应行数不超过 31，`credit` 支持数字与字符串。
  - `.ai` 与 `.cn` 为两个独立 tab / 独立 store：任一站点未登录只影响该 tab，另一站点不受影响；站点请求失败时保留该站旧快照。
  - HTTP 401 / 403 归类为对应站点的会话失效（文案含目标 host），非 2xx 其它状态码归类为 `http(status)`。
  - Cookie 导入失败（未装 Chrome / 未找到 Cookie）的错误文案指向本次导入的目标站点。
- 手工检查：
  - 使用当前 Chrome `Default` profile 读取 Cookie；首次授权后能完成真实请求。
  - 面板卡片结构对齐官方「套餐与用量」页的分组：主套餐行显示 <剩余>/<总量> 与周期更新时间；购买积分与平台奖励积分分组逐条显示资源包。
  - 面板数值与 `https://www.codebuddy.cn/profile/plans-usage` 或 `https://www.codebuddy.ai/profile/plans-usage` 页面一致；应用按 <剩余>/<总量> 口径展示，与官方页的已用口径换算核对（如官方 `1.62/500 积分 · 剩余 498.38` ↔ 应用 `498.38/500 积分`）。
  - 手动退出 CodeBuddy Web 登录后，应用显示会话失效而不是崩溃或清空历史快照。
- 观测检查：刷新期间 UI 不闪空、失败后保留更新时间、定时刷新不重复弹 Keychain 授权。
- 实际结果与未覆盖场景（2026-09-22 Chrome CDP 复核）：
  - 已登录的 `https://www.codebuddy.ai/profile/plans-usage` 页面可正常显示国际版套餐与额度，证明服务端会话有效。
  - 当前页面的 `GET /console/accounts` 与 `POST /billing/meter/get-user-resource` 均返回 200；资源接口响应为 `data.Response.Data.Accounts[]`，已核对主套餐、奖励包、容量精确值和周期字段。
  - 分支现有实现仍请求三个旧端点，且正式客户端没有发送 `X-Client-Platform: web`；因此 APISIX 401 的根因已定位为旧接口契约与请求形态过时，不是 Chrome 登录过期，也没有证据支持 TLS / 浏览器指纹限制。
  - Cookie 导入器已改为按目标 host/path 组装完整有效 Cookie jar，并按名称去重；实测发送 8 个可匹配 Cookie 名称后，URLSession 请求成功。
  - URLSession 还需补齐浏览器上下文头：User-Agent、Accept-Language、Sec-Fetch-* 与 sec-ch-*；仅有 Cookie、Referer、`X-Client-Platform` 仍会被 APISIX 返回 401。
  - 新 envelope 解析、请求契约单测和真实 live probe 均已通过，当前实现不再使用 `data.Packages` 或三个旧资源端点。
  - 国内版（2026-09-22 复核轮）：新增 `codeBuddyCN` store / tab（`www.codebuddy.cn`），复用国际版数据层与面板。修正两个验收阻断项：① 401 / 403 此前抛 `requestRejected`（文案「请稍后重试」），现归类为 `sessionExpired` 并提示重新登录目标站点；② Cookie 导入与错误文案此前硬编码 `www.codebuddy.ai`，现按目标 host 参数化，国内版不再误导用户去国际站登录。国内版真实登录态端到端验证已由用户确认通过。
  - live 探针参数化（2026-09-22，Codex 审查项）：`CodeBuddyLiveProbeTests` 支持 `LOCALQUOTABAR_CODEBUDDY_LIVE_HOST` 指定目标站点（默认 `www.codebuddy.ai`）。双站实测通过——国际版 8 个有效 Cookie、体验版 100 总量 / 83.05 剩余、3 个奖励包；国内版 9 个有效 Cookie、`CodeBuddy个人体验版` 500 总量 / 162.92 剩余、9 个奖励包；两站 `otherPackages` 均为空，资源分类在真实数据上零残留。同时证实 `.cn` 网关接受统一 `get-user-resource` 接口（Codex 审查曾据「.cn 前端仍调旧三接口」推断需分叉，实测推翻）。
  - 归档复核（2026-09-24）：用户确认国际版、国内版与权限路径复核完成；当前主工作区 `swift build` 通过，`swift test` 255 项、0 失败（2 项 live 探针按默认配置跳过）。近 7 天 Credits 聚合仍为明确未实施的可选项，不阻塞本计划归档。

## 进度记录

- [x] 确认范围和约束。
- [x] 完成基础设施与依赖接入（SweetCookieKit 0.5.3，提交 `95178d1`）。
- [x] 把现有 CodeBuddy 实现从三个旧端点迁移到 `get-user-resource`，更新请求头、请求体、解析与 fixture。
- [x] 完成当前接口的真实登录态端到端验证；按目标 host/path 组装并去重完整有效 Cookie 集。
- [x] 完成单测（Cookie 候选 / 请求契约 / envelope 解析 / 套餐分组 / 401 分类 / 错误文案 host）与权限走查路径。
- [x] 国际版与国内版均完成真实登录态端到端验证。
- [x] 完成归档（2026-09-24，用户确认任务全部完成）。

## 决策记录

- 2026-09-20：采用 Chrome Cookie 导入而不是 CLI access token。理由：个人中心接口依赖 HttpOnly Web 会话，现有 CLI token 已实测 401；Chrome 中已有可用登录态。影响：需要 Keychain 授权与更严格的凭证内存管理。
- 2026-09-20：首阶段同时使用资源摘要与付费 / 奖励资源包列表接口。理由：用户要求面板对齐官方「可用积分和已使用」卡片结构，仅靠 summary 难以稳定区分购买积分与平台奖励积分。影响：请求数增加两个小页查询，但数据量仍固定可控。
- 2026-09-20：官方卡片中的「升级套餐」「去升级」「购买积分」「查看全部」不进入首版。理由：这些是购买 / 站外导航动作，超出额度展示职责。影响：首版保留信息卡片，不提供变更账号或支付入口。
- 2026-09-20：不调用 `get-user-request-usage`。理由：请求级 30 天明细数据量大且价值主要在排查单次请求，不适合额度栏高频刷新。影响：CodeBuddy 不提供账号级 Tokens 用量，趋势只展示按日 Credits 聚合。
- 2026-09-20：Cookie 明文只在当次请求内存中使用，不持久化、不打日志。理由：CodeBuddy 会话 Cookie 等同账号凭证。影响：应用重启后需重新从 Chrome 导入。
- 2026-09-22：以 Chrome 当前页面 CDP 抓包结果替代 2026-09-20 的旧接口假设。理由：已登录页面实际调用 `get-user-resource` 并返回 200，而旧 `get-user-resource-summary` / paid-packages / free-packages 被 APISIX 返回 401。影响：现有客户端、解析器和测试 fixture 必须迁移；此前“会话过期或浏览器指纹”的判断撤销。
- 2026-09-22：401 / 403 在完成当前接口迁移前不得统一描述为“会话已失效”。理由：本次已证明有效登录态下旧接口仍返回 401。影响：错误分类需要区分会话失效、接口契约过时与网关拒绝，避免误导用户重新登录。
- 2026-09-22：真实 URLSession 请求需要完整目标 Cookie jar 与浏览器上下文头。理由：只发送 `session` / `session_2` 或只补 `X-Client-Platform` 仍返回 401；补齐按 host/path 过滤的 8 个有效 Cookie 名称、User-Agent、Accept-Language、Sec-Fetch-*、sec-ch-* 后 live probe 成功。影响：Cookie 只在内存中按请求目标过滤和去重，绝不记录值；请求头固定为非凭证浏览器上下文值。
- 2026-09-22：国内版（`.cn`）与国际版（`.ai`）作为两个独立 provider 接入（各一个 tab、各一个 store），而不是在同一 tab 内切换。理由：两站是不同登录态与账号，独立 tab 下快照 / 冷却 / 错误态天然隔离。影响：本计划的双域名支持从「同一实例逐候选校验」改为「两个独立实例」。
- 2026-09-22：HTTP 401 / 403 归类为 `sessionExpired`（带目标 host），撤销此前「401 一律不能说会话失效」的保守口径。理由：当前 `get-user-resource` 接口在有效登录态下实测返回 200，旧接口返回 401 的成因是契约过时而非会话问题；接口迁移完成后 401 已可可靠指向会话失效，且用户退出登录时验收要求显示会话失效。影响：`requestRejected` 分支移除。
- 2026-09-22（口径统一，用户指令）：全部 Credits 展示统一 `<剩余>/<总量> 积分`，不再并列「已用」「剩余」（322pt 窄面板放不下且信息重复）；到期时间下放到资源包单项（`MM-dd HH:mm`），不进 chip 总标题；无资源包的购买积分 chip 不渲染展开按钮，无奖励包时不渲染奖励包 chip；tab tooltip 与顶栏摘要不显示 Chrome profile 标识。影响：`CodeBuddyPanelSection` 展示层、`PanelTabStatus.summary` 与相关单测。
- 2026-09-22（探针参数化，Codex 审查项）：live 探针按 `LOCALQUOTABAR_CODEBUDDY_LIVE_HOST` 参数化目标站点（默认国际版）。理由：审查指出国内版缺少自动化真实验证；参数化后同一探针可随时复核任一站点，两站契约本就一致仅 host 不同。影响：多 Chrome Profile fallback 因多候选无法真实验证登记技术债，未实现。
