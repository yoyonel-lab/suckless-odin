# 🎛️ Manuel Complet : ImGuizmo 3D, Ombres PCF/TAA, Éclairage Volumétrique & Contrôles UI/UX

---

## 1. Vue d'Ensemble & Architecture

Ce document synthétise l'architecture, l'intégration bas-niveau et le guide utilisateur des fonctionnalités majeures implémentées dans **Suckless-Odin** :

```mermaid
graph TD
    subgraph UI_UX ["Interface & Interaction Viewport"]
        GZ["ImGuizmo 3D Transform Gizmo"] -->|Modifie Position / Orbite| PL["Point Light Aggregate"]
        GUI["Dear ImGui Hub + Fuzzy Search"] -->|100% Persistance Session| SS["Session State (JSON)"]
    end

    subgraph Shadow_Pipeline ["Pipeline d'Ombres Omnidirectionnelles"]
        PL -->|Synchronise 6 Faces| SC["Shadow Cubemap (Depth + Linear MRT)"]
        SC -->|Spatial Vogel-Disk (8-16 taps)| PCF["PCF Jittered Sampling (IGN)"]
        PCF -->|Screen-Space Reprojection| STAA["Shadow TAA Reprojection Pass"]
    end

    subgraph Volumetric_Pipeline ["Pipeline d'Éclairage Volumétrique (Phases 1-7)"]
        PL -->|Raymarching Analytique| RAY["Volumetric In-Scattering Buffer"]
        SC -.->|Test d'Ombre God Rays| RAY
        RAY -->|Alpha Dynamique (0.70 -> 0.15)| VTAA["Volumetric TAA History Blend"]
        VTAA -->|Joint Bilateral Filter (5/9-tap)| BLUR["Separable Bilateral Edge Blur"]
        BLUR -->|Upsampling Haute Résolution| JBU["Joint Bilateral Upsampling (JBU)"]
        JBU -->|Composition Scène 3D| COMP["Final Frame Output"]
    end
```

---

## 2. Intégration d'ImGuizmo (Gizmo 3D Viewport)

### 2.1. Abstraction C ABI & Compilation Multi-Plateforme

Pour garantir une compatibilité binaire stricte entre Odin et les bibliothèques statiques externes sans dépendance de mangling C++, une couche C ABI mince a été conçue :

* **Fichiers sources** : [`deps/imguizmo/cimguizmo.h`](../deps/imguizmo/cimguizmo.h) et [`deps/imguizmo/cimguizmo.cpp`](../deps/imguizmo/cimguizmo.cpp).
* **Bibliothèques compilées** :
  * Linux x86_64 : `deps/libimguizmo.a` (compilé via `g++ -O3 -fPIC`).
  * Windows x86_64 : `deps/libimguizmo_windows_x64.lib` (compilé via `x86_64-w64-mingw32-g++`).
* **Bindings Odin Foreign** : [`src/gui/imguizmo.odin`](../src/gui/imguizmo.odin) :
  * `guizmo_manipulate` : manipulation directe de matrice 4x4.
  * `guizmo_set_rect`, `guizmo_set_orthographic` : calibrage de la projection viewport.
  * `guizmo_is_over`, `guizmo_is_using` : interception de la souris pour empêcher la rotation de caméra pendant la manipulation 3D.

### 2.2. Manipulation & Débrayage Dynamique du Cache (Smooth Transition)

Lors du déplacement interactif de la source lumineuse avec la souris, un mécanisme d'amortissement prévient tout clignotement :

| État | Comportement Shadow Caching | Time-Slicing Cubemap | Alpha TAA Volumétrique |
| :--- | :--- | :--- | :--- |
| **Repos (Statique)** | Caching actif (0 rendu si lumière fixe) | Selon réglage utilisateur (1 à 6 faces/frame) | $\alpha = \text{configuré}$ ($0.15$ par défaut) |
| **Manipulation Gizmo** | Bypass total (rendu forcé à chaque frame) | Désactivé (6 faces complètes synchronisées) | $\alpha = 0.70$ (réactivité immédiate, 0 ghosting) |
| **Transition d'Arrêt (Cooldown $400\text{ ms}$)** | Maintien du rendu 6 faces | Maintien du rendu 6 faces | Décroissance `smoothstep` : $0.70 \to 0.15$ |

---

