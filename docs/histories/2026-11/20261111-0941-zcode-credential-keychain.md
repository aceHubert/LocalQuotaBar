## [2026-11-11 09:41 +0800] | 任务：适配 ZCode 3.18.0 登录凭证

### 执行上下文

- **Agent ID** `codex`
- **Base Model** `GPT-6`
- **Runtime** Codex Desktop，macOS 26.6.2 arm64
- **Git User** `hubert <hubert@lejian.com>`
- **Branch** `main`

### 用户诉求

> ZCode 更新后，LocalQuotaBar 无法获取令牌，需要适配新的凭证存储方式。

### 变更概览

- `ZAICredentialCipher.swift` 读取 ZCode 3.18.0 的新版凭证，支持 macOS 钥匙串、环境密钥和密钥文件，并验证密钥摘要与 AES-GCM 认证标签。应用在进程内复用已校验的钥匙串密钥，摘要变更后重新查询。继续支持旧版 `enc:v1` 和明文凭证。
- `ZAIQuota.swift` 统一账号识别、OAuth 凭证与 ZCode JWT 的文件入口。体验套餐优先选用配置中的明文 JWT，遇到密文时改用凭证文件里的 JWT。
- `ZAICredentialCipherTests.swift` 加入 9 项合成凭证测试，覆盖正确解密、密钥轮换、密钥不可用、密钥不匹配、密文篡改和旧版兼容。

### 设计动机

本机 ZCode 3.18.0 仍将密文写入 `~/.zcode/v2/credentials.json`，并将新版加密密钥存入 macOS 钥匙串。旧实现会原样返回 `enc:v2` 密文，导致请求使用了错误的令牌。新版按凭证文件绝对路径的摘要定位钥匙串条目，解密失败时返回本地错误，避免提交密文。

### 验证结果

- 调试构建与测试目标编译通过。SwiftPM 默认运行器以 x86_64 启动，改用原生 arm64 XCTest 执行 109 项 Z.AI 相关测试，全部通过。
- 在本机用户会话通过元数据查询确认对应的钥匙串条目存在。钥匙串授权交互、真实账号额度刷新、Touch Bar 和刘海屏尚未验证。

### 变更统计

- **统计口径** 使用 `git diff --shortstat` 与 `git diff --numstat`。已跟踪文件与 HEAD 比较，两个新增文件与 `/dev/null` 比较，排除历史记录自身和其他工作区改动。
- **变更文件数** 3
- **新增行数** +316
- **删除行数** -85

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZAIQuota.swift` | 28 | 85 |
| `Sources/LocalQuotaBar/zcode/ZAICredentialCipher.swift` | 167 | 0 |
| `Tests/LocalQuotaBarTests/ZAICredentialCipherTests.swift` | 121 | 0 |
