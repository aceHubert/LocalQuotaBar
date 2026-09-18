## [2026-09-15 17:18 +0800] | 任务：统一刷新防重并联动全局按钮

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 单独刷新进入冷却期或正在刷新时，避免全局刷新重复触发。用户随后选定：任一单项处于冷却时，全局按钮不可点击。

### 变更概览

**影响范围**：手动刷新入口、provider 按钮状态、全局按钮状态与回归测试。

- 任一可见 provider 正在刷新或处于 60 秒冷却时，全局刷新置灰；全部恢复后启用。
- 单独刷新、错误重试、全局刷新共用状态检查；接受请求时开始冷却，跳过请求不会延长截止时间。
- 全局按钮事件也检查状态，避免直接调用回调绕过按钮禁用。
- 单项刷新保持独立；隐藏的 Z.AI 不阻塞全局，也不接收全局请求。
- API Key 模式继续禁用余额按钮，全局仍可刷新本机每日用量，并遵守同一防重规则。
- 新增 8 项测试，使用可注入时钟覆盖 60 秒边界，无需等待真实冷却或调用网络。

### 设计动机

此前 60 秒冷却只在单项按钮点击时禁用该按钮；全局直接调用外部刷新回调，绕过冷却。错误重试也能绕过并延长冷却。虽然额度 store 有刷新中防重，但回调中附带的用量刷新仍可能被触发。

现在在共用 provider 入口先判断是否接受请求，再进入包含额度和用量的回调；将数据层传入的刷新中状态加入按钮可用性判断。定时器只负责在截止时更新按钮，截止时间本身用于接受请求判断。自动刷新调度、缓存策略和网络读取逻辑保持既有行为。

### 验证结果

- `swift build`、`swift build -c release`：通过。
- `perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release`：32 项通过，0 失败；其中 8 项为新加的手动刷新防重测试。
- 覆盖：冷却边界、跳过不续期、冷却后仍刷新中、失败重试、全局连点、直接回调保护、隐藏 provider 和 API Key 用量。
- 已安装并重启；`cmp` 确认安装二进制与发布版一致。
- 系统辅助功能实测：单项刷新前全局与 Codex 按钮均可用；点击后均不可用，全局提示“有项目正在刷新或冷却，请稍后重试”。
- 超过 60 秒后再次打开面板，实机确认全局与 Codex 按钮均恢复可用，提示恢复为“全部刷新”和“手动刷新”。
- `git diff --check`：通过。
- 未重新验证：长时间自动刷新计时、真实失败时缓存保留、Touch Bar / 刘海屏提醒投递；本轮未修改这些流程。

### 变更统计

- **统计口径**：三个已有文件与本轮修改前快照执行 `git diff --no-index --shortstat` 和 `--numstat`，新增测试与 `/dev/null` 对比。排除本历史记录及此前 UI、图标、设计稿等未提交改动。
- **变更文件数**：4
- **新增行数**：+280
- **删除行数**：-18

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 40 | 9 |
| `Sources/LocalQuotaBar/ProviderPanelSections.swift` | 21 | 6 |
| `Sources/LocalQuotaBar/main.swift` | 18 | 3 |
| `Tests/LocalQuotaBarTests/ManualRefreshTests.swift` | 201 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/QuotaPanelViews.swift`
- `Sources/LocalQuotaBar/ProviderPanelSections.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Tests/LocalQuotaBarTests/ManualRefreshTests.swift`
- 本历史记录。
