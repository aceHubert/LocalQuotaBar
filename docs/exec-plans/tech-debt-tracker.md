# 技术债追踪

这里记录暂时不阻塞当前任务、但已经明确推迟且值得留档的技术债。后续动作应说明触发条件，并尽可能关联执行计划；已解决的事项在验证依据补齐后直接删除该行。

| 日期 | 区域 | 债务描述 | 为什么会存在 | 计划中的后续动作 |
| --- | --- | --- | --- | --- |
| 2026-09-15 | 额度面板 | 30 天用量图 tooltip 的第二指标「提示 N 次」（原型 tooltip：`5h 峰值 68% · 提示 31 次`）暂不实现 | Z.AI 侧 zcode SQLite `model_usage` 有每日请求数（`COUNT(*)`）可显示，但 Codex `account/usage/read` 只返回每日 tokens、无请求数；两家口径不统一 | 落地时 tooltip 只显示「M月d日 · xx.xM tokens」；若后续 Codex 暴露请求数再统一加上 |
| 2026-09-15 | 设置 | 完整版设置页的「开机自启」「菜单栏显示」「关于」区块未实现 | 用户确认采用 lite 版；开机自启需引入 SMAppService 等新系统能力，属业务逻辑变更 | 如后续需要开机自启，单开执行计划（SMAppService + 菜单入口 + 状态回读） |
| 2026-09-15 | 重置逻辑 | Codex 重置幂等键存储没有跨进程文件锁（ZAI 侧有）：仅实例内 `inFlightKey` 互斥，原子写入不能防止两个实例基于旧数据互相覆盖，可能为同一张卡生成不同幂等键，也可能覆盖其他卡的 pending 记录（`CodexResetService.swift` 的键分配与落盘路径）。未确认键的最终归宿取决于上游对重复 consume 的响应，只读验收未验证服务端防重复消费行为，不做断言 | Codex 重置计划未要求跨实例保护，菜单栏应用默认单实例运行；ZAI 侧经审查补充了 flock 后两侧未同步 | 如需支持多实例，参照 `ZAIResetService` 的独立 lock 文件 + 持锁重读方案补齐 `CodexResetService`；落地前先只读核对 app-server 对不同幂等键重复 consume 的响应 |
| 2026-09-15 | 重置逻辑 | Codex 重置存储不可读时按钮仍显示可点的「重置/重试」：`main.swift` `codexResetAction` 的 `.failed` 分支不区分 `storageIsUnreadable`，账号、刷新等条件允许即启用；点击后才被 `CodexResetService.use()` 的存储检查拒绝，不会发出请求（fail-closed 成立，仅体验问题） | `storageIsUnreadable` 是服务私有状态，按钮状态计算在 AppDelegate，未透出到 UI 层 | 将存储不可读透出到按钮状态（禁用 + tooltip 说明），或在 `codexResetAction` 查询服务存储健康度 |
| 2026-09-15 | 重置逻辑 | Codex `CodexResetService` 仅在初始化时读取存储文件，`storageIsUnreadable` 置位后没有重读或复位路径；修复文件后需重建服务实例，当前应用实际需要重启。ZAI 侧持锁重读、成功后复位标志，两侧行为不一致 | Codex 侧没有持锁重读机制（见跨进程锁条目），init 一次性读取是最简实现 | 若补跨进程锁则顺带引入提交前重读路径并一并复位标志；否则可在 `use()` 入口尝试重读并复位 |
| 2026-09-18 | 额度面板 | 弹窗整页截图未取得（无屏幕录制/辅助功能权限），交互验证依赖系统辅助功能只读核对与像素级单元测试 | 验收环境权限限制 | 若需视觉回归留档，补 ScreenCaptureKit 权限后截图归档 |
| 2026-09-18 | 周配速图 | 月限窗口（Codex free 账号 25~35 天）未启用配速图：`refreshCodexPaceChart` 以 \|mins − 7天\| ≤ 1 天门控 | 首期按计划只放开 7±1 天窗口；推导层 `WeeklyPaceSnapshot.make` 已按任意窗口时长泛化 | 放开时只需放宽接线层门控并补充长窗口刻度规则（M/d + stride 2 已实现）与月限窗口的 E 语义评估 |
| 2026-09-19 | 用量口径 | 本机走 `account:bigmodel-team-coding-plan`（团队套餐渠道）但当前选中个人套餐时，这部分用量两头不显示：不在 zai 个人套餐的 model-usage 里，又被 `%coding-plan` 排除规则从橙段剔除（实测当日 95 万不可见；不双计口径定案后此边界恢复存在） | 服务端 sync 上下文跟随当前选中的套餐；排除集合按前缀宽松匹配无法区分个人/团队套餐 | 量级小暂不处理；如需覆盖，可在本地排除集合中按 domain/connection 精确排除"当前套餐渠道"，或团队渠道单独走 bigmodel 服务端同步 |
| 2026-09-19 | 用量口径 | 其他设备/入口用 z.ai API Key 的平台消耗（走平台余额、不占套餐额度）不出现在应用任何统计段：不进套餐 model-usage（绿段）、不写本机 SQLite（橙段） | 应用数据源只有两个：套餐 monitor（OAuth）与本机 zcode 库；平台 API 用量是第三种鉴权体系，未接入 | 如需展示，新增平台 API 用量数据源（api.z.ai / open.bigmodel.cn 控制台用量接口）并单独立项评估；当前用户可在控制台账单页查看 |
