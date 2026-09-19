# Team Coding Plan 团队套餐余额与用量接入

- 状态：已完成
- 创建日期：2026-09-19
- 最后更新：2026-09-19

## 目标

让 LocalQuotaBar 正确识别并展示 BigModel `team-coding-plan` 的团队套餐限额与官方 MCP 用量。实现必须从 `.zcode/v2/setting.json` 读取 `organizationId` 和 `projectId`，按官方客户端的认证方式分别调用套餐限额接口与 MCP 聚合用量接口，并在请求失败时保留已有缓存。

## 范围

- 包含：
  - 解析 `providerFamilyConnectionSelections[domain]` 中的 `kind`、`productId`、`organizationId`、`projectId`。
  - 为团队上下文建立明确的数据模型，并传入额度查询链路。
  - 实现团队套餐的 `quota/limit?type=2` 查询。
  - 实现官方 MCP `mcp/usage` 查询。
  - 保留个人 Coding Plan 的现有查询路径，避免团队和个人认证方式混用。
  - 统一解析 `limits`、`total_usage`、`level`、`next_refresh_at`，并适配现有面板模型。
  - 修正团队重置状态请求的目标类型与认证头；团队无可用重置卡时保持安全降级。
  - 增加解析、请求构造和响应转换的自动化测试。
- 不包含：
  - 修改 ZCode 或 BigModel 服务端行为。
  - 在仓库中保存任何 OAuth、JWT、API Key 或 Secret。
  - 将 `productId` 臆测为额度接口的必需 Header；当前证据表明它只用于产品/套餐上下文。
  - 改造本地日用量统计数据库的既有口径。

## 背景

- 相关文档：
  - `docs/PLANS_GUIDE.md`
  - `docs/exec-plans/templates/execution-plan.md`
  - 本机 ZCode 日志：`~/.zcode/v2/logs/YYYY-MM-DD.log`（仅用于本地验证，不纳入仓库）。
- 相关代码路径：
  - `Sources/LocalQuotaBar/zcode/ZAIQuota.swift`
  - `Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift`
  - `Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`
  - `Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`
- 当前配置形状：

  ```json
  {
    "providerFamilyConnectionSelections": {
      "bigmodel": {
        "kind": "team-coding-plan",
        "productId": "product-*",
        "organizationId": "org-*",
        "projectId": "proj_*"
      }
    }
  }
  ```

- 官方调用链结论：
  1. 团队套餐限额：

     ```text
     GET https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2
     authorization: <project-api-key>.<project-api-key-secret>
     bigmodel-organization: <organizationId>
     bigmodel-project: <projectId>
     ```

     响应中的 `data.limits` 用于 5 小时和周限额。

  2. 官方 MCP 聚合用量：

     ```text
     GET https://zcode.z.ai/api/v1/mcp/usage
     Authorization: Bearer <zcode-jwt>
     X-Bigmodel-Authorization: Bearer <oauth-access-token>
     Bigmodel-Target-Type: TEAM
     Bigmodel-Organization: <organizationId>
     Bigmodel-Project: <projectId>
     ```

     响应中的 `data.total_usage`、`level`、`next_refresh_at` 用于 MCP 用量展示。

  3. `productId` 出现在配置与套餐上下文中，但当前官方额度请求不直接发送该字段。
  4. 账号额度接口按账号版本存在三套返回口径：v1/v2 旧口径使用
     `TOKENS_LIMIT`，v3 为积分制并使用 `CREDIT_LIMIT` 表示积分额度。
     `CREDIT_LIMIT` 与旧 `TOKENS_LIMIT` 是不同计费口径，互不冲突；
     周窗口统一使用 `unit=6`，解析后映射为现有周限展示桶。

- 已知约束：
  - 当前 `ZAIProviderSelection` 没有保存团队 ID，因此请求层无法带团队 Header。
  - 当前 `fetchCodingPlanSnapshot` 使用个人 OAuth Bearer 请求 `quota/limit`，缺少 `type=2` 与项目 API Key/Secret。
  - 当前代码没有接入 `mcp/usage`，不能展示官方客户端记录的团队 MCP 用量。
  - 工作区已有其他未提交改动；实现时只能修改本计划涉及的文件，必须保留无关改动。

## 风险

- 风险：团队项目 API Key/Secret 的获取链路依赖 ZCode 凭证与项目权限。
  - 缓解方式：复用官方客户端的项目预热/运行时 Key 语义；不把密钥写入缓存或日志。
- 风险：`quota/limit` 与 `mcp/usage` 的指标口径不同，直接合并会造成 UI 误导。
  - 缓解方式：在模型中区分套餐限额与 MCP 聚合用量，UI 分别标注来源。
- 风险：团队上下文切换期间异步请求返回旧账号数据。
  - 缓解方式：在发起请求时捕获完整 selection、团队上下文和凭证，响应写入前校验当前作用域；失败时保留旧快照。
