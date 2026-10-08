package asia.akechi.petlife.overlay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Phase 4C-5.1B：原生应用会话状态机与暂存队列的**纯逻辑**测试。
 *
 * 覆盖需求 §13.1 里可以在 JVM 上真实验证的部分：持续使用、正常切换、切到桌面、
 * 熄屏、权限撤销、暂停与恢复、短暂空快照防抖、服务销毁、异常开放会话恢复、
 * journal 重复读取 / 确认删除 / 损坏隔离 / 原子写入不丢旧数据。
 *
 * **不在这里假装通过**的条目（需要真实 `UsageStatsManager` / 真机）：
 * 真机前台切换与 `ACTION_SCREEN_OFF` 广播、进程被系统杀死后的真实恢复、
 * 服务销毁时序 —— 它们属于真机验收（见 docs/35 §12）。
 */
class UsageSessionTrackerTest {

    /** 固定 1.5 秒采样、切换确认 1.5 秒、容错 6 秒（与真机默认参数一致）。 */
    private class Fixture(config: UsageSessionConfig = UsageSessionConfig()) {
        var counter = 0
        var deviceId = "device-local-1"
        val tracker = AndroidUsageSessionTracker(
            config = config,
            idFactory = { "session-${++counter}" },
            deviceLocalId = { deviceId },
            clock = { 0L },
        )

        fun observe(
            packageName: String?,
            at: Long,
            countable: Boolean = true,
            appName: String? = null,
            category: String? = null,
        ): List<UsageSessionRecord> = tracker.observe(
            UsageObservation(
                packageName = packageName,
                appName = appName,
                category = category,
                countable = countable,
                observedAt = at,
            ),
        )
    }

    private val a = "com.example.a"
    private val b = "com.example.b"
    private val launcher = "com.android.launcher3"

    @Test
    fun `同一应用持续使用只产生一段，且时长等于观察跨度`() {
        val f = Fixture()
        assertTrue(f.observe(a, at = 0).isEmpty())
        assertTrue(f.observe(a, at = 2_000).isEmpty())
        assertTrue(f.observe(a, at = 4_000).isEmpty())
        assertNotNull(f.tracker.open)

        val done = f.tracker.onServiceStopped(4_000)
        assertEquals(1, done.size)
        assertEquals(a, done[0].packageName)
        assertEquals(4, done[0].activeSeconds)
        assertEquals(UsageSessionEndReason.serviceStopped.wire, done[0].endReason)
        assertEquals(0L, done[0].startedAt)
        assertEquals(4_000L, done[0].endedAt)
        assertNull(f.tracker.open)
    }

