# Z.AI 套餐动态选择适配（ZCode 3.14.0，错位副本）

- 状态：已取消
- 创建日期：2026-09-19
- 最后更新：2026-09-24

> 2026-09-24 核对：这是位于 `exec-plans/` 根目录的滞后副本，缺少后续 185 / 187 项测试与 release 构建记录。有效计划以 `completed/zai-dynamic-plan-selection.md` 为准；本副本取消并归档，不作为执行依据。

## 目标

ZCode 3.14.0 起 Z.AI 套餐不再由 settings 文件静态锁定，而是动态获取、可在会话级模型选择器中切换；本应用对 `ZAIPlanKind` 的判定要跟随新语义，保证用户切换套餐后额度面板查询正确的数据源，不再出现「切到 start-plan 仍查 coding-plan 额度」或反之的错位。

## 范围

- 包含：`ZAISettings.resolveProviderSelection` 判定优先级修正（selectedKey 回归为默认套餐信号）、**套餐视图手动切换**（状态栏右键菜单「Z.AI 套餐视图」：跟随默认 / Coding Plan / 体验套餐，OAuth 连接才可切）、注释与单测更新。
- 不包含：多套餐同时展示（coding-plan 与 start-plan 并存渲染）、按 billing/balance 动态标注各套餐可用性（已登记技术债，需先收敛 UI 方案）。

## 背景

- 相关文档：调研会话 `sess_3f35e71d-a1c6-40aa-88ba-93215e194900`（结论：host bundle 反编译 + 日志验证）。
- 相关代码路径：`Sources/LocalQuotaBar/zcode/ZAIQuota.swift`（`resolveProviderSelection`）、`Sources/LocalQuotaBar/zcode/ZAIResetContextResolver.swift`、`Sources/LocalQuotaBar/ui/ProviderPanelSections.swift`。
- 新语义（3.14.0，本机 2026-09-19 实测 + host bundle 核对）：
  - 套餐在**会话级模型选择器**（界面）里选择，按 workspace 记忆；**切换不落盘**。
  - setting.json 的 `modelProviderFamilySelectedKeys[domain]` 只是**默认套餐**（无默认时官方回退到第一个权益 active 的套餐）；bundle 中该字段仅被一次性 legacy 迁移（`needsLegacyAccountConnectionMigration`）读取，无切换回写路径。
  - `providerFamilyConnectionSelections[domain].kind` 只区分**连接形态**（`individual-coding-plan` / `team-coding-plan` + 团队 org/project 作用域），不锁定套餐。
  - 多窗口可同时在不同套餐（本机当日日志 `account:zai-start-plan` 与 `account:zai-individual-coding-plan` 同时活跃）。
  - 旧语义（3.12.3）：切换只写 `connectionKind`（可为套餐级 `start-plan`），`selectedKey` 冻结——旧代码即按此实现并以 connectionKind 为准，方向已反。
- 已知约束：per-workspace 选择状态不在 setting.json 中，应用无法得知每个会话各自在用哪个套餐；只能跟随文件里的默认值（且该值不随切换更新，可能滞后）。

## 风险

- 风险：3.12.3 旧落盘形态（connectionKind 写套餐级 `start-plan`、selectedKey 冻结）被新优先级误判为 coding-plan。
- 缓解方式：`start-plan` 作为套餐级连接标记仅存在于旧版本，3.14.0 的连接形态枚举不含它——判定时优先认出该旧标记，再做 selectedKey 优先。
- 风险：文件里的默认 selectedKey 与会话实际所用套餐不一致（切换不落盘、多窗口不同套餐，且默认值可能长期滞后）。
- 缓解方式：接受「跟随默认值」的口径并写入注释；完整解法（多套餐并存的动态展示）推迟为技术债。
- 回滚方式：还原 `resolveProviderSelection` 单函数与对应单测即可，无数据迁移。

## 里程碑

1. 判定优先级修正 + 单测。
2. 套餐视图手动切换（右键菜单）+ 单测。
3. 验证 `swift build` / `swift test`。
4. 多套餐并存展示与动态可用性标注（推迟，另行立项决策）。

## 验证方式

- 命令：`swift build`、`swift test`。
- 手工检查：本机 setting.json 形态（zai individual + coding-plan selectedKey、bigmodel team）解析结果不变；面板仍正常展示 coding-plan 额度。
- 实际结果与未覆盖场景：见进度记录。

## 进度记录

- [x] 确认范围和约束。
- [x] 判定优先级修正与单测。
- [x] 完成验证并记录结果（`swift build` 通过；`swift test` 176 个测试全部通过；本机 setting.json 形态解析回归：zai individual + coding-plan、bigmodel team + coding-plan，均与面板现状一致）。
- [x] 将明确推迟的事项登记到技术债表（多套餐并存展示与权益探测）。
- [x] 阶段 2：套餐视图手动切换（右键菜单三选项 + 有效 selection 注入 + 5 个新单测，`swift test` 180 全绿）。
- 2026-09-19 修正：按用户澄清改正全部「切换落盘/全局最近值」表述（代码注释、测试命名、本计划、历史记录、技术债表），判定逻辑本身不变，`swift test` 复跑通过。
- 未覆盖场景：真机切换视图后的面板表现已具备（`make run` 重启验证由用户执行）；多套餐并存与动态可用性标注未实现（技术债）。
- [x] 2026-09-24：确认是滞后错位副本，取消并归档；有效记录见 `completed/zai-dynamic-plan-selection.md`。

## 决策记录

