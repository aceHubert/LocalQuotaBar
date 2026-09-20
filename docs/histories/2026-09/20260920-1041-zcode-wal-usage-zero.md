## [2026-09-20 10:41 +0800] | 任务：修复 Zcode 本地用量读库为 0

### 执行上下文

- **Agent ID**：`codex`
- **Base Model**：`未知`
- **Runtime**：`Codex Desktop（macOS）`
- **Git User**：`hubert <hubert@lejian.com>`
- **Branch**：`main`

### 用户诉求

> Zcode 的统计应用用量全部显示为 0，确认是数据库没数据还是异常，并处理截图中的用量图问题。

### 变更概览

**影响范围**：`Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`

**主要操作**：

- 诊断确认 `~/.zcode/cli/db/db.sqlite` 内仍有近 30 天用量数据，数据库并未清空。
- 定位 Zcode 数据库为 WAL 模式；在 `wal/shm` 伴文件不存在时，`SQLITE_OPEN_READONLY` 连接会在 `prepare` 阶段返回 `SQLITE_CANTOPEN`，导致应用按“无数据”补 0。
- 将两处 SQLite 连接改为 `READWRITE` 打开并立即开启 `PRAGMA query_only = ON`，保留业务层只读语义，同时允许 SQLite 恢复 WAL 共享内存。

### 设计动机

只读打开 WAL 数据库时，SQLite 可能需要重建共享内存文件；如果连接本身不可写，会在准备查询时失败。应用不应修改 Zcode 数据库，因此采用“可写连接 + query_only”的组合：连接阶段具备恢复 WAL 元数据的能力，业务查询阶段禁止写入。

### 验证结果

- `swift build`：通过。
- `swift test --filter ZAIUsagePresentationTests`：4 个用例通过。
- 使用独立编译的最小诊断程序验证：
  - 修复前 `last30Days()` 返回总量 `0`，SQLite `prepare` 返回 `14 unable to open database file`。
  - 修复后全渠道近 30 天返回 `2,984,450,512 tokens`，排除套餐渠道返回 `1,082,448,860 tokens`。
- 未覆盖场景：未重新打包并替换 `/Applications/LocalQuotaBar.app`，需用户确认后安装验证面板显示。

### 变更统计

- **统计口径**：当前工作区中 `ZCodeUsageDB.swift` 的本次任务差异；排除历史记录自身。
- **变更文件数**：1
- **新增行数**：+8
- **删除行数**：-2

| 文件 | 新增 | 删除 |
| --- | ---: | ---: |
| `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift` | 8 | 2 |

### 修改文件

- `Sources/LocalQuotaBar/zcode/ZCodeUsageDB.swift`
