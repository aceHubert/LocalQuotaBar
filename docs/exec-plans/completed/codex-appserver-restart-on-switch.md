# 切换 Codex 账号后弹确认框并可选立即重启 Codex app-server

- 状态：已完成
- 创建日期：2026-09-21
- 最后更新：2026-09-21（用户验收通过，归档）

## 目标

在右键菜单「Codex账号切换」切换账号成功后，弹出确认框询问是否「立即重启 Codex」；用户确认时，参照 codex-cliproxy `restart-codex` 的做法安全地停止当前用户的 Codex `app-server` 进程（精确匹配 + 双扫身份复核 + 仅 SIGTERM），让 ChatGPT.app / Codex CLI 自行拉起新进程并读取切换后的 `~/.codex/auth.json`，使新账号真正生效。

## 范围

- 包含：
  - 新建 `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift`：移植 codex-cliproxy 的进程枚举、匹配与停止流程，无状态、依赖可注入、可单测。
  - `main.swift` 接线：切换成功后的确认弹框（仿 `confirmResetCardUse` 模式，取消为默认按钮）、`accountMenuItemSelected` 流程改造、结果状态反馈、重启进行中禁用账号菜单。
  - 单元测试 `Tests/LocalQuotaBarTests/CodexAppServerRestartServiceTests.swift`。
- 不包含：
  - 主动拉起替代进程（与 codex-cliproxy 口径一致：只负责停止，Codex 客户端自行重启）。
  - 重启整个 ChatGPT.app（NSWorkspace/AppleScript 均不引入，本项目无先例且影响面更大）。
  - 「不再提示」偏好或设置项（每次切换都询问，保持简单；后续有需要再立项）。
  - Z.AI / BigModel 套餐切换的类似机制。

## 背景

- 相关文档（codex-cliproxy 仓库）：
  - `src/app-server.ts`：`isCodexAppServerProcess`（:57-78，进程匹配）、`terminateSystemProcess`（:277-289，POSIX 仅 SIGTERM）、`stopCodexAppServers`（:315-367，双扫身份复核 + 发信号 + 等 2 秒终扫）。
  - `src/cli.ts`：`refreshCodexAppServer`（:543-554，`--restart-codex` flag 的入口与文案口径）。
  - `docs/codex-app-server-restart-policy.md`：完整重启策略（触发条件、进程匹配、停止策略、PID 身份保护）。
- 相关代码路径（本仓库）：
  - `Sources/LocalQuotaBar/main.swift`：`CodexAuthManager.switchAccount`（:195-228，原子替换 `~/.codex/auth.json`）、`accountMenuItemSelected`（:1830-1841，切换入口，当前无确认框与重启）、`confirmResetCardUse`（:1447-1457，二次确认弹框模式，取消为默认按钮）、`presentResetResultAlert`（:1459-1469，结果弹框模式）、`CodexRateLimitClient`（:483 起，每次刷新 spawn `codex app-server` 读取额度）。
  - `Sources/LocalQuotaBar/codex/CodexUsage.swift`：另一处 spawn `codex app-server`（官方日用量读取）。
  - `Sources/LocalQuotaBar/codex/CodexResetService.swift`：无状态依赖注入服务的组织方式参考。
- 行为依据：Codex `app-server` 进程启动时读取一次 auth/配置，之后不再重读——切换 `auth.json` 后旧进程仍持有旧账号，必须停止后由 Codex 客户端重新拉起。本应用自身的额度读取不受影响（每次刷新新 spawn 进程、即时读取新 `auth.json`），因此重启针对的是外部 Codex 客户端持有的 app-server 进程。
- 已知约束：本项目此前只终止过自己 spawn 的子进程，终止外部进程属首例；AppKit 侧确认框沿用同步 `runModal()`（与重置卡一致）。

## 方案要点

### 1. `CodexAppServerRestartService`（新文件，`codex/` 目录）

- **枚举**：用 `Foundation.Process` 跑 `/bin/ps -ww -axo pid=,ppid=,uid=,lstart=,command=`（环境 `LC_ALL=C`）取当前用户进程快照，过滤 `uid == getuid()`，并排除 `ppid == getpid()`——本应用自己 spawn 的用量读取进程（`CodexRateLimitClient` / `CodexUsageClient`）不能被误杀。command 列不参与解析，每行再用内核 `sysctl(KERN_PROCARGS2)` 读取精确 argv（与 codex-cliproxy 完全一致；`Darwin` 模块原生暴露 `sysctl`，无需原版的 dlopen ffi）。
- **匹配**（移植 `isCodexAppServerProcess`，刻意收紧、不用宽泛 `*codex*`）：
  - argv[0] 文件名（小写）为 `codex`（或 Windows 变体）或匹配 `^codex-(aarch64|x86_64)-apple-darwin…` target-triple 形式，且跳过全局参数（`GLOBAL_FLAGS` / `GLOBAL_OPTIONS_WITH_VALUE` 及其值、`-x value` 短选项、`--opt=value`）后第一个子命令为 `app-server`；`--` 之后下一个参数是 `app-server` 也算。
  - 或 argv[0] 文件名为 `codex-code-mode-host`。
