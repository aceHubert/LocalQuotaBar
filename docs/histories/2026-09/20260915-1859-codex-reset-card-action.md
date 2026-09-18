## [2026-09-15 18:59 +0800] | 任务：通过 app-server 按卡重置 Codex 额度

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：`Codex Desktop / macOS / Swift Package Manager`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 每行 Codex 重置卡后添加重置按钮，通过 app-server 传当前 creditId；调用期间所有重置按钮禁用，一次只能一个。失败复用 idempotencyKey，成功清理并刷新次数。不要实际调用验证，由用户手工验证。后续要求审核完成后通知指定协作任务统一编译。

### 变更概览

**影响范围**：Codex 数据模型、RPC、状态服务、共享卡片明细、控制器接线、离线测试与执行计划。

- 卡片保留真实 ID 和状态，旧缓存缺失 ID 时继续显示但禁用按钮。
- 初始化 app-server 成功后才发送 account/rateLimitResetCredit/consume，明确传 creditId 和 idempotencyKey，不自动重试。
- 按账号和卡 ID 隔离并原子持久保存未确认键；失败复用，reset/alreadyRedeemed 清理并刷新。
- Codex 明细逐卡按钮原位更新状态；数量使用 availableCount。
- 应用级点击锁覆盖 Codex 和既有 Z.AI 重置；请求中同时禁用账号切换。
- 重置成功后保证一次新的额度读取，丢弃切换前账号的返回结果。
- 新增纯参数、假传输和 UI 事件测试源码；本任务未执行这些测试。

### 设计动机

redeem_request_id 是请求幂等标识，creditId 才指定卡片。幂等键在发送前落盘，避免超时后盲目生成新键。成功卡保留已完成状态，防止旧快照重复提交；读取额度失败继续保留缓存。

### 验证结果

- `swift build`：通过。
- `swift build --build-tests`：首次发现新增 UI 测试缺少显式 self，修正后通过；仅构建测试目标，未运行。
- `git diff --check`：通过。
- 独立静态审核确认逐卡传参、全局禁用、错误复用键的主路径；发现上游成功而本地清键失败时漏刷额度，已修复并增加对应离线测试。
- 审核修正后按用户要求不再编译，交由指定协作任务统一构建。
- 本任务未启动应用、未调用 app-server 或任何额度/重置接口，未消耗重置卡。
- 界面布局、真实成功/错误响应、账号切换、Touch Bar/刘海屏及最终集成运行未验证，由用户手工检查。

### 变更统计

- **统计口径**：未提交。main.swift、QuotaPanelViews.swift 与本任务编辑前临时快照比较；ProviderPanelSections.swift 仅比较 Codex 区块，排除并行写入的 Z.AI 改动；新增文件与 /dev/null 比较。使用 git diff --no-index --shortstat 和 --numstat，排除历史记录自身及其他已有改动。
- **变更文件数**：8
- **新增行数**：+813
- **删除行数**：-28

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 188 | 18 |
| `Sources/LocalQuotaBar/QuotaPanelViews.swift` | 39 | 7 |
| `Sources/LocalQuotaBar/ProviderPanelSections.swift`（Codex 区块） | 20 | 3 |
| `Sources/LocalQuotaBar/CodexResetService.swift` | 186 | 0 |
| `Tests/LocalQuotaBarTests/CodexResetServiceTests.swift` | 218 | 0 |
| `Tests/LocalQuotaBarTests/CodexResetCardRowTests.swift` | 66 | 0 |
| `Tests/LocalQuotaBarTests/CodexResetProtocolTests.swift` | 41 | 0 |
| `docs/exec-plans/completed/codex-reset-card-action.md` | 55 | 0 |

### 修改文件

- 上表所列代码、测试和执行计划。
- `docs/histories/2026-09/20260915-1859-codex-reset-card-action.md`。
