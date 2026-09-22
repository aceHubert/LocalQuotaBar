# CodeBuddy Chrome Cookie 额度接入

- 状态：进行中
- 创建日期：2026-09-20
- 最后更新：2026-09-20

## 目标

从本机已登录 Chrome 导入 CodeBuddy 个人中心会话 Cookie，调用个人中心资源摘要与资源包接口，在 LocalQuotaBar 中按官方「套餐与用量」页的结构展示 CodeBuddy Credits 卡片：主套餐用量、购买积分、平台奖励积分，每张卡片包含已用 / 总量、剩余与周期信息；凭证只在内存中短时使用，不写入日志或本地持久化存储。

## 范围

- 包含：Chrome profile 发现、`session` / `session_2` Cookie 读取与候选校验、`www.codebuddy.cn` 与 `www.codebuddy.ai` 双域名支持、资源摘要与资源包接口解析、CodeBuddy provider 面板与手动刷新。
- 包含：官方卡片结构适配——主套餐卡、购买积分分组、平台奖励积分分组；每张用量卡展示已用 / 总量、剩余、使用中状态、进度条、到期或重置时间。
- 包含：可选的近 7 天每日 Credits 聚合趋势；该接口按日返回 `date` / `credit`，不展开请求明细。
- 包含：接入 SweetCookieKit 作为 Chrome Cookie 与解密基础设施，并补充解析与网络请求单测。
- 不包含：Safari / Firefox / Edge 导入、CodeBuddy CLI token 登录、余额购买入口、企业额度管理、独立资源包明细页与官方 API 等待方案。
- 不包含：「升级套餐」「去升级」「购买积分」「查看全部」等站外或购买动作；首版只展示数据，不在应用内触发账号变更操作。
- 不包含：`get-user-request-usage` 请求级消耗明细。30 天请求记录量大且需要分页 / 导出游标，不适合菜单栏常驻刷新；仅在后续单独设计明细页时评估。
- 不包含：把 Cookie 或解密后的会话值落盘缓存；如后续确需缓存，必须另立决策并加密。

## 背景

- 相关文档：面板展示层以 [额度弹窗横向 Tab 化重构](quota-popup-tabs-redesign.md)（tabs.html 定稿）为准；首版只做国际版（Cookie 候选域名固定 `www.codebuddy.ai`），国内版 `.cn` 看板按该计划「推迟项」章节另立计划，本计划的「面板口径」章节仅作数据口径参考。
- 相关代码路径：
  - `Package.swift`：新增 SweetCookieKit 依赖。
  - 新增 `Sources/LocalQuotaBar/codebuddy/`：Cookie 导入、接口请求、响应模型与快照组装。
  - `Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`：provider 编排与面板展示。
  - `Tests/LocalQuotaBarTests/`：解析、请求头、候选 profile 与 UI 口径测试。
- 相关调研：
  - CodeBuddy CLI `/cost` 只统计当前会话 Token，不是账号余额；现有 CLI access token 请求 `/cost` / `/status` 返回 401。
  - 个人中心前端使用 `withCredentials: true`，普通 Web 登录不携带 Bearer token。
  - 本机 Chrome `Default` profile 已存在 `www.codebuddy.cn` 与 `www.codebuddy.ai` 的 `session`、`session_2`，均为 HttpOnly 加密 Cookie；`Profile 1` / `Profile 2` 当前没有 CodeBuddy Cookie。
