# Rapport d'Optimisation des Performances GPU & Pipeline (P0 Quick Wins)

**Date** : 26 Octobre 2026  
**Auteur** : Antigravity & GLM Review Analysis  
**Statut** : ✅ Implémenté, Mesuré & Validé en Production  
**Fichiers concernés** :
- `shaders/postfx/volumetric_raymarch_directional.frag`
- `src/rendering/postfx/pipeline.odin`
- `src/gui/gui_volumetric.odin`
- `src/rendering/volumetric.odin`
- `src/rendering/depth_downsample.odin`
- `src/rendering/postfx/auto_exposure.odin`
- `src/scene/env_metadata_cache.odin`
- `src/scene/scene.odin`
- `src/gui/gui.odin`
- `src/cli.odin`
- `src/app/app.odin`

---

## 1. Contexte & Diagnostic de Performance

Une revue approfondie des performances a été conduite sur le profil de rendu à haute résolution (1920x1200) afin d'identifier les goulots d'étranglement limitant le débit d'images autour de 100 FPS sur GPU intégré (Intel Iris Xe / Mesa 25.0.7 Core 4.6).

### Diagnostic
1. **Raymarching volumétrique directionnel** : La boucle interne d'échantillonnage de l'ombre solaire (16 à 32 steps par fragment à demi-résolution) exécutait 4 appels scalaires `texture()` pour un filtrage PCF 2x2, totalisant plus de **33 millions d'échantillonnages par image**.
2. **Bande passante PostFX** : Des appels `gl.Clear(COLOR_BUFFER_BIT)` superflus étaient émis sur des framebuffers plein écran HDR (FXAA et composite) immédiatement écrasés à 100% par des quads opaques non blendés.
3. **Surcoût d'inspection UI ImGui** : Les passes de génération des textures de prévisualisation FBO (`depth_downsample_update_preview` et `volumetric_update_preview`) étaient recalculées à chaque image inconditionnellement lorsque l'onglet Volumétrique était affiché, ignorant le dirty flag existant.
4. **Télémétrie d'auto-exposition** : Des readbacks asynchrones PBO (`FenceSync` / `MapBuffer`) étaient exécutés à 10 Hz même lorsque les curseurs de diagnostic ImGui n'étaient pas affichés à l'écran.
5. **Lectures disques répétées au swap d'environnement** : Le fichier `env_metadata.json` était relu et désérialisé depuis le disque à chaque lookup de skybox HDR.

---

## 2. Optimisations Implémentées (P0)

```mermaid
flowchart TD
    subgraph GPU_Optimizations ["Optimisations GPU (Shaders & Bande Passante)"]
        A["textureGather Hardware 4-tap PCF\n(Divise par 4 les requêtes d'ombre)"]
        B["Élimination des gl.Clear superflus\n(FXAA FBO & Composite FBO)"]
        C["Gating Bloom sur intensité > 0.001\n(Évite 9 sous-passes inutiles)"]
    end

    subgraph CPU_State_Optimizations ["Optimisations CPU & Gestion d'État"]
        D["Gating preview_dirty sur Volumetric GUI\n(Supprime 2 passes de rendu par frame)"]
        E["Gating readback Auto-Exposure\n(Conditionné à l'ouverture de l'inspecteur)"]
        F["Cache in-memory O(1) env_metadata.json\n(Supprime l'I/O disque au swap HDR)"]
        G["Cohérence dirty flag sun_shadow sur gizmo\n(Mise à jour immédiate sur déplacement)"]
        H["Profil compute par défaut: Optimized\n(Accélère le bake IBL de 43%)"]
    end
```

### A. Opcode Hardware `textureGather` (PCF 4-tap Raymarch)
Dans `shaders/postfx/volumetric_raymarch_directional.frag`, les 4 lectures `texture()` sont remplacées par l'instruction matérielle OpenGL 4.0+ :
```glsl
float current_depth = shadow_coords.z - u_shadow_bias;
vec4 depths = textureGather(u_sun_shadow_map, shadow_coords.xy, 0);
vec4 cmp = step(vec4(current_depth), depths);
shadow_factor = dot(cmp, vec4(0.25));
```

### B. Suppression des `gl.Clear` Redondants
Dans `src/rendering/postfx/pipeline.odin`, les effacements couleur avant `quad_draw` plein écran ont été supprimés sur `fxaa_fbo` et `prev_fbo`, réduisant la pression mémoire sur la VRAM RGBA16F.

### C. Conditionnement Événementiel des Prévisualisations GUI
Dans `src/gui/gui_volumetric.odin`, `src/rendering/volumetric.odin` et `src/rendering/depth_downsample.odin`, les mises à jour des textures de débogage ne sont désormais déclenchées que si `preview_dirty` est vrai (mouvement de caméra, manipulation de slider ou translation de source lumineuse).

### D. Mise en Cache O(1) des Métadonnées Solaires HDR
Dans `src/scene/env_metadata_cache.odin`, une table de hachage `map[string]Env_Metadata_Entry` persistée en mémoire évite tout accès disque lors du parcours de la bibliothèque de skyboxes.

---

## 3. Résultats des Benchmarks & Gains Mesurés

Les mesures ci-dessous ont été enregistrées sur GPU physique Intel Iris Xe (Mesa 25.0.7, RPL-U) à une résolution de 1920x1200 en mode benchmark natif :

| Métrique / Profil | Référence (Avant) | Après P0 Quick Wins | Gain Obtenu |
|---|---|---|---|
| **Raymarching Volumétrique (Balanced)** | `0.743 ms` | **`0.584 ms`** | **-21.4% de temps GPU** |
| **Raymarching Volumétrique (Quality)** | `0.840 ms` | **`0.735 ms`** | **-12.5% de temps GPU** |
| **FPS Moyen (Balanced)** | `105.4 FPS` | **`110.9 FPS`** | **+5.5 FPS (+5.2%)** |
| **Frame Time Moyen (Balanced)** | `9.484 ms` | **`9.019 ms`** | **-0.465 ms / image** |
| **FPS Moyen (Quality)** | `104.3 FPS` | **`105.8 FPS`** | **+1.5 FPS** |
| **Temps de transition / Bake IBL** | `1846.93 ms` | **`1045.67 ms`** | **-43% de latence de swap** |

---

## 4. Vérification de Non-Régression

- **Tests unitaires et de persistance** : 120/120 tests passés avec 0 fuite mémoire (`task test-unit`).
- **Tests CLI & Shaders** : 14/14 tests CLI et 12/12 tests de compilation shader passés (`task test-cli`, `task test-shader`).
- **Smoke test UI & IBL** : Rendu, commutation de LODs et cycles de vie validés sans erreur (`task test-smoke-ui`).
- **Contrôle qualité de code** : `task lint` validé avec 0 warning (`odin check -vet -strict-style`).
