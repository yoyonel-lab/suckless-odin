# Portage suckless-ogl (C11) → suckless-odin

Document de référence pour le portage ISO de l'application legacy C11 vers Odin.

---

## Vue d'ensemble

| Métrique | C11 (legacy) | Odin (port) |
|----------|-------------|-------------|
| Fichiers source | ~45 `.c` + ~35 `.h` | 49 `.odin` |
| Shaders GLSL | 55+ | 27 |
| Tests | 63 | 160 (16 fichiers) |
| Keybindings | ~67 | 9 (Escape, F, F1, WASD, Q/E, C, Space, Scroll, mouse) |
| Effets post-process | 13 | 9 |

---

## Statut par sous-système

### Légende

- ✅ **Porté** — Fonctionnel, ISO avec le C
- 🟡 **Partiel** — Squelette en place, fonctionnalités manquantes
- ❌ **Non porté** — Rien dans le code Odin

---

### 1. Core Application

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Fenêtre GLFW + contexte GL 4.x | `app.c`, `app_window.c` | `app/app.odin`, `app/window.odin` | ✅ |
| Boucle principale (poll → update → render → swap) | `app.c` | `app/app.odin` | ✅ |
| Toggle fullscreen (F) | `app_input.c` | `app/app.odin` | ✅ |
| CLI (-h/--help) | `cli.c` | `cli.odin` | ✅ |
| CLI OGL_LOG_LEVEL env var | `cli.c` | — | ❌ |
| Logging (niveaux, timestamps, callback) | `log.c` | `core/log/log.odin` | ✅ |
| Framebuffer resize callback | `app.c` | `app/app.odin` | ✅ |

### 2. Caméra

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| FPS camera (position, yaw/pitch) | `camera.c` | `camera/camera.odin` | ✅ |
| Physics (accélération, friction, Verlet) | `camera.c` | `camera/camera.odin` | ✅ |
| Mouse smoothing | `camera.c` | `camera/camera.odin` | ✅ |
| Rotation smoothing | `camera.c` | `camera/camera.odin` | ✅ |
| Head bobbing | `camera.c` | `camera/camera.odin` | ✅ |
| Scroll impulse (vélocité front) | `camera.c` | `camera/camera.odin` | ✅ |
| Reset caméra (Space) | `app_input.c` | `app/app.odin` | ✅ |
| Toggle mouselook (C) | `app_input.c` | `app/app.odin` | ✅ |

### 3. Rendu

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Billboard PBR instancié (SSBO) | `billboard_rendering.c`, `ssbo_rendering.c` | `rendering/instanced.odin`, `rendering/billboard.odin` | ✅ |
| Instanced VBO (icosphere) | `instanced_rendering.c` | — | ❌ |
| Wireframe mode (Z) | `app_input.c`, `renderer.c` | `scene/scene.odin` (GUI toggle) | ✅ |
| Toggle billboards (L) | `app_input.c` | — | ❌ |
| Tri des sphères : CPU qsort / CPU Radix / GPU Bitonic (O) | `renderer.c` | `scene/scene.odin` (qsort + radix) | 🟡 GPU Bitonic not ported |
| Edge factor (analytic billboard AA) | `scene_render.c`, `pbr_ibl_billboard.frag` | `scene/scene.odin`, `pbr_billboard.frag` | ✅ |
| Icosphere subdiv Up/Down | `app_input.c` | — | ❌ |
| RenderContext abstraction | `renderer.c` | — | ❌ |

### 4. PBR / IBL

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| PBR fragment shader (Cook-Torrance, Fresnel, multi-scattering) | `pbr_billboard.frag` | `pbr_billboard.frag` | ✅ |
| Ray-sphere intersection + gl_FragDepth | shaders | shaders | ✅ |
| BRDF LUT (compute) | `ibl_coordinator.c` | `rendering/ibl.odin` | ✅ |
| Irradiance map (compute) | `ibl_coordinator.c` | `rendering/ibl.odin` | ✅ |
| Prefilter specular map (compute, 5 mips) | `ibl_coordinator.c` | `rendering/ibl.odin` | ✅ |
| IBL coordinator state machine (progressive, sliced dispatch) | `ibl_coordinator.c` | — | 🟡 One-shot dispatch, pas de state machine |
| Mean luminance compute (auto-clamp threshold) | `pbr.c` | — | ❌ |
| PBR Debug modes (F5) : Albedo, Normal, Metallic, etc. | `app_input.c`, shaders | — | ❌ |
| Specular anti-aliasing (N / Shift+N) | `app_input.c` | — | ❌ |
| Matériaux JSON | `material.c` | `rendering/material.odin` | ✅ |

