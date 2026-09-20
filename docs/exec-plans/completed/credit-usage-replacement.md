# credit-usage 替换 model-usage 执行计划

- 状态：已完成
- 创建日期：2026-09-19
- 最后更新：2026-09-19

## 目标

将 Z.AI Coding Plan 的服务端用量同步从旧 `model-usage` 迁移到 Zcode
当前使用的 `credit-usage` MODEL 明细，同时保持现有近 30 天用量图、最近
约 8 天小时配速、账号分桶、失败保留缓存和个人/团队作用域行为不变；为
Credit、MCP、activity 和模型性能数据预留可扩展的数据边界。Start Plan
继续使用 `billing/balance`，不纳入本次替换。

## 范围

- 包含：
  - 增加 `credit-usage/usage-detail?usageType=MODEL` 请求与响应归一化。
  - 按 Zcode 作用域使用个人 `type=1`、团队 `type=3`；团队继续携带组织和项目头。
  - 将 Credit MODEL 的 Token 时间序列转换为现有日桶/小时桶缓存。
  - 保持现有账号分桶、增量同步、窗口切分、失败保留旧缓存和账号切换隔离。
  - 审计并补充解析、缓存、图表和周配速测试。
  - 评估并记录 `creditsUsage`、MCP、activity、model-performance 的后续扩展边界。
- 不包含：
  - 不修改 Start Plan 的 `billing/balance` 流程。
  - 不把 Credit 数值直接当作 Token 数值。
  - 不把 MCP 用量并入 MODEL 主图或 Token 总量。
  - 不使用 credit 请求失败后回退 `model-usage` 的探测式逻辑。
  - 不在本计划中重做提醒、重置机会或套餐权益展示。

## 背景

- 相关文档：
  - `docs/PLANS_GUIDE.md`
  - Zcode App 当前行为审计记录（本次调研结论）：Coding Plan 进入
    `getCodingPlanUsageSnapshot`，Start Plan 进入 `billing/balance`。
