## [2026-09-22 11:29 +0800] | 任务：弹窗横向 Tab 化重构（含 DeepSeek / CodeBuddy 国际版接入）

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3（account:zai-individual-coding-plan）
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64，Apple Swift 6.3.3）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：quota-popup-tabs-redesign（worktree ../LocalQuotaBar-tabs，上游 origin 同名分支）

### 用户诉求

> 继续会话 sess_eda651bb 对 UI/UX 重构写待执行文档，注意：1、顶部的刷新只刷新当前 active tab；2、codex 和 z.ai 完全保持原样的看板；3、deepseek 和 codebuddy 是新加的还没有实现，需要实现并完成验证流程；4、codebuddy 分国际版和国内版本，先做国际版本，留一下计划给国内版的看板实现。
> （第二轮）使用 worktree 新建一个分支并绑定同名上游后开始实施并验收。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（ui / deepseek / codebuddy / main.swift）、`Tests/LocalQuotaBarTests/`、`Package.swift`、`docs/exec-plans/`。

**主要操作**：

- **操作一**：新增 `PanelTabBarView`（logo 进度环 tab + 套餐 tag + 状态点 + tooltip），弹窗从纵向双区块改为 Tab 栏 + 单面板容器；顶栏刷新从「全部刷新」改为仅刷新当前 active tab（60 秒冷却 per-provider 不变，后台自动刷新仍全量）。
- **操作二**：`ProviderHeaderView` 精简为 slim 模式（错误文案入头部、tooltip 全文），删除 `ErrorBannerView` 与底部横幅；Codex / Z.AI 看板内容区与 apply 链路零改动。
- **操作三**：新增 DeepSeek 全链路：Chrome localStorage `userToken` 导入（SweetCookieKit LevelDB）→ `get_user_summary` + `by_api_key/amount/cost` → 面板（充值 / 累计消费两指标卡 + 近 30 天消费柱状图）；tab 空环 + 余额金额（不伪造百分比）。
- **操作四**：新增 CodeBuddy 国际版（www.codebuddy.ai）全链路：Chrome Cookie 导入（Keychain 解密，后台禁 UI 读取）→ 资源摘要 + 付费 / 奖励资源包接口 → Credits 面板（套餐基础积分细进度条 + chips 展开列表，复用 ResetCardsRow 并新增 detailText）；国内版（.cn）按计划推迟并已登记技术债。
- **操作五**：测试体系：新增 PanelTabBarView / DeepSeekParsing / CodeBuddyParsing 测试与两个 env 门控 live 探针；重写 ManualRefresh（active-tab 语义）/ ProviderHeaderView（slim）测试；更新 ZAIUsagePresentation / PanelRendering。

### 设计动机

tabs.html（quota-popup-redesign-9319）为用户在来源会话逐项确认的定稿。关键取舍：① provider 身份信息上移 Tab 栏、顶栏刷新聚焦当前查看对象，代价是错误重试统一走顶栏冷却；② Codex / Z.AI 内容区零改动以保护已验收链路，阶段 1 设红线对照关卡；③ 凭证读取统一交给 SweetCookieKit（CodexBar 同源、双能力覆盖），不自研 LevelDB / Keychain 解密；④ DeepSeek 余额型无「剩余/总量」口径，环降级为空环 + 金额，不伪造百分比；⑤ CodeBuddy 国内外为不同登录态，双站并存形态待国际版验证后另立计划。

### 验证结果

- 命令与结果：`swift build` / `swift build -c release` 通过；`arch -arm64 swift test` 237 项通过、0 失败（2 项 live 探针默认 skip）。DeepSeek live 探针（`LOCALQUOTABAR_DEEPSEEK_LIVE=1`）真实登录态端到端通过：充值 ¥4.3042 / 累计消费 ¥10.6958 / 近 30 天消费 ¥6.0988；实测修正口径（bucket 时间字段 `time`、金额字段 `cost`、窗口须对齐自然日）。
- 手工验证及设备：本机 macOS 25.6.0 arm64；debug 构建启动冒烟（8 秒存活、四 store 启动、无崩溃报告）；Keychain 授权在探针中实机通过一次（Cookie 解密成功）。Codex / Z.AI 红线以既有测试套件 + 代码路径审查覆盖。
- 未覆盖场景：① CodeBuddy 真实接口验证受阻——全量 Cookie + 浏览器同款请求头仍被 APISIX 网关 401（前端逆向确认 Web 平台无 Bearer），待用户在 Chrome 复核 www.codebuddy.ai 登录态后重跑探针（`LOCALQUOTABAR_CODEBUDDY_LIVE=1 swift test --filter CodeBuddyLiveProbeTests`）；② 四 tab UI 目检（popover 高度、展开列表、设置页往返、DeepSeek 会话过期态、Touch Bar / 刘海屏通道）留待用户复核。

### 变更统计

> 统计口径：基线 main（8a76809）→ quota-popup-tabs-redesign HEAD（b4a4d4c），排除历史记录自身。

- **变更文件数**：30
- **新增行数**：+3604
- **删除行数**：-569

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift` | 420 | 0 |
| `Sources/LocalQuotaBar/ui/PanelTabBarView.swift` | 406 | 0 |
| `Sources/LocalQuotaBar/main.swift` | 364 | 47 |
| `Sources/LocalQuotaBar/deepseek/DeepSeekModels.swift` | 285 | 0 |
| `Tests/LocalQuotaBarTests/DeepSeekParsingTests.swift` | 244 | 0 |
| `Sources/LocalQuotaBar/ui/CodeBuddyPanelSection.swift` | 211 | 0 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyModels.swift` | 194 | 0 |
| `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift` | ~60 | ~250 |
| 其余（依赖、计划文档、探针、头部/区块改造等 22 个文件） | ~1450 | ~270 |

### 修改文件

- `Package.swift`、`Package.resolved`（SweetCookieKit 0.5.3）
- `Sources/LocalQuotaBar/main.swift`、`ui/PanelTabBarView.swift`（新）、`ui/DeepSeekPanelSection.swift`（新）、`ui/CodeBuddyPanelSection.swift`（新）、`ui/QuotaPanelViews.swift`、`ui/ProviderPanelSections.swift`
- `Sources/LocalQuotaBar/deepseek/`（4 个新文件）、`Sources/LocalQuotaBar/codebuddy/`（4 个新文件）
- `Tests/LocalQuotaBarTests/`（新增 4 个、重写 2 个、更新 2 个）
- `docs/exec-plans/active/quota-popup-tabs-redesign.md`（新）、`docs/exec-plans/tech-debt-tracker.md`、`docs/exec-plans/active/deepseek-chrome-web-session-usage.md`、`docs/exec-plans/active/codebuddy-chrome-cookie-quota.md`
