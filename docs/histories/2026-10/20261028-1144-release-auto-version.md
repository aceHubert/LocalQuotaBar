## [2026-10-28 11:44 +0800] | 任务：发版工作流支持按提交类型自动递增版本

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`zai-api/GLM-5.3`
- **Runtime**：`ZCode Desktop + computer-use（终端操作）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 加上自动打 tag；并确认：使用 GITHUB_TOKEN 是否不会触发另一个 action。

### 变更概览

**影响范围**：`.github/workflows/release.yml`。

**主要操作**：

- **确认 GITHUB_TOKEN 限制**：GITHUB_TOKEN 触发的事件（push tag、创建 release 等）不会触发其他 workflow，仅 workflow_dispatch / repository_dispatch 例外。因此放弃独立的 auto-tag.yml，把版本递增并入 release.yml，单次运行内完成打 tag 与发布。
- **release.yml 重写**：触发扩展为 main 推送 / 手动 v* tag / 手动 dispatch；prepare 作业按 Conventional Commits 计算 bump（`type!:` → major，`feat:` → minor，其余 → patch），仅 docs 或 markdown 改动时置 skip=true 跳过发布；release 作业构建后用 softprops 的 tag_name + target_commitish 在触发提交上自动建 tag 并发布。
- **修复表达式引号**：GitHub 表达式字符串字面量只接受单引号，`!= "true"` 导致整份 workflow 解析失败（run 秒失败且无注解，最终靠 dispatch API 的 422 报错定位），改为 `!= 'true'`。

### 设计动机

GITHUB_TOKEN 防递归机制使"auto-tag 打 tag → 触发 release"两段式链路失效；合并为单工作流后该机制反而成为防死循环的保障（自动建的 tag 不会再触发自身）。docs-only 提交仍会排队跑 prepare（ubuntu，秒级）但不进入 macos 构建。

### 验证结果

- 命令与结果：run 40627947277 成功（prepare 4s + release 1m12s）；自动创建 tag v0.1.1 指向 5084c4f；`gh release view v0.1.1` 确认 asset `LocalQuotaBar-0.1.1.zip` 且为 Latest；run 列表确认自动发布的 tag/release 未再次触发工作流（无递归）。
- 手工验证及设备：本机 Apple Silicon；v0.1.0..HEAD 仅 docs 提交时本地演算 CODE_FILES 为空、走 skip 分支；本历史文档推送用于验证 skip 分支的远端行为。
- 未覆盖场景：Intel 架构产物、Developer ID 签名与公证、feat/breaking 提交的实际 bump 路径（规则已本地演算）、手动 tag 路径回归（逻辑与 v0.1.0 版一致，仅版本来源改为通用表达式）。

### 变更统计

- **统计口径**：基线 2257e5e..5084c4f，仅统计本任务两笔提交，排除历史记录自身。
- **变更文件数**：1
- **新增行数**：+74
- **删除行数**：-2

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `.github/workflows/release.yml` | 74 | 2 |

### 修改文件

- `.github/workflows/release.yml`
