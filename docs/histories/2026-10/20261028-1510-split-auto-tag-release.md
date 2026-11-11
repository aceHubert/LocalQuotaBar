## [2026-10-28 15:10 +0800] | 任务：拆分 auto-tag 与 release 双工作流（PAT/dispatch 双通道）

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`zai-api/GLM-5.3`
- **Runtime**：`ZCode Desktop（Bash + computer-use 混合操作）`
- **Git User**：`hubert <hubert@lejian.com>`（提交 `6500c1f` 由用户审核后自行完成）
- **Branch**：`main`

### 用户诉求

> 参考 codex-cliproxy 仓库的 actions 配置，看它如何在默认 GITHUB_TOKEN 推 tag 不会触发另一个 workflow 的限制下手动触发 action；按该模式改造，添加后不提交、待审核确认。

### 变更概览

**影响范围**：`.github/workflows/`。

**主要操作**：

- **新增 `.github/workflows/auto-tag.yml`**：push main 触发（paths-ignore 排除 docs 与 markdown），按 Conventional Commits 计算版本并打 tag。双通道照搬 codex-cliproxy `deploy.yml`：`HAS_RELEASE_PAT: ${{ secrets.RELEASE_PAT != '' }}` 在 env 固化 secrets 判断；checkout 用 `token: ${{ secrets.RELEASE_PAT || github.token }}`——有 PAT 时 tag 事件直接触发 Release，无 PAT 时 tag 用 GITHUB_TOKEN 推送后以 `gh workflow run release.yml -f tag=...` 主动 dispatch（workflow_dispatch 是防递归的官方例外，GITHUB_TOKEN 亦可发起），需要 `actions: write` 权限。
- **重写 `.github/workflows/release.yml`**：仅保留 `push: tags` 与 `workflow_dispatch(inputs.tag)` 双入口；`concurrency` 按 tag 分组且 `cancel-in-progress: true`（同 tag 双触发只留最后一次）；手动输入的 tag 经 env 传入脚本防注入；checkout `ref: ${{ env.TAG }}` 统一检出目标。构建步骤（make app / plutil 注入 / ad-hoc 签名 / ditto / softprops）不变。

### 设计动机

上一版单工作流虽已验证可用，但发布链路耦合：重发版本只能整体重跑。codex-cliproxy 已验证的双通道模式将「打 tag」与「构建发布」解耦为两个独立 workflow，且不依赖 PAT 也能全自动（无 PAT 走 dispatch 兜底），职责与 codex-cliproxy 的 deploy → github-release 对齐。

### 验证结果

- 命令与结果：提交 `6500c1f` 推送后 Auto Tag run 40645672033 成功，自动创建 tag `v0.1.2` 指向该提交，并 dispatch Release run 40645688008 成功发布（asset `LocalQuotaBar-0.1.2.zip`）；随后 `533f2ca` 再走一遍全链路，`v0.1.3` 发布并标记 Latest（run 40646957026 / 40646968178）。
- 手工验证及设备：本机下载 Release 产物确认设置页版本号与 tag 一致（CFBundleShortVersionString 由 release.yml plutil 注入）。
- 未覆盖场景：配置 `RELEASE_PAT` 后的 PAT 直触发通道（当前走 dispatch 兜底）；新架构下 docs-only 推送经 paths-ignore 完全不触发 Auto Tag（`7b5fd2c` 那次 skip 是旧版单工作流行为，run 40628330379 success 未产出 release）。

### 变更统计

- **统计口径**：基线 7b5fd2c..6500c1f，仅统计拆分提交（用户完成），排除历史记录自身。
- **变更文件数**：2
- **新增行数**：+87
- **删除行数**：-71

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `.github/workflows/auto-tag.yml` | 74 | 0 |
| `.github/workflows/release.yml` | 13 | 71 |

### 修改文件

- `.github/workflows/auto-tag.yml`（新增）
- `.github/workflows/release.yml`