- 2026-09-19：采用「旧版套餐级 `start-plan` 连接标记 > selectedKey 套餐标记 > 连接形态兜底」的优先级。理由：3.14.0 里连接形态不含 start-plan，该标记只可能是旧版语义残留，认出它不影响新版；连接形态兜底覆盖 selectedKey 缺失/无套餐信息的场景。团队作用域（org/project）始终从连接形态读取，与套餐 kind 正交。
- 2026-09-19（修正）：用户澄清 + bundle 核对——切换只在会话级模型选择器、不落盘，`modelProviderFamilySelectedKeys` 是**默认套餐**（无默认时官方回退第一个 active 的），此前按「切换落点/全局最近值」理解的表述已全部改正。代码优先级不变：单套餐展示跟随默认值仍是当前最优解。
- 2026-09-19（阶段 2）：用户账号同时具备 coding-plan 与 start-plan 资格、zcode 不再提供「当前套餐」信号，新增**应用侧手动切换**：`ZAIPlanViewOverride` 偏好（UserDefaults）+ `applyingPlanView` 叠加到 `resolveProviderSelection()`（无参版返回有效选择，额度/面板/重置/用量全链路生效）+ 右键菜单「Z.AI 套餐视图」。override 仅在两个 OAuth 套餐间生效（api-key 连接不受影响）；teamContext 原样保留，start-plan 查询不使用它，来回切换不丢团队作用域。切换后 `refreshAfterPlanViewChange()` 立即按新视图重查（查询中排队），`recomputeZAIUsage()` 同步重算用量口径。菜单每次右键现建，勾选态天然即时。
- 2026-09-19（阶段 2 调整）：按用户反馈菜单精简为两项「Coding Plan（订阅）/ Start Plan（免费）」，去掉「跟随默认」选项；勾选态直接取当前有效视图（无 override 时即文件默认套餐），`ZAIPlanViewSettings.load` 改为可空（nil = 跟随文件默认，旧值 followFile 自然回退 nil）。
- 2026-09-19（阶段 2 定稿）：菜单改为**三选项动态展示**——Start Plan（免费）/ Coding Plan（个人订阅）/ Coding Plan（团队订阅），账号有几个显示几个（可能 3/2/0 项）。可用性按接口探测：start-plan = 当日日志 billing/balance plans[] 有 active 条目；个人订阅 = api.z.ai subscription/list 非空（裸 OAuth token）；团队 = setting.json 团队连接 + getCustomerInfo 校验 org/project。探测结果三态（true/false/nil 未知），未知按可用展示防网络抖动藏入口，明确不可用则隐藏；每刷新周期探测一次并缓存 UserDefaults。团队 override 通过 `teamSelection(object:)` 跨 domain 取 bigmodel 团队连接（含 org/project），无团队连接时无效。
- 2026-09-19（探测直连化 + 换号感知）：用户指正后三点调整——① start-plan 探测从"读 zcode 日志"改为**应用直连 billing/balance 优先**（套餐 JWT + deviceMid，与快照查询同形态），仅网关拦截时回退当日日志，zcode 不在跑也能探测；② 可用性缓存**按账号邮箱失效**，zcode 换号后旧账号的探测结果不作数；③ 监听 credentials.json / setting.json 文件写入（换号、改连接、改默认套餐都会重写），防抖 1 秒立即重查额度 + 可用性，不等下个刷新周期。探测本身随每次刷新周期执行（定时/手动/切换后均触发），与额度同周期更新。
- 2026-09-19（官方口径对齐）：按 `docs/research/2026-09-19-zcode-plan-availability-gating.md` 修正判定谓词——个人订阅从「data 非空」改为 KI 三条件（产品含 coding + VALID + inCurrentPeriod，形状失败降级 unknown）；团队在第 3 层 customerInfo org/project 之外补第 5 层 `querySubscribeDetail`（EFFECTIVE+VALID 才可用，hasSubscription=false / EXPIRED / UNASSIGNED 不可用，其余 unknown）；bigmodel 团队探测不再借 zai 凭证（官方同 token 视为未连接）；start-plan 标识补 "start start" 容忍。菜单探测口径自此与 host 完全一致。
- 2026-09-19（定稿·文件判定法）：按用户指示改用 **codex-cliproxy 的文件判定法**（`src/zcode/config.ts` 的 readZcodePlanSelections 槽位逻辑）——右键菜单可选项由 setting.json 连接形态槽位即时判定：start-plan 永远可选（连接形态无关，资格由 billing/balance 在额度查询时判定、上游最终拒绝）；个人订阅 ⇔ 任意渠道连接形态 individual-coding-plan（legacy 回退看默认选择）；团队 ⇔ 存在 team-coding-plan 连接（含 org/project）。**每次右键现读文件**，不再做网络探测、不进定时刷新周期；上一轮的 subscription/list / querySubscribeDetail / customerInfo / billing/balance 网络探测与可用性缓存全部移除（git 历史与调研文档留档）。语义变化：槽位存在只代表「配置过连接」，切过去后权益无效会在面板报错，不再提前隐藏菜单项。文件监听（换号/改配置触发额度重查）保留。
- 2026-09-19（团队槽位修正）：用户反馈「没有团队 plan 却显示团队项」。纯文件信号补齐：团队槽位在连接形态外叠加 config.json 的 provider 停用标记（`enabled=false` 或 `systemDisabledReason` 非空，如 `oauth_provider_inactive` = 该渠道未真正登录）——本机 `builtin:bigmodel-coding-plan` 即被 host 标记停用，团队项正确隐藏。start-plan 的 provider 镜像标记不采用（codex-cliproxy 注释明确其可能冻结；本机 Weekend Build active 但标记却是 not_entitled），保持永远可选、查询时上游裁决。个人项同理不叠加（避免镜像冻结误伤有效订阅）。
- 2026-09-19：不做服务端权益探测驱动的自动回退（资格接口失败 ≠ 无资格，网络抖动会导致面板在套餐间反复横跳），探测仅作为后续多套餐展示的输入。