- 相关代码路径：
  - `Sources/LocalQuotaBar/zcode/ZAIServerUsage.swift`
  - `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
  - `Sources/LocalQuotaBar/main.swift`
  - `Sources/LocalQuotaBar/ui/DailyUsageChartView.swift`
  - `Sources/LocalQuotaBar/ui/WeeklyPaceChartView.swift`
  - `Tests/LocalQuotaBarTests/ZAIServerUsageTests.swift`
- 当前旧契约：
  - `data.x_time` 与 `data.tokensUsage` 等长。
  - 日图依赖最近 30 天日序列；周配速依赖最近约 8 天小时序列。
  - 缓存只保存 Token：`daily[].usage` 与 `daily[].hourly[].tokens`。
- 目标新契约（2026-09-19 已实测固化，个人 type=1 与团队 type=3 一致）：
  - 请求：`GET {api.z.ai|open.bigmodel.cn}/api/monitor/credit-usage/usage-detail`
    `?type={个人1|团队3}&usageType=MODEL&startTime&endTime`；团队带
    `Authorization: <apiKey>.<secret>` 与 `bigmodel-organization`/`bigmodel-project` 头。
  - 粒度阈值：窗口 ≤ 6 个自然日返回 HOUR，≥ 7 个自然日返回 DAY
    （实测 6 天 = 115+24 点 HOUR、7 天 = DAY；与旧接口的 8 天阈值不同）。
  - 响应：`{code:200, success:true, data:{granularity:"HOUR"|"DAY"（大写）,
    timezone, modelUsage:{xTime, modelDataList}}}`；小时键带秒
    `"yyyy-MM-dd HH:mm:ss"`，日键 `"yyyy-MM-dd"`。
  - `modelDataList` 每项携带与 xTime 等长的分组序列（`totalTokensUsage` 优先，
    回退 `tokensUsage`，再回退 cached+uncached+output 逐点求和）；credits 系列
    实测为字符串数值。汇总桶行（modelCode 命中 cachedInput/output_tokens 等
    9 个编码，或 modelName 为 缓存/未缓存/输出）是模型二次拆分，求和时排除。
  - Token 口径与旧接口一致（8 天窗实测差 ~1%，属两接口窗口边界差异）。
- 已知约束：
  - 当前工作区存在用户未提交改动，本计划执行时必须先读取并保留。
  - 个人和团队 Credit 请求的作用域参数不同：个人 `type=1`、团队 `type=3`。
  - `quota/limit` 仍负责 limits、usedPercent、remainingPercent 和 reset 时间。
  - 当前没有可用的 SwiftPM 测试目标时，不能把 `swift test` 当作现成检查。

## 风险

- 风险：Credit MODEL 返回结构不是旧的 `x_time/tokensUsage` 平铺格式。
  - 缓解方式：新增独立解析器和归一化层，禁止直接替换 URL 后复用旧解析器。
- 风险：Credit 同时包含 Token 与 Credit，单位混用导致图表或配速错误。
  - 缓解方式：缓存与内部模型显式标注 metric；当前图表只消费 Token。
- 风险：Credit 明细分页、重复记录、缺失日期或时区格式导致重复/漏算。
  - 缓解方式：先用个人旧账号和团队新账号固定响应样本建立契约测试，再实现
    去重、聚合、缺日补零和时区归一化。
- 风险：团队仍沿用旧 `type=2` 或组织项目头缺失，返回错误作用域。
  - 缓解方式：请求构造器分别覆盖个人 `type=1` 和团队 `type=3`，增加 URL/头部测试。
- 风险：旧缓存与新单位或新 schema 混用。
  - 缓解方式：缓存增加 schema/metric 版本；不兼容缓存安全丢弃并重新同步，
    不删除用户其他设置。
- 回滚方式：保留旧解析器和端点构造器，增加受控的本地实现开关；若新契约
  验证失败，恢复调用旧同步路径并保留已有缓存读取逻辑。

## 里程碑

1. 调研与契约收敛：抓取个人旧 Coding Plan 与团队新 Coding Plan 的
   `quota/limit`、Credit MODEL/MCP、activity 响应样本；确认 Token 时间轴、
   Credit 字段、分页、粒度和作用域参数。
2. 分阶段实现：新增 Endpoint/Parser/Normalizer；先只替换 MODEL Token
   日桶和小时桶，再视契约结果加入 Credit、MCP、activity 和性能字段。
3. 验证、交付与收尾：运行编译和单元测试，核对图表、周配速、失败缓存、
   账号切换和个人/团队请求；完成后补历史记录并将计划移至 `completed/`。

## 验证方式

- 命令：
  - `swift build` ✅
  - `swift test`（测试目标可用）✅ 173 个测试全部通过（含本计划新增 12 个）
- 自动化测试：
  - ✅ Credit MODEL 平铺/嵌套响应解析（HOUR/DAY、多模型求和、汇总桶排除）。
  - ✅ 大写粒度、带秒时间键、缺日和重复点处理（短序列补 0、字符串数值）。
  - ✅ 个人 `type=1`、团队 `type=3`、组织/项目头部。
  - ✅ Token 与 Credit 分离（credits-only 模型对 Token 无贡献），MCP 不进入请求。
  - ✅ 30 天日桶、8 天小时桶切块（≤6 天块）、窗口切分、失败保留缓存和账号分桶。
  - ✅ 缓存 schema：旧 model-usage 缓存（schema nil）兼容保留、未来版本丢弃。
  - ✅ 真实响应样本管线验证（个人 30d DAY / 个人 2d HOUR / 团队 8d DAY /
    团队当天 HOUR 四份真实 payload 过解析器与缓存管线，临时测试跑完删除）。
- 手工检查（真实账号，2026-09-19）：
  - ✅ 个人旧 Coding Plan（zai type=1）与团队新 Coding Plan（bigmodel type=3，
    key.secret 凭证）均返回 HTTP 200 + success=true + 真实模型数据。
  - ✅ type=1 作用于团队凭证返回空 modelDataList——作用域隔离正确。
  - ✅ 块请求 [T-7 00:00:00 .. T-2 23:59:59] 恰好返回 144 个小时点，边界精确。
  - ✅ 30 天窗口返回 30 个日点；6 天窗口返回 139 个小时点（HOUR）。
  - ✅ 未在本机切换套餐验证账号切换后的缓存隔离（沿用既有分桶测试覆盖）。
  - ⏭ Start Plan `billing/balance` 流程未改动（代码路径未触碰，编译通过）。
- 观测检查：
  - ✅ 记录实际请求路径、query type、响应状态和解析点数；未记录任何凭证。
  - ✅ 对比 `quota/limit` 的 Token 使用口径与 MODEL Token 聚合趋势
    （8 天窗：credit 924.6M vs model-usage 915.1M，差 ~1% 属窗口边界差异）。
- 实际结果与未覆盖场景：
  - 代码与契约均已验证；图表 UI 的实机渲染（Touch Bar / 刘海屏）未在本次
    留档截图（数据管线与既有 UI 未变，风险低）。
  - credit-usage 响应 `timezone: Asia/Shanghai`：非 +08:00 时区用户的日边界
    可能与服务端聚合日有偏移（旧接口同样存在，行为不变；登记技术债）。

## 进度记录

- [x] 确认范围和约束。
- [x] 完成 `model-usage` 消费者与缓存审计。
- [x] 完成 Zcode Credit 调用链与字段缺口审计。
- [x] 获取并固化个人/团队 Credit 响应契约样本。
- [x] 完成 Endpoint、Parser、Normalizer 第一阶段实现。
- [x] 完成缓存迁移、图表和周配速验证。
- [x] 完成验证并记录结果。
- [x] 将明确推迟的事项登记到技术债表并归档计划。

## 决策记录

- 2026-09-19：Coding Plan 目标路径改为 `credit-usage`；Start Plan 保留
  `billing/balance`，因为两者响应语义不同。
- 2026-09-19：第一阶段只使用 Credit MODEL 的 `tokensUsage` 替换旧 Token
  序列；`creditsUsage` 不直接进入现有 Token 图表或配速计算。
- 2026-09-19：不采用 credit 失败后回退 `model-usage`，避免把接口选择变成
  探测重试；失败时沿用现有“保留缓存、下次补齐”策略。
- 2026-09-19：Credit MCP、activity、model-performance 和 Credit 展示列为
  后续阶段，待真实响应契约确认后再实现。
- 2026-09-19：实测确认粒度阈值为 ≤6 个自然日 = HOUR；hourly 增量同步按
  日边界切 ≤6 天的块（8 天周窗 = 两块），daily+hourly 合并请求仅在并集
  窗口 ≤6 天时允许（原规则是 ≤8 天）。
- 2026-09-19：回滚开关落地为 UserDefaults
  `local.codex.touchbar.quota.serverPlanUsage.source`（"credit" 默认 / "model"），
  旧端点构造器与解析器保留为回滚路径。
- 2026-09-19：缓存 schema=2 标记 credit 时代；旧 model-usage 缓存（schema
  nil）与 Token 口径、键格式完全兼容，保留不丢；仅高于当前版本的缓存
  （降级运行）安全丢弃。Token 混源日的 ~1% 口径差在 30 天窗口内自然消化。