### 5. Skybox / Environnement

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Skybox equirectangulaire (fullscreen quad) | `skybox.c` | `rendering/skybox.odin` | ✅ |
| HDR loading (stb_image) | `texture.c` | `rendering/texture.odin` | ✅ |
| Toggle skybox (K) | `app_input.c` | — | ❌ |
| Cycle HDR environments (PgUp/PgDn) | `env_manager.c` | — | ❌ |
| Async HDR loading pipeline (PBO) | `env_manager.c` | — | ❌ |
| Env LOD blur (Shift+PgUp/PgDn) | `app_input.c` | — | ❌ |
| Transitions crossfade / black screen (T) | `env_manager.c` | — | ❌ |

### 6. Light Probes (1-Bounce GI)

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Grille 3D de probes SH9 | `light_probes.c` | — | ❌ |
| Worker thread async (pthread) | `light_probes.c` | — | ❌ |
| Upload GPU (7× 3D textures + SSBO) | `light_probes.c` | — | ❌ |
| Cycle GI mode : OFF / 3D Tex / SSBO (Y) | `app_input.c` | — | ❌ |
| Toggle probe debug viz (Shift+Y) | `app_input.c` | — | ❌ |

### 7. Post-Processing

| Effet | Touche | C11 | Odin | Statut |
|-------|--------|-----|------|--------|
| **Bloom** (multi-mip, prefilter/down/up) | B | `fx_bloom.c` | — | ❌ |
| Bloom debug (Shift+B, Alt+B) | | `fx_bloom.c` | — | ❌ |
| **Depth of Field** (séparable, anamorphique) | H | `fx_dof.c` | — | ❌ |
| DoF debug (Shift+H) | | `fx_dof.c` | — | ❌ |
| **Auto Exposure** (frag + compute paths) | J | `fx_auto_exposure.c` | — | ❌ |
| Exposure debug histogram (Shift+J) | | `fx_auto_exposure.c` | — | ❌ |
| AE path toggle frag/compute (Ctrl+J) | | `fx_auto_exposure.c` | — | ❌ |
| Manual exposure (KP+/KP-) | | `postprocess_input.c` | — | ❌ |
| **Motion Blur** (compute tile/neighbor) | M | `fx_motion_blur.c` | — | ❌ |
| MB debug (Shift+M) | | `fx_motion_blur.c` | — | ❌ |
| **FXAA** | X | shaders | — | ❌ |
| FXAA debug (Shift+X) | | shaders | — | ❌ |
| **Vignette** | V | shaders | — | ❌ |
| **Film Grain** | G | shaders | — | ❌ |
| **Chromatic Aberration** | U | shaders | — | ❌ |
| **3D LUT Color Grading** (7 LUTs) | F8 / Shift+F8 | `fx_lut3d.c` | — | ❌ |
| LUT Visualization 3D (Shift+F10) | | `fx_lut_viz.c` | — | ❌ |
| **Fog** | F7 | shaders | — | ❌ |
| **Banding** (style presets) | 7 | shaders | — | ❌ |
| Scene FBO (MRT : color HDR + velocity + depth/stencil) | | `postprocess_init.c` | — | ❌ |
| **Presets** (1-9, 0) | 1-9, 0 | `postprocess_presets.c` | — | ❌ |
| Sony A7S III (F8) | | `postprocess_presets.c` | — | ❌ |
| Reset PostFX (0 / KP0) | | `postprocess_input.c` | — | ❌ |

### 8. N-Body Simulation

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Velocity Verlet O(N²) gravity | `scene_nbody.c` | — | ❌ |
| Toggle simulation (Shift+G) | `app_input.c` | — | ❌ |
| Time reversal (Ctrl+Shift+G) | `app_input.c` | — | ❌ |
| Speed control (,/.) | `app_input.c` | — | ❌ |
| Gravity control (Shift+,/Shift+.) | `app_input.c` | — | ❌ |
| Trail renderer (ring buffer) | `scene_nbody.c` | — | ❌ |
| Neon glow params (I / Shift+I / Ctrl+I) | `app_input.c` | — | ❌ |
| Shockwave VFX on impact | `scene_nbody.c` | — | ❌ |
| Energy conservation tracking | `scene_nbody.c` | — | ❌ |

