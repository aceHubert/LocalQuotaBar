# 20261002-2217-deepseek-bonus-validity-detail

## [2026-10-02 22:17 +0800] | 任务：赠送余额补有效期明细（ⓘ 展开卡）

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3-Flash`
- **Runtime**：`macOS 25.6.0 arm64 / Swift 5.9+ swift build`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> deepseek 的赠送金额有有效期的，这个没有补充上去。和官方一下，加一个图标，然后点击在下面像重置卡一样展开显示出来，已经过期的过滤掉，同时把设计稿也需要更新一下。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/deepseek/`、`Sources/LocalQuotaBar/ui/`、`Tests/LocalQuotaBarTests/`、`canvas/pages/`。

**主要操作**：

- **操作一**：逆向平台前端定位数据源——`get_user_summary` 的 `bonus_wallets` 无有效期字段（探针实测仅 `balance`/`currency`/`token_estimation`）；官方「查看有效期」入口跳转账单页，数据来自 `GET /auth-api/v0/users/get_all_invoice` 的 `data.biz_data.invoices.bonus_orders[]`（字段 `amount`、`currency`、`bonus_order_status`（ACTIVE/EXPIRED/EXHAUSTED）、`inserted_at`、`expires_at`，ISO8601 带毫秒与时区偏移）。
- **操作二**：`DeepSeekModels.swift` 新增 `DeepSeekBonusGrant`（Status 枚举未知值按已失效处理）与 `DeepSeekInvoiceParser`（无 biz_code 层信封、容错解析、毫秒/无毫秒双 formatter）；快照新增 `bonusGrants`（默认 `[]`，旧构造点不破坏）与 `activeBonusGrants`（过滤 EXPIRED/EXHAUSTED，按到期时间升序）。
- **操作三**：`DeepSeekClient.swift` 新增 invoices 端点并在 `fetchSnapshot` 中 best-effort 拉取——账单失败只降级为空明细，不阻断余额/用量快照。
- **操作四**：`DeepSeekPanelSection.swift`——`MetricCardView` 标题行支持 ⓘ 按钮（`onInfoTap`，默认隐藏）；赠送余额卡有生效明细时显示 ⓘ（tooltip「查看有效期」），点击在指标卡与消费图之间展开 `BonusGrantDetailView`（视觉对齐重置卡明细：#N + 发放金额 + 发放日期 + 到期徽章 + 行 tooltip，7 天内转红），再点收起；展开/收起与刷新后明细清空均上报 `onContentHeightChange` 刷新 popover 高度。
- **操作五**：新增 `DeepSeekRawBonusProbeTests`（live 探针，dump 原始 bonus_orders 与快照 activeBonusGrants）；`DeepSeekParsingTests` 补 4 例（解析/容错/未知状态/过滤排序）。
- **操作六**：设计稿更新——① 仓库 canvas 新增 DeepSeek 页（`canvas/pages/deepseek/`：收起/展开两态草图 + 交互口径注释），manifest 注册 `page:deepseek`；② OpenDesign 项目 `quota-popup-redesign-9319` 的定稿 `tabs.html` DeepSeek tab 从旧两卡（充值金额|累计消费金额）更新为与 App 一致的三卡口径，赠送余额卡加 ⓘ（复用通用 `data-target` 展开/收起），新增 `#ds-bonus-cards` 明细列表（系统赠送 + 发放日期 + 到期徽章），tab tooltip 同步为「充值 ¥5.13 · 赠送 ¥1.08（ⓘ 有效期）…」，三卡去掉 CNY 单位后缀对齐 App「币种代码放 tooltip」口径。
- **操作七**：`make install` 打包安装到 /Applications 并重启应用（新进程验证菜单栏数据）。

### 事故与恢复（tabs.html 误覆盖）

