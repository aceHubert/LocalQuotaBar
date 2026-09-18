## [2026-09-15 17:36 +0800] | 任务：调整设置按钮圆角与高度

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 调整截图中“恢复提醒”和“重置”按钮的圆角，随后将按钮高度调大一点。

### 变更概览

**影响范围**：设置页两个操作按钮。

- 两个按钮的圆角由共用样式中的 8 点改为局部 4 点。
- 17:56 后续调整：两个按钮统一加高至 20 点，增加文字上下留白。

### 设计动机

短按钮使用较大的圆角会呈现两端尖弧的胶囊轮廓，缩小圆角使外形更规整。随后增加固定高度，改善文字与边框的间距。

### 验证结果

- `swift build`、`swift build -c release`、`git diff --check`：通过。
- 已安装并重启，`cmp` 确认安装二进制与发布版一致。
- 纯样式改动，未新增或重跑单元测试；未取得最终整页截图。

### 变更统计

- **统计口径**：与圆角调整前的快照执行 `git diff --no-index --shortstat` 和 `--numstat`，累计包含圆角与高度两轮调整；排除历史记录自身和此前已有改动。
- **变更文件数**：1
- **新增行数**：+4
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/SettingsPageView.swift` | 4 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/SettingsPageView.swift`
- 本历史记录。
