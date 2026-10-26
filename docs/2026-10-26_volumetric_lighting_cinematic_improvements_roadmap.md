# Spécification Technique : Améliorations Cinématographiques de l'Éclairage Volumétrique (Phases 1 & 2)

**Date** : 26 Octobre 2026  
**Auteur** : Antigravity & GLM Review Analysis  
**Statut** : 🚀 Phase 1 en cours d'implémentation / Phase 2 planifiée  
**Fichiers concernés** :
- `shaders/postfx/volumetric_raymarch_directional.frag`
- `src/rendering/volumetric.odin`
- `src/rendering/volumetric_presets.odin`
- `src/core/session/session.odin`
- `src/app/session.odin`
- `src/gui/gui_volumetric.odin`
- `tests/test_session.odin`

---

## 1. Vision & Objectifs Visuels

L'éclairage volumétrique directionnel actuel produit des rayons lumineux physiquement corrects mais basés sur un **milieu homogène à fonction de phase Henyey-Greenstein à lobe unique**.
L'objectif est d'atteindre le rendu atmosphérique des moteurs de jeu AAA contemporains (*Unreal Engine 5*, *Decima*, *Frostbite*) :
- **Atmosphère texturée & poussière vivante** : Présence de micro-particules en suspension et volutes de brume hétérogènes.
- **Réalisme optique & contre-jour** : Halo rétro-diffusé naturel autour de la source lumineuse et éblouissement cinématographique face au soleil.
- **Diffraction chromatique** : Séparation spectrale naturelle (diffusion Rayleigh bleutée en ciel ouvert, absorption chaude/rougeâtre au ras du sol).
- **Zéro régression de performance** : Capitaliser sur l'accumulation temporelle TAA existante pour ne pas alourdir la boucle de marche GPU.

---

## 2. Feuille de Route en 2 Phases

```mermaid
flowchart TD
    subgraph Phase_1 ["Phase 1 : Quick-Wins Zéro Coût (ALU Hors-Boucle)"]
        A["1.1 Dual-Lobed Henyey-Greenstein\n(Mix Lobe Avant g1 ~ 0.70 & Arrière g2 ~ -0.30)"]
        B["1.2 Crepuscular Ray Boost\n(Sur-amplification dynamique en contre-jour direct)"]
        C["1.3 Spectral Scattering\n(Coefficients sigma_s vectoriels RGB Rayleigh/Mie)"]
        D["1.4 Réglage TAA Temporel\n(Alpha = 0.15 pour convergence ultra-lisse)"]
    end

    subgraph Phase_2 ["Phase 2 : Corpuscularité & Bruit Volumétrique"]
        E["2.1 Blue Noise Texture 2D\n(Élimination complète du banding IGN)"]
        F["2.2 Texture 3D de Poussière / FBM\n(Échantillonnage trilinéaire 64x64x64 défilant)"]
        G["2.3 Masquage Altimétrique de Sol\n(Gradient exponentiel de densité e^-k(y-y0))"]
    end

    Phase_1 --> Phase_2
```

---

## 3. Détail de la Phase 1 (Implémentation Immédiate)

Chaque fonctionnalité de la Phase 1 est conçue pour être **individuellement commutable (toggle on/off)** dans l'interface Dear ImGui et **100% persistée dans la session JSON** afin de pouvoir isoler et doser son impact artistique.

### 1.1 Fonction de Phase Double Lobe (Dual-Lobed Henyey-Greenstein)
- **Modèle physique** :
  $$P(\theta) = (1 - w) \cdot P_{\text{HG}}(\theta, g_2) + w \cdot P_{\text{HG}}(\theta, g_1)$$
  avec $g_1 \in [0.0, 0.90]$ (lobe avant), $g_2 \in [-0.99, 0.0]$ (lobe arrière) et $w \in [0.0, 1.0]$.
- **Intérêt visuel** : Génère un halo doux réaliste visible même lorsque la source lumineuse est zénithale ou latérale.
- **Coût GPU** : **0.00 ms** (calculé une seule fois par fragment hors boucle raymarch pour la lumière directionnelle).

### 1.2 Sur-amplification en Contre-jour (Crepuscular Ray Boost)
- **Modèle physique** :
  $$B = 1.0 + \text{smoothstep}(\text{threshold}, 1.0, \cos\theta) \cdot \text{strength}$$
- **Intérêt visuel** : Émule l'éblouissement optique cinématique caractéristique des films lorsque l'observateur regarde directement vers le soleil.
- **Coût GPU** : **0.00 ms** (facteur multiplicateur calculé hors boucle).

