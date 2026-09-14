# LocalQuotaBar

一个 Swift/AppKit macOS 本地额度栏小应用：菜单栏 + 刘海岛式卡片 + Touch Bar 多通道展示，聚合 Codex（用本机 ChatGPT.app 内置的 Codex app-server 读取 `account/rateLimits/read`）与 Z.AI / BigModel 渠道额度，不抓网页。

## 功能

- 启动 ChatGPT.app 内置 app-server：`/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://`
- 通过 JSONL / JSON-RPC 调用：`initialize` → `initialized` → `account/rateLimits/read`
- 每次额度同步都从同一 RPC 响应保存可用重置次数及每张重置卡的发放、过期时间；点击“过期时间”只显示已同步数据，不再发起查询
- 显示两行额度，窗口标题按时长自动识别：小时级（如 `5小时`）、`周限额`、`月限额`（free 账号）或 `N天`
- 剩余额度按 `100 - usedPercent` 计算
- 刷新时保留旧 UI，只有新数据成功返回后才替换旧数据
- 读取失败时不清空旧数据，只在菜单窗口中显示错误
- 成功数据会缓存到本地，应用重启或读取超时后仍显示最后一次额度和更新时间
- 菜单栏常驻，点击菜单栏图标可展开同款额度面板
- Z.AI / BigModel 余额：识别 `~/.zcode` 的 zai / bigmodel 渠道，展示 coding-plan 限额、体验套餐余额与重置卡；后台自动刷新（默认 5 分钟，可在状态栏右键菜单调整；启动后延迟 30 秒与 Codex 错峰）
- 主动提醒（多源统一）：Codex 的 5 小时 / 周限额与 ZAI 的限额、体验余额任一触发阈值（低额度 `🚨` / `⚠️`，快重置 `⏳`）都会提醒
- 提醒投递按设备能力自动回退：有 Touch Bar 走系统模态 Touch Bar（运行时检测 `presentSystemModalTouchBar` 私有 API，其他 App 在前台时也能弹出，显示 12 秒）→ 无 Touch Bar 但屏幕有刘海时，从刘海向下展开岛式黑色卡片（真实百分比 + 10 段电量条，点击打开主面板，12 秒自动收起）→ 都不支持则不主动弹出
- 岛式卡片挂在菜单栏下沿而非刘海内：macOS 26 的系统灵动岛（iPhone 镜像 Live Activities）覆盖刘海区域，且 ActivityKit 对 macOS 全量 unavailable（第三方 Mac 应用无法发布系统 Live Activity，Apple 在 WWDC26 预告了下一代系统的 Mac 支持）；等 API 可用后可在 `ReminderChannels.swift` 里直接新增 Live Activity 通道
- 菜单栏右键菜单提供「测试提醒」：用 Codex 当前真实数据手动走一遍投递链，不受提醒开关、阈值、静音与冷却限制，也不写入提醒状态
- Touch Bar 使用固定 10 段电量条，普通状态和提醒状态宽度一致；ZAI 等其他源的 Touch Bar 提醒用文本形式
- 提醒支持“不再提醒”，会静默对应额度桶到本周期重置；静音 / 冷却状态对 Touch Bar、刘海屏两个通道和 Codex、ZAI 两个数据源共用
- 菜单面板可设置主动提醒开关、低额度阈值（50–10%）、快重置时间（50–10 分钟）和再次提醒冷却时间（5–60 分钟）
- 状态栏右键菜单可设置自动刷新频率（1–60 分钟，Codex 与 ZAI 共用，默认 5 分钟），面板设置区只读展示当前值
- 菜单面板提供“恢复提醒”按钮（仅在有静默状态时显示），可撤销“不再提醒”并清除冷却状态；另有“恢复默认”按钮一键还原默认提醒设置
- 提醒设置区按设备能力显示且位于面板最底部（提醒同时管 Codex 与 ZAI 两个数据源，是全局设置）：有 Touch Bar 或有刘海屏才显示，两者都没有的 Mac 上隐藏提醒设置且不触发提醒

## 构建

```bash
cd LocalQuotaBar
make app
open .build/release/LocalQuotaBar.app
```

安装到 `/Applications`：

```bash
make install
open /Applications/LocalQuotaBar.app
```

## Touch Bar 显示条件

这是公开 AppKit Touch Bar 实现。macOS 通常只会给当前激活 App 显示 Touch Bar 控件，所以点击菜单栏上的 `Codex` 状态项、让弹窗处于激活状态时，会显示两行额度条。

如果 Touch Bar 没出现，检查：

- 系统设置 → 键盘 → Touch Bar 显示内容：选择“App 控件”或包含 App 控件的模式
- 机器需要是带 Touch Bar 的 MacBook Pro
- ChatGPT.app 需要已登录 ChatGPT 账号，否则 app-server 可能返回空或认证错误

## 可调整参数

在 `Sources/LocalQuotaBar/` 中：

- `CodexRateLimitClient.appServerExecutablePath`：ChatGPT.app 内置 Codex 可执行文件路径
- `RefreshSettings`：Codex 与 ZAI 共用的自动刷新频率，默认 5 分钟，档位 1/2/5/10/15/30/60 分钟；在状态栏右键菜单「刷新频率」中修改，即时生效
- `RateLimitStore.refreshInterval`：Codex 自动刷新间隔，读取 `RefreshSettings`；手动刷新按钮有 60 秒防重保护
- `ZAIQuotaStore.refreshInterval`：ZAI 后台刷新间隔，与 Codex 共用同一设置
- `CodexRateLimitClient.requestTimeout`：单次 RPC 超时，默认 30 秒（rateLimits 读取走网络，延迟波动大）
- `TouchBarAlertChannel.displayDuration` / `NotchAlertChannel.displayDuration`：主动弹出提醒的显示时长，默认 12 秒
- 菜单面板“提醒设置”：主动提醒开关、低额度阈值、快重置时间、再次提醒间隔、恢复提醒（条件显示）、恢复默认

## 提醒模块结构

提醒逻辑独立成四个文件，与数据源、UI 解耦：

- `ReminderModels.swift`：统一额度桶 `ReminderBucket`（Codex / ZAI 多源归一）、提醒级别与配置
- `ReminderEvaluator.swift`：纯阈值评估 + 静音 / 冷却状态（按桶 id 存一个 UserDefaults 字典）
- `ReminderChannels.swift`：投递通道协议与实现（Touch Bar 模态、刘海屏胶囊弹窗）
- `ReminderCenter.swift`：编排评估与 `Touch Bar > 刘海屏 > 不弹出` 的通道回退
