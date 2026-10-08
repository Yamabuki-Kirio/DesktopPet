package asia.akechi.petlife.overlay

import java.io.File
import java.io.FileOutputStream

/**
 * 原生使用会话的**暂存队列**（Phase 4C-5.1B，需求 §4）。
 *
 * 存在的理由：Flutter 退出后 Dart 侧完全不能写 SQLite（`AppDatabase.close()`），
 * 原生又刻意不碰 Flutter 的库（双驱动 / schema 漂移 / 锁竞争）——
 * 因此"Flutter 没在跑的时候"产生的会话必须先在这里落地，等 Flutter 起来再幂等导入。
 *
 * 格式：**自己实现的 JSON-Lines 风格文本行**（制表符分隔 + 百分号转义）。
 * 不用 `org.json` 的原因：它在 JVM 单元测试里是"未实现的 Android 桩"，
 * 会让这一层无法被测试；而这里的字段全是扁平的字符串/整数，手写编解码更可控。
 *
 * 布局（应用内部存储）：
 * ```
 * filesDir/PetLife/usage_journal/
 *   ├── pending.jsonl   已结束、尚未被 Flutter 确认的会话（FIFO）
 *   └── open.jsonl      进行中会话的检查点（单行；进程异常终止后据此补齐）
 * ```
 *
 * 三条硬保证：
 * 1. **先落盘再算提交成功**：写入走"临时文件 + rename"，崩溃不会破坏已有记录；
 * 2. **幂等**：同一条记录可以被重复读取，但 Flutter 侧按 `session_id` 去重，
 *    因此重复读取不会重复进入业务库；
 * 3. **有界 + 隔离**：条数超过上限时丢弃最旧的；解析失败的行跳过并计数，绝不阻塞其余导入。
 */
