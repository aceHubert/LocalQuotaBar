## [2026-09-15 12:22 +0800] | 任务：落地额度弹窗与设置页 UI/UX 升级

### 执行上下文

- **Agent ID**：zcode（GLM-5.3）
- **Base Model**：builtin:zai-coding-plan/GLM-5.3
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 基于 sess_c39e43fd / sess_6ecce903 两个会话定稿的原型（open-design `quota-popup-redesign-9319`），结合当前代码实际，不动业务逻辑，只做 UI/UX 升级；设置页采用 lite 版；日用量数据源按调研结论（Codex 官方 `account/usage/read` + Z.AI 本地 SQLite）实施。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（新增 7 个文件，main.swift 大幅瘦身）、`docs/`（执行计划、技术债）。

**主要操作**：

- **操作一**：新增设计 token 与共享组件——`PanelTheme.swift`（322px 宽、深色 token、阈值配色、倒计时/相对时间/卡到期格式化）、`QuotaPanelViews.swift`（图标按钮、provider 头部、胶囊条、额度格、重置卡 chip+展开列表、错误横幅、图例页脚）。
- **操作二**：`ProviderPanelSections.swift` 承载 Codex（3 列：5h/周/余额，含"无限制"空态）与 Z.AI（coding-plan 2 列、startPlan 余额/待生效、API Key 隐藏网格）区块；apply 语义与旧版一致。
- **操作三**：`DailyUsageChartView.swift` 30 天柱状图（均值线、周刻度、今日高亮、hover tooltip）；数据源 `CodexUsage.swift`（独立 app-server 客户端调官方 `account/usage/read`，30 分钟节流，UserDefaults 缓存）与 `ZCodeUsageDB.swift`（zcode SQLite `model_usage` 只读按天聚合，WAL 并行读安全）。
- **操作四**：`SettingsPageView.swift` 设置页 lite 版（自动刷新/主动提醒/三项阈值下拉/恢复提醒/重置默认），齿轮进入、返回退回，popover 重开自动回额度页；写入与右键菜单共用同一配置链（`onReminderConfigurationChange` / 新增 `onRefreshIntervalChange`）。
- **操作五**：重写 `QuotaViewController`（main.swift）为两页容器 + 顶部栏 + 区块 + 页脚结构；删除旧 `QuotaRowView`、NSAlert 重置卡列表、只读设置区、statusLabel 文案分支；AppDelegate 接入两个用量 Store。`RateLimitStore`/`ZAIQuotaStore`/`ReminderCenter`/账号切换/Touch Bar 条带等业务逻辑零改动。

### 设计动机

- 弹窗从 460px 列表式改为 322px 固定深色 provider 网格（对齐原型）；阈值配色（≤20% 橙 / ≤10% 红 / 距重置 ≤30 分黄）与提醒阈值一致，替代旧电池条 20红/50黄 色阶（Touch Bar 保持旧色阶不动）。
- 30 天图口径为每日 token 用量：Codex 官方 API 即账号级 tokens（179 天可回填），Z.AI 官方无历史端点、用 ZCode 官方统计页同款本地 SQLite（本机口径）。
- 用量读取全部为新增只读路径（独立进程调用 + SQLite readonly），失败静默降级，不影响主额度与提醒链路。

### 验证结果

- 命令与结果：`swift build` 通过（无 error / 无 warning）；调试实例运行约 6 分钟无崩溃。
- 手工验证及设备：本机 macOS 25.6.0 arm64。实测确认：① 状态栏标题随额度刷新（"Codex M96%"）；② `account/usage/read` 端到端成功，179 天 buckets 写入 UserDefaults 缓存并可解码；③ popover 以 348×526（=322 内容宽 + 弹窗边框）正确打开（CGWindowList 佐证）。
- 未覆盖场景：无屏幕录制/辅助工具权限，弹窗内交互（齿轮切页、重置卡展开、下拉选择、图例 hover、错误横幅重试）与灵动岛/Touch Bar 通道未能本会话实测，需 `make app` 安装后人工过一遍；Z.AI 用量图数据聚合逻辑已在调研阶段单独验证（30 天覆盖），但新面板内的渲染未目检。已装入 `/Applications` 的旧版仍在运行，需重启安装新构建后生效。

### 变更统计

- **统计口径**：main.swift 与 docs 为 `git diff`（未提交工作区），新增文件按行数全量计入；不含本记录自身；不含仓库中预先存在的图标/AGENTS.md 等无关改动。
- **变更文件数**：10
- **新增行数**：+2724
- **删除行数**：-845

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 243 | 841 |
| `Sources/LocalQuotaBar/PanelTheme.swift` | 148 | 0 |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 877 | 0 |
| `Sources/LocalQuotaBar/ProviderPanelSections.swift` | 517 | 0 |
| `Sources/LocalQuotaBar/DailyUsageChartView.swift` | 249 | 0 |
| `Sources/LocalQuotaBar/CodexUsage.swift` | 233 | 0 |
| `Sources/LocalQuotaBar/ZCodeUsageDB.swift` | 115 | 0 |
| `Sources/LocalQuotaBar/SettingsPageView.swift` | 339 | 0 |
| `docs/exec-plans/active/quota-popup-ui-redesign.md` | 新建 | 0 |
| `docs/exec-plans/tech-debt-tracker.md` | 3 | 2 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/PanelTheme.swift`（新增）
- `Sources/LocalQuotaBar/QuotaPanelViews.swift`（新增）
- `Sources/LocalQuotaBar/ProviderPanelSections.swift`（新增）
- `Sources/LocalQuotaBar/DailyUsageChartView.swift`（新增）
- `Sources/LocalQuotaBar/CodexUsage.swift`（新增）
- `Sources/LocalQuotaBar/ZCodeUsageDB.swift`（新增）
- `Sources/LocalQuotaBar/SettingsPageView.swift`（新增）
- `docs/exec-plans/active/quota-popup-ui-redesign.md`（新增，本任务执行计划）
- `docs/exec-plans/tech-debt-tracker.md`
