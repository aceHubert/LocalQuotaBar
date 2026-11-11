## [2026-10-30 16:18 +0800] | 任务：修复 CodeBuddy 401 后持续失效需重启应用的问题

### 执行上下文

- **Agent ID**：zcode
- **Base Model**：GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）
- **Runtime**：ZCode Desktop（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> CodeBuddy 又刷新失败了。Chrome 重新登录后应用没有重新去读，无论怎么刷新都 401，只有重启应用才会去读新的。

### 排查结论（修复依据）

通过独立探针复现 app 完整导入+请求链路、统一日志抓包、lldb 内存取证，确认：

- 导入层无缓存：源码与 SweetCookieKit 每次 refresh 都重新拷贝并读取 Chrome Cookie 库；Chrome 侧重登录后新 `session`/`session_2` 即时落盘（库为 rollback journal 模式、无 WAL 延迟），仅 Default 一个 profile 持有 codebuddy Cookie。
- 老进程（持续运行 4 天）内存中存在多个历史 session 值，旧值在请求上下文中反复出现，且 15:57 抓到真实 401 响应；同一时刻用相同导入链路的新进程请求始终 200 —— 坏状态钉在老进程的请求链路层（URLSession 长命状态：复用连接 / 共享 Cookie 存储），而非导入层。老进程重启后无法继续取证，最终机理未能完全闭环。
- 实测发现 `URLSession.shared` 在处理 codebuddy 响应的 `Set-Cookie`（.cn 域 `tgw_l7_route` 已写入应用持久化 Cookie 存储，文件 mtime 与 401 响应同秒），请求层与浏览器 Cookie 语义发生交叉。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/codebuddy/`。

**主要操作**：

- **CodeBuddyClient**：请求关闭自动 Cookie 处理（`httpShouldHandleCookies = false`），响应 `Set-Cookie` 不再进入共享存储；401/403 时改用全新 ephemeral `URLSession`（全新连接池、无 Cookie 存储、无缓存，等价于进程内重启传输层）带同一份导入 Cookie 重试一次。
- **CodeBuddyClient**：新增 `CodeBuddyDiagnostics`，刷新链路输出状态码、Cookie 指纹（SHA256 前 16 位，不含凭证）与会话类型的 NSLog 诊断日志。
- **CodeBuddyStore**：会话失效（401/403）后自动安排 +45s / +180s 两次补刷（重新导入 Cookie 再请求），仍在失效态才执行，新刷新开始即作废，不再依赖用户重启应用。

### 设计动机

根因最后一环（老进程为何持续使用旧会话）随进程重启无法取证，因此修复目标是把"只有重启才能恢复"的进程级长命状态从请求链路中全部拆除，并让 401 自愈：

1. ephemeral 重试消除共享 URLSession 连接池 / 缓存 / 存储状态的影响；
2. 关闭自动 Cookie 处理消除响应 Set-Cookie 污染（有实锤行为）；
3. 延迟补刷覆盖 Chrome 侧落盘与用户刚完成重登录的时间差；
4. 哈希化日志保证下次复现时可直接区分"导入旧了"还是"链路旧了"，不记录任何凭证。

### 验证结果

- 命令与结果：`swift build` 编译通过；探针端到端验证（复用新版 CodeBuddyClient 编译为 CLI）：
  - 无效 Cookie：主会话 401 → 自动 ephemeral 重试 → 仍 401 → 正确抛出"会话已失效"错误，诊断日志按预期输出；
  - 真实 Cookie（现场导入）：直接 200，套餐/奖励包解析正常，无多余重试。
- 手工验证及设备：本机 macOS 25.6.0；应用面板行为待用户下次安装后观察（正常路径与 401 自愈路径）。
- 未覆盖场景：401 自愈补刷定时器依赖真实会话过期场景回归验证；根因最后一环（老进程内旧会话来源）未完全闭环，依赖新增诊断日志在下一次复现时定位。

### 变更统计

- **统计口径**：工作区未提交改动，仅统计本任务涉及的 `Sources/LocalQuotaBar/codebuddy/` 两个文件，排除历史记录自身。
- **变更文件数**：2
- **新增行数**：+122
- **删除行数**：-11

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift` | 63 | 6 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift` | 59 | 5 |

### 修改文件

- `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift`
- `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift`
