## [2026-09-18 20:10 +0800] | 任务：修复 start-plan 余额查询在 ZCode 3.12.3 下的 400

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：Atria-Dawn-Preview
- **Runtime**：zcode CLI（macOS 15，arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 查一下最新的 zcode 这个体验套餐的余额查询是怎么查的，怎么调用不了了。（查明后）回主任务中修改。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **逆向确认调用方式**：从 `ZCode.app/Contents/Resources/app.asar` 提取 host bundle，定位 billing/balance 调用链（`fetchZaiStartPlanBalanceEnvelope` → `NodeApiClient` → `buildZCodeSourceHeadersFromContext`），curl 二分验证出网关唯一强制的附加头是 `X-Device-Mid`，其余来源头（UA/平台/时区等）均可省略。
- **补设备标识头**：`ZAISettings.loadDeviceMid()` 读 `~/.zcode/v2/telemetry-state.json` 的 `deviceMid`（对齐 zcode.cjs 的 readExistingDeviceMid，只读不生成）；`makeStartPlanBalanceRequest` 新增 `deviceMid` 参数并设置 `X-Device-Mid` 头。
- **日志兜底前缀兼容**：3.12.3 起 host 日志里 start-plan 的 providerId 从 `builtin:<domain>-start-plan` 变为 `account:<domain>-start-plan`，`latestStartPlanBalancePayload` 的匹配抽成 `isStartPlanLogProviderID`（nonisolated），两种前缀都认。
- **测试**：新增 `ZAIQuotaEndpointTests`（3 例：请求头携带/省略 deviceMid、providerId 前缀匹配）。
- **清理**：删除并行排查会话遗留的临时 os_log 诊断代码（`Self.diag` helper 与三处调用、`import os.log`），重建 release 并重启验证。

### 设计动机

zcode.z.ai 网关对缺 `X-Device-Mid` 的 billing/balance 返回 HTTP 400 `{"code":3001,"msg":"parameter error"}`，误导性极强；上一任务曾因此误判为需要逆向客户端签名（`X-Client-Sig` 那套只用于 CLI 侧其他接口，余额接口不校验）。deviceMid 是本机现成的稳定值，直接从 telemetry-state.json 读取即可，无需自行生成注册。日志兜底优先于直连（app 直连偶被网关风控拦截），providerId 前缀必须双兼容，否则 3.12.3 下兜底静默失效、全部流量压到直连路径。

### 验证结果

- 命令与结果：
  - curl 二分：仅 Authorization → 400；Authorization + X-Device-Mid → 200（app_version 3.10.1 / 3.12.3 均通过）；逐个加 UA/平台/版本头单独均 400，确认唯一必需头。
  - URLSession ephemeral 复刻 App 完整取数路径（config.json JWT + telemetry deviceMid + 同构 URLRequest）→ 200，payload 含 plans[].entitlements[]（GLM-5.3-Flash 300M、effective_at 今日 23:00）。
  - `swift build` / `swift build -c release`：通过。
  - `swift test` 全量：106 例 0 失败（上一任务存在的 `ManualRefreshTests` 偶发失败本次未复现）。
  - 打包重启后 `local.quota.bar` 域内快照 fetchedAt 20:08:20，coding-plan 数据新鲜（5小时额度已用 18%、重置卡 4 张）。
  - 诊断代码清理后再次全量验证：debug/release 构建通过、ZAI 相关 13 例通过、重启（pid 45897）后快照 fetchedAt 20:30:47（codingPlan / lite），用户切回 Coding Plan 后手工验收。
- 手工验证及设备：本机（darwin 25.6.0 arm64）。
- 未覆盖场景：start-plan 模式的实机面板展示——用户排查期间已在 ZCode 切回个人 Coding Plan（setting.json 的 connectionSelection 已是 individual-coding-plan），下次切到 start-plan 时两条路径（日志兜底 account: 前缀 / 直连 deviceMid 头）均已就绪，代码路径由 curl 与 URLSession 复现验证。

### 排查过程中的两次误判修正（记录备查）

- 环境里的 `grep` 是 ugrep 别名，对当天日志静默返回空，导致误判"今天没有 billing/balance 日志"；实际当天有 83 条，且 `[usage-stats]` 最新一条 providerId 为 `account:zai-start-plan`。
- 读缓存用错了 defaults 域：应用 bundle id 是 `local.quota.bar`，此前误读废弃域 `local.codex.touchbar.quota`（仅存 9 月 13 日旧值），一度误判"重启后缓存未更新"。

### 变更统计

- **统计口径**：基线为上一任务（20260918-1855）后的工作区；zcode/ 与 Tests/ 未跟踪，按新增计；统计本任务四个触点文件，排除历史记录自身。
- **变更文件数**：2
- **新增行数**：+75
- **删除行数**：-6

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | +35 | -6 |
| `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift` | +40 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
- `Tests/LocalQuotaBarTests/ZAIQuotaEndpointTests.swift`
