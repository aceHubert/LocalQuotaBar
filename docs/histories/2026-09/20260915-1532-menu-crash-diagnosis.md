## [2026-09-15 15:32 +0800] | 任务：排查菜单栏点击退出并补充真实弹窗回归

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`未知`
- **Runtime**：`Codex 桌面应用，macOS 26.6.2，Swift 6.3.3，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 排查点击菜单栏后应用退出的原因。

### 变更概览

**影响范围**：`Tests/LocalQuotaBarTests/PanelRenderingTests.swift`。

- 新增真实窗口的页脚显示周期测试。
- 新增真实 NSPopover 测试，使用合成额度和重置卡数据，覆盖展开、刷新重建、收起和连续三次重开。
- 本次未修改应用实现，保留工作区其他任务的代码和安装包更新。

### 诊断证据与判断

- 当天四份应用崩溃报告均为主线程 EXC_BAD_ACCESS，栈经过 DesignLibrary、SwiftUI 和 Swift 执行器检查；仅凭此栈无法认定某个原生控件或提醒通道是根因。
- 最新崩溃发生于 15:22:32。同一进程在 15:16:27 和 15:19:24 已两次出现 AppKit 无共同祖先的约束异常。调用栈分别经过 ResetCardsRow 的点击展开路径和额度定时刷新后的卡片重建路径。
- 该异常是明确的项目代码问题：卡片尚未挂载到容器，就启用了卡片与容器之间的宽度约束。当前工作区已由其他改动调整为先挂载、后启用约束；不重复修改。
- 安装包修改时间为 15:25，UUID 与 15:22 崩溃报告不同。不能将旧报告当作当前安装包仍然崩溃的证据。
- 布局异常与最终系统渲染内存崩溃的因果关系仍待确认。NSSwitch 单独窗口、独立 AppKit 进程和当前完整弹窗均未复现崩溃，未据此替换控件或移除 DynamicNotchKit。

### 验证结果

- `swift build`：通过。
- `perl -e 'alarm 60; exec @ARGV' swift test -c release`：13 项测试，12 项通过、1 项失败。本次新增两项及已有两项重置卡测试均通过。
- 失败项为其他并行任务新增的 ProviderHeaderViewTests.testLongDomainCompressesAccountInsteadOfRefreshTime：宽度比较为 92 与 92，不满足严格小于；未改动该测试或其实现。
- 原生 UI 工具连续两次启动失败；系统辅助功能点击未观察到弹窗，随后真实坐标点击也未确认弹窗打开。应用进程仍存活且未发现新崩溃报告，但不将此记作实际菜单栏点击验证通过。
- 未覆盖：用户更新后实际点击确认、长期刷新、Touch Bar / 刘海屏提醒投递。测试不访问额度服务、不写提醒配置。

### 变更统计

- **统计口径**：新增测试与 `/dev/null` 对比，使用 `git diff --no-index --shortstat` 和 `git diff --no-index --numstat`；排除历史记录自身、既有未提交改动及本轮其他任务的并行修改。
- **变更文件数**：1
- **新增行数**：+88
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Tests/LocalQuotaBarTests/PanelRenderingTests.swift` | 88 | 0 |

### 修改文件

- `Tests/LocalQuotaBarTests/PanelRenderingTests.swift`
- 本历史记录。
