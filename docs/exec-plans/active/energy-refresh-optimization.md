# 降低后台刷新耗电：Codex 拉取去 spawn 化与调度错峰

- 状态：进行中
- 创建日期：2026-10-20
- 最后更新：2026-10-22（跨天观测发现 EOF 自旋回归，已修复并回归测试；最终跨天电池面板复查仍待）

## 目标

消除应用被 macOS 判定「使用大量能耗」的主因：把 Codex 额度/用量读取从「每次刷新 spawn 一个 app-server 子进程」改为复用自持的常驻子进程，把 5 个后台刷新定时器错峰并加 tolerance，降低周期性 CPU 突发与唤醒次数，使后台平均 CPU 回到接近 0%、系统设置电池页不再列出本应用。

## 范围

- 包含：
  - 新建 `Sources/LocalQuotaBar/codex/CodexAppServerSession.swift`（名称可调）：自持常驻 `codex app-server --listen stdio://` 子进程会话，`CodexRateLimitClient`（rateLimits / account/read / reset consume）与 `CodexUsageClient`（usage/read）全部改走该会话。
  - 会话生命周期管理：懒启动、EOF/异常自动重拉、账号切换后强制重建、应用退出时 SIGTERM。
  - 定时器错峰：5 个持定时器的 store（Codex / ZAI / DeepSeek / CodeBuddy 国际 / CodeBuddy 国内）的 `Timer` 增加互不相同的固定相位偏移与 `tolerance`，改刷新档位（`setRefreshInterval`）后保持偏移。
  - （第二阶段，可选）DeepSeek token / CodeBuddy cookie 的 Chrome 导入结果缓存：启动/手动刷新/鉴权失败时才重新导入。
- 不包含：
  - 连接外部 codex 官方 `app-server-daemon`（`~/.codex/packages/app-server-daemon/...`，unix socket 由 codex CLI 管理，路径与协议随版本漂移且不保证常驻）——作为 M0 调研中的对照项，除非调研推翻结论。
  - 刷新档位调整——已于 2026-10-20 单独落地：档位表移除 1、2 分钟，下限提高至 5 分钟（见 `docs/histories/2026-10/20261020-1344-refresh-interval-floor-5min.md`），不再属于本计划范围。
  - 面板打开期间的 30fps 呼吸光晕（`PanelTabBarView.swift`）与 15 秒相对时间定时器（`main.swift:2328`）：仅面板可见时运行，已确认非后台耗电来源，不动。
  - ZAI / DeepSeek / CodeBuddy 的网络请求本体（按 interval 拉取是产品行为，只做错峰与导入缓存）。

## 背景

### 耗电诊断结论（2026-10-20 实测）

- 进程自周四 9:00 启动至当日 12:00 累计 **202 分钟 CPU 时间**（平均约 4-5%；菜单栏应用正常应接近 0%），`top` 采样在 0% 与 10-11% 之间周期性跳变；用户系统设置电池页截图显示本应用「使用大量能耗」。
- **主因**：`main.swift:494-527` `CodexRateLimitClient.readAppServerResultsBlocking` 每次调用 `Process()` 启动 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex app-server --listen stdio://`（shell 包装脚本，`exec` 到 CodexCLI.app 内约 65MB 的 codex 二进制），完成 stdio JSON-RPC 握手后发起实时网络请求（实测 2~15 秒），再 SIGTERM。后台抓到两次 spawn：11:55:02 与 12:00:02，正好 5 分钟一个 tick，子进程启动瞬间 CPU 13-17%。默认档位下每天 288 次起停；档位调到 1 分钟则 1440 次。`CodexUsageClient`（30 分钟一次官方日用量）是第二处同模式 spawn。
- **次因**：5 个持定时器的 store 在启动时一并调度、间隔相同（另有 Codex 官方日用量拉取挂在 Codex 刷新回调上，30 分钟节流），每 5 分钟形成一次对齐突发——ZAI 额度 HTTPS + credit-usage 增量同步（可能多请求）、DeepSeek 扫描所有 Chrome profile 的 LevelDB localStorage（`DeepSeekTokenImporter.swift:44-55`）+ HTTPS、CodeBuddy 国际/国内各拷贝 Chrome Cookies SQLite + Keychain 解密 + HTTPS。每次结果回来还伴随主线程配速图重算与菜单栏标题渲染（采样栈可见 `CABackingStoreCollect`）。