    @Test
    fun `应用切换需要确认窗口，确认后 A 结束于候选出现时刻且与 B 不重叠`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 2_000)

        // B 第一次出现：A 记到 2000ms，并记下候选起点 4000。
        assertTrue(f.observe(b, at = 4_000).isEmpty())
        // 还没到确认窗口：不切段、也不继续给 A 计入。
        assertTrue(f.observe(b, at = 5_000).isEmpty())
        assertEquals(a, f.tracker.open?.packageName)
        // 到窗口了：A 结束于 4000，B 从 4000 开始。
        val done = f.observe(b, at = 6_000)

        assertEquals(1, done.size)
        assertEquals(a, done[0].packageName)
        assertEquals(4, done[0].activeSeconds)
        assertEquals(4_000L, done[0].endedAt)
        assertEquals(UsageSessionEndReason.appSwitch.wire, done[0].endReason)

        assertEquals(b, f.tracker.open?.packageName)
        assertEquals(4_000L, f.tracker.open?.startedAt)
    }

    @Test
    fun `候选在确认窗口内被证伪时保持原会话且不丢时间`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(b, at = 2_000) // 候选 B（A 记到 2000ms）
        assertTrue(f.observe(a, at = 3_000).isEmpty()) // B 消失，回到 A

        assertEquals(a, f.tracker.open?.packageName)
        // 回到 A 后一次性补齐 [2000, 3000]，因此这里没有白丢时间。
        val done = f.tracker.onServiceStopped(4_000)
        assertEquals(1, done.size)
        assertEquals(4, done[0].activeSeconds)
    }

    @Test
    fun `切到桌面只结束会话、不新开段`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 2_000)
        assertTrue(f.observe(launcher, at = 4_000, countable = false).isEmpty())
        val done = f.observe(launcher, at = 6_000, countable = false)

        assertEquals(1, done.size)
        assertEquals(a, done[0].packageName)
        // A 一直算到"桌面第一次出现"的时刻（4000ms），之后不再计入。
        assertEquals(4, done[0].activeSeconds)
        assertEquals(4_000L, done[0].endedAt)
        assertNull(f.tracker.open)
    }

    @Test
    fun `桌面上直接开始使用时不会开段`() {
        val f = Fixture()
        assertTrue(f.observe(launcher, at = 0, countable = false).isEmpty())
        assertTrue(f.observe(launcher, at = 2_000, countable = false).isEmpty())
        assertNull(f.tracker.open)
    }

    @Test
    fun `熄屏立即结束会话，原因 screen_off`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 3_000)
        val done = f.tracker.onScreenOff(3_000)
        assertEquals(1, done.size)
        assertEquals(UsageSessionEndReason.screenOff.wire, done[0].endReason)
        assertEquals(3, done[0].activeSeconds)
        assertNull(f.tracker.open)
    }

    @Test
    fun `权限撤销立即结束会话，原因 permission_revoked`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 3_000)
        val done = f.tracker.onPermissionRevoked(3_000)
        assertEquals(1, done.size)
        assertEquals(UsageSessionEndReason.permissionRevoked.wire, done[0].endReason)
    }

    @Test
    fun `暂停立即结束并停止新建，恢复后从新会话开始且不补算暂停期间`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 3_000)

        val paused = f.tracker.onPaused(3_000)
        assertEquals(1, paused.size)
        assertEquals(UsageSessionEndReason.collectionPaused.wire, paused[0].endReason)

        // 暂停期间：前台仍在 A，但不产生任何记录。
        assertTrue(f.observe(a, at = 60_000).isEmpty())
        assertNull(f.tracker.open)

        f.tracker.onResumed()
        assertTrue(f.observe(a, at = 70_000).isEmpty())
        assertEquals(70_000L, f.tracker.open?.startedAt)
        // 暂停期间的 67 秒没有被补算。
        assertEquals(0, f.tracker.currentElapsedSeconds(70_000))
    }

    @Test
    fun `短暂空快照在容错窗口内保持会话，超过后以最后一次可靠时间结束`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 2_000)

        assertTrue(f.observe(null, at = 3_000).isEmpty())
        assertNotNull(f.tracker.open)

        val done = f.observe(null, at = 9_000)
        assertEquals(1, done.size)
        assertEquals(UsageSessionEndReason.collectorUnavailable.wire, done[0].endReason)
        // 结束于最后一次可靠检测（2000ms），不含无法确认的 [2000, 9000]。
        assertEquals(2_000L, done[0].endedAt)
        assertEquals(2, done[0].activeSeconds)
    }

    @Test
    fun `空快照恢复成同一应用时继续保持原会话`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 2_000)
        f.observe(null, at = 3_000)
        assertTrue(f.observe(a, at = 4_000).isEmpty())

        val done = f.tracker.onServiceStopped(4_000)
        assertEquals(1, done.size)
        assertEquals(4, done[0].activeSeconds)
    }

    @Test
    fun `短于 2 秒的会话被丢弃（不产生碎片记录）`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 1_000)
        val done = f.tracker.onServiceStopped(1_000)
        assertTrue("1 秒的碎片必须被丢弃", done.isEmpty())
    }

    @Test
    fun `异常开放会话按 process_recovery 关闭且结束时间取检查点里的最后可靠时间`() {
        val f = Fixture()
        val recovered = OpenUsageSession(
            sessionId = "recovered-1",
            packageName = a,
            appName = "示例 A",
            category = AppCategoryId.SOCIAL,
            startedAt = 1_000,
            creditUpToMs = 31_000,
            activeMillis = 30_000,
            createdAt = 1_000,
        )
        val record = f.tracker.recover(recovered)
        assertNotNull(record)
        assertEquals("recovered-1", record!!.sessionId)
        assertEquals(UsageSessionEndReason.processRecovery.wire, record.endReason)
        assertEquals(31_000L, record.endedAt)
        assertEquals(30, record.activeSeconds)
        assertNull(f.tracker.open)
    }

    @Test
    fun `恢复出来的碎片同样被丢弃`() {
        val f = Fixture()
        val recovered = OpenUsageSession(
            sessionId = "recovered-short",
            packageName = a,
            appName = null,
            category = null,
            startedAt = 1_000,
            creditUpToMs = 2_000,
            activeMillis = 1_000,
            createdAt = 1_000,
        )
        assertNull(f.tracker.recover(recovered))
    }

    @Test
    fun `单次计入被夹在上限内，卡顿不会被算成使用时长`() {
        val f = Fixture(
            UsageSessionConfig(
                maxCreditPerObservationMs = 4_500L,
                switchConfirmMs = 1_500L,
                unavailableToleranceMs = 6_000L,
                minSessionSeconds = 2,
            ),
        )
        f.observe(a, at = 0)
        // 中间卡了 60 秒：只能计入 4.5 秒。
        f.observe(a, at = 60_000)
        val done = f.tracker.onServiceStopped(60_000)
        assertEquals(1, done.size)
        assertEquals(4, done[0].activeSeconds)
    }

    @Test
    fun `记录里带本机设备标识与会话 ID，且 id 在重放时保持不变`() {
        val f = Fixture()
        f.observe(a, at = 0)
        f.observe(a, at = 5_000)
        val first = f.tracker.onServiceStopped(5_000)
        assertEquals("device-local-1", first[0].deviceLocalId)
        assertEquals(USAGE_SESSION_SCHEMA_VERSION, first[0].schemaVersion)
        assertTrue(first[0].sessionId.isNotEmpty())
    }
}

