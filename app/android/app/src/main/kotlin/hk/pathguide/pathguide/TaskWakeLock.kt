package hk.pathguide.pathguide

import android.view.Window
import android.view.WindowManager
import java.util.WeakHashMap

/** Shared foreground-task ownership; one task cannot release another's flag. */
internal object TaskWakeLock {
  private data class State(val previous: Boolean, val owners: MutableSet<String> = mutableSetOf())
  private val windows = WeakHashMap<Window, State>()
  fun set(window: Window?, owner: String, enabled: Boolean) {
    if (window == null) return
    if (enabled) {
      val state = windows.getOrPut(window) { State(window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0) }
      state.owners.add(owner); window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    } else {
      val state = windows[window] ?: return
      state.owners.remove(owner)
      if (state.owners.isEmpty()) { if (!state.previous) window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); windows.remove(window) }
    }
  }
  fun clear(window: Window) { val state = windows.remove(window) ?: return; if (!state.previous) window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
}
