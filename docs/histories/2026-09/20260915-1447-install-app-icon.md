## [2026-09-15 14:47 +0800] | 任务：将定稿图标更新到本机应用

### 执行上下文

- **Agent ID**：codex
- **Base Model**：未知
- **Runtime**：Codex 桌面应用，macOS，当前主会话
- **Git User**：hubert <hubert@lejian.com>
- **Branch**：main

### 用户诉求

> 根据当前定稿，将图标更新到本地应用。

### 变更概览

**影响范围**：正式图标资源、图标渲染脚本、打包入口及本机已安装应用的图标。

- 将 Cowart 定稿同步为 Resources/AppIcon.svg，包含绿色 100%、橙色 50%、红色 30% 额度条，以及两角延伸至边缘中段的玻璃高光。
- 调整正式 SVG 的文字基线与标准粗体属性，避免原生 SVG 解码器忽略 dominant-baseline 或非标准字重后发生偏移。
- 新增原生 AppKit 透明 PNG 渲染脚本，生成 1024 像素 PNG、各尺寸 iconset 和 ICNS。
- 修复 Makefile 对已删除旧图标脚本的引用，同步 AGENTS.md 中的图标构建说明；保持旧脚本原有删除状态。
- 完成应用打包，并仅将 ICNS 写入本机已安装的 LocalQuotaBar.app 图标资源，刷新该应用的 Launch Services 注册。

### 设计动机

使已确认的视觉设计成为可重复构建的正式图标，避免后续打包覆盖回旧版。
使用 macOS 原生透明渲染保留圆角外部透明区域，不使用带白底的 Quick Look 缩略图作为安装资产。
本轮安装命令仅写入图标资源并更新应用目录时间，不停止进程、不覆盖可执行文件。
过程中观察到其他工作更新了已安装应用的可执行文件与运行进程，因此不把它们记入本任务改动。

### 验证结果

- swift build：通过。
- make icon：通过。
- make app：发布构建、SVG 渲染、多尺寸转换及 ICNS 打包均通过。
- 验证 PNG 为 1024×1024，具有 alpha 通道，左上角透明度为 0，中央透明度为 1。
- 查看正式 PNG 缩略图，确认白色 100% 居中、填充比例和玻璃效果符合定稿。
- 源码资源、构建 bundle、安装 bundle 的 ICNS SHA-256 一致：21332dc1a6ca259c94c01f4e1372e3b6e84ccb9e7b1065eb970fdb5baf52cc1f。
- 通过 NSWorkspace 读取系统实际返回的应用图标并查看导出预览，确认系统已识别新版。
- git diff --check：通过。
- 未修改额度或提醒逻辑，未额外执行设备提醒测试。

### 变更统计

- **统计口径**：AGENTS.md、Makefile 和 Resources 下三个正式图标文件与本轮修改前快照比较；新脚本与 /dev/null 比较，均执行 git diff --no-index --shortstat 和 --numstat。排除其他工作已有改动、此前 Cowart 设计稿、被忽略的 iconset 与构建产物，以及本历史记录自身。
- **变更文件数**：6
- **新增行数**：+123
- **删除行数**：-64
- **二进制文件**：2

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| AGENTS.md | 1 | 1 |
| Makefile | 1 | 1 |
| Resources/AppIcon.svg | 67 | 62 |
| Resources/AppIcon-1024.png | bin | bin |
| Resources/AppIcon.icns | bin | bin |
| Tools/render-svg-icon.swift | 54 | 0 |

### 修改文件

- AGENTS.md
- Makefile
- Resources/AppIcon.svg
- Resources/AppIcon-1024.png
- Resources/AppIcon.icns
- Tools/render-svg-icon.swift
