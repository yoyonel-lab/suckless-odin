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

### 2.3. Sélection d'Entités 3D par Raycasting & Cibles Multiples (Light & Sphères)

Auparavant restreint à l'activation manuelle via une case à cocher ImGui pour l'ampoule, ImGuizmo s'active désormais par **sélection directe au clic dans le viewport 3D** :

```mermaid
graph TD
    Click["Clic Souris Viewport (Screen X, Y)"] --> Ray["Unprojection Caméra (World Ray)"]
    Ray --> TestLight{"Intersection Ampoule ?"}
    TestLight -->|Oui (t min)| SelLight["Sélection Light (Gizmo sur position/orbite)"]
    TestLight -->|Non| TestSpheres{"Intersection Sphère PBR ?"}
    TestSpheres -->|Oui (t min)| SelSphere["Sélection Sphère (Gizmo sur instance)"]
    TestSpheres -->|Non| Desel["Désélection Tout (Skybox / Décor)"]
```

#### Fonctionnalités Clés :
1. **Raycasting CPU Analytique Zero-Stall** :
   * Rétro-projection écran $\to$ monde via `ray_from_screen`.
   * Test d'intersection analytique sphère `ray_intersect_sphere` sur l'ampoule (rayon $0.4\text{ m}$) et les 100 sphères PBR (rayon $1.0\text{ m}$).
   * Résolution du plus proche objet touché ($t_{\min}$).
2. **Désélection Contextuelle** :
   * Clic dans le vide (skybox / environnement) désélectionne immédiatement l'entité active et masque le gizmo.
3. **Stabilité au Tri Dynamique (Résolution par ID Stable)** :
   * Les sphères étant triées back-to-front à chaque frame pour la transparence (`instanced_sort_cpu`), chaque instance possède un identifiant permanent `id: i32` ($0..99$).
   * L'inspecteur et ImGuizmo résolvent dynamiquement l'index courant via `instanced_find_index_by_id`, empêchant tout saut d'indice ou télescopage d'instances lors des déplacements.
4. **Contrainte Géométrique Billboard Raymarché** :
   * L'orientation des sphères procédurales étant asservie à la caméra (normales analytiques dans le fragment shader), la matrice `model` est assainie pour n'appliquer que la translation et une échelle uniforme, éliminant les rotations parasites destructrices d'ellipses.
5. **Réinitialisation de la Grille 10x10** :
   * Bouton **"Reset Grid"** dans l'inspecteur Shadows/Scene pour rétablir instantanément toutes les sphères à leur disposition d'origine via `instanced_reset_grid`.

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

### 5.2. Onglet Volumetric (Lumière Volumétrique & Effets Cinématiques)

