# [2026-09-19 21:42 +0800] | 任务：修复 Z.AI 套餐视图切换与 start-plan 多套餐解析

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`account:zai-individual-coding-plan/GLM-5.3`
- **Runtime**：ZCode Desktop（macOS 25.6.0 arm64）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> start plan 下有 2 个套餐，但显示混乱：显示为未开始，额度却是免费客户的；账号有团队套餐，但菜单里没有刷新显示。另追加反馈：选择个人套餐时，面板报“团队套餐缺少 organizationId 或 projectId”，为什么个人会调到团队？

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/ZAIQuota.swift`、`Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`、`Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift`。

**主要操作**：

- **start-plan 多套餐解析**：`parseStartPlanSnapshot` 不再用 `plans[]` 中首个 `active` 套餐作为标题与时间，而是按 `balances[].entitlement_id` 反查实际已生效套餐，再取其中优先级最高者作为展示元数据；无余额时才回退到 active 套餐展示待生效权益。
- **团队套餐菜单恢复**：`planMenuOptions` 的团队槽位只以 `setting.json` 中完整 team-coding-plan 连接（含 org/project）判定，不再受 `config.json` 的 `oauth_provider_inactive` 等镜像停用标记影响。
- **个人视图连接修正**：选择“个人订阅”时，通过 `personalSelection` 切到真正的 `individual-coding-plan` 连接（跨 zai/bigmodel 扫描），不再保留 team 连接的 domain 后仅清空 `teamContext`。
- **凭证过滤与失效视图回退**：套餐菜单与当前视图都校验对应渠道的 OAuth 凭证是否存在；仅剩槽位、没有凭证的残留套餐不显示也不查询，失效 override 自动回退到文件当前连接。
- **渠道切换完整刷新**：监听 `~/.zcode` 与 `~/.zcode/v2` 目录而非单个文件，`providerFamilyDomain` 变化时清空旧渠道快照，再按“套餐列表 → active 套餐 → 视图（额度、用量、配速）”顺序完整刷新。
- **跨渠道选择优先级**：个人/团队连接解析按 `providerFamilyDomain` 当前渠道优先，避免切换到 bigmodel 后仍选中 zai 的残留连接。
- **回归测试**：新增 start-plan 双套餐解析用例；将团队菜单测试改为验证忽略停用标记；个人视图测试补充 `connectionKind == individual-coding-plan` 断言。

### 设计动机

- `billing/balance` 可同时返回多个 active start-plan，`plans[]` 顺序不代表当前可用额度；已有 `balances` 的权益才是已生效口径，标题和有效期必须与其归属套餐一致。
- 本机 host 日志显示团队项目校验成功，但 `config.json` 仍把 bigmodel coding-plan 标为 `oauth_provider_inactive`，说明该 provider 镜像状态滞后，不能作为团队套餐入口的资格判据。
- 个人视图此前只清空团队作用域但保留 team 连接的 domain/connectionKind，查询路径仍进入团队分支，因此出现“个人套餐报团队缺 org/project”的错位。
- 仅以 setting.json 槽位判定会保留已经失效的套餐入口；本机切到 bigmodel 后只剩 `oauth:bigmodel` 凭证，zai 个人槽位仍在，因此必须叠加凭证存在性判定。
- zcode 原子替换 setting.json 会使文件级监听失效，且渠道切换后旧快照/用量缓存属于旧渠道，因此改为目录监听并在渠道变化时清空后完整刷新。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test --filter 'ZAIProviderSelectionTests|ZAIQuotaEndpointTests'` 通过；`swift test` 187 个测试全部通过；`swift build -c release` 通过。
- 手工验证及设备：未做 UI 截图验证；本机 `setting.json` 的 zai individual + bigmodel team 形态已由单测镜像覆盖。
- 未覆盖场景：多套餐并存展示仍未实现（当前单视图按有效余额套餐展示）；切换后真实网络请求结果需应用重启后手工确认。

### 变更统计

- **统计口径**：`git diff HEAD -- Sources/LocalQuotaBar/zcode/ZAIQuota.swift Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift`；包含同日已有未提交改动，历史记录自身不计。
- **变更文件数**：3
- **新增行数**：+170
- **删除行数**：-63

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | 71 | 37 |
| `Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift` | 13 | 26 |
| `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift` | 86 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`
- `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift`
