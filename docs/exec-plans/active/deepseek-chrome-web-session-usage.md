# DeepSeek Chrome Web 会话用量接入

- 状态：进行中
- 创建日期：2026-09-20
- 最后更新：2026-09-20

## 目标

从本机已登录 Chrome 的 DeepSeek 平台 localStorage 导入 `userToken`，调用 DeepSeek 平台 Web 接口获取账户钱包余额与用量统计，在 LocalQuotaBar 中展示余额、今日 / 本月或近 30 天用量、模型成本与每日图表；token 只在内存中使用，不写入日志或本地持久化存储。

## 范围

- 包含：Chrome profile 发现、`platform.deepseek.com` origin 的 `userToken` 读取与解析、多 profile 候选校验、平台钱包余额接口、用量 amount / cost 接口、响应解析与面板集成。
- 包含：接入 SweetCookieKit 的 Chromium localStorage 读取能力，并补充 token 解析、请求、响应解析与刷新行为测试。
- 不包含：Safari / Firefox / Edge 导入、DeepSeek API Key 配置入口、手动 Cookie / token 输入、用量明细钻取页与账单下载。
- 不包含：把平台 token 落盘缓存；如后续确需缓存，必须另立加密与过期策略。

## 背景

- 相关文档：面板展示层以 [额度弹窗横向 Tab 化重构](quota-popup-tabs-redesign.md)（tabs.html 定稿）为准，本计划的「UI 方案」章节仅作数据口径参考。
- 相关代码路径：
  - `Package.swift`：新增 SweetCookieKit 依赖。
  - 新增 `Sources/LocalQuotaBar/deepseek/`：token 导入、请求、解析与快照模型。
  - `Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`、`Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`：provider 编排、面板与图表。
  - `Tests/LocalQuotaBarTests/`：token 提取、请求窗口、响应解析与状态测试。
- 参考实现：CodexBar 的 `DeepSeekPlatformTokenImporter`、`BrowserLocalStorageAPI`、`DeepSeekUsageFetcher` 与 `DeepSeekUsageCostParser`。该实现已在 macOS 上验证 Chrome localStorage 读取路径。
- Web 会话机制：
  - localStorage origin：`https://platform.deepseek.com`。
  - key：`userToken`。
  - value 兼容三种形态：纯 token、JSON string、JSON object；object 依次尝试 `value`、`token`、`access_token`、`accessToken`、`userToken`。
  - 候选 token 至少 20 个字符且不含空白字符。
- 接口口径：
  - 通用平台请求头：`Authorization: Bearer <platformToken>`、`Accept: application/json`、`x-client-platform: web`。
  - 概览与钱包余额：`GET /api/v0/users/get_user_summary`。
  - 用量 token：`GET /api/v0/usage/by_api_key/amount?start=<秒>&end=<秒>&tz=<秒偏移>`，默认近 30 天、本地时区。
  - 用量成本：`GET /api/v0/usage/by_api_key/cost`，query 与 amount 相同。
  - 余额响应 envelope：`code == 0`、`data.biz_code == 0`、`data.biz_data`。
  - 概览字段：`normal_wallets[]` 为充值余额，`bonus_wallets[]` 为赠送余额；两者均含 `balance`、`currency`、`token_estimation`。`total_costs[]` 提供累计消费金额，`total_usage`、`monthly_usage`、`current_token`、`total_available_token_estimation` 提供平台汇总口径。按货币求和，优先展示有余额的 USD，其次任意有余额货币。
  - 用量响应 envelope：`code == 0`、`data.biz_code == 0`、`data.biz_data`。
  - amount 字段：`by_api_key` 版本为 `biz_data.series[]`，每条序列含 `api_key`（`name` / `tracking_id`）、`model`、按时间戳的 `buckets[]`；桶内 `usage` 以 `PROMPT_CACHE_HIT_TOKEN`、`PROMPT_CACHE_MISS_TOKEN`、`RESPONSE_TOKEN`、`REQUEST` 区分 token 与请求数。
  - cost 字段：`biz_data.data[]` 按货币分组，每组含 `currency` 与同结构 `series[]` / `buckets[]`，金额可为小数。
- 已知约束：平台 Web 接口为逆向口径；DeepSeek 官方 API Key 只能查 `/user/balance`，不能查平台账单级历史用量，因此本计划采用 Chrome Web 会话而不是 API Key。

## UI 方案

目标是把平台页的「余额 → 汇总指标 → 趋势 → 构成」压缩成菜单栏面板可扫描的三层，不复制完整网页仪表盘。

1. 顶部状态行：`DeepSeek` + Chrome profile 标签 + 刷新状态；数据延迟约 5 分钟与时区说明放 tooltip，不占首屏。
2. 额度格：
   - `可用余额`：显示选定币种的充值 + 赠送余额，tooltip 拆分 `充值余额` / `赠送余额` / `token_estimation`。
   - `累计消费`：来自 `total_costs[]`。
   - `近 30 天消费`：来自 amount / cost 汇总；余额不支持百分比，胶囊显示绝对金额，不伪造剩余百分比。
