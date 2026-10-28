## [2026-10-20 13:44 +0800] | 任务：自动刷新档位移除 1/2 分钟，下限提高至 5 分钟

### 执行上下文

- **Agent ID**：`zcode`
- **Base Model**：`GLM-5.3（account:zai-individual-coding-plan/GLM-5.3）`
- **Runtime**：`macOS 25.6.0 arm64 · SwiftPM · ZCode Desktop`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> 自动刷新把 1、2 分钟去掉，最低 5 分钟。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/RefreshSettings.swift`、`docs/exec-plans/active/energy-refresh-optimization.md`。

**主要操作**：

- **操作一**：`RefreshSettings.availableMinutes` 由 `[1, 2, 5, 10, 15, 30, 60]` 改为 `[5, 10, 15, 30, 60]`。右键菜单（`main.swift:1871`）与设置页下拉（`SettingsPageView.swift:54`）均从该数组动态生成选项，无需另行改动；已持久化的 1/2 分钟值由 `load()` 的档位校验自动回退默认 5 分钟，无需迁移代码。
- **操作二**：同步更新执行计划 `active/energy-refresh-optimization.md` 中「刷新档位调整」的不包含条目，注明该项已于本次单独落地。

### 设计动机

耗电诊断（见 `docs/exec-plans/active/energy-refresh-optimization.md` 背景）确认 Codex 每次刷新都会 spawn 一个 app-server 子进程：默认 5 分钟档位每天 288 次起停，1 分钟档位高达 1440 次。在拉取常驻化改造落地前，先收紧档位下限，直接封掉最重的档位。档位表是单一定义点，菜单与设置页自动跟随，改动面最小。

### 验证结果

- 命令与结果：`swift build` 通过（Build complete! 4.07s）。
- 手工验证及设备：未执行——改动为纯档位表收缩，当前运行中的实例仍持有旧数组，重启应用后右键菜单与设置页将只显示 5-60 分钟档位。
- 未覆盖场景：无测试引用 `availableMinutes` 档位表；已持久化 1/2 分钟的用户重启后静默回退 5 分钟，未真机复验该路径（`load()` 的档位外回退逻辑为既有行为，本次未改动）。

### 变更统计

> 使用 `git diff HEAD -- Sources/LocalQuotaBar/RefreshSettings.swift` 统计；执行计划文档为本次会话早前新建的未跟踪文件，本任务仅同步其中一行，不计入下表；默认排除历史记录自身。

- **统计口径**：任务开始前快照 = `HEAD`（4e970da）+ 工作区，仅统计 `RefreshSettings.swift`。
- **变更文件数**：1
- **新增行数**：+1
- **删除行数**：-1

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/RefreshSettings.swift` | 1 | 1 |

### 修改文件

- `Sources/LocalQuotaBar/RefreshSettings.swift`
- `docs/exec-plans/active/energy-refresh-optimization.md`（同步不包含条目，未跟踪文件）
