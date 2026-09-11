# Plan de Remédiation & Feuille de Route : Retours d'Audit GLM 5.3-Flash

**Date** : 10 Septembre 2026  
**Auteur** : Antigravity (Assistant Pair-Programming)  
**Contexte** : Analyse critique et plan d'exécution suite à l'audit partiel réalisé par GLM 5.3-Flash sur la codebase `suckless-odin`.  
**Statut** : 📋 Spécification & Plan de Suivi de Projet  

---

## 🎯 1. Contexte & Matrice d'Évaluation Critique

Un audit exploratoire a été réalisé par le modèle GLM 5.3-Flash sur un échantillon de fichiers du moteur (shaders PBR, cubemap d'ombres, rendu volumétrique, pipeline IBL). L'inspection exhaustive de la codebase confirme que la grande majorité des observations relève de bugs silencieux ou d'incohérences architecturales bien réelles, avec une réserve majeure sur l'interprétation de la spécification OpenGL pour le point 6.

### Matrice Synthétique de Validation

| Réf | Catégorie | Description Sommaire | Fichiers Concernés | Verdict | Sévérité Réelle |
| :--- | :--- | :--- | :--- | :---: | :---: |
| **P1.1** | PBR / AA | Specular AA coupé au lieu d'être cappé aux silhouettes | `shaders/pbr_billboard.frag:159-164` | **VRAI** | 🔴 Élevée (Visuel) |
| **P1.2** | Shadows | Incohérence d'unités de profondeur / bias (mètres vs adimensionnel) | `shaders/pbr_billboard.frag:362-368`, `shaders/postfx/volumetric_raymarch.frag:152` | **VRAI** | 🟠 Moyenne |
| **P1.3** | Shadows | Rayon de filtre PCF métrique au lieu d'angulaire (rétrécit avec la distance) | `shaders/pbr_billboard.frag:248-256`, `src/scene/scene.odin` | **VRAI** | 🔴 Élevée (Visuel) |
| **P1.4** | Volumetric | `u_extinction_coeff` mort + Transmittance fixe à 1.0 (Beer-Lambert inactif) | `shaders/postfx/volumetric_raymarch.frag:31,163` | **VRAI** | 🟡 Faible / Choix design |
| **P1.5** | Timing | Position orbitale calculée à 60 Hz fixe vs temps réel cubemap | `src/rendering/volumetric.odin:621`, `src/scene/scene.odin:405` | **VRAI** | 🔴 Élevée (Désalignement) |
| **P1.6** | Conservative Z | Invalidation supposée de `layout(depth_greater)` selon l'ordre de tri | `shaders/shadow_cube.frag:3`, `shaders/shadow_cube.vert` | **FAUX** | ⚪ Non-bug (Théorie erronée) |
| **P1.7** | IBL | Roughness max 1.0 lit le mip 4 au lieu du mip 10 (sous-filtrage IBL) | `shaders/pbr_billboard.frag:117-119`, `src/scene/env_manager.odin:993` | **VRAI** | 🔴 Élevée (PBR IBL faux) |
| **P2.1** | Shaders | Shaders volumétriques en `#version 440` vs `#version 450` | `shaders/postfx/volumetric_*.frag` | **VRAI** | 🟡 Nettoyage / Nit |
| **P2.2** | IBL | Helper `dispatch_compute` mort et division par 32 incorrecte | `src/rendering/ibl.odin:150` | **VRAI** | 🟡 Dead code |
| **P2.3** | Shaders | Duplication `getProjectedBounds` / `computeBillboardSphere` (~100 l.) | `shaders/pbr_billboard.vert`, `shaders/shadow_cube.vert` | **VRAI** | 🟡 Refactoring |
| **P2.4** | IBL | Débind manquant sur l'image unit 0 après dispatch BRDF LUT | `src/rendering/ibl.odin:98` | **VRAI** | 🟡 Hygiène GL |
| **P2.5** | IBL | LUT BRDF potentiellement non initialisée (garbage) frames 0..15 | `src/rendering/ibl.odin:56` | **VRAI** | 🟡 Robustesse |
| **P2.6** | Git | Binaires statiques `deps/*.a` trackés dans l'historique Git | `deps/libsimd.a`, `deps/libtracy.a` | **VRAI** | 🟡 Hygiène dépôt |

---

## 🔍 2. Analyse Technique Détaillée des Éléments

### 2.1 P1.1 — Specular AA désactivé sur les silhouettes
- **Code incriminé** :
  ```glsl
  // shaders/pbr_billboard.frag:159-164
  if (variance >= 0.0 && variance <= 0.1) {
      // Keep valid variance
  } else {
      variance = 0.0;
  }
  ```
- **Diagnostic** : Aux silhouettes géométriques des sphères ou le long des fortes variations de normale, la dérivée spatiale $dFdx(N)$ explose naturellement ($> 0.1$). Au lieu de saturer l'élargissement de rugosité à sa valeur plafond autorisée, le bloc met la variance à `0.0`. L'anti-aliasing spéculaire est brutalement éteint sur les pixels mêmes où le crénelage est maximal.
- **Correction** : Remplacer par un clamp explicite et un guard anti-NaN :
  ```glsl
  if (isnan(variance) || isinf(variance) || variance < 0.0) {
      variance = 0.0;
  } else {
      variance = min(variance, 0.1);
  }
  ```

---

### 2.2 P1.2 — Incohérence des unités de profondeur pour les ombres
- **Code incriminé** :
  - `pbr_billboard.frag:367-368` :
    ```glsl
    float normalizedDist = distToLight / max(0.001, u_point_light_radius);
    float shadowHard = (normalizedDist - dynamicBias <= sampledDepthHard) ? 1.0 : 0.0;
    ```
  - `volumetric_raymarch.frag:152` :
    ```glsl
    if (dist_light - u_shadow_bias > shadow_depth_norm * u_light_radius)
    ```
- **Diagnostic** : Le cubemap d'ombres stocke la distance radiale normalisée $t / R \in [0, 1]$. Dans le shader PBR de surface, `dynamicBias` est soustrait directement de `normalizedDist` (donc un biais relatif au rayon lumineux). Dans le raymarch volumétrique, `u_shadow_bias` est soustrait de `dist_light` (distance absolue en mètres). Si le rayon lumineux est ajusté dynamiquement par l'utilisateur (ex: de 5 m à 30 m), le biais de surface varie proportionnellement alors que le biais volumétrique reste fixe.
- **Correction** : Uniformiser la comparaison en distance métrique absolue pour éviter tout comportement dépendant du rayon de la lampe :
  ```glsl
  float sampledDistHard = sampledDepthHard * u_point_light_radius;
  float shadowHard = (distToLight - dynamicBias <= sampledDistHard) ? 1.0 : 0.0;
  ```

---

### 2.3 P1.3 — Rayon de filtre PCF (Métrique vs Angulaire)
- **Code incriminé** :
  ```glsl
  // shaders/pbr_billboard.frag:248-256
  float r = sqrt((float(i) + 0.5) / float(numSamples)) * u_point_shadow_filter_radius;
  ...
  vec3 sampleDir = lightToBiasedPos + tangent * x + bitangent * y;
  ```
- **Diagnostic** : La variable CPU et les annotations ImGui stipulent un rayon en radians (`0.015 rad`). Le vecteur `lightToBiasedPos` possède une norme $\|\vec{D}\|$ égale à la distance du point à la lumière (ex: 10 mètres). L'offset vectoriel $x, y$ injecté a une norme maximale de $0.015$ mètres. L'angle de déviation vaut donc $\arctan(0.015 / \|\vec{D}\|) \approx 0.0015\text{ rad}$ à 10 m. Le filtre PCF rétrécit avec l'éloignement et produit visuellement une ombre dure.
- **Correction** : Appliquer l'ouverture angulaire sur le vecteur directeur unitaire $\vec{d}_{\text{norm}}$ ou projeter proportionnellement à la distance :
  ```glsl
  vec3 dir = normalize(lightToBiasedPos);
  vec3 sampleDir = dir + (tangent * x + bitangent * y); // Déviation angulaire constante
  ```

---

### 2.4 P1.4 — Paramètre `u_extinction_coeff` mort & Beer-Lambert
- **Code incriminé** : `shaders/postfx/volumetric_raymarch.frag:31` et `FragColor = vec4(scattered_amount * light_color_intensity, 1.0);`.
- **Diagnostic** : `u_extinction_coeff` est déclaré, configuré dans l'UI et uploadé, mais inutilisé dans le raymarching. Le canal alpha reste fixé à 1.0. La passe composite (`src/rendering/volumetric.odin:914`) effectue un blend `gl.BlendFunc(gl.ONE, gl.ONE)` purement additif sans atténuation d'extinction de l'arrière-plan.
- **Correction** :
  1. Si in-scattering additif pur (modèle artistique léger actuel) : supprimer l'uniforme mort et nettoyer la signature shader.
  2. Si extinction Beer-Lambert physique : calculer la transmittance caméra cumulative dans la boucle de marche et l'exploiter dans le composite plein écran (`scene * T + in_scattering`).

---

### 2.5 P1.5 — Dérive temporelle de la lumière en orbite
- **Code incriminé** :
  - `src/rendering/shadow_cubemap.odin:375` : `light_pos := point_light_get_position(light, total_time)` (temps réel).
  - `src/rendering/volumetric.odin:621` : `light_pos := point_light_get_position(light, f32(frame_idx) * 0.016)` (60 Hz fixe).
  - `src/scene/scene.odin:405` : `light_pos := rendering.point_light_get_position(&s.point_light, f32(s.frame_count) * 0.016)` (60 Hz fixe).
- **Diagnostic** : Sur un écran 120/144 Hz, ou en cas de baisse de framerate sous 60 FPS, `f32(frame_idx) * 0.016` accumule une position orbitale désynchronisée de `total_time`. Le cubemap d'ombres projette les ombres depuis une position de lumière différente de celle utilisée par le shader PBR et le volume de lumière.
- **Correction** : Propager le paramètre d'horloge globale `total_time: f32` à `scene_render`, `volumetric_render` et aux fonctions de préparation de frame associées.

---

### 2.6 P1.6 — Réfutation critique : `layout(depth_greater)` et ordre de tri
- **Thèse GLM** : *"layout(depth_greater) (shadow_cube.frag:3) — valide seulement si les instances sont rendues front-to-back ; sinon la garantie est violée"*.
- **Réfutation Technique** :
  - `layout(depth_greater)` (`ARB_conservative_depth`) est une promesse purement **intra-primitive / intra-fragment**. Elle garantit au pipeline matériel que pour chaque fragment individuel généré par la rasterization, `gl_FragDepth >= gl_FragCoord.z`.
  - Dans `shaders/shadow_cube.vert:104-110`, le quad billboard est expressément positionné à `nearestZ = viewPos.z + sphereRadius`, c'est-à-dire le plan tangent antérieur (le point géométrique le plus proche de la caméra pour cette sphère).
  - Tout point d'intersection rayon-sphère calculé par le fragment shader (`hitPos`) est situé sur la calotte sphérique, donc à une distance vue supérieure ou égale à `nearestZ`. En convention de profondeur standard OpenGL (`0.0` near, `1.0` far), `gl_FragDepth >= gl_FragCoord.z` est mathématiquement garanti pour 100% des fragments générés.
  - L'ordre de rendu global des instances (front-to-back, back-to-front ou aléatoire) conditionne l'**efficacité** du rejet Early-Z (taux de rejet plus élevé en front-to-back), mais **ne viole en aucun cas la spécification de conservative depth**. Aucun artefact ni rejet erroné ne peut survenir sur Mesa ou drivers propriétaires du fait de l'ordre d'instance.
- **Décision** : Maintenir `layout(depth_greater)` inchangé.

---

### 2.7 P1.7 — Discordance Roughness / Mip LOD IBL
- **Code incriminé** :
  - `src/rendering/ibl.odin:35` : `PREFILTER_MIP_LEVELS :: 11` (mips $0$ à $10$).
  - `src/scene/env_manager.odin:993` : `roughness := f32(mip) / f32(mgr.ibl_total_mips - 1)`. Le mip 10 correspond à $\text{roughness} = 1.0$, le mip 4 correspond à $\text{roughness} = 0.4$.
  - `shaders/pbr_billboard.frag:117-119` :
    ```glsl
    const float MAX_REFLECTION_LOD = 4.0;
    vec3 prefilteredColor = textureLod(prefilterMap, dirToUV(R), roughness * MAX_REFLECTION_LOD).rgb;
    ```
- **Diagnostic** : Héritage d'un exemple tutoriel basé sur 5 mips ($128 \times 128$). Le moteur alloue et préfiltre 11 niveaux ($1024 \times 1024$). Lors du rendu d'un matériau mat ($\text{roughness} = 1.0$), le shader lit le niveau `4.0`, qui a été préfiltré avec $\text{roughness} = 0.40$. Les mips 5 à 10 sont totalement ignorés, causant une réflexion spéculaire résiduelle excessivement nette et bruitée sur les surfaces rugueuses.
- **Correction** : Fixer `MAX_REFLECTION_LOD` à `10.0` (ou injecter dynamiquement `float(PREFILTER_MIP_LEVELS - 1)`).

---

## 🗺️ 3. Plan d'Exécution par Phases

```mermaid
flowchart LR
    subgraph Phase 1: PBR & IBL Fixes
        A1["P1.1 Specular AA Clamp"]
        A2["P1.7 MAX_REFLECTION_LOD = 10.0"]
        A3["P2.4/P2.5 IBL Unbind & ClearTex"]
    end

    subgraph Phase 2: Shadows & Timing
        B1["P1.2 Shadow Bias en Mètres"]
        B2["P1.3 PCF Rayon Angulaire Const"]
        B3["P1.5 Synchronisation total_time"]
    end

    subgraph Phase 3: Volumetric Cleanup
        C1["P1.4 Assainissement Extinction / Transmittance"]
        C2["P2.1 Harmonisation #version 450"]
    end

    subgraph Phase 4: Refactoring & Git
        D1["P2.2 Retrait Dead Code dispatch_compute"]
        D2["P2.3 Partage sphere_projection.glsl"]
        D3["P2.6 Nettoyage Binaires Git"]
    end

    Phase 1 --> Phase 2 --> Phase 3 --> Phase 4
```

---

### Phase 1 : Correctifs Immédiats PBR & IBL Direct/Indirect (P1.1, P1.7, P2.4, P2.5)
- [ ] **Tâche 1.1** : Dans `shaders/pbr_billboard.frag`, remplacer la condition de variance par un clamp protégé contre les NaN.
- [ ] **Tâche 1.2** : Dans `shaders/pbr_billboard.frag`, passer `MAX_REFLECTION_LOD` de `4.0` à `10.0`.
- [ ] **Tâche 1.3** : Dans `src/rendering/ibl.odin`, ajouter `gl.BindImageTexture(0, 0, 0, false, 0, gl.WRITE_ONLY, gl.RG16F)` à la fin de `ibl_update_brdf_lut`.
- [ ] **Tâche 1.4** : Dans `src/rendering/ibl.odin`, ajouter une initialisation neutre de la texture LUT BRDF (`ClearTexImage` avec scale=1.0, bias=0.0) lors de la création pour éviter les lectures indéfinies durant les frames de précalcul.

### Phase 2 : Précision du Shadow Mapping & Synchronisation Temporelle (P1.2, P1.3, P1.5)
- [ ] **Tâche 2.1** : Dans `shaders/pbr_billboard.frag`, modifier le test de comparaison d'ombre pour opérer en distances métriques absolues (`distToLight - dynamicBias <= sampledDepth * u_point_light_radius`).
- [ ] **Tâche 2.2** : Dans `shaders/pbr_billboard.frag`, corriger le décalage PCF Vogel-Disk pour qu'il agisse sur la direction unitaire normalisée (`dir + offset`), garantissant un rayon angulaire constant quelle que soit la distance du récepteur.
- [ ] **Tâche 2.3** : Dans `src/scene/scene.odin` et `src/rendering/volumetric.odin`, remplacer le calcul `f32(frame_count) * 0.016` par l'utilisation de `total_time` transmis depuis la boucle principale de l'application.

### Phase 3 : Assainissement du Rendu Volumétrique & Harmonisation GLSL (P1.4, P2.1)
- [ ] **Tâche 3.1** : Harmoniser les en-têtes des shaders post-process volumétriques (`shaders/postfx/volumetric_raymarch.frag`, `volumetric_composite_simple.frag`, `volumetric_bilateral_blur.frag`, etc.) vers `#version 450 core`.
- [ ] **Tâche 3.2** : Clarifier le modèle d'extinction volumétrique : supprimer l'uniforme mort `u_extinction_coeff` si l'approche reste l'in-scattering additif pur sans transmittance, ou documenter et câbler le coefficient dans l'équation d'atténuation.

### Phase 4 : Déduplication Shader & Hygiène de Code / Git (P2.2, P2.3, P2.6)
- [ ] **Tâche 4.1** : Dans `src/rendering/ibl.odin`, supprimer la procédure privée morte `dispatch_compute`.
- [ ] **Tâche 4.2** : Créer un module shader partagé `shaders/common/sphere_projection.glsl` contenant `getProjectedBounds` et `computeBillboardSphere`. L'inclure dans `shaders/pbr_billboard.vert` et `shaders/shadow_cube.vert` via le mécanisme existant `inject_defines`.
- [ ] **Tâche 4.3** : Procéder à l'assainissement Git pour retirer les bibliothèques statiques compilées (`deps/libsimd.a`, `deps/libtracy.a`) du versioning actif tout en préservant leur cible de build `task build-tracy-lib`.

---

## 🧪 4. Protocole de Validation & Zéro Régression

Conformément aux règles de sécurité (`AGENTS.md`), toute modification sera validée au travers des tâches outillées du projet sans action proactive de versioning :

1. **Compilation & Typage Strict** :
   ```bash
   task lint
   # odin check src/ -vet -strict-style -warnings-as-errors
   # python3 scripts/verify_docs_links.py
   ```
2. **Tests Unitaires & Tests Shaders** :
   ```bash
   task test-unit
   task test-shader
   ```
3. **Tests OpenGL E2E (100% GPU Accéléré & Headless CI)** :
   ```bash
   # Exécution 100% GPU accéléré direct sur le GPU physique hôte (fenêtre GLFW offscreen invisible) :
   task test-gl

   # Exécution headless sous Xvfb (isolation CI / conteneur sans GPU matériel) :
   task test-gl-xvfb
   ```
4. **Validation Visuelle ImGui** :
   - Vérification de la vue comparative PCF split-screen (`u_point_shadow_debug_mode == 4`).
   - Contrôle du lissage spéculaire IBL sur matériau rugueux (sphère roughness 1.0).
   - Contrôle de la fluidité et de l'alignement des ombres en rotation orbitale à framerate variable.