- 第一次向 OpenDesign 写回时误以「凭记忆手写的精简版」（25KB）整体覆盖了 82KB 定稿（本地与项目侧同时被覆盖，`.file-versions` 此前无该文件版本）。
- 恢复路径：定位到当时编写该文件的历史会话产物（`~/.zcode/cli/artifacts/sess_eda651bb…/call_622241a7…json`，时间戳与文件 mtime Sep 22 17:45 一致），提取完整 HTML（1199 行，与覆盖前当天 MCP 读取的四个窗口逐行比对一致，三个「编辑前锚点串」各恰好出现一次）后还原。
- 修复后：以本地编辑 + daemon 直读磁盘方式重做改动（未再整体写回），并把 `.file-versions` 中被污染的 Version 1 记录（内容、size、sha256 contentDigest）修正为当前正确内容，避免后续从版本历史恢复出坏版本。
- 教训：对 open-design 项目文件做整文件写回前，必须先读原文、以原文为基底做增量修改，严禁凭记忆重建内容。

### 设计动机

- 官方赠送余额的「有效期」不在 `get_user_summary` 里而在账单接口，且账单是补充信息：解析失败返回空、请求失败不失败整次刷新，保证余额/用量主链路稳定。
- 明细行的 `amount` 是发放金额而非剩余金额（本机实测：ACTIVE 发放 ¥6.00，赠送余额 ¥1.08），文案与注释明确区分，避免用户对照余额时产生误解。
- 过滤口径取「只展示 ACTIVE」：EXPIRED 已过期、EXHAUSTED 已耗尽，两者都不再构成可用赠送余额；未知状态宁可不展示。
- 交互复用重置卡的「chip + 展开明细」语言但收进卡片标题 ⓘ，不新增一行 chip，保持三卡布局与平台页一致。

### 验证结果

- 命令与结果：`swift build` 通过；`swift build -c release` 通过；`swift test` 272 tests, 3 skipped（live 探针），0 failures；`LOCALQUOTABAR_DEEPSEEK_LIVE=1 swift test --filter DeepSeekRawBonusProbeTests` 真实登录态通过——本机 ACTIVE 赠送 CNY 6.00（2026-09-30 发放、2026-10-07 到期），赠送余额 ¥1.08，端到端 `activeBonusGrants` 产出一致。
- 手工验证及设备：离屏渲染目检（临时探针，已删除）——收起态三卡 + ⓘ、展开态明细两行（「6天后到期」红 / 「26天后到期」灰），过期 ¥9.00 与耗尽 ¥4.00 条目正确过滤；未在菜单栏 popover 实机复核。
- 未覆盖场景：① 无赠送钱包 / 全部过期时 ⓘ 不显示的路径仅由代码保证（configure 分支），未单测渲染；② 多币种赠送明细行（USD 发放 + CNY 余额）仅解析层单测覆盖；③ `get_all_invoice` 失败降级路径未单测（`try?` 于客户端内）。

### 变更统计

- **统计口径**：`git diff`（工作区，相对 main HEAD 3a1f87b），含新增未跟踪源码/测试文件，排除 `canvas/` 设计稿与历史记录自身。
- **变更文件数**：5
- **新增行数**：+379
- **删除行数**：-5

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/deepseek/DeepSeekClient.swift` | +8 | -1 |
| `Sources/LocalQuotaBar/deepseek/DeepSeekModels.swift` | +75 | 0 |
| `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift` | +161 | -4 |
| `Tests/LocalQuotaBarTests/DeepSeekParsingTests.swift` | +90 | 0 |
| `Tests/LocalQuotaBarTests/DeepSeekRawBonusProbeTests.swift`（新增） | +45 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/deepseek/DeepSeekClient.swift`
- `Sources/LocalQuotaBar/deepseek/DeepSeekModels.swift`
- `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift`
- `Tests/LocalQuotaBarTests/DeepSeekParsingTests.swift`
- `Tests/LocalQuotaBarTests/DeepSeekRawBonusProbeTests.swift`（新增）
- `canvas/pages/deepseek/assets/deepseek-bonus-expiry-sketch.html`（新增，设计稿）
- `canvas/pages/deepseek/cowart-canvas.json`（新增，设计稿）
- `canvas/pages/manifest.json`（注册 DeepSeek 页）
- `~/Desktop/projects/open-design/.od/projects/quota-popup-redesign-9319/tabs.html`（OpenDesign 定稿，不在本仓库内）
