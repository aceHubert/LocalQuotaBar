## [2026-09-15 18:05 +0800] | 任务：根据实际状态启用设置操作按钮

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 重置按钮应判断设置是否为默认值，只有非默认值才可点击，并使用主色高亮；已静音提醒的按钮也应判断是否可点击。

### 变更概览

**影响范围**：设置页操作按钮、提醒配置比较与回归测试。

- “重置”仅在实际提醒配置不同于默认配置时启用；比较开关、两种额度阈值、重置提醒时间及提醒间隔的完整值，不受下拉框显示取整影响。
- “恢复提醒”使用现有 `canRestore`，仅有尚未过期的用户静音时启用；普通提醒冷却不算静音。
- 两个按钮可用时使用绿色主色背景，不可用时灰色显示并禁用。
- 两个动作均检查禁用状态，直接派发动作也无法绕过；完成操作后按最新配置同步回到禁用状态。
- 初始化即按默认、无静音状态禁用；动态着色保留 4 点圆角和 20 点高度。

### 设计动机

此前重置按钮只存在于初始化局部变量中，后续无法根据配置控制状态；恢复按钮只更新“有静音/无”的文案，没有同步可用性。将重置按钮提升为属性，并为 `ReminderConfiguration` 添加完整值相等比较，使操作资格与显示使用同一份实际配置。

恢复默认沿用现有低量提醒配置范围，不包含通用自动刷新频率或静音记录。

### 验证结果

- `swift build`、`swift build -c release`：通过。
- `perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release`：37 项通过，0 失败，其中新增 5 项设置操作测试。
- 覆盖初始/默认禁用、五字段独立差异和小数差异、刷新频率不影响默认判断、恢复默认立即同步、静音状态双向同步、禁用直接派发拦截，以及主色/灰色和圆角高度保持。
- 已安装并重启；`cmp` 确认安装二进制与发布版一致。
- 系统辅助功能读取当前实际设置页，“重置”和“恢复提醒”均处于不可用状态；未为实机核对修改用户配置或清除静音记录。
- `git diff --check`：通过。
- 未取得最终整页截图；未重新验证真实提醒投递及静音自然到期过程，本轮沿用既有 `canRestore` 判定。

### 变更统计

- **统计口径**：两个已有文件与本轮修改前快照执行 `git diff --no-index --shortstat` 和 `--numstat`，新增测试与 `/dev/null` 对比；排除本历史记录及此前未提交改动。
- **变更文件数**：3
- **新增行数**：+183
- **删除行数**：-15

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/SettingsPageView.swift` | 17 | 14 |
| `Sources/LocalQuotaBar/ReminderModels.swift` | 1 | 1 |
| `Tests/LocalQuotaBarTests/SettingsActionButtonTests.swift` | 165 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/SettingsPageView.swift`
- `Sources/LocalQuotaBar/ReminderModels.swift`
- `Tests/LocalQuotaBarTests/SettingsActionButtonTests.swift`
- 本历史记录。
