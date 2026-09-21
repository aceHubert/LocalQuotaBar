## [2026-09-21 10:21 +0800] | 任务：切换 Codex 账号后弹确认框并可选立即重启 app-server

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3`
- **Runtime**：`ZCode CLI（macOS darwin 25.6.0 arm64）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 根据 codex-cliproxy 中 restart-codex 来处理一下切换账号后弹出确认框来重启 codex 立即重启的操作，先制定一个方案（方案已落 `docs/exec-plans/active/codex-appserver-restart-on-switch.md`），随后实施该方案。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/`、`Tests/LocalQuotaBarTests/`、`docs/exec-plans/active/`

**主要操作**：

- **新建 `CodexAppServerRestartService`**：移植 codex-cliproxy `stopCodexAppServers`——`ps -ww` 枚举当前用户进程（排除本应用子进程 ppid）、收紧匹配（`codex … app-server` / `codex-code-mode-host`）、双扫 PID 身份复核（pid+uid+lstart+argv）、仅 SIGTERM、等 2 秒终扫报告 stopped/surviving/failed；运行时（listProcesses/terminate/wait）闭包注入，可单测。
- **`main.swift` 接线**：切换账号成功后弹确认框（仿 `confirmResetCardUse`，「取消」为默认按钮）；确认则后台线程执行停止、按结果反馈（状态条 / 未停止 PID 警告弹框 / unknownScan 弹框），完成后强刷额度；取消则仅提示「重启 Codex 后新账号生效」并刷新。新增 `codexRestartInFlight` 期间禁用账号菜单。
- **新增 19 个单测**：匹配表正反例、ps 解析（uid/ppid 过滤、补空格日归一化、argv 读取竞态跳过）、内核 argv（真实子进程读回含空格参数、缓冲区布局解析、畸形拒绝）、停止流程全分支。
- **验收迭代**：按用户手动验证反馈，「取消」路径在面板状态条之外增加信息弹框「已切换账号 / 切换的账号将在 Codex 重启后生效」（右键菜单切换后面板未开，状态条反馈基本不可见）。
- **迭代 2**：按用户质询「技术债为什么没有解决方案」，argv 获取从 `ps -ww` command 列切分升级为内核 `sysctl(KERN_PROCARGS2)` 精确读取（与 codex-cliproxy 一致；Swift `Darwin` 原生暴露 `sysctl`，无需原版 dlopen），含空格参数局限消除、技术债删除。
- **执行计划文档**：本任务方案、进度与决策记录，验收后归档至 `completed/`。

### 设计动机

Codex `app-server` 启动时读取一次 auth，之后不再重读——切换 `~/.codex/auth.json` 后旧进程仍持有旧账号。沿用 codex-cliproxy 的「只停止、不拉起」语义（ChatGPT.app / Codex CLI 自行拉起新进程），安全措施完整移植：收紧匹配防误杀、双扫身份复核防 PID 复用、仅 SIGTERM 不升级 SIGKILL；另加本仓库特有保护——按 `ppid` 排除本应用自己 spawn 的用量读取进程。argv 获取首版曾按空白切分 `ps` command 列（含空格参数无法精确还原，登记技术债），迭代 2 升级为内核 `KERN_PROCARGS2` 后与原实现完全一致、局限消除。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 218 个测试全部通过（199 既有 + 19 新增，无回归；含迭代 2 的内核 argv 测试）。
- 手工验证及设备：本机（darwin arm64）真机进程形态核对——`ps -ww -axo pid=,ppid=,uid=,lstart=,command=` 实际输出与解析器吻合；ChatGPT.app 与 Cursor 扩展持有的 `codex -c features.code_mode_host=true app-server …` 及 `codex-code-mode-host` 均被匹配规则覆盖（4 个进程、同 uid、非本应用子进程）。
- 未覆盖场景：无遗留。2026-09-21 用户手动验收通过（真实切换账号 → 确认框回车默认取消 →「立即重启」与「取消」两路径；取消路径补弹框后复验通过）。

### 变更统计

> 统计口径：任务开始前工作区为基线；仅统计本任务文件（`main.swift` 修改 + 3 个新增文件），排除工作区既有未提交改动（`Tools/render-icon.swift` 删除、`.zcodeignore`、`Tools/render-svg-icon.swift`、`canvas/`、其他 exec-plans 文档）与历史记录自身。

- **变更文件数**：4
- **新增行数**：+874
- **删除行数**：-4

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/main.swift` | 81 | 4 |
| `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift` | 349 | 0 |
| `Tests/LocalQuotaBarTests/CodexAppServerRestartServiceTests.swift` | 327 | 0 |
| `docs/exec-plans/completed/codex-appserver-restart-on-switch.md` | 114 | 0 |

### 修改文件

- `Sources/LocalQuotaBar/main.swift`
- `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift`（新增）
- `Tests/LocalQuotaBarTests/CodexAppServerRestartServiceTests.swift`（新增）
- `docs/exec-plans/completed/codex-appserver-restart-on-switch.md`（新增，验收后由 `active/` 归档）
- `docs/exec-plans/tech-debt-tracker.md`（登记 ps argv 还原局限）
