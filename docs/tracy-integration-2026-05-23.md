# Tracy Profiler Integration

## Context

Full CPU + GPU profiling integration with [Tracy v0.13.1](https://github.com/wolfpld/tracy),
ported from the C legacy implementation (`suckless-ogl/src/tracy_manager.c`).

## Architecture

### Build Modes

| Build | Flag | Tracy Active | Cost |
|-------|------|--------------|------|
| `just build` | (none) | No — all tracy calls compile to no-ops | Zero (eliminated at compile-time) |
| `just build-profile` | `-define:TRACY_ENABLE=true` | Yes | Minimal (ON_DEMAND — idle until server connects) |
| `just build-release` | (none) | No | Zero |
| `just build-ultra` | (none) | No | Zero |

### Components

1. **Odin bindings** (`src/core/tracy/tracy.odin`)
   - Thin `#force_inline` wrappers over the C API
   - Compile-time guards: `when TRACY_ENABLE { ... }` — zero cost when disabled
   - CPU zones, GPU zones, frame marks, messages, fiber support

2. **Frame image capture** (`src/core/tracy/frame_image.odin`)
   - Async PBO ring-buffer (4× 320×180) for Tracy frame thumbnails
   - Backbuffer → downscale FBO (BlitFramebuffer) → PBO ReadPixels → FenceSync → MapBuffer → `tracy_gpu_screenshot`

3. **GL debug group integration** (`src/core/gl_debug/gl_debug.odin`)
   - `push_group` / `pop_group` emit both OpenGL debug groups (RenderDoc) AND Tracy CPU+GPU zones
   - Nord color theme mapping per pass (Scene=orange, Skybox=cyan, Bloom=blue, etc.)

4. **Client library** (`deps/libtracy.a`)
   - Built from TracyClient.cpp + tracy_gpu.cpp + glad.c
   - Flags: `-DTRACY_ENABLE -DTRACY_ON_DEMAND -DTRACY_FIBERS`
   - Script: `scripts/build_tracy_lib.sh`

### Frame Timeline

```
┌─ frame_mark ─────────────────────────────────────────────────────────────────┐
│  GLFW PollEvents (CPU zone)                                                  │
│  Scene Update (CPU zone)                                                     │
│  Scene Render (CPU zone)                                                     │
│    ├─ Render_Frame (GPU+CPU)                                                 │
│    │    ├─ Scene_Render → Instanced_PBR_Spheres (GPU)                        │
│    │    ├─ Skybox_Pass (GPU)                                                 │
│    │    └─ Post_Processing (GPU)                                             │
│    │         ├─ PostFX_Bloom                                                 │
│    │         ├─ PostFX_AutoExposure                                          │
│    │         ├─ PostFX_MotionBlur_Compute (if enabled)                       │
│    │         ├─ PostFX_FXAA_Prepass (if FXAA+MB)                             │
│    │         ├─ PostFX_Composite_Setup (Clear + mipmap + UBO)                │
│    │         └─ PostFX_Final_Composite                                       │
│    └─ GUI_ImGui (if visible)                                                 │
│  Frame_Image_Capture (GPU — Blit + PBO ReadPixels)                           │
│  Swap_Buffers (GPU)                                                          │
│  gpu_collect (after swap — flushes GPU timestamps)                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **ON_DEMAND**: Tracy only captures when the profiler server connects (no overhead in steady-state)
- **FIBERS**: Required for Odin's implicit context threading model
- **gpu_collect after swap**: Ensures GPU timestamps are flushed before collection (ISO legacy)
- **PBO ring-buffer**: Non-blocking readback avoids GPU stalls for frame thumbnails

## Usage

```bash
# Build everything (one-time setup)
just build-tracy

# Profile build
just build-profile

# Launch profiler server
just tracy-server

# Then run the app — Tracy connects automatically (ON_DEMAND)
./build/profile/suckless-odin
```

## Dependencies

- Tracy v0.13.1 submodule at `deps/tracy/` (`.gitmodules`, ignore=dirty)
- System: `libstdc++`, `libX11`, CMake (for server build)
- Linuxbrew: wayland/X11 dev libs, freetype, capstone (for server)

## Updating Tracy

### Automated (recommended)

```bash
just update-tracy
```

This fetches the latest git tag, checks out that version, and rebuilds both `libtracy.a` and the profiler server.

### Manual

```bash
cd deps/tracy
git fetch --tags
git checkout v0.XX.X   # desired version
cd ../..
just build-tracy       # rebuilds lib + server
```

### Post-update checklist

1. Verify `just build-tracy-lib` succeeds (C++ API changes)
2. Verify `just build-profile` links correctly (symbol compatibility)
3. Check `deps/tracy_gpu.cpp` — if Tracy's `TracyOpenGL.hpp` API changed, update the bridge
4. Check `src/core/tracy/tracy.odin` — if Tracy adds/renames C symbols, update FFI bindings
5. Run `just tracy-server` and connect to a profile build to validate end-to-end

## Zero-Cost Guarantee

All Tracy wrappers use Odin's `when TRACY_ENABLE { ... }` guard — a **compile-time** conditional.
When the config flag is `false` (default), the guarded code is entirely eliminated from the binary.
No branches, no function calls, no symbols. The non-profile builds are byte-identical to what
they would be without any Tracy code in the source tree.

The GL debug group calls (`gl.PushDebugGroup` / `gl.PopDebugGroup`) remain in all builds but are
free when no debug context is active (the driver short-circuits them).

## Zone Color Mapping

Zone colors use a centralized `ZONE_COLORS` table in `src/core/gl_debug/gl_debug.odin`
(Nord color theme), resolved by `zone_color_for_name()`. To add a new zone color, add a
single entry to the table — no duplication across call sites.

## Zone Aggregation (Statistics)

All CPU zones use **static source locations** — a stable pointer to a `Source_Location_Data`
stored in a global cache array (`g_cache`). This allows Tracy to recognize the same zone
across frames and aggregate them in Statistics/Histograms.

Key implementation detail: `zone_begin(loc)` (static pointer) enables aggregation.
`zone_begin_alloc(srcloc)` (dynamic u64 handle) does NOT — Tracy treats each call as unique.

### Interpreting Swap_Buffers

Without VSync, `SwapBuffers` should be near-instantaneous. If Tracy shows significant time
in `Swap_Buffers`, the application is **GPU-bound**: the CPU has submitted all work and is
waiting for the GPU to release a back-buffer (implicit driver back-pressure).

To reduce frame time when GPU-bound, optimize the heaviest GPU passes (use Tracy Statistics
to identify them by total/mean self-time).
