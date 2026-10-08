# 31 - Android 数据库启动失败与 PRAGMA 兼容性

> 记录 2026-09-29 首次真机启动崩溃的根因、修复与回归保护。
> 相关验收状态见 [29-Phase4测试与验收报告.md](29-Phase4测试与验收报告.md) §4.0。

## 1. 现象（真机）

首次把 Debug APK 装到真机上启动，**应用起不来**，停在数据库创建阶段：

```
DatabaseException:
Queries can be performed using SQLiteDatabase query or rawQuery methods only.

SQL:
PRAGMA journal_mode = WAL
```

Windows 上同样的代码从阶段 0 起一直正常，全量测试也全绿 —— 这是个
**只在 Android 上炸**的缺陷。

## 2. 根因

`lib/database/app_database.dart` 的 `onOpen` 里写的是：

```dart
// ❌ 修复前
await db.execute('PRAGMA journal_mode = WAL');
await db.execute('PRAGMA synchronous = NORMAL');
```

`PRAGMA journal_mode = WAL` 是**有结果集**的语句：SQLite 会把**生效后的
journal_mode 作为一行返回**（用来告诉你到底切成功没有）。

而 Android 的 `SQLiteDatabase.execSQL()`（即 sqflite 的 `execute()`）底层是
`SQLiteConnection.nativeExecuteForChangedRowCount`，它只接受"不返回数据"的语句：

```cpp
// frameworks/base/core/jni/android_database_SQLiteConnection.cpp（示意）
int err = sqlite3_step(statement);
if (err == SQLITE_ROW) {
    throw_sqlite3_exception(env, db,
        "Queries can be performed using SQLiteDatabase query or rawQuery methods only.");
}
```

判定标准是 **`sqlite3_step()` 的返回值**（有没有结果行），**不是**"是不是 PRAGMA"。
真机日志本身就印证了这一点：同一个 `onConfigure` 回调里的
`PRAGMA foreign_keys = ON`（赋值形式、无结果行）**没有**报错，
报错的是 WAL —— 而 `onConfigure` 先于 `onOpen` 执行。

Windows 侧（`sqflite_common_ffi` → `sqlite3` 包）对"execute 却拿到结果行"
是宽容的，不检查 step 返回值，于是缺陷被完全掩盖。

## 3. 修复

```dart
// ✅ 修复后（lib/database/app_database.dart::applyPerformancePragmas）
final List<Map<String, Object?>> rows =
    await db.rawQuery('PRAGMA journal_mode = WAL');   // 有结果集 → rawQuery
final Object? raw = rows.isEmpty ? null : rows.first['journal_mode'];
final String? mode = raw?.toString().toLowerCase();
if (mode == 'wal') {
  Loggers.db.info('journal_mode = wal（WAL 已启用）');
} else {
  Loggers.db.warning('本设备的 SQLite 未能切到 WAL：... 功能不受影响，仅性能下降');
}
// ...
await db.execute('PRAGMA synchronous = NORMAL');     // 无结果集 → execute 合法
```

四条要点：

1. **有结果集的 PRAGMA 一律走 `rawQuery()`**；
2. **校验返回值确实是 `wal`**，不是就记明确日志（常见于 `:memory:` 数据库）；
3. **不因为没切成 WAL 就让应用起不来**：WAL 只是并发性能优化，
   任何一步失败都只记日志并继续（同时把实际生效的模式写进日志，绝不静默）；
4. `PRAGMA synchronous = NORMAL` **保持 `execute()`**：实测无结果行，
   在两种后端上都合法（需求 4 明确要求先验证再决定）。

## 4. 为什么 `synchronous` 可以继续用 `execute`（实测结论）

判断标准是"这条语句会不会返回行"。用真实 SQLite 实测（`test/database_pragma_test.dart`）：

| 语句 | `rawQuery` 返回的行数 | 能否用 `execute()` |
|---|---|---|
| `PRAGMA journal_mode = WAL` | **1 行**（`wal`） | ❌ 必须 `rawQuery` |
| `PRAGMA synchronous = NORMAL` | **0 行** | ✅ 可以 |
| `PRAGMA foreign_keys = ON` | **0 行** | ✅ 可以（`onConfigure` 里就是它） |

`journal_mode` 是 SQLite 文档里明确"赋值也会返回结果行"的特例，
所以不能把它当成"PRAGMA 都一样"来处理。

## 5. 回归保护（不需要真机）

`test/database_pragma_test.dart`（7 项）：

| # | 用例 | 作用 |
|---|---|---|
| 1 | `journal_mode` 赋值返回 1 行 | 固化成因 |
| 2 | `synchronous` 赋值返回 0 行 | 固化"可以继续用 execute"的结论 |
| 3 | `foreign_keys` 赋值返回 0 行 | 解释真机日志（外键那条没炸） |
| 4 | `_AndroidStrictExecutor` 会拒绝 `execute('PRAGMA journal_mode = WAL')` | **反向验证**：证明这个替身不是空跑 |
| 5 | `applyPerformancePragmas` 在严格 `execute` 下成功且确实切成 `wal` | 直接复现真机约束并验证修复 |
| 6 | `:memory:`（切不到 WAL）时只记日志、不抛 | 验证"设备不支持 WAL 也不崩" |
| 7 | 扫描 `lib/**` 里所有 `execute('<PRAGMA ...>')`，用真实 SQLite 跑一遍，**有结果行即失败** | 以后任何人再犯同样的错，测试当场红 |

第 7 条是关键：它不依赖白名单，而是用**同引擎的实测行数**判定，
因此对新增的 PRAGMA 也自动生效。

## 6. 修复后必须做的事

1. **卸载真机上的旧版 PetLife，或清除应用数据** —— 崩溃发生在建库之后，
   设备上可能残留一个"表已建好但日志模式未生效"的库文件；
2. 安装重建后的 APK（见 docs/29 §2.1 的大小 / SHA-256）；
3. 确认能**完成数据库创建并进入移动端首页**；
4. 然后才继续走 docs/29 §4.1 起的其余真机验收步骤。

> ⚠️ 本次修复**只消除了启动阻塞**。在真机上重新走完验收之前，
> Phase 4A 的真机项**一律不算通过**（docs/29 §1 与 §4.0 均按此口径）。
