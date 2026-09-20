# [2026-09-19 19:32 +0800] | 任务：适配 Z.AI 套餐动态选择语义

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`account:zai-individual-coding-plan/GLM-5.3`
- **Runtime**：ZCode Desktop（macOS 25.6.0 arm64）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 根据会话（sess_3f35e71d-a1c6-40aa-88ba-93215e194900），z.ai 的 plan 不是通过 settings 文件来确认的了，是动态获取，并可以切换的了。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/ZAIQuota.swift`、`Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift`、`docs/exec-plans/`。

**主要操作**：

- **判定优先级翻转**：`ZAISettings.resolveProviderSelection(object:)` 改为「旧版套餐级 `start-plan` 连接标记 > selectedKey 套餐标记 > 连接形态兜底」。ZCode 3.14.0 下 `providerFamilyConnectionSelections` 只表达 individual/team 连接形态；套餐在会话级模型选择器里按会话选择（切换不落盘），setting.json 的 `modelProviderFamilySelectedKeys` 是**默认套餐**（无默认时官方回退第一个 active 的），应用单套餐展示跟随该默认值。
- **团队作用域与套餐 kind 解耦**：org/project 始终从连接形态读取，selectedKey 判定 kind 时团队上下文不再丢失；不可识别的连接值不再外泄到 `connectionKind`。
- **单测**：新增 3.14.0 切换场景（individual 形态 + start-plan key、api-key key 压过残留连接形态、团队作用域保留），旧用例语义不变；`testUnknownConnectionKindFallsBackToLegacyKey` 等更名为 selectedKey 口径。
- **文档**：新建执行计划 `docs/exec-plans/active/zai-dynamic-plan-selection.md`，技术债表登记「多套餐并存展示与权益探测」推迟项。

### 设计动机

调研会话结论与本机实测（当日日志 `account:zai-start-plan` 与 `account:zai-individual-coding-plan` 同时活跃、setting.json zai=individual+coding-plan key）证实旧实现「connectionKind 为准、selectedKey 视为冻结」的 3.12.3 语义已反向。保留 `start-plan` 连接标记优先识别以兼容 3.12.3 旧落盘（3.14.0 连接形态枚举不含它，两代语义无冲突）。不做权益探测驱动的自动回退：资格接口失败 ≠ 无资格，网络抖动会导致面板在套餐间反复横跳。

交付后用户澄清并经 host bundle 核对：切换只在会话级模型选择器、**不落盘**，`modelProviderFamilySelectedKeys` 是默认套餐（无默认时官方回退第一个 active 的）——初版按「切换落点/全局最近值」理解的注释与文档已全部改正（判定逻辑不变，测试复跑通过）。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 176 个测试 0 失败。
- 手工验证及设备：未做 UI 实测（无活跃 start-plan 可切）；本机 setting.json 两种真实形态（zai individual+coding-plan、bigmodel team+coding-plan）的解析已有单测镜像覆盖。
- 未覆盖场景：真机切换套餐后应用不跟随（切换不落盘，属已知口径）；「无默认回退第一个 active」的权益回退未实现，待多套餐展示立项。

### 变更统计

- **统计口径**：`git diff HEAD -- <本次任务文件>` + `--no-index` 对新增文件；工作区还叠加上一个 credit-usage 任务未提交改动（ZAIQuota.swift 内 4 行注释属该任务），已计入下述数字。历史记录自身不计入。
- **变更文件数**：5
- **新增行数**：+161
- **删除行数**：-31

明细：

```text
50	29	Sources/LocalQuotaBar/zcode/ZAIQuota.swift        # 含上一任务 4 行注释改动
55	2	Tests/LocalQuotaBarTests/ZAIProviderSelectionTests.swift
56	0	docs/exec-plans/active/zai-dynamic-plan-selection.md   # 新增
1	0	docs/exec-plans/tech-debt-tracker.md               # 追加 1 行技术债（表格行）
--	--	docs/histories/2026-09/20260919-1932-zai-plan-selection-precedence.md  # 本文件，不计
```