### 相关代码路径

- `Sources/LocalQuotaBar/main.swift`：`CodexRateLimitClient`（:406 起，spawn 逻辑 :483-649）、`RateLimitStore` 定时器（:909-915）、`readAccountPlan` 每次刷新重试（:946-948，未成功前会双倍 spawn）、5 个 store 启动接线（:1312-1316）、`codexUsageStore.refreshIfNeeded`（:1298）。
- `Sources/LocalQuotaBar/codex/CodexUsage.swift`：`CodexUsageClient` 第二处 spawn（stdio JSON-RPC `account/usage/read`）。
- `Sources/LocalQuotaBar/codex/CodexAppServerRestartService.swift`：账号切换后停止外部 app-server 的既有服务；以 `ppid == getpid()` 排除本应用子进程（与常驻子进程的交互见风险）。
- `Sources/LocalQuotaBar/codex/CodexAppServerLocator.swift`：新旧二进制路径探测（常驻会话重拉时复用）。
- `Sources/LocalQuotaBar/zcode/ZAIQuota.swift:1084-1090`、`deepseek/DeepSeekStore.swift:51-57`、`codebuddy/CodeBuddyStore.swift:45-50`：各 store 的 `scheduleTimer`。
- `Sources/LocalQuotaBar/RefreshSettings.swift`：共用刷新档位（默认 5 分钟，可选 1-60 分钟）。

### 已知约束

- **常驻子进程持有启动时的 auth**：codex app-server 启动读取一次 `auth.json`，之后不再重读（既有结论，见 completed/codex-appserver-restart-on-switch.md 背景）。当前「每次 spawn」隐式保证了账号切换后立即读到新凭证；常驻化后必须在切换流程里显式重建会话，否则额度会一直回旧账号的数据。
- 常驻子进程不能被 `CodexAppServerRestartService` 误杀之外的路径泄漏（应用退出、崩溃后的孤儿进程）。
- app-server 长连接的空闲超时行为未知：若服务端主动断开空闲连接，需要检测 EOF 并自动重拉，且重拉必须发生在下一次请求前而不是请求中失败后丢一次刷新。
- 本项目无 `Tests/` 之外的既有约束：新增测试需在 `Package.swift` 注册测试目标（若尚未注册）。

## 方案要点

### 1. `CodexAppServerSession`：自持常驻 stdio 子进程

- **进程生命周期**：懒启动（首次请求时 spawn）；`readabilityHandler` 收到 EOF（`availableData` 为空）或 JSON-RPC error 致命时标记会话失效并清空，下次请求自动重拉；`applicationWillTerminate` 时 SIGTERM。
- **请求复用**：initialize/initialized 只在会话建立时做一次；`rateLimits/read`、`account/read`、`usage/read`、`resetCredit/consume` 作为方法挂在会话上，逐请求分配自增 id，复用现有 `JSONLineResponseCollector` 的按 id 分发思路（需支持并发多请求或简单串行队列——首版取串行：前一个请求完成才发下一个，实现最简且刷新链路本就低频）。
- **账号切换联动**：`CodexAuthManager.switchAccount` 成功后（现有 `store.refreshAfterReset` 相邻位置）调用 `session.invalidate()`，下一次刷新自动用新 `auth.json` 重拉进程。
- **`CodexAppServerRestartService` 交互**：其 `ppid == getpid()` 排除规则继续保护本应用子进程不被外部重启流程误杀（行为不变）；但「用户主动要求立即重启 Codex」语义下应顺带 `invalidate()` 自持会话，与其他 app-server 一同换新。账号切换不选「立即重启」时，自持会话仍必须重建（本应用读取要即时生效），只有外部进程留旧。
- **`CodexUsageClient` 接入**：30 分钟一次的 usage/read 走同一会话，第二处 spawn 一并消除。
- **重置卡操作**：`consumeRateLimitResetCredit` 同走会话；该操作前会话若已失效按普通路径重拉，不额外特殊化。