| Contrôle ImGui | Type | Plage / Valeurs | Bouton Reset | Description & Effet |
| :--- | :--- | :--- | :---: | :--- |
| **`Volumetric Lighting`** | Checkbox | Bool | — | Active ou désactive le calcul global volumétrique. |
| **`Composite In Scene`** | Checkbox | Bool | — | Additionne le flux lumineux dans le tampon HDR de la scène. |
| **`Isolate in Scene`** | Checkbox | Bool | — | Isole le milieu volumétrique en coupant l'IBL et le ciel. |
| **`Light Source Mode`** | RadioButtons | Omni Point / Sun Directional | — | Sélectionne la source lumineuse pour le raymarching. |
| **`Buffer Resolution`** | RadioButtons | 1/1, 1/2, 1/4 | — | Diviseur de résolution du tampon volumétrique. |
| **`Raymarch Steps (N)`** | SliderInt | $4 \to 64$ pas | — | Nombre d'échantillons le long du rayon. |
| **`Scattering Coeff`** | SliderFloat | $0.01 \to 1.00$ | — | Coefficient de diffusion volumétrique $\sigma_s$. |
| **`Anisotropy (g)`** | SliderFloat | $-0.90 \to 0.90$ | — | Facteur d'asymétrie Henyey-Greenstein avant/arrière. |
| **`Intensity Multiplier`** | SliderFloat | $0.00 \to 10.00$ | `Reset` | Multiplicateur d'énergie globale in-scattering. |
| **`Dual-Lobed HG`** (Phase 1) | Checkbox | Bool | — | Active le mélange double lobe (halo avant + rétrodiffusion). |
| **`Backward Anisotropy (g2)`** | SliderFloat | $-0.99 \to 0.00$ | `Reset` | Anisotropie rétrograde secondaire (défaut $-0.30$). |
| **`Forward Lobe Blend`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Pondération entre les lobes avant et arrière (défaut $0.70$). |
| **`Multi-Scattering Compensation`** (Phase 3) | Checkbox | Bool | — | Compensation d'énergie par albédo isotrope résiduel diffusant. |
| **`Isotropic Multi-Scatter Blend`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Facteur de mélange isotrope pour éliminer l'obscurcissement à $90^\circ$ (défaut $0.25$). |
| **`Crepuscular Boost`** (Phase 1) | Checkbox | Bool | — | Sur-amplification optique face au soleil (contre-jour). |
| **`Boost Strength`** | SliderFloat | $0.00 \to 5.00\times$ | `Reset` | Facteur multiplicateur d'éblouissement (défaut $2.00\times$). |
| **`Cos Threshold`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Seuil d'alignement $\cos\theta$ observateur-soleil (défaut $0.70$). |
| **`Auto Horizon Fade`** (Phase 3) | Checkbox | Bool | — | Atténuation automatique du contre-jour au zénith solaire. |
| **`Horizon Fade Start Angle`** | SliderFloat | $0.0^\circ \to 90.0^\circ$ | `Reset` | Élévation minimale préservant 100% du boost (défaut $45.0^\circ$). |
| **`Horizon Fade End Angle`** | SliderFloat | $0.0^\circ \to 90.0^\circ$ | `Reset` | Élévation maximale où le boost est totalement éteint (défaut $85.0^\circ$). |
| **`Spectral Scattering`** (Phase 1) | Checkbox | Bool | — | Diffusion chromatique RGB Rayleigh/Mie. |
| **`Auto Airmass Spectrum`** (Phase 3) | Checkbox | Bool | — | Spectre RGB automatique dérivé de l'élévation solaire (Kasten-Young). |
| **`Airmass Shift Intensity`** | SliderFloat | $0.00 \to 2.00$ | `Reset` | Intensité du glissement chromatique azur zénithal vers ambre crépusculaire (défaut $1.00$). |
| **`RGB Scattering Weights`** | SliderFloat3 | $0.10 \to 3.00$ | `Reset` | Poids spectraux manuels par canal RGB (défaut $1.20, 1.00, 0.85$, actif si Auto Airmass désactivé). |
| **`Blue Noise Jitter`** (Phase 2) | Checkbox | Bool | — | Jitter Void-and-Cluster 64x64 éliminant le banding IGN. |
| **`Dust Particles`** (Phase 2) | Checkbox | Bool | — | Modulation 3D FBM pour particules de poussière en suspension. |
| **`Dust Intensity`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Contraste des volutes de poussière (défaut $0.50$). |
| **`Dust Scale`** | SliderFloat | $0.01 \to 2.00$ | `Reset` | Fréquence spatiale des panaches (défaut $0.25$). |
| **`Dust Drift Speed`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Vitesse de convection temporelle (défaut $0.15$). |
| **`Convection Drift Mode`** (Phase 3) | Combo | Modes 0, 1, 2 | `Reset` | Mode de dérive de poussière (0: Ambient, 1: Solar Updraft, 2: Custom Wind). |
| **`Wind Drift Vector`** | SliderFloat3 | $-1.00 \to 1.00$ | `Reset` | Vecteur 3D de direction de vent personnalisé (mode 2, défaut $0.08, 0.04, 0.06$). |
| **`Height Fog`** (Phase 2) | Checkbox | Bool | — | Gradient exponentiel de sol (couche limite planétaire). |
| **`Ground Altitude (y0)`** | SliderFloat | $-10.0 \to 10.0\text{ m}$ | `Reset` | Altitude de base du niveau du sol (défaut $0.0\,\text{m}$). |
| **`Altitude Falloff (k)`** | SliderFloat | $0.01 \to 2.00$ | `Reset` | Taux d'atténuation verticale (défaut $0.20$). |
| **`Worley Cellular Dust`** (Phase 3) | Checkbox | Bool | — | Particules discrètes étincelantes par bruit cellulaire 3D Voronoi/Worley. |
| **`Worley Particle Blend`** | SliderFloat | $0.00 \to 1.00$ | `Reset` | Ratio de mélange fumée Perlin (0.0) vers particules Worley (1.0). |
| **`Dust Depth Window Mask`** (Phase 3) | Checkbox | Bool | — | Masque polynomial en cloche pour focaliser les particules à distance intermédiaire. |
| **`Depth Focus Near`** | SliderFloat | $0.10 \to 10.00\text{ m}$ | `Reset` | Limite proche de visibilité des grains (évite le clipping caméra). |
| **`Depth Focus Far`** | SliderFloat | $5.0 \to 100.0\text{ m}$ | `Reset` | Limite lointaine d'atténuation (évite le shimmering en profondeur). |
| **`TAA Reprojection`** | Combo + Slider | Modes 0, 1, 2 | — | Accumulation temporelle anti-bruit avec clamping 3x3. |
| **`Bilateral Blur`** | Combo + Slider | Modes 0, 1, 2 | — | Flou bilatéral guidé par la géométrie (lissage des pas). |

