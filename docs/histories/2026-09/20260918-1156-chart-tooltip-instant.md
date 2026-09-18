## [2026-09-18 11:56 +0800] | 任务：柱状图悬停提示改为即时自绘浮层

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：a14d47f3-204c-4979-be58-fd77ef7f8b68/Atria-Dawn-Preview
- **Runtime**：macOS 25.6.0 arm64（darwin），Swift 工具链
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 排查一个问题，每日使用的柱状图上显示的使用提示使用系统默认的 tooltip 吗，反应特别慢，要好几秒才会显示出来。确认后要求修改。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`、`Tests/LocalQuotaBarTests/DailyUsageChartTests.swift`

**主要操作**：

- **诊断确认**：柱状图原先用 `NSView.toolTip`（`NSHelpManager`）显示明细，延迟来自三处叠加：系统固定约 1 秒悬停延迟且要求光标静止；面板宽 322pt 下 30 根柱子每根仅约 7pt 宽，轻微移动就跨柱重新赋 `toolTip`、重新注册 tooltip 区域并重置计时；面板打开期间的后台刷新走 `configure(days:)`（原第一行 `toolTip = nil`）并触发 `updatePreferredContentSize()` → 重新布局 → `updateTrackingAreas()` 重建 tracking area，再次打断计时。
- **改为自绘浮层**：新增 `ChartTooltipWindow`（无边框 `NSPanel`，`ignoresMouseEvents`、`becomesKeyOnlyIfNeeded`、层级为宿主窗口 +1，不抢焦点、不拦截鼠标、盖在 popover 之上），悬停 0.18 秒后出现，已显示时跟随柱子即时更新文字与位置；`mouseExited`、`configure`、宿主窗口 `willClose` 时收起。
- **悬停高亮**：`drawBars` 命中柱子使用更亮的绿色（highlight 0.4），与浮层对应。
- **布局收敛**：把重复 4 次的柱宽计算抽成 `ChartBarLayout`（等宽/间距布局 + 按 x 反查序号），`drawBars`、`drawTicks`、命中计算、锚点计算共用同一份几何。
- **补充测试**：新增 `Tests/LocalQuotaBarTests/DailyUsageChartTests.swift`（7 个用例），覆盖布局切分、最小柱宽、边界序号、空数据、全宽逐柱命中与文案。

### 设计动机

系统 tooltip 的延迟和静止要求无法在应用内按视图调整（`NSToolTipDelay` 是全局用户默认，不该由 App 写），而"光标必须在 7pt 宽的柱子里静止一整秒"这个交互前提本身就不现实，所以放弃系统 tooltip 改为自绘。

关键取舍：

- 用独立 `NSPanel` 而不是在视图内画 overlay，是因为图表靠近面板边缘，视图内绘制会被 popover 裁切；独立窗口可以超出面板边界，位置按屏幕可视区钳制。
- 浮层窗口设为不响应鼠标且不成为 key 窗口，避免显示时让 `.transient` 的 popover 失焦关闭。
- 保留 0.18 秒延迟而非 0：完全即时会在扫过柱子时闪烁，短延迟兼顾"快"和"不抖"。
- 只在命中柱索引变化时重绘（`needsDisplay`），移动中不触发额外绘制。

### 验证结果

- 命令与结果：
  - `swift build`：Build complete（3.18s）。
  - `make build`（release）：Build complete（10.14s）。
  - `swift test`：97 tests，1 failure —— 失败为 `ManualRefreshTests.testFailedRefreshAndErrorRetryPreserveCooldown`（行 124，重试后请求数 3 ≠ 1），单独重跑 3 次均稳定失败，与本次改动文件无交集，判定为既有失败，未在本次修复。新增的 7 个 `DailyUsageChartTests` 全部通过。
- 手工验证及设备：`make app` 打包后重启应用，人工悬停"近 30 天用量"柱状图验收通过——提示即时出现，面板保持打开，浮层层级正常。
- 未覆盖场景：多屏边界钳制、深浅色外观切换、辅助功能下的浮层可读性，未单独验证。

### 变更统计

> 两个文件均为未跟踪新文件，按 `docs/HISTORY_GUIDE.md` 用 `git diff --no-index /dev/null <文件>` 统计；历史记录自身不计入。

- **统计口径**：本次任务两个文件，对比基线 `/dev/null`；排除图标、设计稿等无关改动。
- **变更文件数**：2
- **新增行数**：+532
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | 424 | 0 |
| `Tests/LocalQuotaBarTests/DailyUsageChartTests.swift` | 108 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`
- `Tests/LocalQuotaBarTests/DailyUsageChartTests.swift`
