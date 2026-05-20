# PostFX Porting Gap Analysis — Legacy C11 vs Odin Port

**Date**: 2026-05-19  
**Branch**: `feat/postfx-pipeline`  
**Legacy reference**: `suckless-ogl` (C11, OpenGL 4.5)

## Status Summary

| Layer | ISO % | Notes |
|-------|-------|-------|
| UBO layout (implemented effects) | ~100% | Matches GLSL PostProcessBlock |
| Core effects (vignette→FXAA, bloom, auto-exposure, DoF) | ~90% | All functional |
| Pipeline architecture (uber-shader, shader cache, GPU timers) | ~85% | Complete |
| Presets (variety, richness) | 38% | 5/13 ported |
| Advanced FX (motion blur, fog, banding, LUT) | 25% | Banding implemented, others pending |
| Camera Profile System | 0% | Not started |

## Missing Subsystems

### 1. Motion Blur (tile-max + neighbor-max compute)

- **Legacy**: Full pipeline — tile_max shader, neighbor_max shader, velocity buffer, stencil masking, configurable samples/intensity/max_velocity
- **Odin**: Bit `Motion_Blur = 10` defined, disabled in GUI, no shader/texture/pipeline
- **UBO fields needed**: `mb_intensity`, `mb_maxVelocity`, `mb_samples` (16B section)
- **Textures needed**: velocity buffer (unit 4), neighbor-max (unit 5), stencil (unit 7)

### 2. Banding (Color Quantization — 5 artistic modes)

- **Legacy**: 5 modes (Linear/Dithered/Perceptual/Channel/Luminance), full shader impl
- **Odin**: **[DONE]** Fully implemented with 5 artistic modes and UBO params.

### 3. Fog (Atmospheric — exponential height-based)

- **Legacy**: Depth-based exponential, height falloff, spectral shift (Rayleigh), skybox masking, debug mode
- **Odin**: Bit `Fog = 15` defined, no shader, no params
- **UBO fields needed**: `fog_density`, `fog_start`, `fog_heightFalloff`, `fog_maxOpacity`, `fog_color` (vec3), `fog_camPos` (vec4), `fog_invViewProj` (mat4) — 112B section
- **Note**: Fog requires camera world-space position and inverse VP matrix per-frame

### 4. 3D LUT (Gamut Mapping)

- **Legacy**: `.cube` file loader, GL_TEXTURE_3D upload, gallery cycling, intensity blend
- **Odin**: Bit `LUT3D = 16` defined, no implementation
- **UBO fields needed**: `lut3d_intensity` — 16B section
- **Textures needed**: 3D LUT texture (unit 8)

## Missing Presets (8/13)

| Preset | Key Feature | Dependencies |
|--------|-------------|--------------|
| Vintage | Warm/grainy, desat | Existing effects only |
| Matrix | Green-tinted, bloom | Existing effects only |
| BW_Contrast | High-contrast B&W | Existing effects only |
| Posterized | Banding mode=linear, 4 levels | **Banding** |
| Retro | Banding mode=dithered | **Banding** |
| Analog | Banding mode=perceptual | **Banding** |
| Channel_GFX | Banding mode=channel (VGA/CGA) | **Banding** |
| Blueprint | Banding mode=luminance | **Banding** |
| Nordic_Noir | Fog + teal shadows + lifted blacks | **Fog** |
| Sony_A7SIII | S-Cinetone + anamorphic + LUT | **LUT3D** |

**Note**: Vintage, Matrix, BW_Contrast use ONLY existing effects — they can be ported immediately.

## Camera Profile System (not started)

Legacy had 4 camera profiles (Sony/Fujifilm/Leica/Canon), each bundling:
- Specific grain characteristics
- Tone mapping curve tuning
- Color grading + white balance
- LUT selection
- Bokeh params (anamorphic ratio)

Applied via `F8` at runtime. In practice, they're specialized presets.

## Porting Roadmap

### Phase 1: Data Structures (immediate)
- [ ] Add `Banding_Params`, `Fog_Params`, `Motion_Blur_Params` structs
- [ ] Add defaults
- [ ] Extend `Post_FX_UBO` (append after Camera planes)
- [ ] Extend GLSL `PostProcessBlock` to match
- [ ] Extend `Preset` struct
- [ ] Port 3 "easy" presets (Vintage, Matrix, BW_Contrast)

### Phase 2: Banding Effect
- [x] GLSL banding implementation (5 modes)
- [ ] Port 5 banding presets (Posterized, Retro, Analog, Channel_GFX, Blueprint)

### Phase 3: Fog Effect
- [ ] GLSL fog implementation (exponential + height + spectral)
- [ ] Pass camera data to UBO per-frame
- [ ] Port Nordic_Noir preset

### Phase 4: Motion Blur
- [ ] Velocity buffer generation
- [ ] Tile-max compute shader
- [ ] Neighbor-max compute shader
- [ ] Motion blur composite in uber-shader

### Phase 5: 3D LUT
- [ ] `.cube` file parser
- [ ] GL_TEXTURE_3D upload
- [ ] GLSL LUT sampling
- [ ] Port Sony_A7SIII preset
- [ ] LUT gallery system

### Phase 6: Camera Profiles
- [ ] Profile system (specialized presets with runtime switching)
- [ ] F8 keybind for profile cycling
