// Pure ordered-list reducer for canvas components keyed by identity — upsert in place or append, remove by id
// — returning new lists for Compose stability; mirrors the Windows client's Canvas.apply_ops.

package com.personalailabs.astraldeep.core.sdui

data class CanvasOp(
    val op: String,
    val componentId: String,
    val component: Component? = null,
)

object Canvas {
    // Untouched components keep their instance — Compose skips recomposing them
    fun apply(
        current: List<Component>,
        ops: List<CanvasOp>,
    ): List<Component> {
        val order = ArrayList<String>(current.size)
        val byId = LinkedHashMap<String, Component>(current.size)
        current.forEachIndexed { index, c ->
            val key = c.id ?: "anon-$index"
            if (byId.put(key, c) == null) order.add(key)
        }
        for (op in ops) {
            when (op.op) {
                "remove" -> if (byId.remove(op.componentId) != null) order.remove(op.componentId)
                else -> {
                    val comp = op.component ?: continue
                    if (byId.put(op.componentId, comp) == null) order.add(op.componentId)
                }
            }
        }
        return order.map { byId.getValue(it) }
    }
}
