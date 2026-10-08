package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 开机自启（Phase 4D）的**纯 JVM** 单元测试。
 *
 * 真机重启无法在单测里复现，因此这里把所有可判定的点都钉在
 * [BootAutostart] 的纯决策 + 注入式副作用上：
 * 关 → 不启动、开 → 恰好一次、重复信号去重、缺权限不启动、
 * 结果可记录可读、持久化标志读写。
 *
 * 真机上仍需验证"重启并解锁后确实起来了"这一条（见 docs/30）。
 */
class BootAutostartTest {

    /** 内存版 [BootStore]：模拟"原生可读、Flutter 未启动时也能读"的那份标志。 */
    private class FakeBootStore(
        override var autostartEnabled: Boolean = false,
        override var petHidden: Boolean = false,
    ) : BootStore {
        override var bootResultCode: String? = null
        override var bootLastAttemptAt: Long = 0L
        var bootResultDetail: String? = null
        var bootResultAt: Long = 0L

        override fun recordBootResult(code: String, detail: String?, atMs: Long) {
            bootResultCode = code
            bootResultDetail = detail
            bootResultAt = atMs
        }
    }

    /** 记录启动次数与"是否按隐藏启动"的假启动器。 */
    private class RecordingStarter(private val fail: Boolean = false) {
        val calls = mutableListOf<Boolean>()
        fun start(hidden: Boolean) {
            calls.add(hidden)
            if (fail) throw IllegalStateException("ForegroundServiceStartNotAllowed")
        }
    }

    private fun runWith(
        store: FakeBootStore,
        starter: RecordingStarter,
        overlayGranted: Boolean = true,
        serviceRunning: Boolean = false,
        nowMs: Long = 1_000_000L,
    ) = BootAutostart.run(
        store = store,
        overlayGranted = overlayGranted,
        serviceRunning = serviceRunning,
        nowMs = nowMs,
        startService = starter::start,
    )

    // --- 1. autostart OFF → 什么都不做 ---

    @Test
    fun `关闭开机自启时重启不启动任何服务`() {
        val store = FakeBootStore(autostartEnabled = false)
        val starter = RecordingStarter()

        val outcome = runWith(store, starter)

        assertEquals(BootAction.SKIP, outcome.action)
        assertEquals(BootAutostart.RESULT_DISABLED, outcome.resultCode)
        assertTrue("关闭自启时绝不能启动服务", starter.calls.isEmpty())
        assertEquals(BootAutostart.RESULT_DISABLED, store.bootResultCode)
    }

    // --- 2. autostart ON → 恰好启动一次 ---

    @Test
    fun `开启开机自启时恰好启动一次（显示）`() {
        val store = FakeBootStore(autostartEnabled = true, petHidden = false)
        val starter = RecordingStarter()

        val outcome = runWith(store, starter)

        assertEquals(BootAction.START, outcome.action)
        assertEquals(BootAutostart.RESULT_START_REQUESTED, outcome.resultCode)
        assertEquals(listOf(false), starter.calls)
        assertEquals(1, starter.calls.size)
    }

    @Test
    fun `开启开机自启且桌宠此前被隐藏时按隐藏方式启动`() {
        val store = FakeBootStore(autostartEnabled = true, petHidden = true)
        val starter = RecordingStarter()

        val outcome = runWith(store, starter)

        // 隐藏 ≠ 关闭自启：服务照样启动，但窗口保持隐藏。
        assertEquals(BootAction.START_HIDDEN, outcome.action)
        assertEquals(listOf(true), starter.calls)
    }

    // --- 3. 重复通话去重 ---

    @Test
    fun `服务已在运行时重复的开机信号不会启动第二次`() {
        val store = FakeBootStore(autostartEnabled = true)
        val starter = RecordingStarter()

        val outcome = runWith(store, starter, serviceRunning = true)

        assertEquals(BootAction.SKIP, outcome.action)
        assertEquals(BootAutostart.RESULT_ALREADY_RUNNING, outcome.resultCode)
        assertTrue(starter.calls.isEmpty())
    }

    @Test
    fun `服务尚未起来时的第二个开机信号被时间窗守卫去重`() {
        val store = FakeBootStore(autostartEnabled = true)
        val starter = RecordingStarter()

        // 第一次（BOOT_COMPLETED）：正常启动并记下尝试时间。
        runWith(store, starter, nowMs = 1_000_000L)
        assertEquals(1, starter.calls.size)

        // 第二次（同一轮开机的另一条广播）：服务可能还在异步创建，靠时间窗挡住。
        val second = runWith(store, starter, nowMs = 1_000_000L + 1_000L)

        assertEquals(BootAutostart.RESULT_DUPLICATE_IGNORED, second.resultCode)
        assertEquals("重复信号绝不能产生第二次启动", 1, starter.calls.size)
    }

    @Test
    fun `时间窗之外的新一轮开机信号可以再次启动`() {
        val store = FakeBootStore(autostartEnabled = true)
        val starter = RecordingStarter()

        runWith(store, starter, nowMs = 1_000_000L)
        runWith(
            store,
            starter,
            nowMs = 1_000_000L + BootAutostart.DUPLICATE_WINDOW_MS + 1,
        )

        assertEquals(2, starter.calls.size)
    }