---

## 6. Guide Pratique des Effets Volumétriques Cinématiques (Physique, Réglages & Phénoménologie Visuelle)

Ce guide détaille pour chaque effet avancé son fondement physique, ses réglages recommandés et sa signature visuelle à l'écran.

### 6.1. Dynamic Airmass Spectrum (Kasten-Young)
* **Physique & Fonctionnement** :
  * Modèle atmosphérique empirique de Kasten & Young (1989) calculant la masse optique relative :
    $$M(\gamma) = \frac{1}{\sin\gamma + 0.50572\,(\gamma + 6.07995)^{-1.6364}}$$
    où $\gamma$ est l'élévation solaire au-dessus de l'horizon.
  * Au zénith ($\gamma = 90^\circ$), l'épaisseur traversée est minimale ($M = 1.0$), produisant une diffusion de Rayleigh bleue azur $(0.75, 1.00, 1.35)$.
  * À l'horizon ($\gamma = 0^\circ$), le trajet optique s'allonge de $38\times$ ($M \approx 38.0$) : les courtes longueurs d'onde sont totalement éteintes, ne laissant passer que l'ambre et le cramoisi crépusculaire $(1.60, 0.85, 0.40)$.
* **Comment le régler** :
  * Activer `Auto Airmass Spectrum (Kasten-Young)`.
  * `Airmass Shift Intensity` (défaut $1.00$) : $0.00$ neutralise la teinte (lumière blanche pure), $1.00$ applique l'étalonnage photoréaliste, $> 1.00$ force une stylisation crépusculaire dramatique.
* **Effet visuel concret** :
  * En manipulant l'élévation du soleil (via le gizmo 3D ou le slider `Sun Elevation`), les rais de lumière passent continûment d'une brume bleutée froide en plein jour à des rayons dorés au coucher du soleil, puis à des rais rouges profonds au ras de l'horizon.

### 6.2. Crepuscular Horizon Fade
* **Physique & Fonctionnement** :
  * L'éblouissement contre-jour direct (*Crepuscular Boost*) est naturel lorsque le soleil est rasant car la ligne de visée traverse une forte couche d'aérosols. Au zénith, un soleil haut ne doit pas aveugler tout l'écran d'un halo blanc saturé uniforme.
  * Une courbe cubique douce (*smoothstep*) CPU atténue progressivement le multiplicateur de boost entre un angle de début et un angle de fin :
    $$\text{factor} = 1.0 - \text{smoothstep}(\gamma_{\text{start}}, \gamma_{\text{end}}, \gamma)$$
* **Comment le régler** :
  * Activer `Auto Horizon Fade`.
  * `Horizon Fade Start Angle` (défaut $45.0^\circ$) : au-dessous de cet angle, 100% du flare contre-jour est actif.
  * `Horizon Fade End Angle` (défaut $85.0^\circ$) : au-dessus de cet angle (zénith plein ciel), le boost est réduit à 0%.
