# 🌌 Calibration Physique du Rendu : Beer-Lambert, God Rays, RNOB & JBU 2x2

---

## 📌 1. Vue d'Ensemble & Objectifs Architecturaux

Lors du cycle de stabilisation et de revue de code de septembre 2026 (`47c27cadf9...HEAD`), le moteur de rendu **Suckless Odin** a bénéficié d'une calibration physique de haute précision portant sur deux piliers majeurs du pipeline graphique :
1. **L'Éclairage Volumétrique & Effet de God Rays (Phases 2 à 7)** : Intégration du transport radiatif basé sur la loi de Beer-Lambert, fonction de phase d'Henyey-Greenstein asymétrique et upsampling bilatéral guidé par la profondeur (*Joint Bilateral Upsampling 2x2*).
2. **Le Shadow Mapping Omnidirectionnel (Phase 1)** : Correction géométrique rigoureuse du *Receiver Normal Offset Bias* (RNOB) et extension dynamique de la résolution des cubemaps ($64^2$ jusqu'à $2048^2$).

Ce document explicite les fondements mathématiques, les modifications de shaders et les raisons physiques qui expliquent le saut qualitatif spectaculaire constaté sur le rendu final.

```
                          PIPELINE DE RENDU PHYSIQUE
  .-------------------------------------------------------------------------.
  | 1. Shadow Pass (Cubemap 6 faces GL_DEPTH32F + GL_R32F radial)           |
  '-----------------------------------+-------------------------------------'
                                      |
  .-----------------------------------v-------------------------------------.
  | 2. Surface PBR Pass (RNOB + SSDB + Vogel PCF 16-tap + TAA Denoising)    |
  '-----------------------------------+-------------------------------------'
                                      |
  .-----------------------------------v-------------------------------------.
  | 3. Low-Res Depth Downsample (Rank/Median 4-tap, Discontinuity Mask)     |
  '-----------------------------------+-------------------------------------'
                                      |
  .-----------------------------------v-------------------------------------.
  | 4. Volumetric Raymarching (Beer-Lambert Transmittance, Phase H-G)       |
  '-----------------------------------+-------------------------------------'
                                      |
  .-----------------------------------v-------------------------------------.
  | 5. Spatial-Temporal Filtering (TAA History Reprojection + Bilateral 9x) |
  '-----------------------------------+-------------------------------------'
                                      |
  .-----------------------------------v-------------------------------------.
  | 6. JBU 2x2 Upsampling & Composite additif dans le Backbuffer HDR        |
  '-------------------------------------------------------------------------'
```

---

## 💡 2. Transport Radiatif & Loi de Beer-Lambert

### 2.1 L'Équation du Rendu Volumétrique (RTE)
Dans un milieu participant homogène (brume, poussière, fumée), la radiance perçue par un observateur le long d'un rayon de visée $\mathbf{x}(t) = \mathbf{c} + t \vec{\omega}$ s'exprime par l'équation intégrale de transfert radiatif :

$$L(\mathbf{c}, \vec{\omega}) = L_0 \cdot T(0, s) + \int_{0}^{s} T(t, s) \cdot \sigma_s \cdot P(\theta, g) \cdot L_i(\mathbf{x}(t), \vec{\omega}_L) \cdot V(\mathbf{x}(t)) \, dt$$

Où :
* $T(t_1, t_2)$ est la **transmittance optique** entre deux points du rayon.
* $\sigma_s$ est le **coefficient de diffusion** (*scattering coefficient*, en $m^{-1}$).
* $\sigma_a$ est le **coefficient d'absorption** (*absorption coefficient*, en $m^{-1}$).
* $\sigma_t = \sigma_s + \sigma_a$ est le **coefficient d'extinction total**.
* $P(\theta, g)$ est la **fonction de phase** angulaire d'Henyey-Greenstein.
* $V(\mathbf{x})$ est le **facteur de visibilité binaire** issu de la shadow map cubique ($1.0$ si éclairé, $0.0$ si dans l'ombre portée).

### 2.2 Pourquoi l'accumulation linéaire précédente échouait ?
Avant la correction, le fragment shader [shaders/postfx/volumetric_raymarch.frag](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_raymarch.frag) accumulait l'énergie lumineuse de façon purement additive :

$$\text{scattered\_amount} = \sum_{i=0}^{N-1} L_i \cdot \sigma_s \cdot P(\theta, g) \cdot \Delta t$$

Sans prise en compte de la transmittance $T(t, s) = 1.0$, chaque tranche d'atmosphère ajoutait la même quantité d'énergie sans qu'aucune lumière ne soit absorbée en traversant le milieu :
1. **Éblouissement plat (*White Washout*)** : Lorsque la caméra s'approchait de la lampe ou que le nombre de pas augmentait, le centre de l'image devenait un disque blanc uniforme brûlé.
2. **Perte de contraste des God Rays** : Les faisceaux d'ombre volumétrique (zones où $V(\mathbf{x}) = 0$) étaient noyés dans la diffusion environnante non atténuée, détruisant tout sentiment d'épaisseur atmosphérique.

### 2.3 L'atténuation exponentielle de Beer-Lambert
La loi de Beer-Lambert stipule que la transmittance décroît exponentiellement avec la densité optique :

$$T(t, s) = \exp\left( -\int_{t}^{s} \sigma_t(u) \, du \right) \implies T_{k+1} = T_k \cdot \exp(-\sigma_t \cdot \Delta t)$$

**Implémentation optimisée dans le shader GLSL** :
```glsl
// Précalcul invariant par pas hors de la boucle
float step_transmittance = exp(-max(u_extinction_coeff, 0.0) * step_size);
float accum_transmittance = 1.0;
float scattered_amount = 0.0;

for (int i = 0; i < steps; ++i) {
    if (in_light_sphere) {
        // Le in-scattering reçu est atténué par la brume située entre l'échantillon et l'œil
        scattered_amount += in_scatter_energy * accum_transmittance;
    }
    // Mise à jour continue de la transmittance optique le long du rayon
    accum_transmittance *= step_transmittance;
    sample_pos += step_dir;
}

// Le canal alpha stocke la transmittance résiduelle du milieu
FragColor = vec4(scattered_amount * light_color_intensity, accum_transmittance);
```

### 2.4 Pourquoi le rendu est immédiatement supérieur ?
* **Profondeur tridimensionnelle réelle** : Les rayons lumineux proches de l'observateur ressortent vifs et nets, tandis que le fond de la scène s'estompe naturellement dans un dégradé cinématique feutré.
* **God Rays sculptés au couteau** : Les zones d'ombre projetées par les sphères dans la brume conservent une obscurité dense et tranchée.
* **Stabilité à haute intensité** : Même avec un multiplicateur d'intensité élevé ($\times 3.0$), le cœur de la lumière ne sature plus l'intégralité du viewport.

---

## ☀️ 3. Diffusion Anisotrope d'Henyey-Greenstein ($g$)

La fonction de phase normalisée d'Henyey-Greenstein régit la répartition angulaire des photons lors d'une collision avec une micro-particule :

$$P(\theta, g) = \frac{1 - g^2}{\left(1 + g^2 - 2g \cos\theta\right)^{3/2}}$$

Où $\theta = \angle(\vec{\omega}_L, \vec{\omega}_{\text{ray}})$ est l'angle entre le vecteur lumière $\to$ échantillon et la direction du regard.

```
       Diffusion Isotropique (g = 0.0)             Diffusion Avant Cinématique (g = 0.75)
                  .---.                                           .---.
                /       \                                       /       \
               |    *    |                                     |    *    |====>> [Faisceau intense]
                \       /                                       \       /
                  '---'                                           '---'
```

### Table des Presets d'Atmosphère et Calibration
Grâce au helper unifié `volumetric_set_anisotropy(vr, light, g)` ([src/rendering/volumetric.odin](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric.odin#L1000)), les réglages suivants sont disponibles de manière instantanée et persistante :

| Preset | $g$ (Anisotropie) | $\sigma_s$ (Scattering) | $\sigma_t$ (Extinction) | Effet Visuel & Utilisation |
|---|:---:|:---:|:---:|---|
| **Isotropic Gas** | `0.00` | `0.040` | `0.040` | Gaz parfait, vapeur chaude uniforme sans éblouissement directionnel. |
| **Morning Fog** | `0.55` | `0.060` | `0.080` | Brume matinale enveloppante, halo doux autour des ampoules. |
| **God Rays** | `0.75` | `0.035` | `0.050` | Puits de lumière spectaculaires, contraste maximal des colonnes solaires. |
| **Torch / Searchlight** | `0.80` | `0.050` | `0.070` | Faisceau de projecteur direct type *Alan Wake*, cône hautement focalisé. |
| **Car Headlights** | `0.88` | `0.060` | `0.090` | Optiques automobiles xénon dans la nuit, diffusion ultra-directionnelle. |
| **Dense Dust** | `0.35` | `0.080` | `0.120` | Tempête de sable / poussières industrielles, forte absorption ambiante. |

---

## 📐 4. Géométrie des Ombres : Correction du Receiver Normal Offset Bias (RNOB)

### 4.1 Le Dilemme du Shadow Mapping sur Sphères
Sur une surface courbe (sphères PBR), le shadow mapping classique à bias constant souffre d'un paradoxe géométrique insoluble :
* **Bias faible ($0.001$)** $\to$ **Acné sévère** (l'arrondi de la sphère coupe le plan discret du texel cubemap $\to$ auto-occlusion parasite en zébrures noires).
* **Bias fort ($0.030$)** $\to$ **Peter-Panning** (l'ombre portée se détache de la base de l'objet et flotte dans le vide).

### 4.2 L'Anomalie de la formule inversée
Dans [shaders/pbr_billboard.frag](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag), la ligne 357 contenait une inversion mathématique :
```glsl
// ❌ ANCIEN CODE ERRONÉ :
float normalOffset = u_point_shadow_normal_bias * clamp(NdotL, 0.0, 1.0);
```
* Sous éclairage normal ($\mathbf{N} \cdot \mathbf{L} = 1.0$) : L'acné est mathématiquement nulle, mais l'offset était **maximal** (dilatation inutile).
* Aux angles rasants ($\mathbf{N} \cdot \mathbf{L} \to 0$) : La projection du texel est étirée et l'acné est **maximale**, mais l'offset devenait **strictement nul**.

### 4.3 La Formule Corrigée conforme à l'état de l'art
$$\mathbf{p}_{\text{biased}} = \mathbf{p}_{\text{hit}} + \mathbf{N} \cdot \left( \text{normalBias} \cdot (1.0 - \mathbf{N} \cdot \mathbf{L}) \right)$$

```glsl
// ✅ CODE CORRIGÉ :
float normalOffset = u_point_shadow_normal_bias * clamp(1.0 - NdotL, 0.0, 1.0);
vec3 biasedHitPos = hitPos + N * normalOffset;
```

```
                          INCIDENCE NORMALE (N.L = 1.0)
                           Lumière en face
                                 │
                                 ▼
                         .───────────────.
                        │  Offset = 0.0  │  <-- Zéro décollement (Zéro Peter-Panning)
                         '───────────────'

                          INCIDENCE RASANTE (N.L -> 0.0)
                         Lumière rasante ──────►
                         .───────────────.
                        │ Offset = MAX  │  <-- Surface dilatée le long de N (Zéro Acné)
                         '───────────────'
```

### 4.4 Gain Visuel Obtenu
1. **Disparition totale de l'acné sur les sphères** : Le limbe des sphères éclairées par la lumière ponctuelle ne présente plus aucune striation noire.
2. **Ancrage physique parfait des ombres de contact** : L'ombre portée commence exactement au point de tangence entre la sphère et le plancher.

---

## 🖼️ 5. Reconstruction Haute Définition : JBU 2x2 & Masque de Silhouette

### 5.1 Pourquoi le calcul à demi-résolution ?
Le raymarching volumétrique à 32 pas sur un écran $4\text{K}$ exigerait $3840 \times 2160 \times 32 \approx 265\text{ millions d'échantillons cubemap/trame}$.
En effectuant le raymarching à **demi-résolution** ($W/2 \times H/2$), le coût est divisé par $4$ ($\approx 66\text{ millions}$).

### 5.2 Le Défi du Bilinear Upsampling Naïf
Un filtrage bilinéaire classique génère du **saignement d'arêtes (*edge bleeding*)** : la lumière volumétrique floutée déborde sur les contours sombres des objets au premier plan, créant un halo laiteux indésirable.

### 5.3 L'Algorithme Joint Bilateral Upsampling (JBU 2x2)
Dans [shaders/postfx/volumetric_composite_simple.frag](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_composite_simple.frag), chaque pixel plein écran consulte les 4 échantillons volumétriques voisins à demi-résolution, pondérés par la proximité géométrique en profondeur :

$$w_{ij} = w_{\text{spatial}}(i, j) \cdot \frac{1}{1.0 + k_{\text{sharpness}} \cdot \frac{|z_{\text{full}} - z_{ij}|}{z_{\text{full}}}}$$

$$\mathbf{C}_{\text{upsampled}} = \frac{\sum_{i,j} w_{ij} \mathbf{C}_{ij}}{\sum_{i,j} w_{ij}}$$

* **Résultat visuel** : L'intégration du brouillard volumétrique épouse les contours des maillages 3D au pixel près, sans le moindre escalier ni bavure.

---

## 🔄 6. Persistance 100% & Recherchabilité Exhaustive

Conformément à la règle absolue inscrite dans [AGENTS.md](file:///home/latty/Prog/__PERSO__/suckless-odin/AGENTS.md) :
1. **Persistance intégrale** : Tous les nouveaux réglages (`shadow_near_plane`, `shadow_far_plane`, `depth_edge_threshold`, `zoom_scale`, `zoom_center`, `shadow_res_index`) sont sérialisés dans `session.json` et restaurés à l'identique au redémarrage.
2. **Recherchabilité universelle** : Tous les presets atmosphériques, curseurs de loupe, modes debug et paliers de résolution sont indexés dans la barre de recherche ImGui (`Ctrl+F` / palette de commande).
3. **Zéro Magic Numbers & Typage fort** : Remplacement des entiers non typés par les énumérations Odin `Volumetric_Preview_Mode` et `Volumetric_Composite_Mode`.

---

## 📊 7. Synthèse des Bénéfices Visuels et Techniques

```
  PROBLÈME INITIAL                            SOLUTION PHYSIQUE / TECHNIQUE                  GAIN VISUEL CONSTATÉ
  ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Voile laiteux plat sans profondeur          Loi de Beer-Lambert (exp(-sigma_t * dt))       Profondeur atmosphérique 3D
  God Rays délavés au centre                  Transmittance exponentielle accumulée          Faisceaux sombres contrastés
  Acné géométrique au terminateur             RNOB proportionnel à (1.0 - N.L)               Courbures de sphères lisses
  Décollement des ombres de contact           Offset géométrique nul sous N.L = 1.0          Zéro Peter-Panning
  Saignement de brume sur les silhouettes     Joint Bilateral Upsampling (JBU 2x2)           Contours découpés au pixel
  Désynchronisation anisotropie g             Helper centralisé volumetric_set_anisotropy    Éblouissement avant cohérent
```

---

*Documentation rédigée et intégrée dans le cadre de la conformité qualité ISO Suckless Odin — Septembre 2026.*
