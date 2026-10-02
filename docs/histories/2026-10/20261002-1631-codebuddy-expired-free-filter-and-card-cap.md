## [2026-10-02 16:31 +0800] | 任务：CodeBuddy 奖励包过滤过期项并封顶明细卡高度

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：GLM-5.3（zai-start-plan/GLM-5.3-Flash）
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 把 codebuddy 下面的奖励包中的过期的过滤掉，并且加一个最大高度，不然会超过屏幕高度了。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`（codebuddy / ui / main.swift）、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **操作一**：`CodeBuddyPackage` 新增 `isExpired(now:)`：`expiredTime` 优先、回退 `cycleEndTime`，已过即失效；无到期时间的条目不参与该判断（不丢数据）。
- **操作二**：`CodeBuddyPanelSection.apply` 组装 chips 前过滤过期奖励包；全部过期时「奖励包」chip 整体消失，与空态口径一致。购买积分（paid）按用户诉求不参与过滤。
- **操作三**：tab 摘要「资源包 X/Y 积分」同步同一过滤口径（`main.swift`），避免面板不展示的过期包仍被计入合计。
- **操作四**：`ResetCardsRow` 新增可选 `maxCardListHeight`：设置后明细卡内容包进 `NSScrollView`，高度封顶、超出卡内滚动；内容不足时经低优先级（999）底部约束仍按实际高度自适应。仅 CodeBuddy 区块启用（220pt），Codex / ZAI 的实例保持 `nil` 不变。

### 设计动机

- 过期奖励包的剩余积分已不可用，继续展示既挤占面板又虚增「资源包剩余」合计；过滤收敛在展示层（`apply` 与 tab 摘要），数据层快照保持完整，后续如需「历史包」入口可随时恢复。
- 高度封顶做在 `ResetCardsRow` 通用层但默认关闭，是为了不把 CodeBuddy 特有的「历史奖励包堆积」问题外溢给行为已定稿的 Codex / ZAI 区块。
- `NSScrollView` 自适应高度的关键取舍：documentView 只钉左上与宽度，底部用 `lessThanOrEqualTo` + 优先级 999——内容矮于上限时它把 scroll view 撑到内容高度，超出上限时让位给 required 的 maxHeight，软约束被弃算即自然进入滚动，无需手动计算内容高度。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 265 项、0 失败、2 项 live 探针按默认配置跳过（改动前 262 项，新增 3 项：`isExpired` 口径、面板过滤过期奖励包、明细卡封顶滚动）。
- 封顶行为单测断言：上限 60pt 时 card 高度 ≤ 上限 + 8pt 内边距、documentView 高于视口（可滚动）、6 行明细仍完整在视图层级；不设上限的实例无滚动容器、按内容自然撑高。
- 手工验证及设备：未做实机 popover 目检（需要真实 CodeBuddy 登录态与菜单栏环境），待用户刷新后确认。
- 未覆盖场景：① 面板实机目检；② 国际版 / 国内版真实奖励包数据的展示效果（单测用构造快照）；③ 大量购买积分（paid）包堆积的场景本次未封顶外溢验证（同用 `maxCardListHeight`，行为一致）。

### 变更统计

> 统计口径：未提交状态，基线 `HEAD`（0db1ec2），仅统计本次任务改动的 6 个文件；`git diff -- Sources Tests`。已排除任务前既有的未跟踪项（`.zcodeignore`、`canvas/`）与历史记录自身。

- **变更文件数**：6
- **新增行数**：+135
- **删除行数**：-9

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift` | 37 | 7 |
| `Tests/LocalQuotaBarTests/CodeBuddyParsingTests.swift` | 50 | 0 |
| `Tests/LocalQuotaBarTests/ResetCardsRowTests.swift` | 33 | 0 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyModels.swift` | 5 | 0 |
| `Sources/LocalQuotaBar/ui/CodeBuddyPanelSection.swift` | 8 | 1 |
| `Sources/LocalQuotaBar/main.swift` | 2 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/codebuddy/CodeBuddyModels.swift`
- `Sources/LocalQuotaBar/ui/CodeBuddyPanelSection.swift`
- `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift`
- `Sources/LocalQuotaBar/main.swift`
- `Tests/LocalQuotaBarTests/CodeBuddyParsingTests.swift`
- `Tests/LocalQuotaBarTests/ResetCardsRowTests.swift`
