# Tracy Profiler Integration

## Context

Full CPU + GPU profiling integration with [Tracy v0.13.1](https://github.com/wolfpld/tracy),
ported from the C legacy implementation (`suckless-ogl/src/tracy_manager.c`).

## Architecture

### Build Modes

| Build | Flag | Tracy Active |
|-------|------|--------------|
| `just build` | (none) | No — all tracy calls compile to no-ops |
| `just build-profile` | `-define:TRACY_ENABLE=true` | Yes |

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
┌─ frame_mark ──────────────────────────────────────────────────────┐
│  PollEvents → Scene Update → Scene Render → PostFX → Swap        │
│                               ├─ Skybox_Pass (GPU zone)           │
│                               ├─ Instanced_PBR_Spheres (GPU zone) │
│                               └─ PostFX_Bloom, AutoExposure, ...  │
│  frame_image_update (async PBO readback)                          │
│  gpu_collect (after swap)                                         │
└───────────────────────────────────────────────────────────────────┘
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
