# Repository Guidelines

## 项目结构与模块组织

LocalQuotaBar 是基于 Swift Package Manager 的 macOS 菜单栏应用，使用 AppKit，支持 macOS 13 及以上版本。

- `Sources/LocalQuotaBar/`：应用源码，按领域分子目录；同一 target 递归编译，子目录仅作组织用途。根目录 `main.swift` 包含入口、Codex 数据读取与界面，`RefreshSettings.swift` 是共用刷新设置。
- `codex/`：Codex 用量读取与重置卡片操作；`zcode/`：Z.AI / BigModel 额度、重置服务与用量数据库。
- `notify/`：`ReminderModels.swift`、`ReminderEvaluator.swift`、`ReminderCenter.swift` 与通道文件分别负责模型、评估、编排和投递；新增提醒行为保持这些职责分离。
- `ui/`：面板与设置页视图（额度面板、Provider 区块、主题、用量图表）。
- `Resources/`：图标资源，`AppIcon.svg` 为图标源文件；`Tools/render-svg-icon.swift`：透明 PNG 渲染脚本。
- `Package.swift`：目标与依赖；`Info.plist`：应用元数据；`Makefile`：构建和打包入口。

## 构建与本地开发

准备支持 Swift 5.9 的 macOS 开发工具链。首次构建需要下载 DynamicNotchKit 依赖。

- `swift build`：调试构建，快速检查编译错误。
- `make build`：发布构建，等价于 `swift build -c release`。
- `make app`：重建图标并生成 `.build/release/LocalQuotaBar.app`，会更新已跟踪的图标文件。
- `make run`：打包并启动应用。
- `make install`：打包并安装到 `/Applications`；可能覆盖已有安装。

## 编码风格与命名

使用四个空格缩进，类型采用 `UpperCamelCase`，方法和属性采用 `lowerCamelCase`，文件名对应主要类型。遵循现有 `// MARK:` 分区习惯，复杂流程添加简体中文注释。界面和可观察状态遵循现有 `@MainActor` 隔离方式，网络读取与提醒评估保持解耦。仓库未配置 SwiftLint 或 SwiftFormat，避免无关的全文件格式调整。

## 测试与验证

当前没有 `Tests/`、SwiftPM 测试目标、CI 或覆盖率门槛，不能将 `swift test` 视为现成检查。新增自动化测试时，在 `Package.swift` 注册测试目标，放入 `Tests/LocalQuotaBarTests/`，采用 `XCTest`、`<类型名>Tests.swift` 和 `test<行为>` 命名，再运行 `swift test`；后台单元测试设置 60 秒超时。

提交前至少执行 `swift build`。行为变更应验证额度刷新、失败后保留缓存、刷新频率及右键菜单“测试提醒”；提醒变更检查阈值、冷却和静音恢复，并记录 Touch Bar / 刘海屏的实际验证情况。图片渲染脚本不属于自动化单元测试。

## Execution Plans & Histories

长周期任务和已完成的代码改动必须记录在仓库中，不能只保留在聊天记录里。

- **执行计划**（`docs/exec-plans/`）：跨会话、存在架构风险或需要分阶段验证的任务必须创建计划。进行中的计划放在 `active/`，完成后移至 `completed/`，从 [执行计划模板](docs/exec-plans/templates/execution-plan.md) 开始填写，并将明确推迟的债务记录到 [技术债追踪](docs/exec-plans/tech-debt-tracker.md)。完整规范见 [PLANS_GUIDE.md](docs/PLANS_GUIDE.md)。
- **历史记录**（`docs/histories/`）：实际修改仓库的任务应按 `YYYY-MM/YYYYMMDD-HHmm-task-slug.md` 命名。使用 [历史记录模板](docs/histories/template.md)，如实填写 Git 用户，并通过 `git diff --shortstat` 与 `git diff --numstat` 记录本次任务的变更统计。完整规范见 [HISTORY_GUIDE.md](docs/HISTORY_GUIDE.md)。
- 纯问答或调研无需历史记录；仅新增或更新调研、评估、报告、执行计划及其模板，也不要求额外生成历史记录。

## 配置与协作注意事项

Codex 读取依赖已登录的本机 ChatGPT.app；Z.AI / BigModel 配置来自 `~/.zcode`。不得提交凭证、令牌或包含敏感信息的日志。

修改前检查 `git status` 并读取现有内容，保留他人的未提交改动。未经用户明确要求，不要执行 `git add`、`git commit` 或 `git push`；提交一律由用户发起，任务收尾时把改动留在工作区或暂存区即可。仅在用户要求提交时，先检查差异再提交，避免混入生成图标或本地设计草稿，提交信息参考 `git log` 近期格式。
