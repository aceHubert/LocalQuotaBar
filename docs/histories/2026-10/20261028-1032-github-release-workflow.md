## [2026-10-28 10:32 +0800] | 任务：新增 tag 触发的 GitHub Actions 发版工作流

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`zai-api/GLM-5.3`
- **Runtime**：`ZCode Desktop + computer-use（终端操作）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 把编译出的应用放进 GitHub Release，先建 release.yml 并打 v0.1.0 tag 验证；自动打 tag 的方案验证成功后再考虑。

### 变更概览

**影响范围**：`.github/workflows/`。

**主要操作**：

- **新增 `.github/workflows/release.yml`**：push `v*` tag 触发；`make app` 构建 `.app`；`plutil` 将 tag 版本注入 `CFBundleShortVersionString` / `CFBundleVersion`；ad-hoc `codesign`；`ditto` 打 zip；`softprops/action-gh-release@v2` 创建 Release 并上传产物。
- **打 `v0.1.0` tag 推送**并验证流水线。

### 设计动机

版本号以 git tag 为唯一来源，仓库内 Info.plist 保持模板角色、构建时注入，避免每次发版手改版本文件。首次踩坑：新增 workflow 的同一次推送携带 tag，事件先于 workflow 注册被丢弃，删除远端 tag 重推即恢复；后续发版（workflow 已注册）不会再遇到。

### 验证结果

- 命令与结果：`ruby -ryaml` 解析 release.yml 为 Hash；Actions run 4062132 成功（1m56s）；`gh release view v0.1.0` 确认 asset `LocalQuotaBar-0.1.0.zip`。
- 手工验证及设备：本机 Apple Silicon（darwin arm64）操作远端 aceHubert/LocalQuotaBar。
- 未覆盖场景：Intel 架构产物、Developer ID 签名与公证、Sparkle 自动更新、自动打 tag。

### 变更统计

- **统计口径**：基线 4e970da..fbf2853，仅统计本任务提交，排除历史记录自身。
- **变更文件数**：1
- **新增行数**：+38
- **删除行数**：-0

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `.github/workflows/release.yml` | 38 | 0 |

### 修改文件

- `.github/workflows/release.yml`（新增）
