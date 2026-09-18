## [2026-09-15 19:16 +0800] | 任务：重置详情铺满并将操作按钮右对齐

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> Codex 重置详情显示 100% 宽度，重置按钮靠右显示。

### 变更概览

**影响范围**：provider 内重置详情容器及明细行。

- 重置卡视图宽度绑定 provider 内容区，展开详情铺满 298 点内容宽度。
- 将行内空白区域的水平拥抱与抗压优先级设为最低，使每行重置按钮对齐详情右侧内边距。
- 新增使用真实 provider 容器的布局回归，不依赖直接给 ResetCardsRow 固定宽度的测试夹具。

### 设计动机

详情内部已有等宽约束，但外层 provider 采用 leading 排列，未绑定 ResetCardsRow 的宽度，因而整块仍可能仅按内容自然宽度布局。修复外层约束，并让空白区域承接剩余宽度。

### 验证结果

- `swift build`：通过。
- 发布构建及指定两项布局测试通过，0 失败；验证详情宽度 298 点、操作按钮右边缘距详情右侧 9 点，以及 Z.AI 组操作宽度不溢出。
- 测试命令：`perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release --filter 'CodexResetCardRowTests/testDetailsFillProviderWidthAndAlignActionsRight|ResetCardActionTests/testResetGroupsFitPanelWidthAndAlignActionsToTrailingEdge'`。
- 仅使用合成视图，未执行真实重置接口或 app-server 重置调用。
- 已安装并重启，`cmp` 确认安装二进制与发布版一致；`git diff --check` 通过。

### 变更统计

- **统计口径**：与本轮修改前快照执行 `git diff --no-index --shortstat` 和 `--numstat`；排除历史记录自身及此前两项重置功能改动。
- **变更文件数**：3
- **新增行数**：+42
- **删除行数**：-1

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ProviderPanelSections.swift` | 1 | 0 |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 2 | 1 |
| `Tests/LocalQuotaBarTests/CodexResetCardRowTests.swift` | 39 | 0 |

### 修改文件

- 上表三个文件及本历史记录。
