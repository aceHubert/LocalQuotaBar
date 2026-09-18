## [2026-09-15 16:45 +0800] | 任务：续接面板修复并统一绿色开关

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 继续“排查菜单栏点击失效”任务的工作，完成重置卡标签和展开按钮高度、圆角统一，并将主面板和设置页的开关开启色改为绿色。

### 变更概览

**影响范围**：面板共享控件、设置页及 AppKit 回归测试。

- 重置卡标签与展开按钮共用 18 点高度、6 点圆角，保持纵向居中。
- 两处提醒开关使用同一个绿色控件，保留既有配置回调。
- 真实弹窗回归使用与应用一致的无动画及尺寸去重策略，检查展开增高、收起恢复原尺寸。

### 续接确认

读取原任务记录并核对源码，以下修改已存在于接手时的工作区，本轮保留并纳入整体回归：

- logo 状态点、邮箱用户名截短、刷新时间 `HH:mm`、LocalQuotaBar 标题及设置页分隔线。
- 重置卡先挂载再启用约束；点击仅切换明细显隐，复用按钮和明细实例。
- 刷新失败横幅预设换行宽度，避免布局反馈循环。
- 设置先更新面板内状态再同步配置，防止 20% 被旧 30% 覆盖；图例随实际配置更新。
- API Key 模式提示独立成行，禁用余额刷新，继续展示本机每日用量。
- 主弹窗关闭尺寸动画，仅在尺寸变化时写入新值；DynamicNotchKit 保持启用。

原任务报告 22 项测试通过及部分实机验证，但最后没有完成历史记录。本节补记已核对的实现；本轮实际验证以下方结果为准，不将源码存在或测试存活等同于目测无闪烁。

### 设计动机

重置卡标签原先依赖文字自然高度，圆角为 8 点，右侧按钮固定 18 点高、6 点圆角，造成明显错位。现在使用局部共享尺寸，避免影响其他胶囊按钮。

系统 NSSwitch 没有公开的单控件开启色属性。共享开关使用原生按钮的状态与事件机制绘制绿色轨道，不修改系统强调色。

### 验证结果

- `swift build`、`swift build -c release`：通过。
- `LOCALQUOTABAR_RENDER_DIR=/tmp/localquotabar-ui-preview perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release`：最终 24 项测试通过，0 失败。包含实际窗口绿色/灰色像素、开关双向配置同步、阈值回退、API Key 日用量、重置卡视图复用及连续弹窗尺寸恢复。
- 首次像素测试将设备缓存像素直接与原始 sRGB 数值比较而失败；改为基准色经过同一窗口绘制和缓存管线，收紧容差后单项及全量测试通过。未为测试结果修改生产颜色。
- 绿色/灰色控件 PNG 已导出并目检；应用整页的区域与窗口截图均失败，因此未取得整页截图，也不声称已目测确认无闪烁。
- 新版已安装并重启，`cmp` 确认安装二进制与发布构建一致；未重生成图标。
- 系统辅助功能实测：菜单栏可打开；重置卡三次展开/收起的弹窗尺寸均为 `348×553 → 348×477`；设置开关 `1→0→1` 后返回主面板仍为 `1`，原设置已恢复。
- 内置文件和原生 UI 工具被工作区符号链接沙箱阻断，局部修改通过命令行补丁工具完成，实机交互使用系统辅助功能。所有本轮修改前快照均已保留。
- Touch Bar / 刘海设备提醒投递、长时间自动刷新和失败后缓存保留未在本轮重新验证。

### 变更统计

- **统计口径**：以本轮接手后的修改前快照为基线，使用 `git diff --no-index --shortstat` 和 `--numstat`；新增文件与 `/dev/null` 比较。排除本历史自身、接手时既有的 UI、图标、设计稿与其他改动。
- **变更文件数**：8
- **新增行数**：+195
- **删除行数**：-12

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 9 | 4 |
| `Sources/LocalQuotaBar/PanelReminderSwitch.swift` | 61 | 0 |
| `Sources/LocalQuotaBar/PanelTheme.swift` | 2 | 2 |
| `Sources/LocalQuotaBar/SettingsPageView.swift` | 1 | 1 |
| `Tests/LocalQuotaBarTests/ResetCardsRowTests.swift` | 6 | 0 |
| `Tests/LocalQuotaBarTests/PanelRenderingTests.swift` | 8 | 1 |
| `Tests/LocalQuotaBarTests/PanelFooterViewTests.swift` | 3 | 3 |
| `Tests/LocalQuotaBarTests/SettingsPageViewTests.swift` | 105 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/QuotaPanelViews.swift`
- `Sources/LocalQuotaBar/PanelReminderSwitch.swift`
- `Sources/LocalQuotaBar/PanelTheme.swift`
- `Sources/LocalQuotaBar/SettingsPageView.swift`
- `Tests/LocalQuotaBarTests/ResetCardsRowTests.swift`
- `Tests/LocalQuotaBarTests/PanelRenderingTests.swift`
- `Tests/LocalQuotaBarTests/PanelFooterViewTests.swift`
- `Tests/LocalQuotaBarTests/SettingsPageViewTests.swift`
- 本历史记录。