- **停止流程**（移植 `stopCodexAppServers`）：
  1. 初扫得到候选；为空 → `.noneFound`。
  2. 立刻二扫，pid+uid+lstart+argv 全等（`sameIdentity`）复核才发信号，防 PID 复用误杀；不一致 → 该 PID 记 `failed`。
  3. `kill(pid, SIGTERM)`，绝不升级 SIGKILL。
  4. 发过信号则等 2 秒终扫：同 pid 同身份仍在 → `surviving`，否则 `stopped`。
  5. 枚举抛错 → `.unknownScan(message)`，不当作「无进程」。
  - 返回 `CodexAppServerRestartOutcome`（如 `stopped(pids:)` / `noneFound` / `partial(surviving:failed:)` / `unknownScan(String)`）；`listProcesses` / `terminate` / `wait` 以闭包注入便于单测。
- **argv 获取的演进**：首版为有意简化，直接按空白切分 `ps -ww` 的 command 列（当时判断现有 codex 命令形态不含空格参数、sysctl 移植成本偏高，登记为技术债）；归档后按用户质询升级为内核 `sysctl(KERN_PROCARGS2)` 精确读取，局限消除、技术债删除。

### 2. `main.swift` 接线

- 新增 `confirmRestartCodexAfterSwitch(label:) -> Bool`，仿 `confirmResetCardUse`：`.warning` 样式；messageText「立即重启 Codex？」；informativeText「已切换到 <label>。将停止当前用户的 Codex app-server 进程（正在执行的任务可能被中断），Codex 会自动拉起新进程并使用新账号。」；按钮「取消」（第一个、默认，回车即取消防误触）/「立即重启」。
- `accountMenuItemSelected` 改造（切换成功后）：
  - 确认 → `showAccountSwitchStatus("已切换账号，正在重启 Codex…")`，`Task` 中异步执行停止（ps/kill/等待不阻塞主线程），完成后按结果显示：全部停止 → 状态条「已停止 N 个 Codex app-server，Codex 重新拉起后新账号生效」；未发现进程 → 状态条提示；有 surviving/failed → 仿 `presentResetResultAlert` 弹 warning（列出未停止 PID，建议手动重启 ChatGPT.app）。随后 `store.refresh(force: true)`。
  - 取消 → 状态条「已切换账号，重启 Codex 后新账号生效」，仍执行 `store.refresh(force: true)`（本应用读取即时生效）。
- 仿 `resetRequestInFlight` 增加重启进行中标记，期间禁用账号子菜单项，避免并发切换/重启。

### 3. 单元测试（纯逻辑，注入 fake）

- ps 输出解析：uid 过滤、ppid 排除自身子进程、lstart 提取。
- 匹配表：`codex app-server` ✓、`codex-aarch64-apple-darwin app-server` ✓、全局参数后接 `app-server` ✓、`codex-code-mode-host` ✓、`codex exec` ✗、其他用户进程 ✗、本应用子进程 ✗。
- 停止流程：二扫身份不一致 → `failed`；SIGTERM 后进程消失 → `stopped`；仍在 → `surviving`；枚举抛错 → `unknownScan`。

## 风险

- 风险：误杀无关进程（本项目首次终止外部进程）。
- 缓解方式：收紧的匹配规则（可执行名 + `app-server` 子命令 / `codex-code-mode-host`）+ 双扫 PID 身份复核（pid+uid+lstart+argv 全等）+ 仅 SIGTERM 不 SIGKILL + `ppid` 排除自身子进程；确认框文案明确警示、取消为默认按钮。
- 风险：中断正在执行的 Codex 任务（app-server 被 SIGTERM 会打断活跃 turn）。
- 缓解方式：弹框属用户主动确认，informativeText 明示「正在执行的任务可能被中断」。
- 风险：argv 获取不准确导致漏判/误判。
- 缓解方式：argv 由内核 `KERN_PROCARGS2` 读出（首版 `ps` command 列切分的含空格参数局限已在归档后消除）；读取失败的行按竞态跳过；畸形缓冲区（argc 越界、条目缺失）直接判否。
- 回滚方式：移除 `accountMenuItemSelected` 中的确认框与 Task 调用、删除新文件与测试即可，无数据迁移、无持久化状态。

## 里程碑

1. 新建 `CodexAppServerRestartService`（枚举/匹配/停止流程）+ 单测。
2. `main.swift` 接线（确认弹框、切换流程改造、状态反馈、in-flight 保护）。
3. 验证：`swift build`、`swift test`、真机手动验证。
4. 收尾：历史记录、必要的技术债登记、计划归档至 `completed/`。

## 验证方式

