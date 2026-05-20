# GUI Session Persistence & ImGui Tab Restore

**Date:** 2026-05-21
**Branch:** `feat/postfx-pipeline`

---

## Context

The `session.json` save/restore system existed but was incomplete — several Scene tab parameters and the active GUI tab were not persisted across runs.

## Missing Fields Added to `Session_State`

| Field | Type | Purpose |
|-------|------|---------|
| `skybox_blur_lod` | `f32` | Skybox blur level (slider in Scene tab) |
| `sort_mode` | `i32` | Billboard sort algorithm (None/CPU/Radix) |
| `gui_active_tab` | `i32` | Active tab index in Engine Controls window |

## ImGui Tab Restore — Lessons Learned

Restoring the active tab in a Dear ImGui `BeginTabBar`/`BeginTabItem` loop is **non-trivial** due to ImGui's deferred internal state management.

### The Problem (3 layers)

1. **`SetSelected` is deferred**: The `TabItemFlags{.SetSelected}` flag sets `NextSelectedTabId` internally, which only takes effect on the NEXT frame's `BeginTabBar` call — not immediately.

2. **Tab bar initialization**: On the very first frame a tab bar is rendered, ImGui creates internal state and defaults to the first submitted tab. `SetSelected` is queued but hasn't propagated yet.

3. **First-tab-wins race condition**: On the current frame, `BeginTabItem("Camera")` returns `true` (it's the default first tab). If you naively write `g.active_tab = 0` inside its block, you overwrite the restore target index. Next frame, `tab_flags` checks `g.active_tab == target_idx` — but `active_tab` is now 0, not the saved value.

### The Fix

```
active_tab:   i32   // Persisted tab index
restore_tab:  i32   // Frame counter (set to 3 on restore)
```

While `restore_tab > 0`:
- Apply `{.SetSelected}` flag to the tab matching `active_tab`
- **Do NOT update** `active_tab` from `BeginTabItem` results (guard: `if !restoring`)
- Decrement counter each frame

The 3-frame window guarantees `SetSelected` propagates through ImGui's deferred selection pipeline regardless of when the tab bar's internal state is first created.

### Key Insight

ImGui's tab selection is a **2-frame pipeline**: frame N sets `NextSelectedTabId`, frame N+1 applies it. Combined with the initialization frame, you need at least 3 frames of `SetSelected` without overwriting the target to reliably restore a tab.