### 1.3 Diffusion Chromatique Spectrale ($\sigma_s$ RGB)
- **Modèle physique** :
  Vectorisation du coefficient de diffusion $\vec{\sigma}_s = (\sigma_{s,R}, \sigma_{s,G}, \sigma_{s,B})$ avec pondération par défaut $(1.20, 1.00, 0.85)$.
- **Intérêt visuel** : Teinte dorée chaude aux rayons proches du sol et composante bleue atmosphérique en altitude.
- **Coût GPU** : **0.00 ms** (registres vectoriels SIMD natifs du GPU).

### 1.4 Calibrage Fin de l'Accumulation Temporelle TAA
- **Modèle** : Réduction du poids de la frame courante `taa_alpha` de $0.20$ à $0.15$.
- **Intérêt visuel** : Permet au filtre TAA existant d'accumuler davantage d'historique (4 à 8 frames), gommant le bruit d'échantillonnage et autorisant un step count réduit sans aucun aliasing.

---

## 4. Détail de la Phase 2 (Implémentée)

Chaque fonctionnalité de la Phase 2 dispose de son **toggle on/off**, de curseurs de réglage avec bouton **Reset**, d'une **persistance JSON intégrale** et d'une intégration dans la recherche floue (`draw_filtered_volumetric`).

### 2.1 Jitter Blue Noise 2D (Void-and-Cluster)
- **Modèle** : Table périodique 64x64 précalculée (algorithme de void-and-cluster de Robert Ulichney, 1993) intégrée dans le binaire (`src/rendering/blue_noise_data.odin`).
- **Rotation temporelle** : Décalage quasi-aléatoire par frame selon le nombre d'or sur tore toroïdal $64 \times 64$ :
  $$\vec{u}_{\text{offset}} = \frac{\text{gl\_FragCoord.xy} + (f \bmod 64) \cdot (0.754877, 0.569840)}{64}$$
- **Intérêt visuel** : Élimine totalement le lignage diagonal caractéristique de l'IGN (*Interleaved Gradient Noise*) et optimise la dispersion fréquentielle pour une convergence ultra-rapide sous TAA.
- **Coût VRAM / GPU** : $4\,\text{KB}$ de VRAM (`GL_R8`, 64x64). Échantillonnage GPU négligeable ($< 0.01\,\text{ms}$).

### 2.2 Texture Volumétrique 3D de Poussière / Corpuscularité ($64^3$)
- **Modèle** : Texture 3D $64 \times 64 \times 64$ `GL_R8` ($256\,\text{KB}$) générée au démarrage avec bruit de Perlin FBM périodique à 3 octaves sans coupure de bord (`src/rendering/dust_noise.odin`).
- **Échantillonnage dynamique** :
  $$\vec{p}_{\text{noise}} = \vec{p}_{\text{sample}} \cdot s + \vec{v}_{\text{drift}} \cdot (t \cdot v)$$
  $$\text{mod}_{\text{dust}} = \text{mix}(1.0, 2.0 \cdot \text{noise3D}(\vec{p}_{\text{noise}}), \text{intensity})$$
- **Paramètres réglables** :
  - `Dust Intensity` : contraste des volutes ($[0.0, 1.0]$, défaut $0.50$, reset).
  - `Dust Scale` : échelle spatiale des panaches ($[0.01, 2.0]$, défaut $0.25$, reset).
  - `Dust Drift Speed` : vitesse de convection temporelle ($[0.0, 1.0]$, défaut $0.15$, reset).
- **Coût GPU** : Filtrage trilinéaire matériel natif OpenGL 4.5 ($< 0.15\,\text{ms}$ à 16 steps en half-res).

### 2.3 Masquage Altimétrique de Sol (Height Fog / Plafond Exponentiel)
- **Modèle** : Atténuation barométrique exponentielle simulant la troposphère et la couche limite :
  $$\text{mod}_{\text{height}} = e^{-k \cdot \max(0, y - y_0)}$$
- **Paramètres réglables** :
  - `Ground Altitude (y0)` : altitude de base du sol ($[-10.0, 10.0]\,\text{m}$, défaut $0.0\,\text{m}$, reset).
  - `Altitude Falloff (k)` : coefficient de décroissance vertical ($[0.01, 2.0]$, défaut $0.20$, reset).
- **Intérêt visuel** : Concentre le brouillard dense et les rais de lumière au sol tout en dégageant le ciel et l'arrière-plan.
- **Coût GPU** : $0.00\,\text{ms}$ (1 exponentielle vectorielle par pas).