### 2. 定时器错峰与 tolerance

- 5 个 store 各分配固定相位偏移（如 Codex 0s、ZAI 45s、DeepSeek 90s、CodeBuddy 国际 135s、CodeBuddy 国内 180s；间隔 60 秒档位时按 interval 等比例缩小），实现方式：`scheduleTimer` 首次触发延迟 = 剩余相位 + interval，此后周期为 interval。
- `setRefreshInterval`（右键菜单改档位）重建定时器时保留各 store 相位，避免改档后重新对齐。
- 所有周期 `Timer` 设 `tolerance`（如 `min(10, interval * 0.1)`），允许系统合并唤醒；面板内 15 秒文案定时器已有 tolerance=1，不动。

### 3.（第二阶段，可选）Chrome 导入缓存

- DeepSeek token / CodeBuddy cookie：启动、面板手动刷新、请求鉴权失败（401/403）时重新导入；周期刷新复用上次结果。多 Chrome profile 切换场景由鉴权失败兜底重导入。
- 该阶段若实现，CodeBuddy 两个 store 共享一次 Chrome Cookies 拷贝与解密（当前各拷一次）。

## 风险

- 风险：常驻子进程持有旧账号凭证，账号切换后额度显示旧账号。
- 缓解方式：切换流程显式 `invalidate()`（见方案要点 1）；验收用例必须覆盖「切换账号 → 下一次刷新返回新账号额度」。
- 风险：app-server 空闲断开导致刷新失败率上升（现在是每次新进程，天然无此问题）。
- 缓解方式：EOF 检测 + 请求前健康检查（会话失效即静默重拉再发请求），失败保留缓存的行为不变；验证期观察一周 `lastError` 表现。
- 风险：应用崩溃后常驻子进程成为孤儿。
- 缓解方式：子进程加 `terminationHandler` 清理状态；孤儿进程在下一次应用启动时按「ppid=1 且 argv 匹配自持会话形态」由 `CodexAppServerRestartService` 的枚举顺带确认（只观察不主动杀，首版不扩大杀进程范围）。
- 风险：ChatGPT.app 升级期间二进制被替换，常驻进程为旧版本。
- 缓解方式：重拉时重新走 `CodexAppServerLocator` 定位；升级窗口的瞬时失败由现有「失败保留缓存」兜底。
- 风险：错峰后各 store 状态栏/面板更新时间不再一致，用户感知「刷新变慢」。
- 缓解方式：偏移量控制在单个 interval 内均匀分布，最长延迟 ≈ interval；面板「更新时间」文案本就按各 tab 最近成功时刻展示，无需改。
- 回滚方式：改动集中在 `CodexAppServerSession`（新文件）与两个 client 的取数入口、各 store 的 `scheduleTimer`，无持久化数据迁移；git revert 即可回到每次 spawn 的旧行为。

## 里程碑

1. M0 方案收敛（半个会话）：核实 app-server 空闲超时行为（起一个常驻进程挂 30 分钟观察是否断开）、确认串行请求模型够用、确定错峰相位表；产出决策记录。
2. M1 Codex 拉取常驻化：新建 `CodexAppServerSession`，三个调用方（rateLimits / account / usage / reset）接入，账号切换与会话失效联动；`swift build` + 手动验证。
3. M2 调度错峰 + tolerance（+ 可选 Chrome 导入缓存）：各 store 相位偏移与 tolerance 落地。
4. M3 验证与收尾：按下方验证方式观测后台行为（spawn 计数、CPU 采样、能耗面板跨天复查），历史记录、必要的技术债登记、计划归档。

## 验证方式

- 命令：`swift build`；如 M1 增加单测（会话失效/重建、相位计算），在 `Package.swift` 注册测试目标后 `swift test`（60 秒超时）。
- 手工检查：
  - 额度刷新正常、失败保留缓存、右键菜单改刷新档位后各 store 周期正确且不再对齐。
  - 切换 Codex 账号 → 下一次刷新返回新账号额度；选「立即重启 Codex」后自持会话同样换新。
  - 重置卡 consume 正常。
