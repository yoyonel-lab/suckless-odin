# Dear ImGui Integration — suckless-odin

**Date**: 2026-05-17  
**Branch**: `feat/imgui-integration`  
**Status**: Fonctionnel, tests verts

## Contexte

Intégration de Dear ImGui (v1.91.7-docking) dans le moteur PBR Odin pour
remplacer les raccourcis clavier par une interface graphique unifiée. Toutes
les options de rendu, debug et post-processing sont exposées dans une fenêtre
unique à onglets.

## Architecture

```
deps/odin-imgui/          ← Bindings L-4/odin-imgui (GitLab)
├── imgui_linux_x64.a     ← Bibliothèque statique précompilée (2.8 MB)
├── imgui.odin            ← Bindings Odin (modifié: system:stdc++)
├── imgui_impl_glfw/      ← Backend GLFW
└── imgui_impl_opengl3/   ← Backend OpenGL3

src/gui/gui.odin          ← Package GUI
├── Gui struct            ← État lifecycle ImGui + focus_search
├── Scene_State struct    ← Pointeurs vers l'état mutable de la scène
├── init/destroy          ← Lifecycle (GLFW + OpenGL3 backends)
├── new_frame/render      ← Frame ImGui
├── update(state)         ← Fenêtre unique + search bar + tab bar
├── draw_tab_camera()     ← Onglet Camera (connecté live)
├── draw_tab_scene()      ← Onglet Scene (connecté live)
├── draw_tab_rendering()  ← Onglet Rendering (placeholders grisés)
├── draw_filtered_view()  ← Vue filtrée par recherche (toutes sections)
├── fuzzy_match()         ← Matching multi-termes insensible à la casse
├── wants_keyboard()      ← Query: ImGui capture-t-il le clavier ?
└── wants_mouse()         ← Query: ImGui capture-t-il la souris ?
```

## Design decisions

| Décision | Justification |
|----------|---------------|
| Fenêtre unique + onglets | UX simple, pas de fenêtres multiples à gérer |
| Pas de raccourcis clavier pour les toggles | Tout passe par ImGui (sauf F2 toggle, WASD, Escape) |
| `Scene_State` avec pointeurs | Évite l'import circulaire gui→scene |
| Placeholders `BeginDisabled()` | Interface prête pour le futur, visuellement claire |
| `system:stdc++` au lieu de `system:c++` | libc++ non installée ; `nm` confirme 0 symboles libc++ |

## Contrôles connectés (live)

### Onglet Camera
- Position / Yaw / Pitch (lecture seule)
- Speed, Acceleration, Friction (sliders)
- Sensitivity, Rotation Smoothing, Mouse Smoothing (sliders)
- FOV (slider)
- Head Bobbing enable + fréquence/amplitude
- Reset Camera (bouton)

### Onglet Scene
- Skybox visible (checkbox)
- Skybox Blur LOD (slider)
- Exposure (slider — grisé, pas de tone mapping actif)
- Wireframe (checkbox)

### Onglet Rendering (tout grisé — non implémenté)
- **PBR Debug Modes**: Combo 10 modes (Final PBR, Albedo, Normal, Metallic, Roughness, AO, Irradiance, Prefilter, BRDF LUT, GI Probes)
- **Post-Processing**: Bloom, DoF, Auto-Exposure, Motion Blur, FXAA, Vignette, Film Grain, Chromatic Aberration, Color Grading
- **Debug Views**: Bloom/DoF/Exposure/MB/FXAA/Stencil debug
- **Profiling**: GPU Timeline, GPU Metrics, Perf Mode, Effect Benchmark
- **Scene Debug**: Light Probes, N-Body sim, GI mode, Sort mode
- **Environment**: HDR env cycling, Env LOD blur, Screenshot, Hot-Reload

## Raccourcis clavier restants

| Touche | Action |
|--------|--------|
| Escape | Quitter (toujours actif) |
| F2 | Toggle fenêtre ImGui (toujours actif) |
| Ctrl+F | Focus barre de recherche (quand GUI visible) |
| F1 | Cycle overlay texte |
| F | Fullscreen |
| C | Toggle contrôle caméra souris |
| Space | Reset caméra |
| WASD / QE | Mouvement caméra |
| Scroll | Impulsion vélocité |

## Gestion du focus clavier

| Situation | Comportement |
|-----------|-------------|
| GUI visible, focus sur search input | Touches imprimables (A-Z, 0-9, ponctuation) capturées par ImGui — keybindings app désactivés |
| GUI visible, focus ailleurs dans la fenêtre | Tous les keybindings app actifs |
| GUI visible, Ctrl+F | Place le focus sur la barre de recherche |
| GUI masqué | Tous les keybindings app actifs |
| Touches F1/F2/Escape | Toujours actifs quel que soit le focus ImGui |
| Mouvement caméra (WASD/QE) | Désactivé quand ImGui capture le clavier |

## Recherche de paramètres (fuzzy search)

Barre de recherche en haut de la fenêtre "Engine Controls" :

- **Multi-termes** : les mots séparés par des espaces doivent tous matcher (AND)
- **Insensible à la casse** : `bloom` = `Bloom` = `BLOOM`
- **Recherche sur** : label affiché + mots-clés techniques + nom de section
- **Exemples** :
  - `blur` → Skybox Blur, Env LOD Blur
  - `post-processing` → tous les effets post-FX
  - `debug` → tous les modes debug/profiling
  - `camera speed` → uniquement le slider Speed
- **Mode filtré** : affichage plat groupé par catégorie (remplace les onglets)
- **Aucun résultat** : message rouge "No matching parameters"
- **Ctrl+F** : raccourci pour placer le focus sur la barre

## Compilation

```bash
just build          # Build debug (inclut ImGui)
just build-imgui    # Recompile la bibliothèque ImGui depuis les sources
just lint           # odin check -vet -strict-style -warnings-as-errors
just test           # 16 tests GL + 31 unit tests
```

## Problèmes résolus

1. **`-lc++` linker error** → Remplacé par `system:stdc++` dans `imgui.odin`
2. **Unused import `gl`** → Retiré du package gui
3. **Tone mapping cassait le rendu ISO** → Retiré du shader, exposure grisée dans l'UI
4. **Import circulaire gui↔scene** → `Scene_State` struct avec pointeurs bruts

## Prochaines étapes

1. Implémenter le tone mapping via post-process FBO (dé-griser Exposure)
2. Brancher PBR debug mode (uniform `debugMode` dans le shader)
3. Ajouter hot-reload shaders
4. Implémenter le pipeline post-process (bloom, DoF, etc.)
5. Screenshot via `glReadPixels` + stb_image_write
