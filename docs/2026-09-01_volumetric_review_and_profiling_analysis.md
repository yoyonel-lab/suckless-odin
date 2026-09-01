# Review Technique & Analyse d'Intégration : Volumetric Lighting & Profiling (Phases 6 & 7)

**Date** : 1er Septembre 2026  
**Projet** : [`suckless-odin`](file:///home/latty/Prog/__PERSO__/suckless-odin) (`OpenGL 4.4 Core`)  
**Fichiers de Référence** :
- Plan d'intégration : [`docs/2026-08-31_volumetric_dynamic_lights_integration_plan.md`](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/2026-08-31_volumetric_dynamic_lights_integration_plan.md)
- Modules Odin : [`src/rendering/shadow_cubemap.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin), [`src/rendering/volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric.odin), [`src/rendering/volumetric_timers.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric_timers.odin), [`src/rendering/volumetric_presets.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric_presets.odin)
- Shaders : [`shaders/shadow_cube.vert`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.vert), [`shaders/shadow_cube.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.frag), [`shaders/postfx/volumetric_composite_simple.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_composite_simple.frag), [`shaders/postfx/volumetric_raymarch.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_raymarch.frag), [`shaders/postfx/volumetric_taa.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_taa.frag), [`shaders/postfx/volumetric_bilateral_blur.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_bilateral_blur.frag)
- Interface ImGui : [`src/gui/gui_volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_volumetric.odin), [`src/gui/gui_postfx.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_postfx.odin)
- Tests : [`tests/test_volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/test_volumetric.odin), [`tests/test_shadow_cubemap.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/test_shadow_cubemap.odin)

---

## 1. Synthèse Globale de l'Intégration (Phases 6 & 7)

Les **Phases 6 (Composite & Joint Bilateral Upsampling)** et **Phase 7 (Hub ImGui, Presets & Profiling Hardware)** sont implémentées de manière conforme à la spécification OpenGL 4.4 Core. L'ensemble de la suite de tests unitaires et graphiques (`task test`) passe avec 100% de succès (98 tests unitaires, 13 tests CLI, 12 tests shaders, 88 tests GL).

---

## 2. Analyse Approfondie : Shadow Maps, MRT & Instancing

### 2.1 Formats de Texture & Framebuffer Object (FBO)
* **Depth Cubemap** : `GL_TEXTURE_CUBE_MAP`, format interne `GL_DEPTH_COMPONENT32F`.
  * Filtre : `GL_NEAREST` (requis pour test de comparaison ou lecture brute de profondeur).
  * Clamping : `GL_CLAMP_TO_EDGE` sur S, T, R.
* **Linear Depth Cubemap** : `GL_TEXTURE_CUBE_MAP`, format interne `GL_R32F`.
  * Stocke la distance radiale normalisée $[0..1]$ ($t / R$).
  * Filtre : `GL_LINEAR` (permet un filtrage matériel continu lors du raymarching volumétrique).

### 2.2 Multiple Render Targets (MRT)
* Le FBO [`sc.fbo`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin#L79) attache simultanément :
  1. `GL_DEPTH_ATTACHMENT` $\rightarrow$ `sc.depth_cubemap` (Face $+X..-Z$)
  2. `GL_COLOR_ATTACHMENT0` $\rightarrow$ `sc.linear_depth_cubemap` (Face $+X..-Z$)
* **Avantage architectural** : Dans [`shaders/shadow_cube.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.frag#L3-L9), l'intersection rayon-sphère analytique est calculée **une seule fois** par fragment. Le shader écrit simultanément :
  * `gl_FragDepth` (`layout(depth_greater)`) pour le test matériel Z.
  * `LinearDepth` (`layout(location = 0)`) pour l'in-scattering volumétrique.
* Zéro passe supplémentaire requise, bande passante mémoire optimisée.

### 2.3 Rendu Instancié (Instanced Billboard Spheres)
* **Draw Call** : 1 seul appel `glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, spheres.count)` par face de cubemap.
* **Extraction des instances** :
  * Le vertex shader [`shaders/shadow_cube.vert`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.vert#L23-L25) lit les transformations depuis l'instance SSBO (`BillboardInstanceSSBO`, binding 2) via `gl_InstanceID`.
  * Calcul analytique des boîtes englobantes projetées (tangent-line bounding calculation) pour minimiser la surface de rastérisation des quads.

### 2.4 Dirty Caching & Time-Slicing Temporel
* **Dirty Caching** : Si la source lumineuse est statique (`light.is_dirty == false` et `!light.is_animated`), la passe shadow cubemap est totalement ignorée ($0\,\mu s$).
* **Time-Slicing** : Supporte 4 modes de découpage temporel :
  * Mode 0 : 6 faces / frame (Temps réel pur).
  * Mode 1 : 3 faces / frame (Cycle 2 frames).
  * Mode 2 : 2 faces / frame (Cycle 3 frames).
  * Mode 3 : 1 face / frame (Cycle 6 frames - Max FPS).

---

## 3. Analyse Phase 6 : Composite & Joint Bilateral Upsampling (JBU)

* **Intégration** : Réalisée dans [`volumetric_composite_to_scene`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric.odin#L873-L951) et [`shaders/postfx/volumetric_composite_simple.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_composite_simple.frag).
* **Blending** : `glBlendFunc(GL_ONE, GL_ONE)` (composite additif pur dans le buffer HDR `scene_fbo`).
* **Modes d'Upsampling** :
  1. **Mode 0 (Bilinear)** : Échantillonnage matériel standard basse résolution (baseline).
  2. **Mode 1 (Nearest-Depth Fast JBU)** : Sélection directe du tap volumétrique dont la profondeur est la plus proche de la profondeur haute résolution $Z_{\text{full}}$.
  3. **Mode 2 (Joint Bilateral Upsampling 2x2)** : Calcul de 4 poids combinant interpolation bilinéaire spatiale et pénalisation par écart relatif de profondeur :
     $$w_i = w_{\text{spatial}, i} \cdot \frac{1.0}{1.0 + k_{\text{upsample}} \cdot \frac{|Z_{\text{full}} - Z_i|}{\max(Z_{\text{full}}, Z_{\text{near}})}}$$
     Avec normalisation et fallback automatique sur Nearest-Depth si $\sum w_i < 10^{-4}$.
* **Résultat Visuel** : Élimine totalement le crénelage demi-résolution et les bavures de brouillard à travers les arêtes des sphères opaques.

---

## 4. Analyse Phase 7 : Profiling, Instrumentation & ImGui Hub

### 4.1 Système de Timers GPU Hardware (`GL_TIME_ELAPSED`)
* Structure dédiée [`Volumetric_Gpu_Timers`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric_timers.odin#L42) avec requêtes asynchrones en double-buffering ($N-1$).
* **6 Sous-Passes Mesurées Individuellement** :
  1. `Shadow_Pass`
  2. `Depth_Downsample`
  3. `Raymarching`
  4. `TAA_Blend`
  5. `Bilateral_Blur`
  6. `Composite_Upsample`
* **Lissage** : Fenêtre glissante de moyenne arithmétique de 0.5s (`display_avg`, `display_min`, `display_max`).
* **Zéro Stalling GPU** : Vérification `GL_QUERY_RESULT_AVAILABLE` avant `glGetQueryObjectui64v`. Zéro `glFinish` et zéro flush pipeline.

### 4.2 Instrumentation Tracy & OpenGL Debug Markers
* **Groupes de Débogage GL** : Parfaitement imbriqués (`Volumetric_Pipeline`, `Volumetric_Raymarch_Pass`, `Volumetric_TAA_Reprojection_Pass`, `Volumetric_Bilateral_Blur_Pass`, `Volumetric_Composite_Direct`).
* **Zones Tracy** :
  * `srcloc_volumetric_render` (Zone englobante de la fonction).
  * `srcloc_volumetric_composite` (Passe composite).

### 4.3 Intégration ImGui
* **Onglet 9 : Volumetric & Shadows** ([`gui_volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_volumetric.odin)) :
  * Contrôle physique complet (Raymarch steps, coefficients de diffusion/extinction, anisotropie $g$, jittering).
  * Tracé temps réel de la courbe polaire Henyey-Greenstein $P(\theta, g)$.
  * Atlas 3x2 déplié interactif des 6 faces du cubemap avec tooltip UV au survol.
  * Loupe $1\times..16\times$ avec translation UV.
  * 7 Presets cinématiques physiques (`Default`, `Isotropic`, `Morning Fog`, `God Rays`, `Alan Wake Torch`, `Car Headlights`, `Dense Dust`).
  * Télémétrie en temps réel avec barres de progression et métriques en microsecondes ($\mu s$).
* **Onglet 5 : Profiling** ([`gui_postfx.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_postfx.odin#L738-L800)) :
  * Tableau récapitulatif complet de la pipeline volumétrique avec moyenne, minimum, maximum et pourcentage du budget frame, aligné avec les passes Post-FX.

---

## 5. Estimation Détaillée du Coût GPU (1080p Viewport / 540p Buffer)

### 5.1 Coût de l'Instrumentation (Profiling Hardware)
* **Overhead des requêtes `GL_TIME_ELAPSED`** : $< 1\,\mu s$ ($0.001\text{ ms}$) par frame.
* **Overhead CPU Driver** : $\approx 1 - 2\,\mu s$ (émission de 6 `Begin/EndQuery` asynchrones).
* **Impact Stalling** : $0\,\mu s$ (lecture différée sur frame $N-1$).

### 5.2 Breakdown des Sous-Passes Volumétriques

| Sous-Passe | Résolution Cible | Description du Traitement | Coût GPU Estimé ($\mu s$) |
| :--- | :---: | :--- | :---: |
| **Shadow Cubemap** | $256^2 \times 6$ faces | Rendu instancié billboard ($0\,\mu s$ si statique / mis en cache) | $0 - 100\,\mu s$ |
| **Depth Downsample** | $960\times 540$ | Filtre médian 4-tap linéaire + détection de discontinuité | $30 - 60\,\mu s$ |
| **Raymarching ($N=16$)** | $960\times 540$ | Ray-sphere cone clipping + Phase HG + 1 shadow tap / step | $250 - 550\,\mu s$ |
| **TAA Reprojection** | $960\times 540$ | Reprojection $\mathbf{VP}_{\text{prev}}$ + 3x3 clamp + Disocclusion | $40 - 80\,\mu s$ |
| **Joint Bilateral Blur** | $960\times 540$ | 2 passes 1D séparables (9 taps horizontal + 9 taps vertical) | $60 - 130\,\mu s$ |
| **JBU Composite Pass** | $1920\times 1080$ | 2x2 Depth-Guided Bilateral Upsample additif dans HDR | $80 - 160\,\mu s$ |
| **TOTAL PIPELINE** | - | **Pipeline Volumétrique Complète** | **$0.46 - 1.08\text{ ms}$** |

### 5.3 Budget Frame
* À **60 FPS** (budget 16.67 ms) : $\approx 3.0\% - 6.5\%$ du temps de trame.
* À **144 FPS** (budget 6.94 ms) : $\approx 6.5\% - 15.5\%$ du temps de trame.

---

## 6. Points d'Amélioration & Corrections Recommandées

### 🔍 Point 1 : Zones Tracy Internes Inutilisées (Dead Code)
* **Constat** : Dans [`src/rendering/volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric.odin#L23-L48), les descripteurs de localisation `srcloc_volumetric_raymarch`, `srcloc_volumetric_taa`, `srcloc_volumetric_blur` sont déclarés mais jamais appelés dans le corps de `volumetric_render`.
* **Correction** : Ajouter les appels `tracy.zone_begin` / `tracy.zone_end` dans chaque sous-bloc de `volumetric_render` pour un profiling CPU Tracy à granularité fine correspondant aux timers GPU.

### 🔍 Point 2 : Delta Time Hardcodé dans `scene.odin` pour la collecte des timers
* **Constat** : Dans [`src/scene/scene.odin:446`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/scene.odin#L446), l'appel est `rendering.volumetric_timers_collect(&s.volumetric.timers, 0.016)`.
* **Correction** : Stocker le véritable `dt` dans `Scene` (ou `Volumetric_Renderer`) lors de `scene_update` pour que la fenêtre de lissage de 0.5s soit exacte quel que soit le framerate réel (144 Hz, 30 Hz, VRR).

### 🔍 Point 3 : Synchronisation du Journal de Suivi dans le Plan
* **Constat** : Dans [`docs/2026-08-31_volumetric_dynamic_lights_integration_plan.md:236-237`](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/2026-08-31_volumetric_dynamic_lights_integration_plan.md#L236-L237), les jalons M7 (Phase 6) et M8 (Phase 7) étaient encore notés `⏳ À faire`.
* **Correction** : Mettre à jour la matrice d'avancement à `✅ Terminé` (01/09/2026).