class UsageSessionJournalTest {

    private lateinit var root: File

    private fun newJournal(maxRecords: Int = UsageSessionJournal.MAX_RECORDS): UsageSessionJournal {
        root = File(
            System.getProperty("java.io.tmpdir"),
            "petlife_usage_journal_${System.nanoTime()}",
        )
        root.mkdirs()
        return UsageSessionJournal(root, maxRecords)
    }

    @After
    fun cleanup() {
        if (::root.isInitialized && root.exists()) root.deleteRecursively()
    }

    private fun record(
        id: String,
        pkg: String = "com.example.a",
        startedAt: Long = 1_000,
        endedAt: Long = 5_000,
        seconds: Int = 4,
        reason: String = "app_switch",
        appName: String? = null,
    ) = UsageSessionRecord(
        sessionId = id,
        deviceLocalId = "device-local-1",
        packageName = pkg,
        appName = appName,
        category = AppCategoryId.SOCIAL,
        startedAt = startedAt,
        endedAt = endedAt,
        activeSeconds = seconds,
        endReason = reason,
        createdAt = 1_000,
    )

    @Test
    fun `写入后可原样读回（含特殊字符转义）`() {
        val journal = newJournal()
        assertTrue(journal.append(record("s1", appName = "应用\tA 100%")))

        val pending = journal.readPending(limit = 10)
        assertEquals(1, pending.size)
        assertEquals("s1", pending[0].sessionId)
        assertEquals("应用\tA 100%", pending[0].appName)
        assertEquals(4, pending[0].activeSeconds)
        assertEquals("device-local-1", pending[0].deviceLocalId)
        assertEquals(0, journal.lastCorruptLines)
    }

    @Test
    fun `重复读取是幂等的，不会改变内容`() {
        val journal = newJournal()
        journal.append(record("s1"))
        val first = journal.readPending(limit = 10)
        val second = journal.readPending(limit = 10)
        assertEquals(first, second)
        assertEquals(1, journal.pendingCount())
    }

    @Test
    fun `重复写入同一会话 ID 只保留一份`() {
        val journal = newJournal()
        journal.append(record("s1", seconds = 4))
        journal.append(record("s1", seconds = 9))
        val pending = journal.readPending(limit = 10)
        assertEquals(1, pending.size)
        assertEquals(9, pending[0].activeSeconds)
    }