### 9. Input System

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Clavier WASD + Q/E (up/down) | `app_input.c` | `app/app.odin` | ✅ |
| Souris (mouselook, toggle C) | `camera_input.c` | `app/app.odin` | ✅ |
| Scroll (impulse vélocité front) | `camera_input.c` | `app/app.odin` | ✅ |
| AppBindingRegistry (67 bindings) | `app_binding.c` | — | ❌ |
| Gamepad support (sticks, triggers, buttons) | `gamepad_input.c` | — | ❌ |
| PostProcessInputContext (effet toggles) | `postprocess_input.c` | — | ❌ |
| Action notifier (toasts) | `app_input.c` | — | ❌ |

### 10. Overlays / Debug

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Text overlay FPS/position (F1) | `app_ui.c` | `rendering/overlay.odin` | ✅ |
| Help overlay keyboard (F2) | `app_ui.c`, `app_binding.c` | — | ❌ |
| Help overlay gamepad (F2) | `app_ui.c` | — | ❌ |
| GPU timeline (F3) | `gpu_profiler.c` | — | ❌ |
| GPU metrics log (F4) | `gpu_profiler.c` | — | ❌ |
| Stencil debug (F6) | `app_input.c` | — | ❌ |
| Perf mode (F9) | `app_input.c` | — | ❌ |

### 11. Profiling

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| GPU profiler (ping-pong queries, adaptive sampling) | `gpu_profiler.c` | `rendering/postfx/gpu_timer.odin` | ✅ |
| Effect benchmark (A/B auto measurement) | `effect_benchmark.c` | — | ❌ |
| Tracy integration | `tracy_manager.c` | `core/tracy/tracy.odin` | ✅ |
| `perf_timer.c` (CPU timing) | `perf_timer.c` | — | ❌ |

### 12. Screenshot / Capture

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Screenshot PNG timestamped (Shift+F12) | `app_input.c` | — | ❌ |
| Quick capture (P) | `app_input.c` | — | ❌ |

### 13. Shader Management

| Feature | C11 | Odin | Statut |
|---------|-----|------|--------|
| Load vert+frag program | `shader.c` | `rendering/shader/shader.odin` | ✅ |
| Load compute program | `shader.c` | `rendering/shader/shader.odin` | ✅ |
| `@header` include processing | `shader.c` | `rendering/shader/shader.odin` | ✅ |
| Uniform caching | `shader.c` | `rendering/shader/shader.odin` | ✅ |
| Hot-reload shaders (R) | `app_input.c`, `shader.c` | — | ❌ |

---

## Keybindings — Mapping complet

### Portés ✅

| Touche | Action | Fichier Odin |
|--------|--------|--------------|
| Escape | Quitter | `app/app.odin` |
| F | Toggle fullscreen | `app/app.odin` |
| F1 | Toggle overlay (3 modes) | `app/app.odin` → `scene/scene.odin` |
| W/A/S/D | Déplacement caméra | `app/app.odin` |
| Q | Monter | `app/app.odin` |
| E | Descendre | `app/app.odin` |
| Space | Reset caméra (position + orientation) | `app/app.odin` |
| C | Toggle mouselook (curseur visible/caché) | `app/app.odin` |
| Scroll | Impulse vélocité (front caméra) | `app/app.odin` → `camera/camera.odin` |
| Souris | Mouselook (quand camera_enabled) | `app/app.odin` → `camera/camera.odin` |

### Non portés ❌ (par catégorie)

#### Visuals
| Touche | Action | Priorité |
|--------|--------|----------|
| Z | Wireframe | P2 |
| L | Toggle billboards | P3 |
| K | Toggle skybox | P1 |
| F5 | Cycle PBR debug | P2 |
| Up/Down | Subdiv icosphere | P3 |
| PgUp/PgDn | Cycle HDR env | P2 |
| Shift+PgUp/PgDn | Env LOD blur | P3 |
| Y / Shift+Y | GI mode / probe debug | P3 |
| Shift+G | N-Body toggle | P3 |
| Ctrl+Shift+G | Time reversal | P3 |
| ,/. | Sim speed | P3 |
| Shift+,/. | Gravity | P3 |
| I / Shift+I / Ctrl+I | Neon params | P3 |

#### PostFX
| Touche | Action | Priorité |
|--------|--------|----------|
| B | Bloom | P2 |
| H | DoF | P2 |
| J | Auto-exposure | P2 |
| M | Motion blur | P2 |
| X | FXAA | P2 |
| V | Vignette | P3 |
| G | Grain | P3 |
| U | Chromatic aberration | P3 |
| N / Shift+N | Specular AA | P3 |
| F7 | Fog | P3 |
| F8 / Shift+F8 | LUT / Sony A7S | P3 |
| Shift+F10 | LUT Viz 3D | P3 |
| 1-9, 0 | Presets / Reset | P2 |
| KP+/KP- | Exposure manuelle | P2 |