    // --- 4. 缺少悬浮窗权限 ---

    @Test
    fun `缺少悬浮窗权限时不启动并记录原因`() {
        val store = FakeBootStore(autostartEnabled = true)
        val starter = RecordingStarter()

        val outcome = runWith(store, starter, overlayGranted = false)

        assertEquals(BootAction.SKIP, outcome.action)
        assertEquals(BootAutostart.RESULT_MISSING_OVERLAY, outcome.resultCode)
        assertTrue(starter.calls.isEmpty())
        assertEquals(BootAutostart.RESULT_MISSING_OVERLAY, store.bootResultCode)
    }

    // --- 5. 持久化标志"无需 Flutter 即可读"、写入即生效 ---

    @Test
    fun `持久化标志写入后决策立即可读（不依赖 Flutter）`() {
        val store = FakeBootStore(autostartEnabled = false)
        // 初始关闭 → 不启动。
        assertEquals(BootAutostart.RESULT_DISABLED, runWith(store, RecordingStarter()).resultCode)

        // 模拟 Flutter 设置页写穿：只改这一个标志。
        store.autostartEnabled = true
        val starter = RecordingStarter()
        val outcome = runWith(store, starter)

        assertEquals(BootAction.START, outcome.action)
        assertEquals(1, starter.calls.size)
    }

    @Test
    fun `开关关闭后重启必须不启动任何东西`() {
        val store = FakeBootStore(autostartEnabled = true)
        runWith(store, RecordingStarter())

        // 用户随后关闭自启（Flutter 写穿）。
        store.autostartEnabled = false
        val starter = RecordingStarter()
        val outcome = runWith(store, starter, nowMs = 5_000_000L)

        assertEquals(BootAutostart.RESULT_DISABLED, outcome.resultCode)
        assertTrue(starter.calls.isEmpty())
    }

    // --- 6. 开机结果记录与读取 ---

    @Test
    fun `开机结果被记录并可读（含时间戳）`() {
        val store = FakeBootStore(autostartEnabled = true)
        runWith(store, RecordingStarter(), nowMs = 42_424L)

        assertEquals(BootAutostart.RESULT_START_REQUESTED, store.bootResultCode)
        assertEquals(42_424L, store.bootResultAt)
        // 尝试时间也要落下，供下一轮去重判断。
        assertEquals(42_424L, store.bootLastAttemptAt)
    }

    @Test
    fun `决策结果是纯函数（同样的输入得到同样的结果）`() {
        val a = BootAutostart.decide(
            autostartEnabled = true,
            petHidden = false,
            overlayGranted = true,
            serviceRunning = false,
            nowMs = 100L,
            lastAttemptAtMs = 0L,
        )
        val b = BootAutostart.decide(
            autostartEnabled = true,
            petHidden = false,
            overlayGranted = true,
            serviceRunning = false,
            nowMs = 100L,
            lastAttemptAtMs = 0L,
        )
        assertEquals(a, b)
    }

    // --- 7. 系统拒绝启动：记录原因，不无限重试 ---

    @Test
    fun `系统拒绝启动前台服务时记录 system_blocked 且不重试`() {
        val store = FakeBootStore(autostartEnabled = true)
        val starter = RecordingStarter(fail = true)

        val outcome = runWith(store, starter)

        // 只尝试一次（绝不循环重试）。
        assertEquals(1, starter.calls.size)
        assertEquals(BootAutostart.RESULT_SYSTEM_BLOCKED, store.bootResultCode)
        assertEquals("IllegalStateException", store.bootResultDetail)
        // 决策本身仍是"要启动"，只是执行被系统挡住。
        assertEquals(BootAction.START, outcome.action)
    }

    // --- 8. START_HIDDEN 在状态机里的语义（不依赖 Context）---

    @Test
    fun `START_HIDDEN 让服务运行但窗口不可见`() {
        val next = OverlayStateMachine.next(OverlayState.stopped, OverlayCommand.START_HIDDEN)
        assertTrue(next.running)
        assertTrue(next.hidden)
        assertFalse(next.windowVisible)
    }

    @Test
    fun `fromWire 能解析 start_hidden，且大小写与拼写固定`() {
        assertEquals(OverlayCommand.START_HIDDEN, OverlayCommand.fromWire("start_hidden"))
    }

    @Test
    fun `隐藏启动后 show 能正常恢复可见`() {
        val hidden = OverlayStateMachine.next(OverlayState.stopped, OverlayCommand.START_HIDDEN)
        val shown = OverlayStateMachine.next(hidden, OverlayCommand.SHOW)
        assertTrue(shown.running)
        assertFalse(shown.hidden)
        assertTrue(shown.windowVisible)
    }

    @Test
    fun `未被接受的决策不会误写结果`() {
        // 纯决策不产生副作用。
        val store = FakeBootStore(autostartEnabled = true)
        BootAutostart.decide(
            autostartEnabled = store.autostartEnabled,
            petHidden = false,
            overlayGranted = true,
            serviceRunning = false,
            nowMs = 1L,
            lastAttemptAtMs = 0L,
        )
        assertNull(store.bootResultCode)
    }
}
