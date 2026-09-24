## [2026-09-22 19:25 +0800] | 任务：Codex 审查问题修复（idle 状态点与 live 探针参数化）

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64，Apple Swift 6.3.3）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：quota-popup-tabs-redesign（worktree ../LocalQuotaBar-tabs，上游 origin 同名分支）

### 用户诉求

> 验收一下 codex 审核出来的问题，已经修改一轮。
> （验收后确认修复范围）按确认的修改：live probe 加 host 参数、状态点 idle 态、Profile fallback 登记技术债。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/ui/PanelTabBarView.swift`、`Sources/LocalQuotaBar/main.swift`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/`。

**主要操作**：

- **操作一**：CodeBuddy live 探针支持 `LOCALQUOTABAR_CODEBUDDY_LIVE_HOST` 指定目标站点（默认 `www.codebuddy.ai`），Cookie 导入与 `CodeBuddyClient` 均按该 host 构造，国内版链路可随时用真实登录态复核。
- **操作二**：tab 状态点增加 idle 三态：`PanelTabStatus.isIdle`（无快照且无错误）→ `PanelStatusDotView.isIdle`（点体置灰 tertiaryText、光晕不画、呼吸 timer 停跑），五个 provider 的 `tabStatuses()` 全部接线；`PanelTabBarViewTests` 补 idle 断言（含 `isBreathing` 停表断言）。
- **操作三**：多 Chrome Profile fallback 登记技术债（多候选需按候选发真实请求试错且本机仅 Default 一个候选，无法验证，不实现）。
- **操作四**：回填两份执行计划（决策记录 / 实际结果 / 进度）与技术债表。

### 设计动机

Codex 审查遗留两项未修：「未登录 tab 状态点显绿」与「`.cn` 无自动化验证」。idle 采用与面板头部 mini 点相同的 tertiaryText 灰、不呼吸，不引入新口径；live 探针参数化而不是复制第二个探针，两站契约一致仅 host / Referer / region 不同。验收时并实测推翻了 Codex「国内版应分叉旧三接口」的判定——`.cn` 网关接受统一 `get-user-resource`，双站 `otherPackages` 分类零残留。Profile fallback 修复成本（真实请求试错 + 无法验证）高于当前收益，按用户确认留债。

### 验证结果

- 命令与结果：`swift build` 通过；`arch -arm64 swift test` 253 项通过、0 失败（2 项 live 探针默认 skip）；`LOCALQUOTABAR_CODEBUDDY_LIVE=1` 默认站（.ai：8 个有效 Cookie、体验版 100 总量 / 83.05 剩余、3 个奖励包）与 `LOCALQUOTABAR_CODEBUDDY_LIVE_HOST=www.codebuddy.cn`（.cn：9 个有效 Cookie、`CodeBuddy个人体验版` 500 总量 / 162.92 剩余、9 个奖励包）双站 live probe 均通过，两站 `otherPackages` 为空。
- 手工验证及设备：本机 macOS 25.6.0 arm64，`make app` 重建并重启应用（新 PID 51356）；idle 灰点发生在首刷完成前（窗口期短暂），待用户目检。
- 未覆盖场景：idle 态实机目检、Touch Bar / 刘海屏通道（沿用既有未覆盖清单）。

### 变更统计

> 统计口径：基线 HEAD（`57c906a`）→ 工作区未提交改动，仅列本轮触碰文件；同文件中与并行会话的未提交改动无法按提交切分，numstat 为合并值。排除历史记录自身。

- **统计口径**：本轮触碰的 4 个代码 / 测试文件 + 3 份文档；排除历史记录自身与 `Tools/`、`canvas/` 等无关改动。
- **变更文件数**：7（另新增本历史记录）
- **新增行数**：+472（合并口径，含并行会话同文件改动）
- **删除行数**：-161（合并口径）

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/PanelTabBarView.swift` | 194 | 42 |
| `Sources/LocalQuotaBar/main.swift` | 103 | 39 |
| `Tests/LocalQuotaBarTests/PanelTabBarViewTests.swift` | 46 | 2 |
| `Tests/LocalQuotaBarTests/CodeBuddyLiveProbeTests.swift` | 17 | 4 |
| `docs/exec-plans/active/quota-popup-tabs-redesign.md` | 62 | 39 |
| `docs/exec-plans/active/codebuddy-chrome-cookie-quota.md` | 50 | 34 |
| `docs/exec-plans/tech-debt-tracker.md` | 0 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/ui/PanelTabBarView.swift`（idle 三态、`isBreathing` 访问器）
- `Sources/LocalQuotaBar/main.swift`（`tabStatuses()` 五 provider 的 `isIdle` 接线）
- `Tests/LocalQuotaBarTests/CodeBuddyLiveProbeTests.swift`（host 参数化）
- `Tests/LocalQuotaBarTests/PanelTabBarViewTests.swift`（idle 断言）
- `docs/exec-plans/active/quota-popup-tabs-redesign.md`、`docs/exec-plans/active/codebuddy-chrome-cookie-quota.md`、`docs/exec-plans/tech-debt-tracker.md`