- 接口口径：
  - 请求：`POST https://www.codebuddy.cn/billing/meter/get-user-resource-summary`，body 为 `{}`；国际站域名替换为 `www.codebuddy.ai`。
  - 请求头：`Content-Type: application/json`、目标域名的 `session` / `session_2` Cookie。
  - 响应 envelope 以个人中心前端为准：HTTP JSON 的 `data` 内包含 `Packages`、`SubscriptionPackageCode`、`IsProtectedPriceUser` 等字段。
  - 资源摘要用于确定当前套餐、周期与汇总口径，字段包括 `Packages[]` 的 `PackageCode`、`CycleTotalCapacity`、`CycleUsedCapacity`；剩余量按 `total - used` 计算，字段缺失时显示数据不完整而非伪造数值。
  - 资源包列表用于官方卡片分组：
    - `POST /billing/meter/get-user-resource-paid-packages`
    - `POST /billing/meter/get-user-resource-free-packages`
    - 请求沿用个人中心参数：`PageNumber`、`PageSize`、`Status`、`PackageCodes`、`NeedRenewInfo`；首版固定小页拉取有效与用完状态，不做全量翻页。
    - 响应 `data.Accounts[]` 使用 `PackageCode`、`ResourceId`、`Status`、`InUsage`、`CycleCapacitySizePrecise`、`CycleCapacityRemainPrecise`、`CycleEndTime`、`DeductionEndTime`、`ExpiredTime`、`AutoRenewFlag` 等字段。
  - 每日趋势（可选）：`POST /billing/meter/get-user-daily-usage`，body 含 `startTime`、`endTime`、`pageNum`、`pageSize`；默认查近 7 天并按页取 31 条以内，响应 `data.data.data[]` 仅需 `date` / `credit`。官方 UI 提示该数据有 2-3 小时延迟。
- 面板口径（对齐官方页面结构）：
  - 主套餐卡：标题显示套餐名（如「体验版」），副标题显示套餐定位；「套餐用量」行显示 `已用/总量 积分（套餐基础积分）`，右侧显示 `剩余`，带「使用中」标签；下方显示进度条与下次权益周期更新时间。
  - 购买积分分组：标题为「购买积分」；有资源包时逐条显示 `已用/总量 积分`、剩余、使用中状态、进度条与到期时间；无资源包时显示可用数量与剩余积分的空态，不显示购买按钮。
  - 平台奖励积分分组：标题为「平台奖励积分」；每条资源包显示 `已用/总量 积分`、到期时间与进度条，不合并不同到期时间的奖励包。
  - 卡片排序：主套餐固定在首位；购买积分与平台奖励积分按到期时间升序，未到期优先；同一到期时间按 `ResourceId` 稳定排序。
  - 数值精度：Credits 保留两位小数，去除多余的末尾零；`0` 与缺失必须区分，缺失显示 `--` 或「数据不完整」。
- 已知约束：这是个人中心逆向接口，没有官方稳定性承诺；接口路径、字段或 Cookie 语义变化时应降级为明确错误并保留最后一次有效快照。

## 风险

- 风险：Chrome Cookie 解密需要访问 `Chrome Safe Storage` Keychain 项，首次读取可能触发系统授权，后台刷新时无法响应弹窗。
  - 缓解方式：手动刷新时完成一次授权；后台周期只做禁止 Keychain UI 的读取，失败时保留缓存并提示需要在面板手动刷新。
- 风险：Chrome Cookie SQLite 被浏览器锁定或 schema 变化。
  - 缓解方式：使用 SweetCookieKit 的只读导入能力；导入失败视为浏览器凭证不可用，不复制或修改 Chrome 数据文件。
- 风险：`.cn` 与 `.ai` 是不同站点登录态，用户可能只在其中一个域名有效。
  - 缓解方式：逐个候选域名校验；401 / 403 标记无效并继续尝试，不做自动登录。
- 风险：`Packages` 汇总口径与官方 UI 分组存在差异，直接求和可能把基础额度、加量包、赠送包混合。
  - 缓解方式：按 `PackageCode` 与资源包端点分组还原官方卡片；主套餐只取当前套餐基础积分，购买积分与平台奖励积分分别列卡，不做跨组求和。
- 风险：资源包端点分页参数或套餐代码枚举变化导致分组不完整。
  - 缓解方式：单测固定已知 `PackageCode` 分类；未知代码保留原名称并归入「其他积分」分组，不丢弃数据。
- 风险：逆向接口变更或风控。
  - 缓解方式：请求失败时保留上一次快照并展示错误时间；同时把接口版本、状态码、脱敏错误写入应用内状态，不记录 Cookie。
- 风险：误用 `get-user-request-usage` 拉取 30 天请求级明细，导致响应数据量、刷新耗时和内存占用不可控。
  - 缓解方式：常驻刷新只允许资源摘要与按日聚合接口；请求级明细列为非目标，不在定时任务中调用。
