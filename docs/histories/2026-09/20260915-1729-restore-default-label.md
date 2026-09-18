## [2026-09-15 17:29 +0800] | 任务：调整恢复默认文案

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 把重置默认修改为恢复默认。

### 变更概览

**影响范围**：设置页文案。

- 设置行标题从“重置默认”改为“恢复默认”，同步对应注释。

### 设计动机

按用户指定的用词调整展示，恢复配置的行为不变。

### 验证结果

- `swift build`、`swift build -c release`、`git diff --check`：通过。
- 已安装并重启，`cmp` 确认安装二进制与发布版一致。
- 纯文案改动，未新增或重跑单元测试。

### 变更统计

- **统计口径**：与本轮修改前快照执行 `git diff --no-index --shortstat` 和 `--numstat`；排除历史记录自身和此前已有改动。
- **变更文件数**：1
- **新增行数**：+2
- **删除行数**：-2

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/SettingsPageView.swift` | 2 | 2 |

### 修改文件

- `Sources/LocalQuotaBar/SettingsPageView.swift`
- 本历史记录。