## 3. Pipeline d'Ombres Omnidirectionnelles & Anti-Aliasing

### 3.1. Échantillonnage Vogel-Disk PCF & Jitter Temporel

* **PCF Vogel-Disk** : Répartition stochastique à divergence d'or (Golden Ratio Spiral) en $8$ ou $16$ taps.
* **Spatial Ray Jitter (IGN)** : Rotation pseudo-aléatoire du disque d'échantillonnage basée sur le *Interleaved Gradient Noise* de Jorge Jimenez.
* **Temporal Jitter** : Séquence de rotation inter-frame basée sur le nombre d'or $R_\phi = 0.6180339887$, transformant le bruit statique en résidu haute fréquence éliminé par le TAA.

### 3.2. Vues de Debug des Ombres (`shadow_debug_mode`)

L'onglet **Shadows** propose 7 modes de visualisation analytique :

1. **`0: Off (Normal Shading)`** : Rendu éclairé standard PBR + ombres douces.
2. **`1: Shadow Mask (Green/Red)`** : Vert = surface directement éclairée, Rouge = surface à l'ombre.
3. **`2: Penumbra / Softness Heatmap`** : Gradient thermique visualisant la largeur de pénombre calculée.
4. **`3: PCF vs Hard Delta Heatmap (|PCF - Hard|)`** : Écart absolu entre le masque dur 1-tap et le filtrage doux multi-taps amplifié 10x.
5. **`4: Split-Screen Comparison`** : Comparateur A/B temps réel avec slider de séparation (Gauche = Hard 1-tap, Droite = PCF Actif).
6. **`5: Temporal Jitter Phase Heatmap`** : Visualisation chromatique de la phase d'échantillonnage temporel.
7. **`6: Only Shadow Factor (Grayscale)`** : Isolation du facteur d'atténuation d'ombre pur (Blanc = 100% éclairé, Noir = 100% occlus).

---

## 4. Pipeline d'Éclairage Volumétrique & Atmosphère (Phases 1 à 7)

### 4.1. Résumé des Phases de Traitement

| Phase | Description & Algorithme | Résolution / Format |
| :--- | :--- | :--- |
| **Phase 2 : Depth Downsample** | Filtre Rank/Median 4-tap conservateur de silhouettes géométriques + masque de discontinuité. | $\frac{W}{2} \times \frac{H}{2}$, `GL_R32F` + `GL_R8` |
| **Phase 3 : Raymarching** | Intégration de diffusion le long du rayon caméra avec fonction de phase Henyey-Greenstein $P(\theta, g)$. | $\frac{W}{d} \times \frac{H}{d}$ ($d \in \{1, 2, 4\}$), `GL_RGBA16F` |
| **Phase 4 : Volumetric TAA** | Reprojection temporelle avec estimation de vélocité caméra, détection de disocclusion géométrique et clamping de voisinage 3x3. | $\frac{W}{d} \times \frac{H}{d}$, Double FBO Ping-Pong |
| **Phase 5 : Joint Bilateral Blur** | Flou bilatéral séparable 5-tap (Fast) ou 9-tap (Smooth ISO) guidé par la profondeur pour préserver les bords des sphères. | $\frac{W}{d} \times \frac{H}{d}$, `GL_RGBA16F` |
| **Phase 6 : Upsampling & Composite** | *Joint Bilateral Upsampling* (JBU) vers la pleine résolution plein écran avec modes de debug direct. | Fullscreen $W \times H$ |
| **Phase 7 : Presets Atmosphériques** | Banques de réglages physiques d'atmosphère et de milieu diffusant (g, $\sigma_s$, $\sigma_e$, intensité, steps). | Profils configurables |

### 4.2. Banques de Presets Atmosphériques & Raccourcis d'Anisotropie

* **Raccourcis d'Anisotropie Henyey-Greenstein ($g$)** (Phase 3) :
  * `Isotropic` ($g = 0.00$)
  * `Dust / Sand` ($g = 0.35$)
  * `Morning Fog` ($g = 0.55$)
  * `God Rays` ($g = 0.70$)
  * `Alan Wake Torch` ($g = 0.80$)
  * `Car Headlights` ($g = 0.88$)
  * `Backscatter` ($g = -0.35$)
