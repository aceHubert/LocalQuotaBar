## [2026-09-19 16:41 +0800] | 任务：支持团队 Coding Plan 重置卡

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-5`
- **Runtime**：Codex desktop，macOS 13+ Swift 工具链
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 团队套餐不限制重置，只要能查到重置次数就应允许使用。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **放开团队限制**：重置上下文仅校验 Coding Plan 与支持的渠道，不再把 `team-coding-plan` 当作不支持。
- **补充团队作用域**：团队上下文缺少组织或项目时拒绝发请求；完整上下文随 `ZAIResetContext` 传入重置服务。
- **修正请求头**：团队请求发送 `Bigmodel-Target-Type: TEAM`、`Bigmodel-Organization`、`Bigmodel-Project`，个人请求保持 `PERSONAL`。
- **隔离幂等作用域**：团队账号作用域散列纳入组织与项目 ID，避免跨团队或与个人账号复用未确认请求。
- **补齐测试与文档**：增加团队上下文解析、请求头、作用域隔离测试，并归档执行计划。

### 设计动机

团队套餐本身没有个人重置卡，但官方客户端确认团队账号只要查询到可用重置卡，就使用同一 `reset/use` 接口和团队作用域。实现因此把“是否有可用卡”保留在 UI 判定中，同时让服务层对团队请求携带完整作用域；这样既能按用户要求放开，又不会把团队操作记到个人幂等键下。

### 验证结果

- 命令与结果：
  - `swift build`：通过。
  - `swift test`：158 项通过，0 失败。
  - `swift build -c release`：通过。
- 手工验证及设备：
  - 重启本机 BigModel 团队账号应用后，额度与重置卡刷新正常。
  - 未点击真实重置按钮，未消耗重置卡。
- 未覆盖场景：
  - 未对真实团队账号执行 `reset/use`，服务端成功消费与选卡顺序仍未实测。

### 变更统计

> 基线为任务开始前 `HEAD`；范围仅包含本次代码与测试文件，排除历史记录、执行计划、已有图标和设计稿改动。

- **统计口径**：`git diff HEAD -- <本次代码/测试文件>`。
- **变更文件数**：4
- **新增行数**：+68
- **删除行数**：-13

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift` | 22 | 10 |
| `Sources/LocalQuotaBar/zcode/ZAIResetService.swift` | 8 | 1 |
| `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift` | 16 | 1 |
| `Tests/LocalQuotaBarTests/ZAIResetServiceTests.swift` | 22 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift`
- `Sources/LocalQuotaBar/zcode/ZAIResetService.swift`
- `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift`
- `Tests/LocalQuotaBarTests/ZAIResetServiceTests.swift`
- `docs/exec-plans/completed/team-coding-plan-reset.md`
