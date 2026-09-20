# [2026-09-19 19:51 +0800] | 任务：Z.AI 套餐视图手动切换

## 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`account:zai-individual-coding-plan/GLM-5.3`
- **Runtime**：ZCode Desktop（macOS 25.6.0 arm64）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 我现在账号就可以查 individual-coding-plan 和 start-plan，需要自己切换了，不能靠 zcode 来切换。（并确认 billing/balance 是「账号有哪些 plan」的唯一动态数据源，plans[].status=active 即有资格。）

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/ZAIQuota.swift`、`Sources/LocalQuotaBar/main.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`、`Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`。

**主要操作**：

- **套餐视图 override**：新增 `ZAIPlanViewOverride`（followFile / codingPlan / startPlan）与 `ZAIPlanViewSettings`（UserDefaults 持久化）；`resolveProviderSelection()` 无参版返回「文件解析 + override」的有效选择，额度查询、面板展示、重置与用量统计全链路生效。
- **右键菜单入口**：状态栏菜单新增「Z.AI 套餐视图」子菜单，仅 OAuth 连接（coding-plan / start-plan）时可切，api-key 或未连接置灰；菜单每次右键现建，勾选态即时。（用户验收后定稿：三选项「Start Plan（免费）/ Coding Plan（个人订阅）/ Coding Plan（团队订阅）」按接口探测动态展示，账号有几个显示几个；可用性 = 直连 billing/balance（网关拦截回退当日日志）active start-plan + subscription/list 非空 + 团队连接 customerInfo 校验，三态缓存按账号邮箱失效、随每次刷新更新，并监听 credentials/setting 文件变化防抖 1 秒立即重查；`load` 可空，旧值回退 nil）切换后 `zaiStore.refreshAfterPlanViewChange()` 立即按新视图重查（查询中排队），`recomputeZAIUsage()` 重算用量口径。
- **细节**：override 仅在两个 OAuth 套餐间生效；teamContext 原样保留（start-plan 查询不使用它），来回切换不丢团队作用域；`refreshAfterReset` 与新方法共用 `queueRefreshAfterCurrent()`。
- **单测**：新增 5 个（偏好读写回环、OAuth 两套餐互切、团队作用域跨视图保留、api-key 不受影响），`swift test` 180 全绿。

### 设计动机

ZCode 3.14.0 起套餐选择是会话级、不落盘，setting.json 只有静态默认值；用户账号同时具备 coding-plan 与 start-plan 资格（当日 billing/balance 日志：Weekend Build active、300M tokens），应用必须自己提供切换。选择右键菜单而非面板内控件：与既有「切换账号 / 刷新频率」模式一致、零 UI 重排风险，面板 plan tag 已能反映当前视图。不做权益探测驱动的自动切换（接口失败 ≠ 无资格，网络抖动会横跳），可用性动态标注与多套餐并存展示留在技术债。

### 官方口径对齐（同日追加）

按 `docs/research/2026-09-19-zcode-plan-availability-gating.md`（host bundle 调研）修正探测谓词：个人订阅 KI 三条件（coding 产品 + VALID + inCurrentPeriod）、团队第 5 层 querySubscribeDetail（EFFECTIVE+VALID）、bigmodel 团队凭证不回退、start-plan 标识容忍 "start start"。`swift test` 186 全绿。

### 改用文件判定法（同日第二次追加）

按用户指示，菜单可选项判定改为 codex-cliproxy 的文件槽位法（setting.json 连接形态），每次右键现读文件；网络探测（subscription/list / querySubscribeDetail / customerInfo / billing/balance）与可用性缓存全部移除，不再占用定时刷新。`swift test` 183 全绿。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 180 个测试 0 失败。
- 手工验证及设备：`make run` 打包重启后由用户在右键菜单实际切换验证（Coding Plan ↔ 体验套餐来回，确认额度区块与用量图切换）。
- 未覆盖场景：切换瞬间的旧快照短暂残留（新查询到达前按新 kind 渲染空格子，属可接受过渡）；多套餐并存展示未实现。

### 变更统计

- **统计口径**：`git diff HEAD -- <本次任务文件>`；数字包含同日早前「判定优先级修正」任务的改动（同文件连续两次任务，未提交叠加），纯本任务增量约 +100/-5。历史记录自身不计。
- **变更文件数**：4
- **新增行数**：+296（含早前任务）
- **删除行数**：-37（含早前任务）

明细：

```text
41	1	Sources/LocalQuotaBar/main.swift
2	1	Sources/LocalQuotaBar/ui/ProviderPanelSections.swift
127	33	Sources/LocalQuotaBar/zcode/ZAIQuota.swift
126	2	Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift
```
