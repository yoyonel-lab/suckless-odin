# CPU Usage Profiling — Tracy Analysis (2026-05-23)

## Context

Application: suckless-odin (OpenGL 4.6 PBR renderer, 100 spheres, postfx pipeline)
Observation: ~25% CPU during run (GPU 77%, 143 FPS), semblait anormalement élevé
pour une app pure-rendering sans simulation/réseau/gameplay.

## Setup

- Build: `just build-profile` (Tracy enabled, `-o:speed`)
- Profiler: Tracy 0.13.1 (`just tracy-server`)
- Config: `glfw.SwapInterval(0)` (vsync off)
- Machine: Linux, ~4 cores logiques

## Tracy Zones Instrumentées

### CPU (Main thread)

| Zone             | Source          | Couleur  | Contenu                              |
| ---------------- | --------------- | -------- | ------------------------------------ |
| Frame            | app.odin        | default  | Frame entier (englobant)             |
| GLFW PollEvents  | app.odin        | gris     | Input/event dispatch                 |
| Scene Update     | app.odin        | rouge    | Camera/matrices update               |
| Render_Frame     | app.odin        | —        | Tout le rendu                        |
| Scene_Render     | scene.odin      | orange   | Draw calls (skybox + sphères)        |
| GUI_ImGui        | app.odin        | gris     | ImGui build+render                   |
| Post_Processing  | pipeline.odin   | —        | Chaîne postfx complète               |
| Swap_Buffers     | gl_debug.odin   | orange   | glfwSwapBuffers                      |

### GPU (OpenGL context)

Mêmes zones via `gl_debug.push_group()` qui émet simultanément :
- `glPushDebugGroup` (visible dans RenderDoc)
- Tracy CPU zone
- Tracy GPU zone (timer queries)

## Résultats Mesurés (VSync OFF, 1686 frames, 9.26s)

### Swap_Buffers — la zone critique

| Métrique   | Valeur   |
| ---------- | -------- |
| Total time | 1.47s    |
| Mean       | 873.2 μs |
| Median     | 370.7 μs |
| Mode       | 202.2 μs |
| σ          | 763.3 μs |
| P75        | 1.54 ms  |
| P90        | 1.88 ms  |
| P99        | 2.88 ms  |
| P99.9      | 4.1 ms   |

### Distribution

Bimodale :
- Pic principal à ~200μs (GPU a fini → flush rapide)
- Longue traîne jusqu'à 4.5ms (GPU pas fini → driver stall/back-pressure)

### GPU Frame Time

- Frame 1242: 4.61 ms
- Frame 1243: 3.78 ms
- Frame 1244: 3.85 ms
- Moyenne: ~4 ms → ~250 FPS max théorique GPU

## Diagnostic

### Pourquoi 25% CPU avec "rien à faire" côté CPU ?

**Cause : le CPU ne dort JAMAIS.**

Avec `SwapInterval(0)`, la boucle principale tourne en spin-loop :
1. Poll events (~0.1ms)
2. Update (~0ms)
3. Render + submit GL commands (~2-3ms)
4. SwapBuffers retourne immédiatement OU le driver fait du back-pressure

Le driver MESA/NVIDIA utilise SwapBuffers comme point de throttle :
quand la command queue GPU est pleine (>2-3 frames en vol),
il **bloque** dans SwapBuffers (busy-wait, pas sleep).

Résultat : un core CPU à ~100% → affiché comme ~25% sur 4 cores (ou ~41% avec Tracy overhead).

### Répartition CPU par frame

| Source                             | % frame |
| ---------------------------------- | ------- |
| SwapBuffers (driver back-pressure) | ~20-30% |
| Scene_Render (draw calls)          | ~25-30% |
| Post_Processing                    | ~20-25% |
| GLFW PollEvents                    | ~1%     |
| ImGui + Tracy overhead             | ~10-15% |

### L'app est GPU-bound

- GPU utilisation: 77% (render ~4ms/frame)
- CPU soumission: ~2-3ms/frame (plus rapide que le GPU)
- Le CPU attend le GPU dans SwapBuffers → temps "gaspillé" en apparence

## Test A/B : VSync ON

Prédiction initiale : CPU drops à 5-10% — **FAUX**.

### Résultats réels

| Métrique | Vsync OFF | Vsync ON (Tracy) | Vsync ON (ultra, no profiler) |
| -------- | --------- | ---------------- | ----------------------------- |
| FPS      | 143       | 60               | 60                            |
| GPU      | 77%       | 41%              | 36%                           |
| CPU      | 25%       | 29%              | 18%                           |
| Swap mean| 873 μs    | 285 μs           | —                             |

### Analyse

- SwapBuffers est PLUS RAPIDE avec vsync (285μs vs 873μs) : pas de back-pressure
- L'attente vsync se fait hors des zones Tracy (kernel DRM pageflip)
- CPU 18% en ultra-release = travail réel de soumission GL (~3ms/16.7ms frame)
- Les 11% de delta (29% - 18%) = overhead Tracy + MangoHud combinés
- Le CPU n'atteint pas 5% car le rendu (100 sphères + postfx) consomme réellement ~3ms/frame

### Conclusion corrigée

Le 18% CPU résiduel avec vsync ON est **le coût réel incompressible** de :
- 1 draw call instancié (100 sphères) + SSBO sort/upload chaque frame
- Pipeline postfx (~6 passes : bloom, FXAA prepass, DoF, motion blur, auto-exposure, composite)
- ImGui overlay (vertex building + draw)
- Driver GL overhead (state validation, command buffer building)

C'est normal pour OpenGL. Seul Vulkan/Metal pourrait réduire la partie driver.

## Commandes

```bash
# Build avec Tracy
just build-profile

# Lancer Tracy profiler
just tracy-server

# Lancer l'app (dans un autre terminal)
./build/profile/suckless-odin

# Activer vsync via CLI (réduit CPU usage)
./build/profile/suckless-odin --vsync

# Pour le test A/B, comparer:
./build/ultra/suckless-odin              # vsync off (uncapped, CPU hot)
./build/ultra/suckless-odin --vsync      # vsync on (capped, CPU idle)
```

## Conclusion

Le CPU usage observé est **normal et attendu** pour une app OpenGL sans vsync :
- Ce n'est pas un bug
- Ce n'est pas du travail CPU inutile
- C'est le driver GL qui fait du back-pressure (spin-wait dans SwapBuffers)
- L'application est correctement GPU-bound

Pour économiser du CPU (laptop, multi-app) : activer vsync.
Pour maximiser le throughput/latence : garder vsync off (comportement actuel).