- 命令：`swift build`；`swift test`（后台运行设 60 秒超时）。
- 手工检查：
  - 右键菜单切换账号 → 弹确认框，回车默认为「取消」（不误触重启）。
  - 选「立即重启」：`ps -ww -axo pid=,ppid=,uid=,command= | grep app-server` 确认本用户 Codex app-server 被 SIGTERM、本应用自己 spawn 的读取进程不受影响、ChatGPT.app 重新拉起 app-server、面板刷新出新账号额度。
  - 选「取消」：弹信息框「已切换账号 / 切换的账号将在 Codex 重启后生效」（面板状态条同步提示），额度仍立即刷新。
  - 无运行中 app-server 时切换：状态条提示未发现进程，无报错。
- 观测检查：切换后 `~/.codex/auth.json` 为新账号；重启进行中账号菜单项禁用；结果状态条/弹框文案正确。
- 实际结果与未覆盖场景：
  - `swift build` 通过；`swift test` 213 个测试全部通过（199 既有 + 14 新增），新增 14 个覆盖匹配表、ps 解析（uid/ppid 过滤、lstart 补空格日归一化）、停止流程（noneFound/stopped/surviving/PID 复用/身份变化跳过信号/terminate 抛错/枚举失败 unknownScan）。
  - 真机进程形态核对：本机实际存在 `codex -c features.code_mode_host=true app-server --analytics-default-enabled`（ChatGPT.app 与 Cursor 扩展各持）与 `codex-code-mode-host`（app-server 子进程），均被匹配规则覆盖，`ps` lstart 5 列格式与解析器吻合。
  - 2026-09-21 用户手动验收通过：真实切换账号 → 确认框（回车默认取消）→「立即重启」与「取消」两路径均验证；取消路径按验收反馈补了「已切换账号 / 切换的账号将在 Codex 重启后生效」信息弹框后复验通过。无遗留未覆盖场景。

## 进度记录

- [x] 确认范围和约束。
- [x] 里程碑 1：`CodexAppServerRestartService` + 单测。
- [x] 里程碑 2：`main.swift` 接线。
- [x] 里程碑 3：完成验证并记录结果。
- [x] 里程碑 4：历史记录、技术债登记、归档。（ps argv 局限初登记技术债，后按用户质询升级为 KERN_PROCARGS2 内核读取，验证后删除该债；历史记录已更新验收结果）

## 决策记录

- 2026-09-21：采用 codex-cliproxy 的「只停止、不拉起」语义。理由：app-server 退出后 ChatGPT.app / Codex CLI 会自行重新拉起并重读配置（codex-cliproxy 生产验证过的口径），主动拉起反而引入管理他人进程生命周期的复杂度；本应用自身读取不受旧进程影响。
- 2026-09-21：进程枚举用 `ps -ww` command 列而非 sysctl `KERN_PROCARGS2`。理由：Swift 下 sysctl 方案需大量 unsafe 指针代码，`ps -ww` 已不截断且对 `codex app-server` 命令形态解析可靠；局限（含空格参数不可还原）登记为已知局限。
- 2026-09-21：以 `ppid == getpid()` 排除本应用自己 spawn 的 app-server 进程。理由：`CodexRateLimitClient` / `CodexUsageClient` 每次刷新都会拉起同名进程，刷新进行中切换账号时不能被误杀；按父进程判断比维护 PID 登记表更可靠。
- 2026-09-21：确认框「取消」为第一个（默认）按钮。理由：与 `confirmResetCardUse` 既有防误触模式一致——重启会中断正在执行的 Codex 任务，回车应默认保守动作。
- 2026-09-21（实施）：停止结果枚举定为 `finished(stopped:notStopped:) / noneFound / unknownScan(String)`（计划中的 `partial` 并入 `finished`，语义为“流程正常走完”，未停止 PID 单列）。理由：UI 只需区分“全部停止 / 有未停止 / 无进程 / 状态未知”四态，`finished` 携带两个 PID 列表即可表达部分失败，无需第三个 case。二扫失败时不再像 codex-cliproxy 那样把初扫 PID 逐个标记为 failed 再抛错，直接返回 `unknownScan(message)`，弹框提示用户手动重启。
- 2026-09-21（迭代）：按用户手动验证反馈，「取消」路径在面板状态条之外增加信息弹框「已切换账号 / 切换的账号将在 Codex 重启后生效」。理由：右键菜单切换后面板通常未打开，状态条反馈基本不可见且会在下次刷新成功后自动清除；取消意味着新账号尚未对 Codex 客户端生效，需要明确告知用户，避免误以为已生效。
- 2026-09-21（迭代 2）：按用户质询「技术债为什么没有解决方案」，把 argv 获取从 `ps -ww` command 列切分升级为内核 `sysctl(KERN_PROCARGS2)` 精确读取——与 codex-cliproxy 完全一致，且 Swift `Darwin` 模块原生暴露 `sysctl`，不像原版要 dlopen ffi，当时“成本偏高”的判断不成立。ps 只负责 pid/ppid/uid/lstart 快照，command 列不再参与解析；新增测试覆盖真实子进程 argv 读回（含空格参数）、构造缓冲区布局解析、畸形缓冲区拒绝、含空格参数的正反匹配。技术债条目按「验证依据补齐后删除」规则移除。
