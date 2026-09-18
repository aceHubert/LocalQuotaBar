## [2026-09-15 20:12 +0800] | 任务：重置按钮点击增加确认弹框

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3`
- **Runtime**：`ZCode 桌面应用，macOS，SwiftPM`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 补充一个需求，把重置按钮点击添加一个确认弹框。本轮验证不要去调用接口，只改弹窗确认、只读验收，用户将手动验收结论。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/main.swift` 的两个重置卡使用入口。

- 新增 `confirmResetCardUse(informativeText:)` 助手：NSAlert 警告弹框，标题"确认使用重置卡？"，"取消"为第一个按钮即默认按钮（回车即取消），"确认重置"为第二个按钮。
- `useCodexResetCredit` 在全部前置校验通过后、上锁发请求前弹框确认；取消直接返回，不发送任何请求。
- `useZAIResetCard` 同样在状态校验后、发请求前确认，文案带种类（5小时额度/周额度）；"重置"与"重试"共用同一闸门。

### 设计动机

重置卡一旦消耗不可撤回，误触成本高；把确认放在 AppDelegate 的两个统一入口，覆盖面板全部重置按钮（Codex 每张卡、ZAI 两种额度）而无须改动面板层。取消作为默认按钮符合防误触习惯。中途曾抽出可注入的确认组件用于自动化验证，按用户要求回退，保持最小改动、手动验收。

### 验证结果

- `swift build`：通过。
- `swift test`：90 个测试全部通过（未新增测试）。
- 只读验收：本轮未启动应用、未点击真实重置按钮、未调用任何重置接口；弹框实际表现（取消不请求、确认才请求）由用户手动验收。

### 变更统计

- **统计口径**：`git diff HEAD -- Sources/LocalQuotaBar/main.swift` 相对本轮改动前快照的增量（逆向回滚本轮编辑对比）；不含历史记录自身。
- **变更文件数**：1
- **新增行数**：+14
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 14 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift` 及本历史记录。