- 观测检查：
  - 后台脚本（`pgrep -f "CodexCLI.app/Contents/MacOS/codex"` 循环采样，注意实际 argv 含 `bin/../`）连续观察 ≥10 分钟：稳态下 spawn 次数从每 interval 一次降为 0（仅启动/失效/切换时出现）。
  - `top -l 3 -s 5 -pid <pid>`：刷新时刻 CPU 突发峰值与持续时间较基线（10-11%）下降；跨天对比累计 CPU 时间增速（基线约 60 CPU-分钟/天）。
  - 系统设置电池页「使用大量能耗」列表不再出现本应用（需跨天观察，属 M3 收尾项）。
- 实际结果与未覆盖场景：
  - `swift build` 通过；`swift test` 287 个测试执行，284 通过、3 跳过、1 个用例失败（`CodeBuddyParsingTests.testPanelRendersPlanBarAndPackageChips`，在 HEAD 干净工作树上复现，属既有问题，与本计划无关）。新增 17 个测试：会话协议顺序 2、复用/断连重拉/auth 戳重拉/握手超时 4、auth 戳语义 4、相位计算 7。
  - M0 空闲探测：常驻 stdio app-server 挂机 35 分钟（initialize 后每 30 秒轮询）进程存活且连接未断开——app-server 不做空闲超时，EOF 重拉机制保留为防御性兜底。
  - M3 实机观测（2026-10-20，新调试构建替换 10 月 2 日旧实例）：11 分钟窗口内 Codex 子进程仅 1 个（PID 38303）且全程存活，两个 5 分钟刷新 tick（约 14:18、14:23）**零 spawn**（旧构建同期每 tick 必起一个）；新实例 CPU 采样全程 0.0%（旧实例基线为周期性 10-11% 突发）；会话子进程稳态 CPU 0.0%。
  - 未覆盖场景：账号切换真机链路（会改写真实 `~/.codex/auth.json`，未执行；由显式 invalidate 调用点 + 单测的戳变化重拉覆盖）；系统设置电池页「使用大量能耗」跨天复查（待次日确认）；手动刷新/重置卡/提醒链路未逐项人工点验。
  - **2026-10-22 跨天复查发现回归并已修复**：10-20 安装版运行期间会话子进程于 10-21 约 11:06 死亡（死因不明，重拉机制本身正常），之后应用以 >100% CPU 持续自旋约 22.5 小时（累计 2644 CPU-分钟，比旧版更糟）。根因：子进程退出后管道 EOF 使 fd 永久可读，`readabilityHandler` 未在 EOF 时自摘除，空数据无限回调烧满两个 `NSFileHandle.fd_monitoring` 线程（`sample` 采样实锤；两线程 × 22.5h ≈ 2640 分钟与累计值吻合）。10-20 的 11 分钟观测窗口内子进程一直存活，故未暴露。修复：stdout/stderr 的 EOF 分支回调内自摘除 handler，`teardown()` 同步摘除；新增回归测试 `testEOFRemovesReadabilityHandlerAndStopsCallbacks`（EOF 回调计数恒 ≤1 且不增长）。修复版已重装 `/Applications` 并重启验证：CPU 稳态 0.0%、刷新瞬间短峰 ~6%、启动 2.5 分钟累计 CPU 2 秒。

## 进度记录

- [x] 确认范围和约束（M0，2026-10-20）。
- [x] M1：Codex 拉取常驻化完成并手动验证（2026-10-20）。
- [x] M2：错峰 + tolerance 完成（2026-10-20；可选 Chrome 导入缓存未做，登记技术债）。
- [x] M3：完成观测验证并记录结果（2026-10-20，spawn 归零、CPU 0.0%；跨天电池面板复查除外）。
- [ ] 跨天复查系统设置电池页不再列出本应用，完成后归档至 `completed/`。

## 决策记录

