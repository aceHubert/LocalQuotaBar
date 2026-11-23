## [2026-11-23 10:41 +0800] | 任务：修复 Chrome 后台静默更新导致 CodeBuddy 持续 401

### 执行上下文

- **Agent ID**：`antigravity`
- **Base Model**：`Gemini 4 Neon (High)`
- **Runtime**：Antigravity（macOS 26.6.2 arm64）
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> CodeBuddy 授权过期后，即使在 Chrome 中重新登录，应用依然报 HTTP 401；希望能够直接动态获取运行中的 Chrome 版本，避免每次 Chrome 升级出现版本错位。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/codebuddy/`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **CodeBuddyChromeVersion**：新增运行中 Chrome 框架版本直接检测（Darwin `proc_listallpids` + `proc_pidpath`）、`Chrome/Local State` 运行版本读取、无缓存磁盘 `Info.plist` 读取、`Frameworks/Versions/` 扫描与 `N-1` 兜底，汇总为有序候选版本列表 `candidateMajorVersions`。
- **CodeBuddyClient**：按候选版本列表构造请求 UA / `sec-ch-ua`，在 401/403 的 `ephemeral` 重试会话中自动遍历候选版本并记忆命中版本（`preferredChromeMajor`），同时支持测试注入 `recoverySessionFactory` 并补充 `ua=<major>` 诊断日志。
- **CodeBuddyClientRequestTests**：新增无 `Bundle` 缓存实时读取、候选版本优先级与 `N-1` 兜底、401 自动切换候选版本并记忆偏好版本的单元测试，修复原有 401 单测未注入恢复会话传输层的问题。

### 设计动机

现场排查与对照实测证实，CodeBuddy 国际/国内站接口均严格校验请求头 `User-Agent` 中的 Chrome 主版本号与签发 Cookie 时浏览器主版本一致（本机运行中 Chrome 为 157、磁盘 `Info.plist` 已被后台静默更新至 158，发 158/156 均返回 401，发 157 返回 200）。同时原实现通过 `Bundle(url:).infoDictionary` 读取版本会被 Foundation 进程级缓存，Chrome 升级重启后长期运行的应用仍会发送旧版本。改为优先直接读取运行中的 Chrome 进程版本与 `Local State`，并结合无缓存 `Info.plist`、`Versions/` 目录与 `N-1` 的 401 自动回退，既保证常态首次请求直接命中 200，又完全覆盖后台未重启与升级过渡期，后续 Chrome 升级无需修改代码。

### 验证结果

- 命令与结果：
  - `swift test --filter "CodeBuddyClientRequestTests|CodeBuddyCookieImporterTests|CodeBuddyStoreTests"`：全部通过。
  - `LOCALQUOTABAR_CODEBUDDY_LIVE=1 swift test --filter CodeBuddyLiveProbeTests`（`www.codebuddy.ai`）：直接 200 OK，解析正常，无多余重试。
  - `LOCALQUOTABAR_CODEBUDDY_LIVE=1 LOCALQUOTABAR_CODEBUDDY_LIVE_HOST=www.codebuddy.cn swift test --filter CodeBuddyLiveProbeTests`（`www.codebuddy.cn`）：直接 200 OK，解析正常，无多余重试。
  - `swift build -c release`：编译通过，已重新打包签名安装并重启 `/Applications/LocalQuotaBar.app`。
- 手工验证及设备：本机 macOS 26.6.2 arm64（运行中 Chrome 157、磁盘 Info.plist 158 现场环境），实测国际站与国内站均恢复正常；新进程已启动。
- 未覆盖场景：未验证 Touch Bar / 刘海屏展示交互；待后续 Chrome 重启升级到 158 后持续观察过渡期自动切换。

### 变更统计

- **统计口径**：相对 `HEAD`（`8001c7f`）的工作区 `git diff --shortstat` 与 `git diff --numstat`，仅统计本次任务代码与测试变更，排除本历史记录文件。
- **变更文件数**：2
- **新增行数**：+396
- **删除行数**：-24

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift` | 257 | 21 |
| `Tests/LocalQuotaBarTests/CodeBuddyClientRequestTests.swift` | 139 | 3 |

### 修改文件

- `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift`
- `Tests/LocalQuotaBarTests/CodeBuddyClientRequestTests.swift`
