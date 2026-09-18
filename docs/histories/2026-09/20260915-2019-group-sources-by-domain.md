## [2026-09-15 20:19 +0800] | 任务：按领域分组源码目录

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`builtin:zai-coding-plan/GLM-5.3`
- **Runtime**：ZCode Desktop（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 可以按文件夹把 codex/zcode/notify 把代码分组吗？

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`、`AGENTS.md`

**主要操作**：

- **目录分组**：`Sources/LocalQuotaBar/` 源码按领域移入子目录，仅移动文件、不改代码内容：
  - `codex/`：`CodexUsage.swift`、`CodexResetService.swift`
  - `zcode/`：`ZAIQuota.swift`、`ZAIResetContextResolver.swift`、`ZAIResetService.swift`、`ZCodeUsageDB.swift`
  - `notify/`：`ReminderModels.swift`、`ReminderEvaluator.swift`、`ReminderCenter.swift`、`ReminderChannels.swift`、`DynamicNotchKitAlertChannel.swift`
  - `ui/`：`QuotaPanelViews.swift`、`ProviderPanelSections.swift`、`PanelTheme.swift`、`PanelReminderSwitch.swift`、`DailyUsageChartView.swift`、`SettingsPageView.swift`
- **根目录保留**：`main.swift`（入口）与 `RefreshSettings.swift`（Codex / ZAI 共用的刷新设置）。
- **文档同步**：更新 `AGENTS.md` 项目结构小节，说明子目录划分与职责。
- 已跟踪文件用 `git mv` 移动（保留他人未提交修改，git 记录为 rename）；未跟踪文件用 `mv`。

### 设计动机

根目录 19 个源码文件已难以辨认领域边界。SwiftPM 的 executableTarget 按目录递归编译，子目录不影响构建，因此分组零成本。用户点名 codex / zcode / notify 三组；剩余 6 个面板/设置视图同属 UI 层，顺手归入 `ui/`，`main.swift` 与跨源的 `RefreshSettings.swift` 留在根目录。

### 验证结果

- 命令与结果：`swift build` 构建成功（2.82s）；`swift test` 90 个用例全部通过（0 失败）。
- 手工验证及设备：无需手工验证，纯文件移动、无行为变更。
- 未覆盖场景：无（`Makefile` 与 `Package.swift` 均不引用具体源码路径，已确认无遗漏引用）。

### 变更统计

- **统计口径**：本次任务 = 17 个源码文件移动（0 行内容变更）+ `AGENTS.md` 项目结构小节改写（+5/−2）；不含本历史记录自身，不含任务开始前已存在的他人未提交修改。
- **变更文件数**：18
- **新增行数**：+5
- **删除行数**：-2

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `AGENTS.md`（项目结构小节） | +5 | -2 |
| `Sources/LocalQuotaBar/**`（17 个文件移动至子目录） | 0 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/codex/`、`zcode/`、`notify/`、`ui/`（新增目录及移入文件）
- `AGENTS.md`
