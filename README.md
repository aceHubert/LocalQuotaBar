# CodexTouchBarQuota

一个 Swift/AppKit macOS 菜单栏 + Touch Bar 小应用，用本机 ChatGPT.app 内置的 Codex app-server 读取 `account/rateLimits/read`，不抓网页。

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
- Touch Bar 主动提醒：低额度、快重置时在最前面显示 `🚨` / `⚠️` / `⏳`
- 主动提醒优先走系统模态 Touch Bar（运行时检测 `presentSystemModalTouchBar` 私有 API），其他 App 在前台时也能弹出，显示 12 秒后自动消失；私有 API 不可用时回退到激活菜单栏弹窗
- Touch Bar 使用固定 10 段电量条，普通状态和提醒状态宽度一致
- 提醒面板支持“不再提醒”，会静默当前 5 小时或周限额周期
- 菜单面板可设置主动提醒开关、低额度阈值（50–10%）、快重置时间（50–10 分钟）和再次提醒冷却时间（5–60 分钟）
- 菜单面板提供“恢复提醒”按钮（仅在有静默或冷却状态时显示），可撤销“不再提醒”并清除冷却状态；另有“恢复默认”按钮一键还原默认提醒设置
- 自动识别 Touch Bar 硬件：无 Touch Bar 的 Mac 上只显示菜单栏额度面板，隐藏提醒设置且不触发 Touch Bar 提醒

## 构建

```bash
cd CodexTouchBarQuota
make app
open .build/release/CodexTouchBarQuota.app
```

安装到 `/Applications`：

```bash
make install
open /Applications/CodexTouchBarQuota.app
```

## Touch Bar 显示条件

这是公开 AppKit Touch Bar 实现。macOS 通常只会给当前激活 App 显示 Touch Bar 控件，所以点击菜单栏上的 `Codex` 状态项、让弹窗处于激活状态时，会显示两行额度条。

如果 Touch Bar 没出现，检查：

- 系统设置 → 键盘 → Touch Bar 显示内容：选择“App 控件”或包含 App 控件的模式
- 机器需要是带 Touch Bar 的 MacBook Pro
- ChatGPT.app 需要已登录 ChatGPT 账号，否则 app-server 可能返回空或认证错误

## 可调整参数

在 `Sources/CodexTouchBarQuota/main.swift` 中：

- `CodexRateLimitClient.appServerExecutablePath`：ChatGPT.app 内置 Codex 可执行文件路径
- `RateLimitStore.refreshInterval`：自动刷新间隔，默认 5 分钟；手动刷新按钮有 60 秒防重保护
- `CodexRateLimitClient.requestTimeout`：单次 RPC 超时，默认 30 秒（rateLimits 读取走网络，延迟波动大）
- `TouchBarAlertPresenter.displayDuration`：主动弹出 Touch Bar 的显示时长，默认 12 秒
- 菜单面板“提醒设置”：主动提醒开关、低额度阈值、快重置时间、再次提醒间隔、恢复提醒（条件显示）、恢复默认