- 风险：旧缓存无法解码新增字段。
  - 缓解方式：新增 Codable 字段使用 `decodeIfPresent`，为缺失团队字段提供个人/未知作用域兼容路径。
- 回滚方式：回退本计划涉及的源文件和测试文件；保留旧缓存读取兼容逻辑，不删除用户本地配置。

## 里程碑

1. 调研与方案收敛：确认团队配置字段、两套接口、认证头和响应结构（已完成）。
2. 数据模型与配置解析：补充团队上下文模型，增加解析单测。
3. 网络层实现：分别实现团队 `quota/limit` 与 `mcp/usage` 请求，保留个人路径。
4. 展示与容错：将两类数据映射到现有面板，处理缺失、过期和失败保留缓存。
5. 验证、交付与收尾：运行构建/测试，进行真实团队账号手工刷新验证，更新历史记录并归档计划。

## 验证方式

- 命令：
  - `swift build`
  - 已注册测试目标后运行 `swift test`，后台执行超时不超过 60 秒。
- 自动化测试：
  - `team-coding-plan` 能解析 `organizationId`、`projectId`、`productId`。
  - 团队 `quota/limit` URL 包含 `type=2`，并生成组织/项目 Header。
  - 团队 `mcp/usage` 生成 `TEAM`、组织/项目和两个 Bearer 认证 Header。
  - 个人请求不携带团队 Header，不错误追加 `type=2`。
  - `total_usage` 能正确转换为剩余百分比与下次刷新时间。
  - `CREDIT_LIMIT + unit=6` 能映射为周限；旧 `TOKENS_LIMIT + unit=6` 路径保持可用。
  - 个人账号 `TIME_LIMIT + unit=5` 被丢弃，不生成周限；缺失 `unit` 的限额同样丢弃。
  - 网络失败时保留上一次有效快照和缓存。
- 手工检查：
  - 当前 BigModel 团队账号刷新后能显示 `level`、MCP 剩余量以及套餐 5 小时/周限额。
  - 切换到个人 Coding Plan 后仍能使用原有额度路径。
  - 团队账号不显示不适用的个人重置卡；重置状态失败不影响主额度展示。
- 观测检查：
  - 本地调试日志只记录 provider、作用域类型和是否有数据，不记录任何 Token/Key/Secret。
  - 检查刷新频率、快照更新时间和账号切换后的作用域一致性。
- 实际结果与未覆盖场景：
  - `swift test`：136 个测试中首轮收尾测试发现并修正了 API Key 路径断言；随后额度端点专项测试 6/6 通过。
  - 修正后完整 `swift test`：136/136 通过。
  - 尚未对真实团队账号执行网络联调；未覆盖服务端权限变化、项目 API Key 被撤销、组织中存在多个同名项目等外部异常。

## 进度记录

- [x] 确认范围和约束。
- [x] 确认官方 Team 调用链与请求字段。
- [x] 完成团队上下文数据模型与配置解析。
- [x] 完成两套额度接口实现。
- [x] 完成 UI 映射与失败保留缓存。
- [x] 完成验证并记录结果。
- [x] 将明确推迟的事项登记到技术债表，完成归档。

## 决策记录

- 2026-09-19：将 `quota/limit` 和 `mcp/usage` 视为两类独立数据源。前者代表 Coding Plan 套餐限额，后者代表官方 MCP 聚合用量；不能用其中一个替代另一个。
- 2026-09-19：团队请求必须以 `organizationId + projectId` 作为作用域。`productId` 保留在上下文中用于产品识别，但不作为当前已确认的额度请求 Header。
- 2026-09-19：个人与团队认证路径分支处理。个人继续使用 OAuth 额度接口；团队使用项目 API Key/Secret 查询套餐限额，并使用 ZCode JWT + OAuth 查询 MCP 用量。
- 2026-09-19：不在本阶段改造本地日用量数据库；先保证官方额度接口的准确性，再评估是否需要合并展示。
- 2026-09-19：v3 团队账号是积分制，`CREDIT_LIMIT` 表示积分额度；它不会覆盖或替代 v1/v2 的 `TOKENS_LIMIT`。周限窗口编码统一为 `unit=6`，额度类型只决定计费口径，不改变周限展示。
- 2026-09-19：限额窗口只信服务端明确返回的可识别 `unit`。`unit=5` 或缺失 `unit` 时直接丢弃该条限额，不按 `type` / `number` 推断；个人账号因此无周限，Z.AI 周限格显示既有虚线“无限制”空态，5 小时缺失仍显示 "--"。
- 2026-09-19（归档）：用户确认完成验收归档。真实团队账号网络联调仍未执行（会话期间本机 selection 保持在个人套餐），接受为已知边界——后续使用团队套餐时如额度卡片异常可重开计划；“本地日用量口径改造”（原不包含项）已由 server-plan-usage 计划另行完成；本计划无其他明确推迟的债务需要登记。
