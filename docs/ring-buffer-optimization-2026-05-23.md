# Ring Buffer & Async Transfer Optimization Analysis

> **Date**: 2026-05-23
> **Branch**: feat/postfx-pipeline
> **Hardware**: Intel Iris Xe (RPL-U), Mesa 25.0.7-2, unified memory architecture
> **Context**: Analysis of CPU↔GPU synchronization points and ring buffer opportunities

---

## Current State

The renderer has **two** existing ring buffer implementations:

| Resource | Ring Size | Direction | Size/frame | Source |
|----------|-----------|-----------|------------|--------|
| Tracy PBO | 4 | GPU→CPU | 230,400 B | `src/core/tracy/frame_image.odin` |
| Auto-Exposure PBO | 2 | GPU→CPU | 16 B | `src/rendering/postfx/auto_exposure.odin` |

Both use `glFenceSync` + non-blocking `glClientWaitSync` — zero stall by design.

All **CPU→GPU uploads** currently use single-buffer `glBufferSubData`:

| Resource | Type | Size/frame | Upload API | Potential Stall |
|----------|------|-----------|------------|-----------------|
| Sphere Instances | SSBO (binding 2) | 12,800 B | `glBufferSubData` | Yes (implicit sync) |
| PostFX UBO | UBO (binding 0) | 512 B | `glBufferSubData` | Yes (implicit sync) |
| Text Overlay | VBO (dynamic) | Variable (~4 KB typical) | `glBufferSubData` | Yes (implicit sync) |

---

## Implicit Sync Problem

