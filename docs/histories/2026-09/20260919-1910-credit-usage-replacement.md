## [2026-09-19 19:10 +0800] | 任务：credit-usage 替换 model-usage

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）
- **Runtime**：ZCode CLI，macOS（darwin 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 执行 credit-usage 替换 model-usage 执行计划
> （`docs/exec-plans/active/credit-usage-replacement.md`，按计划完成剩余里程碑：
> 契约固化 → 实现 → 验证 → 归档）

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/`、`Sources/LocalQuotaBar/ui/`（注释）、
`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **契约固化**：解密本机 `~/.zcode` 凭证向真实 API 抓样（个人 zai type=1、
  团队 bigmodel type=3 + key.secret + org/project 头），实测固化请求/响应契约
  与粒度阈值（≤6 个自然日 = HOUR、≥7 = DAY）；关键差异：旧接口 8 天窗返回
  hourly，credit 6 天即降级 DAY。
- **新端点与解析器**：`ZAIServerUsageEndpoint.makeCreditUsageRequest`
  （type=1/3 + usageType=MODEL）与 `ZAICreditUsageResponse`（大写粒度、
  带秒小时键、逐模型序列求和、汇总桶行排除、credits 不混入 Token）；
  旧端点/解析器保留为回滚路径（UserDefaults
  `local.codex.touchbar.quota.serverPlanUsage.source` = "model" 切回）。
- **同步计划改造**：`planSync` 合并条件从并集 ≤8 天收紧为 ≤6 天；新增
  `hourlyFetches` 把 >6 天的 hourly 增量窗按日边界切 ≤6 天块（8 天周窗 =
  两块），`Fetch` 增加 `end` 支持中间日截止的块请求。
- **缓存 schema**：`ZAIServerUsageCache` 增加 `schema`（当前 2）；旧
  model-usage 缓存（nil）Token 口径兼容保留，高于当前版本的缓存（降级
  运行）安全丢弃；写入时统一打 schema。
- **测试**：新增 credit 请求构造（个人/团队）、响应解析（9 个用例）、
  数据源开关、同步计划切块、缓存 schema 共 12 个测试；旧接口请求/解析
  保留为回滚回归；真实 payload（个人 30d/2d、团队 8d/当天）过全管线
  验证通过（临时测试，验证后删除）。

### 设计动机

Zcode 已把 Coding Plan 用量统计迁移到 `credit-usage/usage-detail`，旧
`model-usage` 随时可能下线。替换时最大风险是粒度阈值差异（6 天 vs 8 天）：
若沿用旧的合并请求策略，7~8 天窗会拿到 DAY 响应导致小时明细永远拉不到，
因此同步计划必须收紧合并条件并对长窗切块。Token/Credit 双口径通过
"解析器只读 Token 系列 + credits-only 模型贡献 0"用测试钉死。缓存不设
强淘汰：新旧 Token 数值与键格式完全兼容（同口径差 ~1% 属窗口边界），
保留比丢弃更平滑，schema 字段为后续 Credit/MCP/activity 字段预留边界。

### 验证结果

- 命令与结果：
  - `swift build` ✅
  - `swift test` ✅ 173 个测试全部通过（0 失败）
  - 临时契约测试：真实个人/团队 payload 过解析器与缓存管线 ✅（跑完删除）
- 手工验证及设备：
  - 个人旧 Coding Plan（zai）：30 天窗 30 日点（DAY）、2 天窗 43 小时点
    （HOUR）、6 天窗 139 小时点（HOUR）、7 天窗 DAY；块请求
    [T-7..T-2] 恰好 144 个小时点，边界精确。
  - 团队新 Coding Plan（bigmodel）：type=3 + key.secret 返回真实数据；
    同凭证用 type=1 返回空列表（作用域隔离正确）。
  - 口径对比：8 天窗 credit 924.6M vs 旧 model-usage 915.1M（差 ~1%，
    窗口边界差异，同为 Token 口径）。
  - 打包实机验证（个人版，2026-09-19 19:02）：`make app` 后替换运行中的
    旧实例；启动刷新自动完成升级路径——旧 schema=nil 缓存原地保留并升级为
    schema=2，今日小时点 19→20（新增 19:00 桶），30 天日桶与 8 天小时明细
    齐全；缓存今日总量 123,230,043 / 20 点与直连 credit-usage 实时抓取
    逐位一致，数据确出自新端点。数据源开关未设置（默认 credit），进程稳定。
  - 未记录任何凭证到日志或仓库。
- 未覆盖场景：
  - Touch Bar / 刘海屏实机渲染未截图留档（UI 消费接口未变，数据管线
    已由测试覆盖）；非 +08:00 时区的日边界偏移与旧行为一致，登记技术债。

### 变更统计

> `git diff --shortstat` / `git diff --numstat`（工作区，仅本任务文件；
> 历史记录自身与计划文档移动不计入）。

- **统计口径**：基线为任务开始前工作区；仅统计本任务触碰的 6 个源文件/测试/文档。
- **变更文件数**：6
- **新增行数**：+620
- **删除行数**：-85

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIServerUsage.swift` | +283 | -60 |
| `Tests/LocalQuotaBarTests/ZAIServerUsageTests.swift` | +330 | -21 |
| `docs/exec-plans/tech-debt-tracker.md` | +3 | -0 |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | +2 | -2 |
| `Sources/LocalQuotaBar/main.swift` | +1 | -1 |
| `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift` | +1 | -1 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZAIServerUsage.swift`
- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`（注释）
- `Sources/LocalQuotaBar/main.swift`（注释）
- `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`（注释）
- `Tests/LocalQuotaBarTests/ZAIServerUsageTests.swift`
- `docs/exec-plans/tech-debt-tracker.md`
- `docs/exec-plans/completed/credit-usage-replacement.md`（自 active/ 移入并收尾）