3. 汇总行：`今日` 与 `近 30 天` 并列，每项展示 `消费 · Tokens · 请求次数`；多币种时显示主币种并在 tooltip 拆分。
4. 趋势图：复用 `DailyUsageChartView` 的近 30 天 token 柱状图；hover 展示日期、Tokens、消费与请求次数，图头显示日均值。
5. 构成区：首版只列 Top model 与 API Key 数量；模型 / API Key 完整钻取与切换推迟，避免面板变成网页仪表盘复刻。
6. 空态与失效态：未找到 `userToken`、多 profile 待选择、会话过期、用量接口部分失败分别显示明确状态；失败保留旧快照与更新时间。

## 风险

- 风险：Chrome localStorage LevelDB 被浏览器锁定或 key 结构变化。
  - 缓解方式：通过 SweetCookieKit 做只读快照式读取；读取失败降级为 Web 会话不可用，不修改浏览器数据。
- 风险：多个 Chrome profile 都有 `userToken`，自动选择错误账号。
  - 缓解方式：先校验候选 token；多有效候选时要求用户显式选择 profile，单候选才自动使用，并把 profile 标识持久化到应用设置而非 token。
- 风险：平台 token 失效返回 401 / 403 或业务码 40002 / 40003。
  - 缓解方式：标记该候选无效并继续尝试其他 profile；全部无效时展示 Web 会话过期，保留最后有效快照。
- 风险：amount 与 cost 两个接口部分失败，导致 token / 金额口径不完整。
  - 缓解方式：两者都成功才展示完整用量；余额成功而用量失败时展示余额与“用量暂不可用”，不用半份数据伪造汇总。
- 风险：时区与日期窗口错位，近 30 天和自然月口径混淆。
  - 缓解方式：在领域模型中显式保存 `period`；请求窗口使用本地自然日近 30 天，UI 文案与周期一致，单测覆盖跨月与夏令时边界。
- 回滚方式：移除 DeepSeek provider 入口与依赖即可，不影响现有 Codex / Z.AI 链路；新增文件可按提交整体还原。

## 里程碑

1. 基础设施：引入 SweetCookieKit，枚举 Chrome profile，读取 DeepSeek localStorage 并提取 `userToken`。
2. 数据链路：实现平台余额、amount / cost 用量请求与响应解析，完成多 profile 候选校验。
3. 应用集成：新增 DeepSeek 快照模型、余额与用量卡片、每日图表、profile 选择和失败保留缓存行为。
4. 验证与收尾：单测、构建、真实 Chrome 登录态验证、UI 数值核对、文档归档。

## 验证方式

- 命令：`swift build`、`swift test`。
- 单测：
  - `userToken` 纯文本、JSON string、object、带引号、空白、过短、多候选解析。
  - 余额钱包多币种、空钱包、字符串 / 数字金额、`code` / `biz_code` 错误、认证错误。
  - amount / cost 正常、空数组、字段缺失、非法数字、请求窗口、token / request 聚合、日期补齐。
  - 多有效 profile 要求选择；单 profile 自动选择；所有候选失效保留旧快照。
- 手工检查：
  - 使用已登录 Chrome profile 导入 token，真实请求成功。
  - 余额与 `https://platform.deepseek.com` 页面钱包一致。
  - 今日 token、周期 token、请求次数、模型成本与平台用量页一致。
  - 退出 DeepSeek Web 登录后，应用显示会话过期并保留旧快照。
- 观测检查：用量图表坐标与日期不因时区偏移；刷新失败不清空卡片；token 与 Cookie 不出现在日志、错误详情或调试输出。
- 实际结果与未覆盖场景：尚未执行；本计划当前只完成调研与方案收敛。

## 进度记录

- [x] 确认范围和约束。
- [ ] 完成基础设施与依赖接入。
- [ ] 完成平台余额与用量数据链路。
- [ ] 完成应用集成、真实登录态验证与 UI 核对。
- [ ] 将明确推迟的事项登记到技术债表，完成归档。

## 决策记录

- 2026-09-20：采用 Chrome localStorage `userToken`，而不是官方 API Key。理由：用户目标是复用已登录浏览器查平台账单级用量；官方 API Key 只能查余额，不能查平台历史用量。影响：依赖 Web 接口稳定性，但避免让用户配置 API Key。
- 2026-09-20：余额走 `users/get_user_summary`，用量走 `usage/by_api_key/amount` 与 `usage/by_api_key/cost`。理由：这组接口已由 CodexBar 实现验证，能同时得到钱包、token、请求和成本口径。影响：需要处理三层 envelope 与两接口一致性。
- 2026-09-20：token 明文只在当次请求内存中使用，不持久化、不打日志。理由：平台 token 等同 DeepSeek Web 账号凭证。影响：应用重启后重新从 Chrome 导入，多 profile 选择只保存 profile 标识。
