# Async Environment Manager

Port of the C11 async environment manager to Odin (`async_loader.c` + `env_manager.c`).

## Architecture

Two new source files in `src/scene/`:

- **async\_loader.odin** (211 LOC) — Background thread for HDR I/O + decode via `stb/image`.
  Worker sleeps on a condition variable, wakes on request, loads HDR, signals ready/failed.
- **env\_manager.odin** (462 LOC) — Per-frame orchestrator: polls async result, runs progressive IBL
  pipeline (one GPU step per frame), manages transition alpha.

Integration points:

- **skybox.odin** — Added `skybox_update_env` (delete old cubemaps, regenerate from new env texture)
- **scene.odin** — `Env_Manager` field, create/destroy/update hooks, public `scene_change_env`

## State Machines

### Async Loader

```
IDLE → PENDING → LOADING → READY | FAILED
```

Main thread submits path via `async_loader_request`, polls via `async_loader_poll`.

### IBL Progressive Pipeline

```
Upload_Texture → Generate_Mipmaps → Specular_Init → Specular_Mips → Irradiance → Done
```

One step per frame — avoids GPU stalls during interactive use.
Adaptive slicing: 24 slices for mip0, 8 for mip1, grouped for higher mips.

### Transition State

```
Idle → Loading → (Wait_IBL | direct) → Fade_Out/Fade_In → Idle
```

Two modes:

- **Crossfade**: swap textures immediately at `Done`, fade overlay alpha 1→0
- **Black\_Screen**: fade alpha 0→1, swap at full black, fade 1→0

## Key Design Decisions

- **One step per frame**: If poll triggers IBL start, advance is skipped that frame (no double-work).
- **Synchronous initial load**: First HDR is loaded synchronously at scene creation (legacy compat).
  `env_mgr` starts in `Idle` with `is_first_load = false`.
- **Error recovery**: If `Upload_Texture` encounters nil data, both states reset to Idle gracefully.
- **Cleanup on destroy**: All pending GPU textures are freed even if IBL was mid-pipeline.

## Test Coverage

27 GL tests in `tests/gl/test_gl_async_loader.odin` (899 LOC):

- Async loader unit: create/destroy, request validation, poll states, real HDR load
- Env manager unit: lifecycle, trigger guards, overlay alpha, fade progression
- Integration: full crossfade/black\_screen transitions, double env change, IBL progression,
  skybox update verification
- Error paths: nil data recovery, request rejection, destroy with pending textures, fallback states

All branches in introduced code are covered.

## ISO Mapping (C11 → Odin)

| C11 file | Odin equivalent |
|---|---|
| `async_loader.c` | `src/scene/async_loader.odin` |
| `env_manager.c` | `src/scene/env_manager.odin` |
| `pthread_mutex/cond` | `core:sync.Mutex` / `core:sync.Cond` |
| `stbi_loadf` | `vendor:stb/image.loadf` |
| `ASYNC_MAX_PATH` | `ASYNC_MAX_PATH :: 256` |
