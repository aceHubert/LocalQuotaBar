## [2026-09-22 18:50 +0800] | 任务：CodeBuddy 国内版独立 tab 接入与验收问题修复

### 执行上下文

- **Agent ID**：codex
- **Base Model**：GPT-5.6（未知具体档位）
- **Runtime**：Codex CLI（macOS 25.6.0 arm64，Apple Swift 6.3.3）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：quota-popup-tabs-redesign（worktree ../LocalQuotaBar-tabs，上游 origin 同名分支）

### 用户诉求

> 按国际版的流程再补充一下国内版的实现，新增一个 tab 的形式，确认是不是和国际版一样的流程。
> （验收轮）确认一下验收问题，给出修复方案；这个按现在的逻辑，显示 INTL/CN，更新到文档就好了，其它正常修复。
> （收尾）国内版验证已完成了，可以从技术债中删除。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/codebuddy/`、`Sources/LocalQuotaBar/ui/`、`Sources/LocalQuotaBar/main.swift`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **操作一**：CodeBuddy 国内版（`www.codebuddy.cn`）作为独立 tab 接入，新增 `codeBuddyCNStore` 与 `codeBuddyCN` 面板，复用国际版数据层与 `CodeBuddyPanelSection`；自动刷新扩为五 store。
- **操作二**：修复 401 误报——`CodeBuddyAPIError.sessionExpired` 由死分支改为实际构造，401 / 403 归类为会话失效，移除 `requestRejected`。
- **操作三**：错误文案按目标站点参数化：`sessionExpired(host:detail:)`、`ImportError.chromeNotFound(host:)` / `cookieNotFound(host:)`，修正国内版提示去 `.ai` 登录的问题。
- **操作四**：tab 角标口径确认为区域标识 `INTL` / `CN`（两站同名同 logo，角标是唯一区分手段），套餐名改在面板基础积分行与 tooltip 展示。
- **操作五**：补 CN 专项单测（tab 可见性与角标、active-tab 刷新互不影响、请求契约 host / region、401 分类、错误文案 host）与测试隔离改造（`QuotaViewController.makeForTesting()` 注入独立 defaults suite）。
- **操作六**：同步执行计划、CodeBuddy 数据计划与技术债表；删除国内版「未验证」技术债条目。

### 设计动机

国内版与国际版是不同登录态与账号，采用独立 tab（原推迟项方案 A）而非单 tab 内区域切换：两站的快照、60 秒冷却与错误态天然隔离，不需要在面板内维护切换态。角标选择区域标识而非套餐名，是因为两站 `displayName` 同为 `CodeBuddy`、logo 与品牌渐变也相同，若角标同样显示「体验版」则两个 tab 无法区分；套餐名信息移入面板基础积分行与 tooltip，未丢失。401 分类此前保留 `requestRejected` 是为了避免在旧接口契约下误导用户重新登录，接口迁移完成后该顾虑已不成立。

### 验证结果

- 命令与结果：`swift build` 通过；`arch -arm64 swift test` 执行 253 项（2 项 live 探针默认 skip），3 项失败全部落在 `ResetCardActionTests` / `ResetCardsRowTests` 的布局断言（18.0 vs 19.0 ± 0.5），已在改动前基线 `adc31e1` 上复现，属既有问题。本轮新增用例（`CodeBuddyClientRequestTests` 3 项、`CodeBuddyCookieImporterTests` 2 项、`PanelTabBarViewTests` 2 项、`ManualRefreshTests` 2 项）全部通过。
- 手工验证及设备：本机 macOS 25.6.0 arm64。国内版真实登录态端到端验证由用户确认通过。
- 未覆盖场景：五 tab UI 目检（popover 逐 tab 高度、展开列表、设置页往返）、CodeBuddy Keychain 授权弹窗实机走查、DeepSeek 会话过期态实测、Touch Bar / 刘海屏通道；既有重置卡布局断言失败待单独排查。

### 变更统计

> 统计口径：基线 HEAD（`8570d25`）→ 工作区未提交改动，路径范围 `Sources/`、`Tests/`、`docs/exec-plans/`；排除历史记录自身与 `Tools/`、`canvas/` 等无关改动。已跟踪文件用 `git diff HEAD --numstat`，未跟踪新增文件用 `git diff --no-index --numstat /dev/null <file>`。本统计含同分支上国内版功能实现与本轮修复两部分（尚未提交，无法按提交切分）。

- **变更文件数**：26（含 4 个新增测试文件）
- **新增行数**：+1404
- **删除行数**：-397

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/PanelTabBarView.swift` | 177 | 41 |
| `Tests/LocalQuotaBarTests/CodeBuddyClientRequestTests.swift`（新） | 172 | 0 |
| `Tests/LocalQuotaBarTests/CodeBuddyParsingTests.swift` | 140 | 41 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyModels.swift` | 131 | 53 |
| `Sources/LocalQuotaBar/main.swift` | 99 | 39 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyCookieImporter.swift` | 86 | 22 |
| `Tests/LocalQuotaBarTests/ManualRefreshTests.swift` | 83 | 1 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift` | 81 | 34 |
| `Tests/LocalQuotaBarTests/CodeBuddyCookieImporterTests.swift`（新） | 67 | 0 |
| `Tests/LocalQuotaBarTests/RenderProbeTests.swift`（新） | 60 | 0 |
| `docs/exec-plans/active/quota-popup-tabs-redesign.md` | 51 | 37 |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | 45 | 22 |
| `Sources/LocalQuotaBar/ui/CodeBuddyPanelSection.swift` | 41 | 26 |
| `docs/exec-plans/active/codebuddy-chrome-cookie-quota.md` | 41 | 26 |
| `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift` | 27 | 16 |
| `Sources/LocalQuotaBar/ui/DeepSeekPanelSection.swift` | 25 | 21 |
| `Tests/LocalQuotaBarTests/QuotaViewControllerTestSupport.swift`（新） | 21 | 0 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift` | 14 | 3 |
| 其余（探针、tab 测试、既有测试构造入口、技术债表等 8 个文件） | 43 | 15 |

### 修改文件

- `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift`、`CodeBuddyCookieImporter.swift`、`CodeBuddyModels.swift`、`CodeBuddyStore.swift`
- `Sources/LocalQuotaBar/ui/PanelTabBarView.swift`、`CodeBuddyPanelSection.swift`、`QuotaPanelViews.swift`、`DeepSeekPanelSection.swift`、`DailyUsageChartView.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Tests/LocalQuotaBarTests/`（新增 `CodeBuddyClientRequestTests.swift`、`CodeBuddyCookieImporterTests.swift`、`QuotaViewControllerTestSupport.swift`、`RenderProbeTests.swift`；更新 `ManualRefreshTests.swift`、`PanelTabBarViewTests.swift`、`CodeBuddyParsingTests.swift`、`CodeBuddyLiveProbeTests.swift`、`PanelRenderingTests.swift`、`PanelFooterViewTests.swift`、`SettingsActionButtonTests.swift`、`SettingsPageViewTests.swift`、`ResetCardActionTests.swift`）
- `docs/exec-plans/active/quota-popup-tabs-redesign.md`、`docs/exec-plans/active/codebuddy-chrome-cookie-quota.md`、`docs/exec-plans/tech-debt-tracker.md`
