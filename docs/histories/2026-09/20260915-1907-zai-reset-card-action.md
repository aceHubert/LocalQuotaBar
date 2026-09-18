## [2026-09-15 19:07 +0800] | 任务：接入 Z.AI 重置卡及持久幂等重试

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 在 5h 和周重置卡旁添加重置按钮；生成并保存幂等键，失败重试始终复用，只有返回 200 后才清除。等待并行 Codex 重置任务结束后一起编译，不实际执行重置验证。

### 变更概览

- 两种 Z.AI / BigModel 个人套餐重置操作分别展示，进行中禁用，失败显示重试，成功后读取新额度和卡片状态。
- `POST /api/v1/coding-plan/reset/use` 只传类型与幂等键，凭证取当前账号；不在客户端选择或指定某张卡。
- 以稳定账号身份、渠道和额度类型隔离请求，令牌刷新不改变作用域。
- 发送前原子保存键，异常、非 200、业务失败、畸形响应均保留。仅 HTTP 200、成功码且 `used=true`、`success` 非 false 后清理。
- 跨进程文件锁覆盖读盘、请求与清理，避免多实例覆写；其他实例清理后，旧界面重试仍复用本实例已知键。
- 存储故障不擅自发送；服务端已成功但清理落盘失败时刷新额度，保留原键供确认。
- 卡片组操作更新保留展开和视图实例；与并行 Codex 功能共同使用全局重置互斥。

### 设计动机

网络响应丢失不代表操作失败，重新生成键会造成额外消耗。未确认请求必须在重启、多实例和令牌刷新后保留身份；快照和重置卡查询使用相同捕获凭证，避免换号期间错配。

### 验证结果

- 等指定 Codex 任务完成后联合编译；`swift build` 通过，发布应用和全部测试目标均完成编译。
- 直接 `swift build -c release --build-tests` 曾因未启用 `@testable` 失败；随后通过 `swift test -c release` 的测试构建成功。
- `perl -e 'alarm 60; exec @ARGV' arch -arm64 /usr/bin/swift test -c release --filter 'ZAIResetServiceTests|ZAIResetIntegrationTests|ResetCardActionTests|ResetCardsRowTests|ZAIUsagePresentationTests'`：32 项通过，0 失败。
- 所有重置网络验证为注入的模拟响应；Codex 重置测试只编译、未执行。
- 新版已安装并重启，`cmp` 确认一致；系统辅助功能只读确认 5h、周两个重置按钮可用，Codex 三个逐卡按钮同时显示。
- 未点击任何真实重置按钮；生产重置结果、服务端选卡顺序由用户手工验证。未取得最终整页截图。
- `git diff --check`：通过。计划已归档，无本范围明确推迟实现项。

### 变更统计

- **统计口径**：使用修改前快照与 `git diff --no-index --shortstat/--numstat`；新增文件与 `/dev/null` 比较。共享 UI 和 main 使用 Codex 任务介入前的 Z.AI 完成快照，ProviderPanelSections 只提取 Z.AI 类范围，排除并行 Codex 和此前改动；历史自身不计入。
- **变更文件数**：10
- **新增行数**：+1436
- **删除行数**：-40

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 82 | 2 |
| `Sources/LocalQuotaBar/ProviderPanelSections.swift` | 96 | 30 |
| `Sources/LocalQuotaBar/main.swift` | 71 | 0 |
| `Sources/LocalQuotaBar/ZAIQuota.swift` | 35 | 8 |
| `Sources/LocalQuotaBar/ZAIResetService.swift` | 276 | 0 |
| `Sources/LocalQuotaBar/ZAIResetContextResolver.swift` | 84 | 0 |
| `Tests/LocalQuotaBarTests/ZAIResetServiceTests.swift` | 412 | 0 |
| `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift` | 126 | 0 |
| `Tests/LocalQuotaBarTests/ResetCardActionTests.swift` | 186 | 0 |
| `docs/exec-plans/completed/zai-reset-card-action.md` | 68 | 0 |

### 修改文件

- 上表十个文件及本历史记录。
- 相关计划：`docs/exec-plans/completed/zai-reset-card-action.md`。