* **Effet visuel concret** :
  * En levant la caméra vers un soleil haut dans le ciel, la surexposition blanche aveuglante disparaît naturellement pour laisser place à des rais d'ombre nets et contrastés derrière les sphères.

### 6.3. Isotropic Multi-Scattering Compensation
* **Physique & Fonctionnement** :
  * L'approximation classique de Henyey-Greenstein à simple diffusion ($g \ge 0.6$) concentre toute l'énergie vers l'avant. À $90^\circ$ du soleil (vue de profil), la fonction de phase chute à des valeurs quasi nulles, créant un "trou noir" non physique dans les rais.
  * Dans la nature, les photons diffusent plusieurs fois contre les particules d'air, formant un fond lumineux isotrope ($P \approx 1.0$) qui compense les pertes :
    $$P_{\text{eff}}(\theta) = \text{lerp}(P_{HG}(\theta), 1.0, \alpha_{\text{multi}})$$
* **Comment le régler** :
  * Activer `Multi-Scattering Compensation`.
  * `Isotropic Multi-Scatter Blend` (défaut $0.25$) : $0.00$ = simple diffusion pure (fort contraste mais creux sombre à $90^\circ$), $0.25$ = équilibre physique naturel, $0.50+$ = brume très diffuse / jour de brouillard épais.
* **Effet visuel concret** :
  * Lorsqu'on regarde les rayons de profil ou perpendiculairement à la direction solaire, l'espace entre les sphères ne devient plus complètement noir et éteint : une douce nappe lumineuse ambiante baigne le volume.

### 6.4. Worley Cellular Dust (Poussière Granulaire 3D)
* **Physique & Fonctionnement** :
  * La poussière et les grains de sable en suspension ne forment pas un gaz continu (Perlin FBM), mais des micro-particules discrètes réfléchissant la lumière spéculaire.
  * Une texture 3D de cellules de Voronoi/Worley $64^3$ calcule la distance euclidienne aux germes de particules les plus proches, générant des points lumineux isolés et étincelants.
* **Comment le régler** :
  * Activer `Dust / Corpuscular Particles` puis `Worley Cellular Dust`.
  * `Worley Particle Blend` (défaut $0.85$) : $0.00$ = brume continue Perlin (fumée), $1.00$ = particules de poussière étincelantes pures.
  * `Dust Scale` ($0.15 \to 0.35$) : ajuste la granularité spatiale des poussières.
* **Effet visuel concret** :
  * Les rais de lumière semblent traversés de grains de poussière flottants qui s'allument lorsqu'ils traversent les zones éclairées, évoquant un rai de lumière traversant un grenier ou une grange.

### 6.5. Dust Depth Window Mask (Masque de Distance en Cloche)
* **Physique & Fonctionnement** :
  * Les particules de poussière ne doivent être visibles qu'à distance moyenne. Trop près de l'objectif, elles créent d'immenses taches floues disgracieuses qui clignotent lors des rotations caméra ; trop loin, elles génèrent du sous-échantillonnage et du scintillement (*shimmering*).
  * Un masque polynomial symétrique en cloche $4 \cdot u(1 - u)$ (sans division ni exponentielle coûteuse) annule la visibilité des grains hors de la zone d'intérêt :
    $$u = \text{clamp}\left(\frac{t - d_{\text{near}}}{d_{\text{far}} - d_{\text{near}}}, 0.0, 1.0\right)$$
* **Comment le régler** :
  * Activer `Dust Depth Window Mask`.
  * `Depth Focus Near` (défaut $0.50\,\text{m}$) : distance minimale avant apparition progressive des grains (évite le clipping caméra).
  * `Depth Focus Far` (défaut $20.0\,\text{m}$) : distance maximale au-delà de laquelle les particules s'estompent doucement.
* **Effet visuel concret** :
  * Disparition totale des artéfacts de "grosses taches blanches" collées à la vitre de la caméra en marchant ou tournant rapidement, et arrière-plan lointain propre sans moiré stochastique.