* **Atmospheric & Cinematic Presets** (Phase 7) :
  * Applique simultanément le coefficient de diffusion $\sigma_s$, le coefficient d'extinction $\sigma_e$, le nombre de pas $N$, l'anisotropie $g$ et le multiplicateur d'intensité lumineuse.

---

## 5. Guide des Contrôles ImGui & Recherche Fuzzy

### 5.1. Onglet Shadows (Ombres & Source Lumineuse)

| Contrôle ImGui | Type | Plage / Valeurs | Description & Effet |
| :--- | :--- | :--- | :--- |
| **`Light Enabled`** | Checkbox | Bool | Active ou désactive la source ponctuelle. |
| **`Orbit Animation`** | Checkbox | Bool | Active la trajectoire circulaire automatique de la lumière. |
| **`Orbit Speed`** | SliderFloat | $0.0 \to 2.0\text{ rad/s}$ | Vitesse angulaire de rotation. |
| **`Orbit Radius`** | SliderFloat | $0.0 \to 20.0\text{ m}$ | Rayon de la trajectoire d'orbite. |
| **`Position` / `Orbit Center`** | DragFloat3 | $X, Y, Z$ | Coordonnées spatiales de la source ou du centre de rotation. |
| **`Radius / Influence`** | SliderFloat | $1.0 \to 50.0\text{ m}$ | Rayon d'atténuation physique maximale de la lumière. |
| **`Light Color`** | ColorEdit3 | RGB $[0..1]$ | Teinte spectrale émise par la source. |
| **`Intensity`** | SliderFloat | $0.0 \to 10.0$ | Puissance d'émission lumineuse. |
| **`Enable 3D Light Gizmo`** | Checkbox | Bool | Affiche le gizmo interactif ImGuizmo directement dans le viewport. |
| **`Gizmo Operation`** | Combo | Translate, Rotate, Scale, Universal | Type de manipulation 3D active sur le gizmo. |
| **`Gizmo Coordinate Space`**| Combo | World, Local | Système d'axes de transformation. |
| **`Grid Snapping`** | Checkbox + Slider | $0.05 \to 5.0\text{ m}$ | Alignement sur une grille discrète lors du déplacement. |
| **`Show Light Bulb Gizmo`** | Checkbox + Slider | $0.05 \to 2.0\text{ m}$ | Rendu d'une sphère brillante matérialisant l'ampoule. |
| **`Direct Surface Shadows`** | Checkbox | Bool | Active la passe de calcul des ombres sur la géométrie de scène. |
| **`Shadow Base Bias`** | SliderFloat | $0.0001 \to 0.0200$ | Décalage constant de profondeur pour éliminer l'acné d'ombre. |
| **`Normal Offset Bias`** | SliderFloat | $0.000 \to 0.100\text{ m}$ | Décalage le long du vecteur normal géométrique. |
| **`Slope-Scaled Bias`** | SliderFloat | $0.0000 \to 0.0100$ | Décalage proportionnel à la pente incidente du rayon. |
| **`PCF Filtering Samples`** | Combo | Hard 1-tap, Vogel 8-tap, Vogel 16-tap | Qualité de l'échantillonnage de pénombre. |
| **`Filter Radius`** | SliderFloat | $0.001 \to 0.050\text{ rad}$ | Largeur angulaire du cône de pénombre. |
| **`Shadow TAA Reprojection`**| Checkbox | Bool | Lissage temporel anti-scintillement des ombres. |
| **`Cube Shadow Map Res`** | Combo | 64, 128, 256, 512 | Résolution par face du framebuffer cubemap. |
| **`Shadow Map Dirty Caching`**| Checkbox | Bool | Cache évitant le recalcul des ombres quand la lumière est immobile. |
| **`Shadow Time-Slicing`** | Combo | 6 faces, 3 faces, 2 faces, 1 face | Répartition du coût de rendu des faces sur plusieurs frames. |

---

## 6. Persistance des Paramètres (100% JSON)

Tous les paramètres ci-dessus sont strictement sérialisés et restaurés à l'identique entre les sessions de l'application via `session.json` :

* **Structure de données** : [`Point_Light_State`](../src/core/session/session.odin) et [`Volumetric_State`](../src/core/session/session.odin).
* **Extraction & Restauration** : [`src/app/session.odin`](../src/app/session.odin).
* **Validation continue** : `python3 scripts/check_persistence.py` & `tests/test_session.odin`.