- 回滚方式：移除 CodeBuddy provider 入口与依赖即可，不影响 Codex / Z.AI 现有数据链路；新增文件可按提交整体还原。

## 里程碑

1. 基础设施：引入 SweetCookieKit，实现 Chrome profile 枚举、域名与 Cookie 名过滤、Keychain 禁 UI 导入路径。
2. 数据链路：实现资源摘要与付费 / 奖励资源包请求、双域名候选校验、响应 envelope 与 `Packages` / `Accounts` 解析、套餐代码分类与错误分类；可选接入近 7 天每日聚合。
3. 应用集成：新增 CodeBuddy 快照模型、定时 / 手动刷新、主套餐卡 / 购买积分 / 平台奖励积分卡片、失败保留缓存行为；趋势图只消费按日聚合数据。
4. 验证与收尾：单测、构建、真实 Chrome 登录态验证、权限提示走查、文档归档。

## 验证方式

- 命令：`swift build`、`swift test`。
- 单测：
  - Cookie 候选只接受 CodeBuddy 域名下的 `session` / `session_2`。
  - 请求只发送到目标域名，Cookie 不进入描述、错误或日志模型。
  - `Packages` 正常、空数组、字段缺失、非数字、401、403、5xx 的解析与错误分类。
  - `Accounts` 的套餐基础积分、购买积分、平台奖励积分、未知 `PackageCode`、过期 / 用完 / 使用中状态、到期时间排序与数值格式化。
  - 每日聚合日期窗口固定为近 7 天，响应行数不超过 31，`credit` 支持数字与字符串。
  - `.cn` 无效时尝试 `.ai`，两个都无效时保留旧快照。
- 手工检查：
  - 使用当前 Chrome `Default` profile 读取 Cookie；首次授权后能完成真实请求。
  - 面板卡片结构对齐官方「套餐与用量」页：主套餐卡显示已用 / 总量 / 剩余 / 周期更新时间；购买积分与平台奖励积分分组逐条显示资源包。
  - 面板数值与 `https://www.codebuddy.cn/profile/plans-usage` 或 `https://www.codebuddy.ai/profile/plans-usage` 页面一致，特别是截图中的 `1.62/500 积分` 与 `498.38 剩余` 口径。
  - 手动退出 CodeBuddy Web 登录后，应用显示会话失效而不是崩溃或清空历史快照。
- 观测检查：刷新期间 UI 不闪空、失败后保留更新时间、定时刷新不重复弹 Keychain 授权。
- 实际结果与未覆盖场景：尚未执行；本计划当前只完成调研与方案收敛。

## 进度记录

- [x] 确认范围和约束。
- [ ] 完成基础设施与依赖接入。
- [ ] 完成接口解析与应用集成。
- [ ] 完成单测、真实登录态验证与权限走查。
- [ ] 将明确推迟的事项登记到技术债表，完成归档。

## 决策记录

- 2026-09-20：采用 Chrome Cookie 导入而不是 CLI access token。理由：个人中心接口依赖 HttpOnly Web 会话，现有 CLI token 已实测 401；Chrome 中已有可用登录态。影响：需要 Keychain 授权与更严格的凭证内存管理。
- 2026-09-20：首阶段同时使用资源摘要与付费 / 奖励资源包列表接口。理由：用户要求面板对齐官方「可用积分和已使用」卡片结构，仅靠 summary 难以稳定区分购买积分与平台奖励积分。影响：请求数增加两个小页查询，但数据量仍固定可控。
- 2026-09-20：官方卡片中的「升级套餐」「去升级」「购买积分」「查看全部」不进入首版。理由：这些是购买 / 站外导航动作，超出额度展示职责。影响：首版保留信息卡片，不提供变更账号或支付入口。
- 2026-09-20：不调用 `get-user-request-usage`。理由：请求级 30 天明细数据量大且价值主要在排查单次请求，不适合额度栏高频刷新。影响：CodeBuddy 不提供账号级 Tokens 用量，趋势只展示按日 Credits 聚合。
- 2026-09-20：Cookie 明文只在当次请求内存中使用，不持久化、不打日志。理由：CodeBuddy 会话 Cookie 等同账号凭证。影响：应用重启后需重新从 Chrome 导入。
