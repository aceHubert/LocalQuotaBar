## [2026-09-30 14:35 +0800] | 任务：DeepSeek 赠送余额与充值余额分卡显示

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：GLM-5.3（deepseek/deepseek-flash）
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64，Apple Swift 6.3.3）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> deepseek 多了个赠送金额，和充值金额是分开的，按官方的同步显示成一样的。

（附平台页截图：`充值余额 ¥4.30` / `累计消费金额 ¥10.69` / `赠送余额 ¥6.00` 三张并列卡。）

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（deepseek / ui / main.swift）、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **操作一**：`DeepSeekSnapshot` 新增 `balance(kind:currency:)` 与 `availableBalance(currency:)`，把「充值 / 赠送按币种分别聚合」的口径收到模型层，面板与 tab 摘要共用同一套逻辑。
- **操作二**：面板指标卡由两格改三格，顺序与标签对齐平台页：`充值余额 | 累计消费金额 | 赠送余额`；充值卡不再用「充值 + 赠送」合计顶替（旧实现把合计值挂在「充值金额」标签下），赠送余额独立成卡。
- **操作三**：`MetricCardView` 去掉币种单位后缀（`CNY`），数值字号 14pt → 13pt：三格等分后单格内容区仅约 70pt，原「¥10.89 CNY」宽 74pt 已溢出卡片。
- **操作四**：非主币种的同类钱包余额逐条进 tooltip（避免主币种口径把其他币种的钱藏起来）；`othersCurrenciesText` / `amountText` 收口重复的金额格式化。
- **操作五**：tab 摘要由「充值 ¥10.11」改为「余额 ¥10.11（充值 ¥4.30 + 赠送 ¥5.81）」——环上的数字是合计可用余额，旧文案把合计误标成充值。
- **操作六**：新增 3 项单测：同类型多钱包按币种求和且赠送不并入充值、多币种互不串、赠送钱包缺失时按 0 显示。
- **操作七**：`make install` 重建发布产物并替换 `/Applications/LocalQuotaBar.app` 中的旧版本，重启应用（用户要求「编译到应用程序中把旧的替换掉」）。

### 设计动机

- 数据链路本已区分 `normal_wallets` / `bonus_wallets`（`DeepSeekSummaryParser` 就解析出两种 `kind`），问题只在展示层把两者加总成一个数，导致「充值余额」标签名不副实且赠送金额不可见。因此本次不动请求与解析，只改展示口径。
- 用户要求「按官方显示成一样的」，故三卡顺序、标签（充值余额 / 累计消费金额 / 赠送余额）逐项对齐平台页；合计可用余额降级到充值卡 tooltip。
- 面板内容宽仅 298pt，三格等分后单格约 94.7pt、内容区约 70pt。实测文本宽度：「¥10.89 CNY」74.1pt（溢出）、「¥10.89」47.7pt（宽松）。故按 Codex 余额格既有做法去掉冗余币种代码（`¥` 已表意，币种代码进 tooltip），并把字号压到 13pt，使「¥1234.56」68.9pt 仍在限内。
- 关键取舍：保留官方页的 `CNY` 后缀则四位数金额必然溢出，故舍去；换来的是三卡在四 / 五位数金额下都不截断。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 262 项、0 失败、2 项 live 探针按默认配置跳过（改动前 259 项，新增 3 项）。
- 真实数据核对：`LOCALQUOTABAR_DEEPSEEK_LIVE=1 swift test --filter DeepSeekLiveProbeTests` 真实登录态通过，本机钱包为 `normal CNY 4.30417724` + `bonus CNY 5.80677952`（累计消费 CNY 10.88904324），与平台页三卡口径一致；面板三格实测渲染为 `¥4.30 | ¥10.89 | ¥5.81`，tab 环为合计 `¥10.11`。
- 手工验证及设备：本机 macOS 25.6.0 arm64。用临时渲染探针（`LOCALQUOTABAR_RENDER_PROBE` 门控，跑完即删）把面板放进真实窗口渲染成 PNG 并逐项目检：三卡标题 / 数值正确、无截断无省略号、等宽且左对齐、柱状图正常；长金额场景（¥1234.50 / ¥12345.67 / ¥9999.99）亦无溢出卡片。首版离屏 `cacheDisplay` 全黑（layer-backed 内容未绘制），改为真实窗口 + backing store 后取到有效画面（非黑像素占比 0.41），该踩坑记录在下方未覆盖场景。
- 启动冒烟：debug 二进制前台运行 8 秒存活、无标准错误输出、5 分钟内无崩溃报告。
- 发布安装：`make install` 通过（release 构建 + 图标重建 + `ditto` 覆盖 `/Applications/LocalQuotaBar.app`）。安装前先退出正在运行的旧版；安装后 `.build/release/LocalQuotaBar` 与 `/Applications/LocalQuotaBar.app/Contents/MacOS/LocalQuotaBar` 的 SHA-256 完全一致（`dc16a9d8…`），产物时间晚于本次源码改动，确认替换生效；重启后进程存活、无新崩溃报告。`Resources/` 下跟踪的图标文件重建后无差异（`git status` 干净），未产生额外改动。
- 未覆盖场景：① 面板实机目检仍需用户在真实菜单栏弹窗复核（本次为离屏渲染核对，非 popover 实机）；② 赠送钱包只在 `bonus_wallets` 非空时才有数据，本机已实测存在，但「赠送钱包缺失」的界面表现仅由单测覆盖；③ 多币种（主币种 USD + CNY 赠送）路径仅单测覆盖，本机无该登录态。

### 变更统计

> 统计口径：未提交状态，基线 `HEAD`（aa276a1），仅统计本次任务改动的 4 个文件；`git diff HEAD -- <文件>`。已排除任务前既有的未跟踪项（`.zcodeignore`、`canvas/`）与历史记录自身。

- **变更文件数**：4
- **新增行数**：+123
- **删除行数**：-36

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift` | 59 | 35 |
| `Tests/LocalQuotaBarTests/DeepSeekParsingTests.swift` | 45 | 0 |
| `Sources/LocalQuotaBar/deepseek/DeepSeekModels.swift` | 12 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 7 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift`
- `Sources/LocalQuotaBar/deepseek/DeepSeekModels.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Tests/LocalQuotaBarTests/DeepSeekParsingTests.swift`
