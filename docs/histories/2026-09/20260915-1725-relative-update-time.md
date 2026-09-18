## [2026-09-15 17:25 +0800] | 任务：顶部更新时间改为相对时间

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 顶部全局更新时间显示为刚刚、x 分钟前、x 小时前；刚刚表示 2 分钟内。

### 变更概览

**影响范围**：顶部时间文案及可见期间的定时更新。

- 少于 120 秒显示“刚刚”；满 2 分钟显示整数分钟数，满 1 小时显示整数小时数。
- 顶部复用相对时间格式；悬停保留上次成功刷新的具体时间。
- 打开面板立即更新文案，打开期间每 15 秒更新一次；关闭时停止定时器。
- 保持原有时间数据来源，provider 内的 `HH:mm` 显示不变。

### 设计动机

相对时间更方便判断数据新鲜程度。文案更新独立于数据刷新，避免为了更新时间文本发起网络请求。

### 验证结果

- `swift build`：通过。
- `perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release`：发布构建及现有 32 项测试通过，0 失败。
- 已更新安装并重启；`cmp` 确认安装二进制与发布版一致。
- `git diff --check`：通过。
- 本次未新增测试；现有真实弹窗测试覆盖了重复打开与关闭的生命周期。未实机等待小时级文案变化。

### 变更统计

- **统计口径**：与本轮修改前快照执行 `git diff --no-index --shortstat` 和 `--numstat`；排除历史记录自身及此前已有改动。
- **变更文件数**：2
- **新增行数**：+30
- **删除行数**：-9

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 27 | 2 |
| `Sources/LocalQuotaBar/PanelTheme.swift` | 3 | 7 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/PanelTheme.swift`
- 本历史记录。
