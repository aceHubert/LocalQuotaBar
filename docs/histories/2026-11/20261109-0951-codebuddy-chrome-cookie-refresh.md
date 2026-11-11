## [2026-11-09 09:51 +0800] | 任务：修复 Chrome 运行期间的 CodeBuddy 会话导入

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`GPT-6`
- **Runtime**：Codex Desktop，macOS 26.6.2 arm64
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> Chrome 中重新登录 CodeBuddy 后，LocalQuotaBar 仍找不到会话 Cookie，只有重启 Chrome 后才能读取。

### 变更概览

- CodeBuddy 国际版和国内版均优先通过 SQLite 在线备份读取一致的数据库快照，再复用 SweetCookieKit 解密及筛选。临时快照使用私有目录，并在读取后清理。在线备份无法读取时，保留原有导入路径。
- 找不到会话 Cookie 时沿用会话失效的补刷机制，每轮最多两次，约在初次失败后 45 秒和 3 分钟触发。后台补刷禁止钥匙串弹窗，并保留上一次成功读取的额度。

### 设计动机

旧流程分别复制 SQLite 主库和旁路文件，复制期间发生写入时无法保证视图一致。本机读取时 Chrome 使用回滚日志模式，不能据此确定故障现场是否出现了快照竞争。SQLite 在线备份覆盖两种日志模式下已经提交的变更。Chrome 会批量写入 Cookie，初次导入可能早于提交，因此需要对找不到会话的结果补刷。[Chromium 写入逻辑](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/extras/sqlite/sqlite_persistent_cookie_store.cc#347)

### 验证结果

- 调试构建通过。原生 arm64 XCTest 执行 Cookie 导入与刷新编排的 5 项测试，全部通过。新增用例覆盖回滚日志和 WAL 下保持写连接开启并读到新提交的 Cookie，以及缺失会话后只补刷两次。
- 扩大 CodeBuddy 回归范围至 21 项用例后，有两项现有测试失败。401 测试的备用请求没有继承模拟传输层，遇到 DNS 错误。面板测试使用的奖励包固定到期日已过，有两条断言失败。
- 未执行真实账号重新登录或生产额度接口的端到端验证。本次变更涉及后台导入和补刷，未验证 Touch Bar 或刘海屏展示。

### 变更统计

- **统计口径**：按 `git diff --shortstat` 和 `git diff --numstat` 汇总。原先已有改动的 `CodeBuddyStore.swift` 与任务前快照比较，其他已跟踪文件与 HEAD 比较，新增测试与空文件比较。排除本历史记录。
- **变更文件数**：4
- **新增行数**：+210
- **删除行数**：-53

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyCookieImporter.swift` | 60 | 5 |
| `Sources/LocalQuotaBar/codebuddy/CodeBuddyStore.swift` | 52 | 48 |
| `Tests/LocalQuotaBarTests/CodeBuddyCookieImporterTests.swift` | 66 | 0 |
| `Tests/LocalQuotaBarTests/CodeBuddyStoreTests.swift` | 32 | 0 |
