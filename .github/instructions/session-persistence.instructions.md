---
description: "Use when adding GUI controls, app state, or any user-facing settings. Mandates that ALL runtime state must be fully synchronized across GUI, session persistence, and restore."
applyTo: ["src/**/*.odin"]
---
# Session Persistence — Total State Synchronization

## Golden Rule

**Every piece of user-visible runtime state MUST be persisted and restored identically across app restarts.** A re-run must put the user in EXACTLY the same state as when they closed the app.

## What "Total Synchronization" Means

When you add/modify ANY user-facing setting, you MUST update ALL 4 locations:

| # | Location | Purpose |
|---|----------|---------|
| 1 | `src/core/session/session.odin` → `Session_State` | Add field with `json:"..."` tag |
| 2 | `src/app/app.odin` → `extract_session_state` | Save field from live state |
| 3 | `src/app/app.odin` → `restore_session_state` | Restore field to live state |
| 4 | `src/gui/gui.odin` → GUI widget | Display/edit the setting |

Missing ANY of these 4 is a bug. No exceptions.

## Camera Persistence — Critical

The camera uses smoothed rotation (`yaw_target`/`pitch_target` interpolated to `yaw`/`pitch`). When restoring:
- Set BOTH `yaw` AND `yaw_target` to the saved value
- Set BOTH `pitch` AND `pitch_target` to the saved value
- Call `cam.update_vectors()` after

Failing to set the targets causes the camera to drift back to defaults.

## Checklist for New Settings

Before considering a GUI feature complete, verify:

- [ ] Field exists in `Session_State` with proper JSON tag
- [ ] `extract_session_state` reads from the live state
- [ ] `restore_session_state` writes to the live state (with sane defaults for zero-values from old sessions)
- [ ] GUI widget reads/writes the same pointer
- [ ] Default value handled gracefully (0/false from missing JSON key must not break UX)

## Exempt from Persistence

Only these categories are NOT persisted (they're runtime-derived):
- GPU texture handles (regenerated at startup)
- Frame timing / performance metrics
- Dirty flags (transient triggers)
- Computed/derived values (recalculated from persisted inputs)

Everything else: **persist it.**