internal class UsageSessionJournal(
    private val root: File,
    /**
     * 队列条数上限（超出后丢弃最旧的）。
     *
     * 做成参数而不是写死常量：单测需要一个很小的上限来验证"丢最旧"这条规则，
     * 否则得真的写入 2000 条记录（每次追加都要整体重写，代价是 O(n²)）。
     */
    private val maxRecords: Int = MAX_RECORDS,
) {

    companion object {
        /** 与 Flutter 侧 `AppConstants.appDataFolder` 一致。 */
        const val APP_DATA_FOLDER = "PetLife"

        const val SUBDIR = "usage_journal"
        const val PENDING_FILE = "pending.jsonl"
        const val OPEN_FILE = "open.jsonl"

        /**
         * 条数上限：超出后丢弃最旧的记录（宁可丢老数据，也不能让文件无限增长）。
         *
         * 取值 2000 是"留存天数"与"单次重写代价"的折中：每次追加都要整体重写以保证
         * 原子性，因此上限越大最坏情况下的单次写盘量越大。
         */
        const val MAX_RECORDS = 2_000

        private const val FIELD_COUNT = 11

        /** 与 [UsageSessionRecord] 的字段顺序（写死顺序 = 格式契约）。 */
        private const val FIELD_ORDER =
            "schemaVersion,sessionId,deviceLocalId,packageName,appName,category," +
                "startedAt,endedAt,activeSeconds,endReason,createdAt"

        /** 默认根目录（`context.filesDir` 下的应用私有目录）。 */
        fun of(filesDir: File): UsageSessionJournal =
            UsageSessionJournal(File(File(filesDir, APP_DATA_FOLDER), SUBDIR))
    }

    /** 目录是否可用（拿不到存储时降级为"什么都记不下"，但绝不崩）。 */
    private val available: Boolean = runCatching { root.mkdirs(); root.isDirectory }.getOrDefault(false)

    /** 最近一次读取时被隔离（解析失败）的行数 —— 诊断用。 */
    var lastCorruptLines: Int = 0
        private set

    /** 因超过上限被丢弃的记录数（累计，诊断用）。 */
    var droppedForCapacity: Int = 0
        private set

    // -----------------------------------------------------------------------
    // 已结束会话：写入 / 读取 / 确认
    // -----------------------------------------------------------------------

    /**
     * 追加一段已结束的会话。
     *
     * 返回是否写入成功。**先落盘再返回 true** —— 调用方据此决定要不要保留内存态。
     */
    fun append(record: UsageSessionRecord): Boolean {
        if (!available) {
            OverlayLog.warn("usage.journal.unavailable 无法写入使用记录（存储不可用）")
            return false
        }
        return runCatching {
            val existing = readPending(maxRecords)
            val merged = ArrayList<UsageSessionRecord>(existing.size + 1)
            // 同 session_id 只保留最新一份（幂等写入）。
            for (item in existing) {
                if (item.sessionId != record.sessionId) merged.add(item)
            }
            merged.add(record)
            val trimmed = trim(merged)
            writeLines(pendingFile(), trimmed.map { encode(it) })
            OverlayLog.log(
                "usage.journal.written id=${record.sessionId} pkg=${record.packageName} " +
                    "seconds=${record.activeSeconds} reason=${record.endReason} " +
                    "pending=${trimmed.size}",
            )
            true
        }.getOrElse { throwable ->
            // 写入失败绝不能影响采集：记录日志，由调用方决定是否重试。
            OverlayLog.error("usage.journal.write-failed pkg=${record.packageName}", throwable)
            false
        }
    }

    /** 读取最早的 [limit] 条未确认会话（FIFO；损坏行被隔离并计数）。 */
    fun readPending(limit: Int): List<UsageSessionRecord> {
        if (!available) return emptyList()
        return runCatching {
            val lines = pendingFile().takeIf { it.isFile }?.readLines().orEmpty()
            val out = ArrayList<UsageSessionRecord>(minOf(limit, lines.size))
            var corrupt = 0
            for (line in lines) {
                if (line.isBlank()) continue
                val record = decode(line)
                if (record == null) {
                    corrupt++
                    continue
                }
                out.add(record)
                if (out.size >= limit) break
            }
            lastCorruptLines = corrupt
            if (corrupt > 0) {
                OverlayLog.warn(
                    "usage.journal.corrupt 发现 $corrupt 行无法解析（已隔离，不影响其余记录）",
                )
            }
            out
        }.getOrElse { throwable ->
            OverlayLog.error("usage.journal.read-failed", throwable)
            emptyList()
        }
    }

    /**
     * 按 `session_id` 确认并删除（Flutter 侧**本地事务成功之后**才会调用）。
     *
     * 返回真正删除的条数。重复确认是幂等的（找不到就什么也不做）。
     */
    fun acknowledge(sessionIds: Collection<String>): Int {
        if (!available || sessionIds.isEmpty()) return 0
        val targets = sessionIds.toHashSet()
        return runCatching {
            val existing = readPending(maxRecords)
            val remaining = existing.filter { it.sessionId !in targets }
            val removed = existing.size - remaining.size
            if (removed > 0) {
                writeLines(pendingFile(), remaining.map { encode(it) })
                OverlayLog.log(
                    "usage.journal.acknowledged removed=$removed pending=${remaining.size}",
                )
            }
            removed
        }.getOrElse { throwable ->
            OverlayLog.error("usage.journal.ack-failed", throwable)
            0
        }
    }

    /** 待导入条数（诊断 / 界面展示；损坏行不计入）。 */
    fun pendingCount(): Int = readPending(maxRecords).size

    // -----------------------------------------------------------------------
    // 开放会话检查点
    // -----------------------------------------------------------------------

    /** 写入（或清除）进行中会话的检查点。 */
    fun writeOpen(session: OpenUsageSession?) {
        if (!available) return
        runCatching {
            val file = openFile()
            if (session == null) {
                if (file.exists()) file.delete()
                return
            }
            writeLines(file, listOf(encodeOpen(session)))
        }.onFailure {
            // 检查点写不进去只影响"异常退出后的补齐精度"，不能让采集失败。
            OverlayLog.warn("usage.journal.open-checkpoint-failed", it)
        }
    }

    /** 读取遗留的开放会话检查点（没有则返回 null）。 */
    fun readOpen(): OpenUsageSession? {
        if (!available) return null
        return runCatching {
            val file = openFile()
            if (!file.isFile) return null
            val line = file.readLines().firstOrNull { it.isNotBlank() } ?: return null
            decodeOpen(line)
        }.getOrElse { throwable ->
            OverlayLog.warn("usage.journal.open-read-failed", throwable)
            null
        }
    }

    /** 诊断摘要（设置页「journal 状态」用）。 */
    fun summary(): Map<String, Any?> = linkedMapOf(
        "available" to available,
        "pending" to pendingCount(),
        "maxRecords" to maxRecords,
        "corruptLines" to lastCorruptLines,
        "droppedForCapacity" to droppedForCapacity,
        "fieldOrder" to FIELD_ORDER,
    )

    // -----------------------------------------------------------------------
    // 编解码（扁平字段 + 百分号转义；不引 JSON 依赖）
    // -----------------------------------------------------------------------

    private fun encode(record: UsageSessionRecord): String = listOf(
        record.schemaVersion.toString(),
        record.sessionId,
        record.deviceLocalId,
        record.packageName,
        record.appName ?: "",
        record.category ?: "",
        record.startedAt.toString(),
        record.endedAt.toString(),
        record.activeSeconds.toString(),
        record.endReason,
        record.createdAt.toString(),
    ).joinToString("\t") { escape(it) }

    private fun decode(line: String): UsageSessionRecord? {
        val parts = line.split('\t')
        if (parts.size != FIELD_COUNT) return null
        val values = parts.map { unescape(it) }
        val version = values[0].toIntOrNull() ?: return null
        if (version != USAGE_SESSION_SCHEMA_VERSION) return null
        val startedAt = values[6].toLongOrNull() ?: return null
        val endedAt = values[7].toLongOrNull() ?: return null
        val activeSeconds = values[8].toIntOrNull() ?: return null
        val createdAt = values[10].toLongOrNull() ?: return null
        if (values[1].isEmpty() || values[3].isEmpty()) return null
        if (activeSeconds < 0 || endedAt < startedAt) return null
        return UsageSessionRecord(
            sessionId = values[1],
            deviceLocalId = values[2],
            packageName = values[3],
            appName = values[4].ifEmpty { null },
            category = values[5].ifEmpty { null },
            startedAt = startedAt,
            endedAt = endedAt,
            activeSeconds = activeSeconds,
            endReason = values[9].ifEmpty { UsageSessionEndReason.processRecovery.wire },
            createdAt = createdAt,
        )
    }

    private fun encodeOpen(session: OpenUsageSession): String = listOf(
        session.sessionId,
        session.packageName,
        session.appName ?: "",
        session.category ?: "",
        session.startedAt.toString(),
        session.creditUpToMs.toString(),
        session.activeMillis.toString(),
        session.createdAt.toString(),
    ).joinToString("\t") { escape(it) }

    private fun decodeOpen(line: String): OpenUsageSession? {
        val parts = line.split('\t')
        if (parts.size != 8) return null
        val values = parts.map { unescape(it) }
        val startedAt = values[4].toLongOrNull() ?: return null
        val creditUpTo = values[5].toLongOrNull() ?: return null
        val activeMillis = values[6].toLongOrNull() ?: return null
        val createdAt = values[7].toLongOrNull() ?: return null
        if (values[0].isEmpty() || values[1].isEmpty()) return null
        return OpenUsageSession(
            sessionId = values[0],
            packageName = values[1],
            appName = values[2].ifEmpty { null },
            category = values[3].ifEmpty { null },
            startedAt = startedAt,
            creditUpToMs = creditUpTo,
            activeMillis = activeMillis.coerceAtLeast(0L),
            createdAt = createdAt,
        )
    }

    private fun escape(value: String): String {
        if (value.isEmpty()) return value
        val sb = StringBuilder(value.length + 8)
        for (ch in value) {
            when (ch) {
                '%' -> sb.append("%25")
                '\t' -> sb.append("%09")
                '\n' -> sb.append("%0A")
                '\r' -> sb.append("%0D")
                else -> sb.append(ch)
            }
        }
        return sb.toString()
    }

    private fun unescape(value: String): String {
        if (value.indexOf('%') < 0) return value
        val sb = StringBuilder(value.length)
        var i = 0
        while (i < value.length) {
            val ch = value[i]
            if (ch == '%' && i + 3 <= value.length) {
                when (value.substring(i + 1, i + 3).uppercase()) {
                    "25" -> { sb.append('%'); i += 3; continue }
                    "09" -> { sb.append('\t'); i += 3; continue }
                    "0A" -> { sb.append('\n'); i += 3; continue }
                    "0D" -> { sb.append('\r'); i += 3; continue }
                }
            }
            sb.append(ch)
            i++
        }
        return sb.toString()
    }

    // -----------------------------------------------------------------------
    // 文件
    // -----------------------------------------------------------------------

    private fun pendingFile(): File = File(root, PENDING_FILE)

    private fun openFile(): File = File(root, OPEN_FILE)

    /**
     * 原子写：先写 `*.tmp` 并 fsync，再 rename 覆盖目标文件。
     *
     * 这样"写到一半崩溃"只会留下一个临时文件，`pending.jsonl` 永远是上一次的完整内容。
     */
    private fun writeLines(target: File, lines: List<String>) {
        val tmp = File(target.parentFile, "${target.name}.tmp")
        FileOutputStream(tmp).use { stream ->
            stream.write((lines.joinToString("\n") + if (lines.isEmpty()) "" else "\n").toByteArray())
            stream.flush()
            runCatching { stream.fd.sync() }
        }
        if (!tmp.renameTo(target)) {
            // 个别文件系统不支持直接覆盖 rename：退化为"删除 + 重命名"，并如实记录。
            if (target.exists() && !target.delete()) {
                throw IllegalStateException("无法覆盖 journal 文件：${target.name}")
            }
            if (!tmp.renameTo(target)) {
                throw IllegalStateException("无法重命名临时 journal 文件：${target.name}")
            }
        }
    }

    /** 控制条数上限：超限时丢弃**最旧**的记录并计数。 */
    private fun trim(records: List<UsageSessionRecord>): List<UsageSessionRecord> {
        if (records.size <= maxRecords) return records
        val drop = records.size - maxRecords
        droppedForCapacity += drop
        OverlayLog.warn(
            "usage.journal.trimmed 丢弃最旧的 $drop 条记录（上限 $maxRecords，累计 ${droppedForCapacity}）",
        )
        return records.subList(drop, records.size).toList()
    }
}