    @Test
    fun `按限制条数读取，且按 FIFO 顺序`() {
        val journal = newJournal()
        for (i in 1..5) journal.append(record("s$i", startedAt = i * 1_000L, endedAt = i * 1_000L + 3_000))
        val batch = journal.readPending(limit = 3)
        assertEquals(listOf("s1", "s2", "s3"), batch.map { it.sessionId })
    }

    @Test
    fun `确认后记录被删除，重复确认是幂等的`() {
        val journal = newJournal()
        journal.append(record("s1"))
        journal.append(record("s2"))

        assertEquals(1, journal.acknowledge(listOf("s1")))
        assertEquals(0, journal.acknowledge(listOf("s1")))
        assertEquals(listOf("s2"), journal.readPending(limit = 10).map { it.sessionId })
    }

    @Test
    fun `损坏行被隔离，其余记录仍可正常读取`() {
        val journal = newJournal()
        journal.append(record("s1"))
        journal.append(record("s2"))
        // 人工注入一行坏数据（模拟"写到一半掉电"）。
        File(root, UsageSessionJournal.PENDING_FILE).appendText("这不是一条合法记录\n")

        val pending = journal.readPending(limit = 10)
        assertEquals(listOf("s1", "s2"), pending.map { it.sessionId })
        assertEquals(1, journal.lastCorruptLines)
    }

    @Test
    fun `超过上限时丢弃最旧的记录`() {
        val journal = newJournal(maxRecords = 3)
        for (i in 1..5) {
            journal.append(record("s$i", startedAt = i * 1_000L, endedAt = i * 1_000L + 3_000))
        }
        assertEquals(3, journal.pendingCount())
        assertEquals(2, journal.droppedForCapacity)
        // 留下的必须是最新的三条（FIFO 丢最旧）。
        assertEquals(listOf("s3", "s4", "s5"), journal.readPending(limit = 10).map { it.sessionId })
    }

    @Test
    fun `原子写入失败时不破坏已有记录`() {
        val journal = newJournal()
        assertTrue(journal.append(record("s1")))
        // 让临时文件位置变成一个目录 → 写入必然失败。
        File(root, "${UsageSessionJournal.PENDING_FILE}.tmp").mkdirs()

        assertFalse(journal.append(record("s2")))
        assertEquals(listOf("s1"), journal.readPending(limit = 10).map { it.sessionId })
    }

    @Test
    fun `存储不可用时安全降级，不抛异常`() {
        val file = File(System.getProperty("java.io.tmpdir"), "petlife_journal_not_a_dir_${System.nanoTime()}")
        file.writeText("x")
        try {
            val journal = UsageSessionJournal(file)
            assertFalse(journal.append(record("s1")))
            assertTrue(journal.readPending(limit = 10).isEmpty())
            assertEquals(0, journal.acknowledge(listOf("s1")))
            assertNull(journal.readOpen())
            assertFalse(journal.summary()["available"] as Boolean)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `开放会话检查点可写入、读回与清除`() {
        val journal = newJournal()
        val open = OpenUsageSession(
            sessionId = "open-1",
            packageName = "com.example.a",
            appName = "示例 A",
            category = AppCategoryId.SOCIAL,
            startedAt = 1_000,
            creditUpToMs = 11_000,
            activeMillis = 10_000,
            createdAt = 1_000,
        )
        journal.writeOpen(open)
        val read = journal.readOpen()
        assertNotNull(read)
        assertEquals("open-1", read!!.sessionId)
        assertEquals(11_000L, read.creditUpToMs)
        assertEquals(10_000L, read.activeMillis)

        journal.writeOpen(null)
        assertNull(journal.readOpen())
    }

    @Test
    fun `诊断摘要如实反映待导入数量`() {
        val journal = newJournal()
        journal.append(record("s1"))
        journal.append(record("s2"))
        val summary = journal.summary()
        assertEquals(2, summary["pending"])
        assertEquals(true, summary["available"])
    }
}
