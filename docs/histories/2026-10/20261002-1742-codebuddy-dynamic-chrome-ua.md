## [2026-10-02 17:42 +0800] | 任务：CodeBuddy UA 跟随本机 Chrome 版本修复 401

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：GLM-5.3（zai-start-plan/GLM-5.3-Flash）
- **Runtime**：ZCode CLI（macOS 25.6.0 arm64）
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 再次确认了是因为 user agent chrome 版本不一致造成的，必须要与浏览器授权时使用的版本一致，不能写死。Chrome/154 返回 200，因为浏览器有升级变更了。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/codebuddy/`、`Tests/LocalQuotaBarTests/`。

**主要操作**：

- **操作一**：新增 `CodeBuddyChromeVersion`：从本机 Chrome 应用 bundle 的 `CFBundleShortVersionString` 读主版本号（`/Applications` 与 `~/Applications` 两个候选路径）。
- **操作二**：`CodeBuddyClient` 注入 `chromeMajorVersion` 闭包（默认走上述检测），UA 与 `sec-ch-ua` 按版本动态构建，替换写死的 `Chrome/153`；`sec-ch-ua` 品牌结构同步对齐 Chrome 实际发送格式（`"Chromium";v="N", "Google Chrome";v="N", "Not A(Brand";v="99"`）。
- **操作三**：检测失败（Chrome 不在标准路径）时用 `fallbackChromeMajorVersion` 兜底保证请求可发出，注释说明此时仍可能 401。
- **操作四**：测试更新：原 UA 断言（写死 153）改为注入版本 137 断言完整 UA 与 sec-ch-ua；新增版本检测用例（伪 bundle、多路径回退、全失败返 nil）与兜底版本用例。

### 设计动机

- 根因（用户实测确认 + 本机验证）：CodeBuddy 站点网关把会话 Cookie 绑定到登录浏览器的 UA 版本，浏览器升级后版本号不匹配即 401。此前诊断一度指向 TLS/HTTP2 指纹（curl-impersonate 成功、URLSession 失败），实为混淆变量——当时所有失败请求都带着写死的 `Chrome/153` UA，唯一成功的 curl-impersonate 恰好用了 154。
- 版本号跟随本机 Chrome 安装动态获取，浏览器升级后自动适配，不再需要改代码。
- 国际版与国内版共用 `CodeBuddyClient`，两站一次修复同时生效。

### 验证结果

- 命令与结果：`swift build` 通过；`swift test` 267 项、0 失败、2 项跳过（较上一任务 +2：版本检测、兜底版本）。
- 真实链路：`LOCALQUOTABAR_CODEBUDDY_LIVE=1` 国际版探针 200——普通 URLSession + 动态 154 UA 返回完整数据（体验版 100/100 + 4 个奖励包，其中 1 个 2026-09-23 已过期会被面板过滤）；`LOCALQUOTABAR_CODEBUDDY_LIVE_HOST=www.codebuddy.cn` 国内版探针 200（"CodeBuddy个人体验版"）。
- 安装部署：`make install` 覆盖 `/Applications/LocalQuotaBar.app`，构建与安装产物 SHA-256 一致（`905da5e2…`），重启后进程存活。
- 未覆盖场景：① Chrome 安装在非标准路径时走兜底版本，可能仍 401（错误文案会提示重登，用户可反馈调整候选路径）；② Chrome Beta/Canary 等变体未适配（其用户数据目录与稳定版不同，SweetCookieKit 现亦只读稳定版）。

### 变更统计

> 统计口径：未提交状态，基线 `HEAD`（0db1ec2），含同日上午"奖励包过期过滤 + 明细卡封顶"任务的未提交改动；`git diff -- Sources Tests`。已排除任务前既有未跟踪项（`.zcodeignore`、`canvas/`）与历史记录自身。本次任务单独改动：`CodeBuddyClient.swift`（+49/-6）、`CodeBuddyClientRequestTests.swift`（+57/-2）。

- **变更文件数**：8
- **新增行数**：+241
- **删除行数**：-17

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift` | 49 | 6 |
| `Tests/LocalQuotaBarTests/CodeBuddyClientRequestTests.swift` | 57 | 2 |
| `Sources/LocalQuotaBar/ui/QuotaPanelViews.swift` | 37 | 7 |
| `Tests/LocalQuotaBarTests/CodeBuddyParsingTests.swift` | 50 | 0 |
| `Tests/LocalQuotaBarTests/ResetCardsRowTests.swift` | 33 | 0 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyModels.swift` | 5 | 0 |
| `Sources/LocalQuotaBar/ui/CodeBuddyPanelSection.swift` | 8 | 1 |
| `Sources/LocalQuotaBar/main.swift` | 2 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/codebuddy/CodeBuddyClient.swift`
- `Tests/LocalQuotaBarTests/CodeBuddyClientRequestTests.swift`
- `docs/histories/2026-10/20261002-1631-codebuddy-expired-free-filter-and-card-cap.md`（同日上午任务，未提交）
