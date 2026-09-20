# 团队 Coding Plan 重置卡操作

- 状态：已完成
- 创建日期：2026-09-19
- 最后更新：2026-09-19

## 目标

让 LocalQuotaBar 在团队 Coding Plan 能查询到重置卡时提供重置操作，同时保持个人与团队账号的认证头、幂等键和作用域严格隔离。

## 范围

- 包含：
  - 解析团队 Coding Plan 的重置上下文与组织/项目作用域。
  - 重置请求按个人/团队发送正确的 `Bigmodel-Target-Type`、组织和项目 Header。
  - 幂等作用域纳入团队组织和项目，避免不同团队或团队与个人互相复用。
  - 补齐团队重置请求与作用域隔离的自动化测试。
- 不包含：
  - 修改 ZCode 或 BigModel 服务端协议。
  - 主动执行真实重置或消耗用户重置卡。
  - 为团队套餐新增与个人套餐不同的 UI 操作模型。

## 背景

- 相关文档：
  - `docs/exec-plans/completed/zai-reset-card-action.md`
  - `docs/exec-plans/completed/team-coding-plan-quota.md`
- 相关代码路径：
  - `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift`
  - `Sources/LocalQuotaBar/zcode/ZAIResetService.swift`
  - `Tests/LocalQuotaBarTests/ZAIResetIntegrationTests.swift`
  - `Tests/LocalQuotaBarTests/ZAIResetServiceTests.swift`
- 已知约束：
  - 只有实际查询到未过期重置卡时才应允许操作。
  - 团队请求必须携带组织和项目 Header，缺少作用域时不得发送请求。
  - 未确认请求仍须复用原幂等键。

## 风险

- 风险：团队与个人请求混用认证头会导致服务端拒绝或作用域错误。
  - 缓解方式：团队上下文显式进入 `ZAIResetContext`，请求头按上下文生成。
- 风险：不同团队共享账号身份时幂等键冲突。
  - 缓解方式：作用域散列纳入组织和项目 ID。
- 风险：团队配置缺失作用域时发出无效请求。
  - 缓解方式：上下文解析阶段直接拒绝并展示明确原因。
- 回滚方式：回退上下文模型、解析器、请求头构造及对应测试。

## 里程碑

1. 确认官方客户端团队重置协议。
2. 实现团队上下文解析、请求头与作用域隔离。
3. 完成自动化测试、发布构建和真实账号只读验证。

## 验证方式

- 命令：
  - `swift build`
  - `swift test`
  - `swift build -c release`
- 自动化测试：
  - 完整团队作用域可解析，缺失作用域被拒绝。
  - 团队重置请求发送 `TEAM`、组织和项目 Header。
  - 不同团队作用域生成不同幂等作用域。
  - 原有个人、失败重试、并发锁与成功清理逻辑保持通过。
- 手工检查：
  - 使用当前 BigModel 团队账号重启应用，确认额度与重置卡刷新正常。
  - 未点击真实重置按钮，未消耗重置卡。
- 实际结果与未覆盖场景：
  - `swift build`：通过。
  - `swift test`：158 项通过，0 失败。
  - `swift build -c release`：通过。
  - 未对真实团队账号执行 `reset/use`，服务端成功消费与选卡顺序仍未实测。

## 进度记录

- [x] 确认官方团队重置协议与范围。
- [x] 实现团队上下文、请求头与幂等作用域隔离。
- [x] 完成自动化测试和发布构建。
- [x] 重启应用并完成真实账号只读刷新验证。
- [x] 归档计划并记录历史。

## 决策记录

- 2026-09-19：不再按个人/团队写死拦截；允许条件是当前账号能解析出完整上下文且查询到可用重置卡。
- 2026-09-19：团队幂等作用域加入组织与项目 ID，避免跨团队错误复用未确认请求。