### 6.6. Dual-Lobed Henyey-Greenstein (Rétrodiffusion)
* **Physique & Fonctionnement** :
  * Les aérosols complexes (cristaux de glace, gouttes d'eau, grains de pollen) présentent à la fois un halo avant intense ($g_1 > 0$) et un lobe de réflexion arrière opposé ($g_2 < 0$) vers la source de lumière.
  * Mélange convexe de deux fonctions de phase Henyey-Greenstein :
    $$P_{\text{dual}}(\theta) = w \cdot P_{HG}(\theta, g_1) + (1 - w) \cdot P_{HG}(\theta, g_2)$$
* **Comment le régler** :
  * Activer `Dual-Lobed HG`.
  * `Backward Anisotropy (g2)` (défaut $-0.30$) : asymétrie de la rétro-réflexion.
  * `Forward Lobe Blend` (défaut $0.70$) : pondération du lobe avant ($70\%$) face au lobe arrière ($30\%$).
* **Effet visuel concret** :
  * Lorsque l'on tourne le dos au soleil pour regarder les sphères dans le sens de la lumière, l'atmosphère n'est pas éteinte : un contre-halo subtil souligne le contour arrière des objets dans l'axe de projection.

### 6.7. Height Fog (Brume Exponentielle de Sol)
* **Physique & Fonctionnement** :
  * Loi barométrique de densité verticale simulant l'accumulation de vapeur froide ou de poussière lourde près du sol :
    $$\rho(y) = e^{-k \cdot \max(0, y - y_0)}$$
* **Comment le régler** :
  * Activer `Height Fog`.
  * `Ground Altitude (y0)` (défaut $0.0\,\text{m}$) : calage du niveau de plancher.
  * `Altitude Falloff (k)` (défaut $0.20$) : taux de décroissance verticale. Une valeur faible ($0.05$) crée un brouillard montant haut ; une valeur forte ($0.50$) crée une nappe rase très dense au sol.
* **Effet visuel concret** :
  * Les pieds des sphères inférieures baignent dans une nappe de brume dense, tandis que les sphères supérieures et le ciel restent limpides et dégagés.

### 6.8. Convection Dynamique Orientée Solaire / Vent (Wind Convection)
* **Physique & Fonctionnement** :
  * La poussière ne dérive pas selon un axe figé arbitraire : l'énergie thermique solaire chauffe l'air au sol créant une ascendance verticale (*thermal updraft*), tandis que les courants d'air extérieurs induisent des dérives de vent directionnelles.
  * Le vecteur `u_dust_drift_dir` est injecté dynamiquement sans recompiler le shader ($0.00\,\text{ms}$ coût GPU) :
    * Mode 0 (*Ambient*) : dérive douce équilibrée $(0.08, 0.04, 0.06)$.
    * Mode 1 (*Solar Updraft*) : vecteur ascendant thermique orienté selon l'azimut solaire $\hat{\mathbf{v}} = \text{normalize}(s_x \cdot 0.25, 1.0, s_z \cdot 0.25) \times 0.09$.
    * Mode 2 (*Custom Wind*) : vecteur 3D paramétrable par l'opérateur.
* **Comment le régler** :
  * Choisir `Convection Drift Mode` dans l'onglet Volumetric.
  * En mode 1 (*Solar Updraft*), la direction s'adapte automatiquement à l'orientation du soleil.
  * En mode 2 (*Custom Wind*), ajuster `Wind Drift Vector` avec le slider 3D pour orienter le flux de poussière.
* **Effet visuel concret** :
  * En mode solaire, les grains de poussière s'élèvent lentement vers le ciel en suivant l'inclinaison des rais de lumière. Lors de la manipulation du soleil par ImGuizmo, le mouvement des poussières réagit en direct avec la lumière.

---

## 7. Persistance des Paramètres (100% JSON)

Tous les paramètres ci-dessus sont strictement sérialisés et restaurés à l'identique entre les sessions de l'application via `session.json` :

* **Structure de données** : [`Point_Light_State`](../src/core/session/session.odin) et [`Volumetric_State`](../src/core/session/session.odin).
* **Extraction & Restauration** : [`src/app/session.odin`](../src/app/session.odin).
* **Validation continue** : `python3 scripts/check_persistence.py` & `tests/test_session.odin`.
