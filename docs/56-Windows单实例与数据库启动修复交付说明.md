# Windows 单实例与数据库启动修复 —— 交付说明

交付日期：2026-10-24
交付提交：`d3311aa`（仓库 `petlife-sync-main`，基于 main `6b39dae`）
分发目录：`dist_release_d3311aa/`（33 MB 整目录，含 petlife.exe / flutter_windows.dll / sqlite3.dll / data 等 10 项）

---

## 一、交付物清单

| 交付物 | 位置 |
|---|---|
| Windows Runner 单实例协调器 | `windows/runner/single_instance_coordinator.{h,cpp}` |
| 主实例唤醒 / 退出通道 | `windows/runner/flutter_window.{h,cpp}`（`app_lifecycle` 通道）+ `lib/platform/app_lifecycle.dart` + `lib/platform/windows/windows_app_lifecycle.dart` |
| 统一退出控制器 | `lib/core/app_exit.dart`（ShutdownCoordinator）+ `lib/app/app_scope.dart`（runShutdownTransaction / requestShutdown） |
| 数据目录启动前检查 | `lib/database/storage_preflight.dart` + 中文诊断页 `lib/ui/storage_failure_app.dart` |
| 幂等自启注册逻辑 | `lib/platform/windows/windows_startup_registrar.dart`（pruneLegacyEntries）+ `lib/settings/startup_registration_service.dart` |
| 自动化测试 | `test/windows_native_single_instance_test.dart`、`test/app_exit_test.dart`、`test/storage_preflight_test.dart`、`test/windows_app_lifecycle_test.dart`、`test/data_root_gating_test.dart` |
| 真实进程验收脚本 | `tool/acceptance_single_instance.ps1` |
| Release 整目录分发包 | `dist_release_d3311aa/` |

## 二、机制说明（对照规格）

1. **单实例仲裁前移**：`wWinMain` 最先仲裁 `Local\PetLife.Desktop.SingleInstance.v1` 命名互斥体；第二实例不初始化 Flutter / SQLite / 托盘，经消息窗口通知主实例后立即退出。进程级存在标记，异常退出由 Windows 自动释放。未使用文件锁。
2. **统一退出事务**：控制面板退出、托盘退出、窗口关闭、系统注销/关机（WM_QUERYENDSESSION/WM_ENDSESSION）、`--shutdown`（更新程序/验收脚本）全部收敛到 `AppServices.requestShutdown`；按规格§二固定顺序执行（冻结新任务→停采集→落盘当前活动段→停同步→关 SQLite 与日志→移除托盘与窗口→释放互斥体→结束进程）；事务只执行一次，看门狗 2.5 秒强制结束。
3. **禁止提权启动**：`runner.exe.manifest` 固定 `requestedExecutionLevel level="asInvoker"`。
4. **数据库启动前检查**：目录存在性 → 探针文件（PID 唯一名 + 多策略重试）→ `petlife.db`/`-wal`/`-shm` 只读校验 → 打开后轻量写事务（PRAGMA user_version 回写）。失败显示中文诊断页（打开数据目录 / 复制诊断信息 / 退出），不暴露原始 SQLite 堆栈，不自动删除/重建/移动用户数据库。
5. **自启入口收敛**：启动对齐幂等覆盖 `HKCU\...\Run\PetLife` 为当前 exe 绝对路径；清理仅限已知旧版条目（`PetLifeDesktopPet`，且内容必须指向 petlife），不扫描其他软件配置。
6. **第二实例行为**：已实现规格§六表格（唤醒 / 退出中等待提示 / 无响应提示 / 数据目录不可写中文诊断）。

## 三、真机验收结果（petlife-sync-main 构建，本机 Windows 10 Pro 22H2）

| 验收项 | 结果 | 实测 |
|---|---|---|
| 连续快速启动 20 次（400ms 节奏） | PASS | 每个检查点（1/2/5/10/20 次）后本构建进程数均为 1 |
| 请求退出（--shutdown 转交）后 3 秒内归零 | PASS | **196ms** |
| 再次启动 → 1 个进程、数据库可写 | PASS | 实际=1 |
| `petlife.db` 保留（不删除/重建） | PASS | db + wal + shm 齐全 |

自动化测试：**1620 项全部通过**（`flutter test`），`flutter analyze` 无告警。

验收命令（单行，可复跑）：

```
powershell -ExecutionPolicy Bypass -File tool\acceptance_single_instance.ps1 -ExePath build\windows\x64\runner\Release\petlife.exe
```

## 四、交付审查问题处置（本轮修正记录）

1. **环境变量门控**：`PETLIFE_DATA_ROOT` 现在**只在命令行显式带 `--acceptance` 时生效**（`StorageAcceptanceMode.parseFromArgs`，Runner 经 entrypoint arguments 传入 main）。正式运行绝不读取该环境变量；持久环境变量已从系统删除。验收脚本所有启动均带 `--acceptance`。
2. **诊断页目录显示**：`AppPaths.describeDataRoot()` 按启动口径（override / 验收环境变量 / 默认 AppData）返回本次实际试图使用的目录，诊断页不再显示 `<无法解析>`；顺带修复诊断页「复制诊断信息」的 `ScaffoldMessenger` 空指针。
3. **仓库迁移**：全部修复已迁移至 `petlife-sync-main` 并以提交 `d3311aa` 落在 `main`；迁移方式为逐文件比对（仅 `app_scope.dart` 有新仓库独立改动 `liveSegmentProvider`，已在其上手工重放，未覆盖丢失）。旧工作区 `petlife`（backup/main-before-duration-fix）不再作为交付来源。

## 五、过程中发现并修复的缺陷（回归价值）

1. **SinkWndProc 假 ack（严重）**：接收窗口未绑定 `GWLP_USERDATA`，信号处理回调永不执行且仍返回 ack——第二实例以为通知成功而退出，主实例毫无动作（唤醒与退出请求无声丢失）。已修复并在真机验证（退出归零从「不生效」变为 196ms）。
2. 探针文件竞争：探针名带 PID + 启动前清理残留探针，避免跨运行共享冲突。
3. `AppDatabase.open` 现显式使用注入平台的数据库后端（装配封闭、可测）。
4. 诊断页 SnackBar context 空指针。

## 六、边界与遗留说明

1. **本机当前仍有 34 个旧版 petlife.exe 僵尸进程**（10月5日起积累，路径/命令行不可读，属旧版本产物，权限状态异常）。新代码无法控制它们；**首次安装修复版前请真正重启一次 Windows**。重启后由新机制阻止再次积累。
2. 本机存在针对"未信任新进程向既有目录写入新文件"的安全防护（探针写入 errno=5，但同进程自建目录、日志写入正常；dart.exe 同目录写入正常）。验收脚本因此让被测实例**自建**沙箱数据目录（预检第 1 步的正常路径）。这不影响真实用户环境（用户正常启动时数据目录由应用自建）。
3. 验收覆盖了规格§八第 1–7、9–12 项的机制路径与自动化等价项；「数据目录设为不可写」「恢复权限后无需删库」两项已由真实只读属性（attrib +R）的自动化测试与此前真机诊断页反复触发所验证（诊断页内容与规格文案一致）。
4. 版本号与安装方式未改动（冻结边界§七遵守）；Android / 服务端 / 表结构 / 统计口径 / UI 均未修改。
