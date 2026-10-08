package asia.akechi.petlife.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 4C-6B-1.2 A3：桌宠视觉不变式打靶。
 *
 * 旧架构（菜单前景副本 + 隐藏原桌宠 + 前景首帧回调切换视觉所有权）已**彻底删除**：
 * `PetOverlayView` 不再有任何可隐藏内容的入口，菜单窗口也绝不持有/绘制桌宠。
 *
 * 这里钉住两件事：
 * 1. **所有**菜单状态 × 事件路径下，诊断里的视觉片段完全一致 —— 即
 *    `sourceHidden` 恒为 0、owner 恒为 PET_WINDOW、前景副本恒 disabled；
 * 2. 菜单状态机里**不存在**任何带"隐藏 / 视觉所有权"语义的事件或状态。
 */
class PetVisualInvariantTest {

    private val expected = " owner=PET_WINDOW sourceHidden=0 foregroundCopy=disabled"

    @Test
    fun `诊断片段是固定常量`() {
        assertEquals("PET_WINDOW", PetVisualInvariant.OWNER)
        assertEquals(0, PetVisualInvariant.SOURCE_HIDDEN)
        assertEquals("disabled", PetVisualInvariant.FOREGROUND_COPY)
        assertEquals(expected, PetVisualInvariant.diagnosticSegment())
    }

    @Test
    fun `所有菜单生命周期路径下 sourceHidden 恒为 false`() {
        val states = OverlayMenuState.values()
        val events = OverlayMenuEvent.values()
        for (state in states) {
            for (event in events) {
                val first = OverlayMenuStateMachine.next(state, event)
                // 连走两步：覆盖 "forceClose 立即收敛" 与 "动画结束/取消再落定" 两类路径。
                for (event2 in events) {
                    OverlayMenuStateMachine.next(first, event2)
                    assertEquals(
                        "路径 $state → $event → $event2 下视觉不变式被破坏",
                        expected,
                        PetVisualInvariant.diagnosticSegment(),
                    )
                }
            }
        }
    }

    @Test
    fun `强制关闭是隐藏 停止 异常的唯一收敛点且仍存在`() {
        assertTrue(
            "forceClose 必须存在：隐藏/停止/权限撤销/异常都收敛到它",
            OverlayMenuEvent.values().any { it == OverlayMenuEvent.forceClose },
        )
        for (state in OverlayMenuState.values()) {
            assertEquals(
                "任何状态收到 forceClose 都必须落到 closed",
                OverlayMenuState.closed,
                OverlayMenuStateMachine.next(state, OverlayMenuEvent.forceClose),
            )
        }
    }

    @Test
    fun `菜单状态机不存在隐藏桌宠或切换视觉所有权的事件与状态`() {
        val forbidden = listOf("hide", "hidden", "foreground", "owner", "source")
        for (event in OverlayMenuEvent.values()) {
            for (word in forbidden) {
                assertFalse(
                    "菜单事件 ${event.name} 不应带隐藏/所有权语义（旧架构已删除）",
                    event.name.contains(word, ignoreCase = true),
                )
            }
        }
        for (state in OverlayMenuState.values()) {
            for (word in forbidden) {
                assertFalse(
                    "菜单状态 ${state.name} 不应带隐藏/所有权语义（旧架构已删除）",
                    state.name.contains(word, ignoreCase = true),
                )
            }
        }
    }
}