When the CPU calls `glBufferSubData` on a buffer the GPU is currently reading
(from the previous frame's draw call), the driver must choose:

1. **Stall the CPU** until the GPU finishes reading (worst case)
2. **Orphan the buffer** internally (allocate new backing, copy) — free but wastes memory
3. **Pipeline the write** if the driver knows the GPU won't read until later

Mesa's Intel driver (i915/iris) generally uses **orphaning** for `DYNAMIC_DRAW`
buffers, but this is an implementation detail — not guaranteed, not controllable,
and invisible to profiling without `INTEL_performance_query` or Tracy GPU zones.

---

## Candidate Analysis

### 1. SSBO Triple Buffer (Sphere Instances)

**Current path** (per frame):

```
scene_update()
  → instanced_update_prev_centers()
  → instanced_sort()
  → instanced_upload()        ← glBufferSubData(SSBO, 0, 12800, data)
  ...
scene_render()
  → instanced_draw()          ← glDrawArraysInstanced reads SSBO
```

**Problem**: `instanced_upload` writes to the same SSBO that was read by
`instanced_draw` in the previous frame. If the GPU hasn't finished that draw,
the driver must sync or orphan.

**Ring buffer solution**:

```
┌─────────┐   ┌─────────┐   ┌─────────┐
│ SSBO[0] │   │ SSBO[1] │   │ SSBO[2] │
│ 12.8 KB │   │ 12.8 KB │   │ 12.8 KB │
└────┬────┘   └────┬────┘   └────┬────┘
     │              │              │
Frame N: CPU writes [0], GPU reads [2]
Frame N+1: CPU writes [1], GPU reads [0]
Frame N+2: CPU writes [2], GPU reads [1]
```

**Implementation cost**: Low — 3 handles instead of 1, modulo index, fence.

**Expected gain on Intel Iris Xe**: **Uncertain**. Intel's unified memory
architecture means the "transfer" is just a cache flush, not a DMA copy.
Mesa's iris driver likely already orphans DYNAMIC_DRAW SSBOs at near-zero cost.
The gain would only be measurable if:
- The GPU is bottlenecked (complex postfx active)
- AND the driver isn't orphaning (unlikely for DYNAMIC_DRAW)

**Verdict**: Low priority. Profile first with Tracy GPU zones.

---

### 2. UBO Triple Buffer (PostFX Settings)

**Current path**: `upload_ubo()` → `glBufferSubData(UBO, 0, 512, &ubo)`

Same pattern as SSBO but 512B is trivially small. Any driver will orphan
this instantly. No ring buffer needed.

**Verdict**: Not worth it. 512B is below any meaningful sync threshold.

---

### 3. Overlay VBO — Buffer Orphaning

**Current path**: `overlay_render()` → `glBufferSubData(VBO, 0, vert_count*32, &verts)`

The VBO was drawn in the previous frame (overlay renders last). Classic
candidate for **explicit orphaning** (simplest fix):

```odin
// Before SubData, orphan the old backing store:
gl.BufferData(gl.ARRAY_BUFFER, MAX_VERTICES * FLOATS_PER_VERTEX * size_of(f32), nil, gl.DYNAMIC_DRAW)
gl.BufferSubData(gl.ARRAY_BUFFER, 0, vert_count * FLOATS_PER_VERTEX * size_of(f32), &verts[0])
```

This is 1 extra line. The `BufferData(nil)` tells the driver "I don't care about
the old contents" → it can allocate fresh storage without waiting for the GPU.

**Verdict**: Trivial fix. Do it if ever overlay causes a hitch (unlikely at ~4 KB).

---

### 4. GUI Inspector PBO Readback

**Current path** (in `src/gui/gui.odin`): `glReadPixels` synchronous — 1 pixel.

**Problem**: `ReadPixels` without a PBO bound causes a **full pipeline flush**.
The CPU blocks until every queued draw/compute is done. This is the most
expensive sync primitive in OpenGL.

**Solution**: PBO double buffer (same pattern as auto-exposure):

```
Frame N:   ReadPixels → PBO[0] (async, immediate return)
           MapBuffer PBO[1] → get previous frame's pixel (no stall)
Frame N+1: ReadPixels → PBO[1]
           MapBuffer PBO[0] → get frame N's pixel
```

**Cost**: 2 PBOs × 4 bytes = 8 bytes of GPU memory. Negligible.

**Expected gain**: Eliminates a **full pipeline flush** when the inspector is
open. This is the single most impactful optimization on this list, but only
triggers when the user has the pixel inspector active in the GUI.

**Verdict**: Medium priority. Implement when inspector causes visible hitches.

---

## Persistent Mapped Buffers (GL 4.4+)

### Concept

`ARB_buffer_storage` (core since GL 4.4) allows mapping a buffer **once** at
creation and keeping the pointer valid forever:

```odin
// At init:
gl.BufferStorage(target, 3 * frame_size, nil,
    GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT)
ptr = gl.MapBufferRange(target, 0, 3 * frame_size,
    GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT)

// Per frame (no GL calls for upload!):
offset := (frame_index % 3) * frame_size
mem.copy(rawptr(uintptr(ptr) + uintptr(offset)), data, frame_size)
// Fence to protect the slot we'll write next frame
```

### Comparison with Manual Ring

| Aspect | Manual Ring (3 buffers) | Persistent Mapped (1 buffer, 3x size) |
|--------|------------------------|---------------------------------------|
| GL calls per upload | `BindBuffer` + `BufferSubData` | 0 (direct memcpy) |
| Sync mechanism | `FenceSync` + `ClientWaitSync` | Same |
| Driver overhead | 1 validate per bind | 0 |
| Memory layout | 3 separate allocations | 1 contiguous allocation |
| CPU cache behavior | Varies (driver-managed) | Predictable (write-combined) |
| Latency | 3 frames | 3 frames |
| Complexity | Low | Medium (init heavier, simpler per-frame) |

### Performance Equivalence

Both achieve the same goal: **eliminate CPU↔GPU synchronization on uploads**.
The throughput is identical — the difference is CPU overhead:

- **Manual ring**: ~2 GL API calls per frame per resource (Bind + SubData)
- **Persistent mapped**: 0 GL API calls per frame (just `mem.copy`)

On a hot path with many small uploads, persistent mapping wins. For this
project (2 uploads/frame: 1 SSBO + 1 UBO), the difference is negligible.

### Intel Iris Xe Specifics

Intel integrated GPUs use **unified memory** (CPU and GPU share the same DRAM).
This means:

1. `glBufferSubData` doesn't do a "real" DMA transfer — it's a cache-coherent
   memory write + cache flush
2. Persistent mapping with `COHERENT_BIT` maps to the same physical behavior
3. The main benefit of ring buffering (avoiding sync stalls) still applies,
   but the cost of the sync itself is lower than on discrete GPUs

**Bottom line**: On discrete GPUs (PCIe transfer), persistent mapping saves
significant overhead. On Intel UMA, the gain is much smaller because there's
no "transfer" to avoid — just cache coherency management.

---

## Recommendations (Priority Order)

| # | Action | Trigger | Effort |
|---|--------|---------|--------|
| 1 | Profile with Tracy GPU zones | Before any optimization | Low |
| 2 | Inspector PBO readback | Inspector open causes hitch | Low |
| 3 | Overlay VBO orphaning | Overlay causes hitch | Trivial (1 line) |
| 4 | SSBO ring buffer | Tracy shows sync stall at upload | Medium |
| 5 | Persistent mapping | Multiple resources show stalls | Medium |

**Key principle**: On Intel UMA with Mesa iris driver, `glBufferSubData` on
`DYNAMIC_DRAW` buffers is already near-optimal. Ring buffers / persistent
mapping provide guarantees (no driver-dependent orphaning behavior), but the
measurable gain will likely be <1ms/frame at current workload (100 instances,
512B UBO). Profile before implementing.

---

## References

- [OpenGL Wiki: Buffer Object Streaming](https://www.khronos.org/opengl/wiki/Buffer_Object_Streaming)
- [ARB_buffer_storage specification](https://registry.khronos.org/OpenGL/extensions/ARB/ARB_buffer_storage.txt)
- Mesa iris driver source: `src/gallium/drivers/iris/iris_bufmgr.c` (orphaning heuristics)
- Cass Everitt, John McDonald — "Approaching Zero Driver Overhead" (GDC 2014, NVIDIA)
- Graham Sellers — "Vulkan vs OpenGL: Buffer management" (GPU Pro 7, Chapter 1)
