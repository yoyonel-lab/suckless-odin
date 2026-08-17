# GL Synchronization Inventory — C11 vs Odin Port

**Date**: 2026-05-26
**C11 branch**: `fix/302-atmospheric-fog-height-falloff` (repo: `yoyonel/suckless-ogl`)
**Odin branch**: `feat/env-manager-async` (repo: `yoyonel/suckless-odin`)

## 1. Memory Barriers (`glMemoryBarrier`)

| # | Rôle | C11 | Odin | Bits | Verdict |
|---|------|-----|------|------|---------|
| 1 | Final IBL → PBR sampling | `src/ibl_coordinator.c:406` | `src/scene/env_manager.odin:286` | C11: `IMAGE_ACCESS` / Odin: `TEXTURE_FETCH \| IMAGE_ACCESS` | Odin + correct |
| 2 | Après specular (tous mips) | `src/pbr.c:163` | `src/scene/env_manager.odin:396` | `IMAGE_ACCESS` | ✅ ISO |
| 3 | Après irradiance dispatch | `src/pbr.c:271` | `src/scene/env_manager.odin:440` | `IMAGE_ACCESS` | ✅ ISO |
| 4 | BRDF LUT compute | `src/pbr.c:406` | `src/rendering/ibl.odin:53` | C11: `ALL_BARRIER_BITS` / Odin: `IMAGE_ACCESS` | Odin + précis |
| 5 | Luminance pass1→pass2 | `src/pbr.c:336` | — | `SHADER_STORAGE` | C11 seul |
| 6 | Luminance pass2→readback | `src/pbr.c:366` | — | `BUFFER_UPDATE` | C11 seul |
| 7 | Auto-exposure downsample→adapt | `src/effects/fx_auto_exposure.c:142` | `src/rendering/postfx/auto_exposure.odin:102` | `IMAGE_ACCESS \| TEXTURE_FETCH` | ✅ ISO |
| 8 | Auto-exposure fragment→compute | `src/effects/fx_auto_exposure.c:172` | — | `TEXTURE_FETCH` | C11 seul |
| 9 | Auto-exposure adapt→uber | `src/effects/fx_auto_exposure.c:199` | *(consolidé #7)* | `IMAGE_ACCESS \| TEXTURE_FETCH` | Consolidé Odin |
| 10 | Motion blur tile-max→neighbor | `src/effects/fx_motion_blur.c:123` | `src/rendering/postfx/motion_blur.odin:66` | `IMAGE_ACCESS \| TEXTURE_FETCH` | ✅ ISO |
| 11 | Motion blur neighbor→composite | `src/effects/fx_motion_blur.c:146` | `src/rendering/postfx/motion_blur.odin:78` | C11: `TEXTURE_FETCH` / Odin: `IMAGE_ACCESS \| TEXTURE_FETCH` | Odin + conservatif |
| 12 | PostFX compute→sampler | `src/postprocess_apply.c:34` | — | `TEXTURE_FETCH` | C11 seul |
| 13 | Billboard sort inter-pass ×4 | `src/billboard_sorting.c:260,279,297,309` | — | `SHADER_STORAGE` | Non porté |
| 14 | Light probes update | `src/light_probes.c:610` | — | `SHADER_STORAGE \| TEXTURE_FETCH` | Non porté |

## 2. Fence Sync + Client Wait

| # | Rôle | C11 FenceSync | C11 ClientWaitSync | Odin FenceSync | Odin ClientWaitSync | Params | Verdict |
|---|------|---------------|--------------------|----------------|---------------------|--------|---------|
| 1 | Luminance compute | `src/ibl_coordinator.c:210` | `src/ibl_coordinator.c:225` | — | — | `GPU_COMMANDS_COMPLETE`, wait: `SYNC_FLUSH_COMMANDS_BIT`, timeout: 1s | **Absent Odin** |
| 2 | Exposure PBO readback | `src/postprocess_apply.c:120` | `src/postprocess_readback.c:61` | `src/rendering/postfx/auto_exposure.odin:130` | `src/rendering/postfx/auto_exposure.odin:136` | `GPU_COMMANDS_COMPLETE`, wait: `SYNC_FLUSH_COMMANDS_BIT`, timeout: 1ms | ✅ ISO |
| 3 | Histogram PBO | `src/postprocess_readback.c:123` | `src/postprocess_readback.c:150` | — | — | `GPU_COMMANDS_COMPLETE`, wait: `SYNC_FLUSH_COMMANDS_BIT`, timeout: 1ms | Non porté |
| 4 | Exposure PBO (2nd slot) | `src/postprocess_apply.c:133` | — | — | — | `GPU_COMMANDS_COMPLETE` (fence only, no wait) | Consolidé #2 |
| 5 | Tracy frame image | `src/tracy_manager.c:128` | `src/tracy_manager.c:79` | `src/core/tracy/frame_image.odin:113` | `src/core/tracy/frame_image.odin:76` | `GPU_COMMANDS_COMPLETE`, wait: `SYNC_FLUSH_COMMANDS_BIT`, timeout: 5ms | ✅ ISO |

## 3. `glFinish()` — stall pipeline complet

| # | Rôle | C11 | Odin | Params | Verdict |
|---|------|-----|------|--------|---------|
| 1 | Fullscreen toggle | `src/app_input.c:835` | `src/app/app.odin:383` | *(aucun param — drain complet GPU)* | ✅ ISO |
| 2 | Benchmark frame timing | `src/perf_timer.c:119` | `src/app/benchmark.odin:55,68,74` | *(aucun param — garantit GPU idle pour mesure CPU-side)* | ✅ ISO |
| 3 | Post-GenerateMipmap HDR env | — | — | *(supprimé : optimisé via PBO asynchrone)* | ✅ Optimisé (0ms) |
| 4 | Post-BRDF LUT compute | — | `src/rendering/ibl.odin:54` | *(aucun param — garantit LUT prête avant premier draw)* | **Odin seul** |

## 4. Sync implicite (GenerateMipmap / GetTexImage / GetBufferSubData)

| # | Rôle | C11 | Odin | Appel GL | Params | Verdict |
|---|------|-----|------|----------|--------|---------|
| 1 | HDR env texture mipmap | `src/texture.c:326` | `src/scene/env_manager.odin:234` | `GenerateMipmap` | target: `TEXTURE_2D` | ✅ ISO |
| 2 | Cubemap mipmap (skybox blur) | — | `src/rendering/skybox.odin:351` | `GenerateMipmap` | target: `TEXTURE_CUBE_MAP` | Odin seul |
| 3 | PostFX LOD source mipmap | — | `src/rendering/postfx/pipeline.odin:278` | `GenerateMipmap` | target: `TEXTURE_2D` | Odin seul |
| 4 | Texture load mipmap (generic) | — | `src/rendering/texture.odin:43` | `GenerateMipmap` | target: `TEXTURE_2D` | Odin seul |
| 5 | Luminance readback (top mip) | — | `src/scene/env_manager.odin` | `GetTexImage` | level: 0, format: `RED`, type: `FLOAT`, PBO-bound (async) | ✅ PBO Asynchrone |
| 6 | Luminance SSBO readback | `src/pbr.c:376` | — | `GetBufferSubData` | target: `SHADER_STORAGE_BUFFER`, offset: 0, size: 4 bytes | **C11 seul** |
| 7 | Exposure sync (GUI debug) | `src/effects/fx_auto_exposure.c:208` | — | `GetTexImage` | level: 0, format: `RED`, type: `FLOAT`, 1×1 px | C11 seul |
| 8 | Exposure PBO async fill | `src/postprocess_apply.c:118,131` | `src/rendering/postfx/auto_exposure.odin:124` | `GetTexImage` | level: 0, format: `RED`, type: `FLOAT`, PBO-bound (async) | ✅ ISO |
| 9 | Histogram PBO fill | `src/postprocess_readback.c:121` | — | `GetTexImage` | level: 0, format: `RED_INTEGER`, type: `UNSIGNED_INT`, PBO-bound | Non porté |

## 5. DeleteSync (lifecycle)

| # | Rôle | C11 | Odin | Appel GL | Params | Verdict |
|---|------|-----|------|----------|--------|---------|
| 1 | Luminance fence cleanup | `src/ibl_coordinator.c:161,208,229,249` | — | `DeleteSync` | fence guard: check `!= 0` avant delete | C11 seul |
| 2 | Exposure PBO fence reset | `src/postprocess_setters.c:14,24` | `src/rendering/postfx/auto_exposure.odin:76,128,146` | `DeleteSync` | fence guard: C11 `!= 0` / Odin: `sync != nil` | ✅ ISO |
| 3 | Tracy PBO fence reset | `src/tracy_manager.c:61,88,125` | `src/core/tracy/frame_image.odin:61,78,111` | `DeleteSync` | fence guard: C11 `!= 0` / Odin: `sync != nil` | ✅ ISO |

## Résumé quantitatif

| Type | C11 | Odin | Écart |
|------|-----|------|-------|
| MemoryBarrier | 15 | 7 | −8 (features non portées + design diff) |
| FenceSync | 5 | 2 | −3 |
| ClientWaitSync | 4 | 2 | −2 |
| DeleteSync | 12 | 7 | −5 |
| Finish | 2 | 4 | +2 (ibl, bench) |
| GetTexImage | 4 | 2 | −2 |
| GenerateMipmap | 1 | 4 | +3 |

## Observations clés

1. **Odin utilise moins de `glFinish`** — le `glFinish` bloquant d'Odin dans le pipeline IBL async a été totalement supprimé grâce au couplage de Pixel Buffer Objects (PBOs) asynchrones.

2. **Les barriers manquantes (billboard sort, light probes, histogramme)** correspondent à des features
   non encore portées dans Odin.

3. **Design divergence luminance** — C11 utilise SSBO + `GetBufferSubData` + fence async ;
   Odin utilise compute downsample → `GetTexImage` 1×1 asynchrone via Pack PBO sans bloquer la frame CPU, mappé et lu 1 frame plus tard.

4. **Odin est plus conservatif sur les bits de barrier** — ajoute systématiquement `TEXTURE_FETCH`
   en plus de `IMAGE_ACCESS` quand la texture sera samplée dans un pass suivant, ce qui est
   techniquement plus correct selon la spec OpenGL 4.5 §7.12.2.