#### System
| Touche | Action | Priorité |
|--------|--------|----------|
| F2 | Help overlay | P2 |
| F3 | GPU timeline | P3 |
| F4 | GPU metrics log | P3 |
| F9 | Perf mode | P3 |
| Shift+F12 | Screenshot | P1 |
| P | Quick capture | P2 |
| R | Hot-reload shaders | P1 |
| O | Cycle tri sphères | P3 |
| T | Transition env | P3 |

---

## Plan de portage recommandé

### Phase 1 — Interaction de base (Priorité P1)
Quick wins, pas de nouveau shader/FBO requis.

1. ~~**Reset caméra** (Space)~~ ✅ — `app/app.odin` → `camera.init()`
2. ~~**Toggle mouselook** (C)~~ ✅ — `app/app.odin` → `camera_enabled` + curseur
3. **Toggle skybox** (K) — skip le draw call skybox
4. **Screenshot** (Shift+F12) — `glReadPixels` → stb_image_write PNG
5. **Hot-reload shaders** (R) — recompiler shaders à chaud
6. ~~**Text overlay FPS** (F1)~~ ✅ — `rendering/overlay.odin` (stb_truetype, 3 modes)

### Phase 2 — Post-Processing Pipeline (Priorité P2)
Requiert : Scene FBO (MRT), ping-pong buffers, fullscreen quad pass.

1. **Scene FBO** (color HDR RGBA16F + depth) — fondation de toute la chaîne
2. **Tone mapping** — HDR → LDR (Reinhard / ACES / exposure manuelle)
3. **Bloom** (B) — downsample/upsample chain
4. **Auto-Exposure** (J) — luminance compute → adaptation
5. **FXAA** (X) — luma-in-alpha, edge detection pass
6. **Motion Blur** (M) — velocity buffer MRT + compute tile/neighbor
7. **Depth of Field** (H) — CoC + séparable blur
8. **Presets** (1-9, 0) — combinaisons d'effets

### Phase 3 — Environnement avancé (Priorité P2)
1. **Env manager** — scanner dossier HDR, cycle PgUp/PgDn
2. **Async HDR loading** (PBO upload)
3. **Transitions** crossfade / black screen (T)
4. **Env LOD** blur (Shift+PgUp/PgDn)

### Phase 4 — Simulation & VFX (Priorité P3)
1. **N-Body** Velocity Verlet O(N²)
2. **Trail renderer** ring buffer
3. **Neon glow** params
4. **Shockwave VFX**
5. **Time control** (,/./Shift+G/Ctrl+Shift+G)

### Phase 5 — Profiling & Debug (Priorité P3)
1. **GPU profiler** (F3) — GL_TIMESTAMP queries
2. **Effect benchmark** (8) — A/B measurement
3. **PBR debug modes** (F5) — 10 visualization modes
4. **Wireframe** (Z)
5. **Help overlay** (F2)
6. **Light probes** (Y) — GI 1-bounce

### Phase 6 — Polish (Priorité P3)
1. **Gamepad** support
2. **Binding registry** — système déclaratif comme `app_binding.c`
3. **Sorting modes** (O) — CPU/GPU sort
4. **Tracy** integration
5. **Tests** — portage des 63 tests

---

## Statistiques de couverture

| Catégorie | Total C11 | Porté Odin | % |
|-----------|-----------|------------|---|
| Sous-systèmes | 13 | 11 | 85% |
| Keybindings | 67 | 9 | 13% |
| Effets PostFX | 13 | 9 | 69% |
| Shaders | 55+ | 27 | ~49% |
| Tests | 63 | 160 | 254% |

### Ce qui fonctionne aujourd'hui
- 100 sphères PBR instanciées (SSBO, grille 10×10)
- Skybox HDR equirectangulaire
- IBL complet (irradiance + prefilter + BRDF LUT)
- Caméra FPS physique (accélération, friction, bobbing, smoothing)
- Toggle fullscreen
- Shaders : PBR billboard + skybox + 3 compute IBL

### Ce qui manque le plus (impact utilisateur)
1. **Post-processing** — rendu brut HDR sans tone mapping, bloom, etc.
2. **Env cycling** — bloqué sur une seule HDR
3. **Contrôles interactifs** — seulement WASD/mouse/Escape/F
4. **Profiling** — pas de métriques GPU
5. **Screenshot** — pas de capture d'image