- 2026-10-20：选择「自持常驻 stdio 子进程」而不是连接 codex 官方 `app-server-daemon`。理由：stdio JSON-RPC 是本应用已在用的协议，只拉长进程生命周期、改动面最小；外部 daemon 的 unix socket 路径与协议由 codex CLI 版本管理、不保证常驻，耦合它反而引入新的失败面。M0 保留推翻空间。
- 2026-10-20：会话首版取串行请求模型（前一个请求完成才发下一个）。理由：刷新链路本就低频（5 分钟级）且现有实现隐式串行（每进程一次请求），并发分发收益为零、复杂度实增。
- 2026-10-20：错峰采用固定相位偏移而非随机 jitter。理由：固定相位可测试、可复现，且各 store 偏移在 `setRefreshInterval` 重建后保持，避免改档后回到对齐状态；系统级唤醒合并交给 `tolerance`。
- 2026-10-20：Chrome 导入缓存列为第二阶段可选项。理由：相对 spawn 消除属次级收益，且「鉴权失败才重导入」对多 profile 切换场景的行为需要真机验证；先保证主链路落地。
- 2026-10-20（M0 实测）：常驻 stdio app-server 空闲 35 分钟不断开、不退出，确认无服务端空闲超时。EOF 自动重拉机制保留为防御性兜底（覆盖 ChatGPT.app 升级替换二进制、进程崩溃等场景），不依赖它处理常态。
- 2026-10-20（实施）：会话失效判定采用「auth.json 身份戳比对 + 显式 invalidate」双保险。身份戳取 fileNumber+size+mtime：本应用切换账号与 codex CLI 重登录都是原子替换（rename 换 inode），fileNumber 必变；即使未来出现原地写入，size/mtime 也能兜住。切换流程里的显式 invalidate 保证不等下一次请求才发现变化。
- 2026-10-20（实施）：会话初始化时 `signal(SIGPIPE, SIG_IGN)`。旧实现每次请求新进程、管道生命周期与请求严格同步，永远不会向死管道写入；常驻会话可能在子进程刚退出后写 stdin，必须让 EPIPE 走 Swift 错误路径（connectionDropped 重试）而不是 SIGPIPE 杀死本应用。
- 2026-10-20（实施）：错峰用 `Timer(fire:interval:repeats:)` 首触发延迟实现，而非「短 timer 首跳 + 重建」。各 store 持有创建时刻锚点，改档位重建后相对相位保持；档位表同日收缩为 5 分钟起（另一任务），60 秒档位已不存在，偏移表只在 ≥5 分钟档位按比例缩小。
- 2026-10-20（实施）：设置页测试的下拉识别从「首个标题」改为「视图顺序」。档位表移除 1/2 分钟后自动刷新与冷却下拉的标题集合完全相同（5-60 分钟），原标题断言失效；两测试的调整属档位收缩任务的连带修复，随本计划一并提交。
- 2026-10-22（回归修复）：EOF 必须在回调内自摘除 `readabilityHandler`，`teardown()` 同步摘除。理由：子进程退出后管道 EOF 使 fd 永久可读，dispatch source 持续以空数据触发回调——旧实现进程生命周期与请求严格同步、请求结束即置 nil，不存在此路径；常驻化后每个退出路径（EOF、teardown）都必须显式摘除，否则两线程满负荷自旋。配套回归测试以「EOF 回调计数恒 ≤1 且不随时间增长」固化该约束。
- 2026-10-22（死因定案）：10-21 的子进程更替**不是 codex 更新**（ChatGPT.app/codex-cli/CodexCLI 二进制 mtime 均未变、app-server-daemon 无新版本、无崩溃报告），而是 codex 例行刷新 token 于 11:02:45 重写了 `~/.codex/auth.json`（mtime 实证；非账号切换——无新 auth 槽位/套餐缓存），11:06:02 第一个刷新 tick 上身份戳检测触发设计内的「SIGTERM 旧进程 + 重拉新进程」。即：子进程死于我们自己的戳检查主动换新（行为正确），唯一真 bug 是旧 teardown 不摘 handler 导致的 EOF 自旋。auth.json 会被 codex 周期性重写，该换新路径属常态而非异常，修复后每次仅多一次进程启动（对比旧版每天 288 次可忽略）。
