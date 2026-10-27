# Analyse Approfondie : Singularité Polaire IBL Spéculaire (Zenith Pinch)

**Date** : 23 Septembre 2026  
**Auteur** : Antigravity  
**Statut** : 🔬 Rapport d'Investigation, Étude Comparative & Spécification Octahedral Mapping  
**Fichiers concernés** :
- [`shaders/pbr_billboard.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag)
- [`shaders/IBL/spmap.glsl`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/IBL/spmap.glsl)
- [`shaders/IBL/irmap.glsl`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/IBL/irmap.glsl)
- [`src/rendering/ibl.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/ibl.odin)
- [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin)
- [`tests/gl/test_visual_regression.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/gl/test_visual_regression.odin)
- [`docs/2026-09-11_ibl_cubemap_migration_architecture_todo.md`](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/2026-09-11_ibl_cubemap_migration_architecture_todo.md)

---

## 1. Contexte & Observation Visuelle

Sur une capture d'écran du banc de test multi-sphères PBR ([`assets/materials/pbr_materials.json`](file:///home/latty/Prog/__PERSO__/suckless-odin/assets/materials/pbr_materials.json)), une singularité visuelle pointue (pincement en entonnoir, point central sombre entouré de rayons radiaux formant un repli en étoile) apparaît au sommet d'une sphère métallique (`metallic = 1.0`).

### Caractéristiques spatiales observées
- **Position apparente** : Localisée vers l'apex visible de la sphère dans le viewport.
- **Forme** : Cuspide étoilée à symétrie radiale avec rupture brutale d'intensité au centre.
- **Condition de déclenchement** : Matériau spéculaire métallique sous éclairage IBL avec carte d'environnement 2D équirectangulaire.

---

## 2. Démontage & Analyse Racine (Root Cause)

### 2.1. Innocence de la Géométrie & des Normales
Les sphères ne sont **PAS** des maillages polygonaux découpés en méridiens/parallèles (UV sphere triangulée).
Le moteur utilise un **billboard quad analytique** tracé via [`intersectSphere`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag#L317) :
$$\mathbf{N} = \text{normalize}(\mathbf{P}_{\text{hit}} - \mathbf{C}_{\text{sphere}})$$
La normale est analytique, continue et strictement indifférenciable de la perfection sphérique ($C^\infty$). En mode debug normal (`u_pbr_debug_mode = 2`), le tampon présente un dégradé 100% lisse sans la moindre anomalie au pôle.

### 2.2. Vecteur de Réflexion Spéculaire $R$
Sur la sphère métallique analysée :
- $k_D = (1.0 - k_S) \cdot (1.0 - \text{metallic}) = 0.0$ : la composante diffuse (`irradianceMap`) est nulle.
- 100% de l'énergie provient du préfiltrage spéculaire IBL ([`compute_IBL_PBR`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag#L151)) :
```glsl
vec3 prefilteredColor = textureLod(prefilterMap, dirToUV(R), roughness * MAX_REFLECTION_LOD).rgb;
```
L'analyse géométrique de la caméra et du point d'impact révèle que le vecteur réfléchi $\mathbf{R} = \text{reflect}(-\mathbf{V}, \mathbf{N})$ s'aligne exactement avec le vecteur zénithal mondial :
$$\mathbf{R} \approx (0.0, 1.0, 0.0)$$

### 2.3. Dégénérescence Topologique du Mapping Équirectangulaire
La fonction [`dirToUV`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag#L101-L106) convertit la direction 3D en coordonnées UV 2D :
```glsl
vec2 dirToUV(vec3 v)
{
    float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
    vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0))) * INV_ATAN + 0.5;
    return uv;
}
```

Quatre facteurs mathématiques et matériels convergent pour créer l'artefact :

1. **Singularité de paramétrisation (Pôle géographique)** :
   La sphère $S^2$ ne peut être recouverte par une seule carte plane sans singularité.
   La rangée entière de texels supérieurs $V = 1.0$ ($U \in [0.0, 1.0]$) correspond à un **unique point géométrique 3D** : le pôle $(0, 1, 0)$.
2. **Explosion du gradient azimutal** :
   Quand $\mathbf{R}_{xz} \to 0$, l'angle azimutal $\phi = \text{atan2}(R_z, R_x)$ varie de $-\pi$ à $+\pi$ sur un voisinage sub-pixel. Les lignes d'azimut constant forment des rayons partant du centre.
3. **Discontinuité de seuil du shader** :
   La clause de garde `(abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : ...` force brutalement $\phi = 0.0 \implies U = 0.5$ au centre exact, alors que les texels contigus autour échantillonnent $U \in [0.0, 1.0]$.
4. **Interpolation bilinéaire 2D plane (Filtrage GPU inapproprié)** :
   L'unité de texture OpenGL effectue un filtrage bilinéaire en espace cartésien $(u, v)$ plan. Elle interpole horizontalement entre texels distants sur la sphère comme s'ils étaient espacés sur un plan euclidien, générant le plissement radial (*pinch*).

### 2.4. Biais de Convolution dans `spmap.glsl`
Dans [`shaders/IBL/spmap.glsl`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/IBL/spmap.glsl#L100-L103) :
```glsl
vec3 up = abs(normal.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
tangent = normalize(cross(up, normal));
bitangent = cross(normal, tangent);
```
Au zénith ($\text{normal} \to (0, 1, 0)$), la base orthonormale $(T, B, N)$ se fige le long des axes $(-X, +Z, +Y)$ sans tourner avec la longitude $st.x$. Les échantillons Hammersley GGX conservent une orientation fixe alors que la projection tourne, imprimant des variations d'intensité non physiques le long de la ligne $V = 1.0$.

---

## 3. Matrice de Caractérisation Expérimentale

| Test de Bissection | Procédure | Comportement Observé | Verdict |
| :--- | :--- | :--- | :--- |
| **Translation Caméra** | Orbiter autour de la sphère | La singularité glisse sur la surface pour rester sous $\mathbf{R} = (0, 1, 0)$ | Artefact optique/IBL, non maillage |
| **Rotation HDR** | Modifier le Yaw de l'environnement | L'étoile de singularité pivote sur elle-même | Dépendance directe de la texture HDR |
| **Buffer Normales** | Mode debug normal (`u_pbr_debug_mode = 2`) | Surface parfaitement sphérique, 0 artefact | Géométrie 100% intègre |
| **Buffer Prefilter** | Mode debug prefilter (`u_pbr_debug_mode = 7`) | Singularité reproduite à 100% | Problème isolé dans le stream spéculaire IBL |
| **Variation Rugosité** | $0.05 \to 0.8$ | Ponctuelle à $0.05$, étalée en entonnoir flou à $0.4+$ | La convolution GGX disperse l'anomalie angulaire |

---

## 4. Étude Approfondie des Alternatives sans Changement de Format Texture (Maintien `sampler2D`)

```
                +-------------------------------------------------------------+
                |        ALTERNATIVES SANS CHANGEMENT DE FORMAT (2D)          |
                +-------------------------------------------------------------+
                                       |
          +----------------------------+-----------------------------+
          |                            |                             |
    [1. MÉTHODES 2D              [2. PROJECTIONS 2D            [3. RUNTIME ONLY]
    SUR ÉQUIRECTANGULAIRE]       NON-POLAIRES]                 Smoothstep Cap
    - Moyenne Azimutale Zénith   - Octahedral Mapping (1:1)    dans pbr_billboard.frag
    - Flou Longitudinal 1/cos    - Dual Paraboloid (2:1)
```

---

### Alternative 1 : Moyenne Azimutale sur l'Anneau Zénithal (Zonal / Ring Averaging)

#### A. Principe mathématique & Implémentation
Sur la carte équirectangulaire $W \times H$, la ligne supérieure $y = H-1$ ($V = 1.0$) et la ligne inférieure $y = 0$ ($V = 0.0$) correspondent respectivement au pôle Nord $(0, 1, 0)$ et au pôle Sud $(0, -1, 0)$.

L'opération consiste à écraser l'ensemble des $W$ texels de la dernière rangée par leur moyenne arithmétique sphérique :
$$C_{\text{north\_pole}} = \frac{1}{W} \sum_{x=0}^{W-1} \text{prefilteredEnvMap}(x, H-1)$$
$$C_{\text{south\_pole}} = \frac{1}{W} \sum_{x=0}^{W-1} \text{prefilteredEnvMap}(x, 0)$$

Pour éviter un pli brutal de gradient (discontinuité de dérivée première) avec la rangée $H-2$, on applique une transition en cosinus amorti sur les $K$ dernières lignes de latitude ($K \approx 2$ à $4$ texels) :
$$w(y) = \sin^2\left(\frac{\pi}{2} \cdot \frac{H - 1 - y}{K}\right)$$
$$\text{Color}(x, y) = \text{mix}(C_{\text{pole}}, \text{Color}(x, y), w(y)) \quad \forall y \ge H - 1 - K$$

#### B. Avantages
1. **Zéro surcoût runtime** : Le fragment shader [`shaders/pbr_billboard.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag) conserve exactement son code d'échantillonnage `textureLod(prefilterMap, dirToUV(R), lod)`. Zéro instruction ALU ni conditionnelle ajoutée au tracé PBR.
2. **Conservation intégrale du pipeline** : Aucune modification des types d'allocation dans [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin), ni des bindings (unités 15, 16).
3. **Disparition immédiate de l'étoile/pinch** : Comme toute la rangée $y=H-1$ est monochromatique, l'explosion de l'angle azimutal $\phi$ lit toujours la même couleur.

#### C. Inconvénients & Limites
1. **Écrasement des détails zénithaux sur reflets nets** : Pour les surfaces très polies ($\text{roughness} < 0.08$), si une source lumineuse directionnelle nette (soleil, lustre, fenêtre) traverse le pôle zénithal, elle est étalée en un disque diffus uniforme.
2. **Ne supprime pas la couture longitudinale ($360^\circ$)** : La discontinuité $U = 0.0 \leftrightarrow U = 1.0$ sur le méridien arrière ($Z < 0$) persiste.
3. **Risque de banding annulaire** : Si l'étalonnage de l'amortissement $K$ est trop abrupt, un anneau de transition concentrique devient perceptible à l'angle critique.

---

### Alternative 2 : Filtrage Longitudinal Adaptatif en $\frac{1}{\cos\theta}$ (Adaptive Latitudinal Low-Pass Filter)

#### A. Principe mathématique & Implémentation
Sur une sphère, le périmètre d'un cercle de latitude à la déclinaison $\theta \in [-\frac{\pi}{2}, +\frac{\pi}{2}]$ est :
$$\mathcal{P}(\theta) = 2\pi R \cos\theta$$
Quand $\theta \to \pm \frac{\pi}{2}$, la distance métrique couverte par un texel horizontal se contracte proportionnellement à $\cos\theta$.
Un filtrage isotrope sur la surface de la sphère exige donc un filtre passe-bas horizontal dont l'écart-type spatial en texels $\sigma_x(\theta)$ s'élargit inversement à la métrique :
$$\sigma_x(\theta) = \frac{\sigma_0}{\max(\cos\theta, \epsilon_{\text{pole}})}$$

#### B. Avantages & Inconvénients
- **Avantages** : Transition continue $C^\infty$, zéro coût à l'exécution temps réel PBR.
- **Inconvénients** : Surcoût de convolution 1D circulaire lourd lors du baking dans [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin), persistance des gradients d'écran élevés au pôle géométrique.

---

## 5. Étude Spécifique Approfondie : Octahedral Environment Mapping

L'**Octahedral Environment Mapping** (Cigolle et al. 2014, Meyer et al. 2010) est la méthode de référence pour stocker des signaux sphériques dans un `sampler2D` plan sans singularité polaire.

```
Projection Octaédrique Dépliée (Texture 2D Carrée 1:1) :
               (0, 1) +-------------------+ (1, 1)
                      | \   Hémisphère  / |
                      |   \   Sud     /   |
                      |     \ (Y < 0)/    |
                      |  Hémisphère Nord  |   <-- Pôle Nord (0, 1, 0)
                      |     / (Y > 0)\    |       exactement au centre
                      |   /   Sud     \   |       (U=0.5, V=0.5) !
                      | /   Hémisphère  \ |       ZÉRO singularité !
               (0, 0) +-------------------+ (1, 0)
```

### 5.1. Formulation Mathématique & Algorithme Branchless

L'espace $S^2$ est projeté sur un octaèdre régulier via la norme $L_1$ :
$$\mathbf{p} = \frac{\mathbf{v}}{\|\mathbf{v}\|_1} = \frac{\mathbf{v}}{|v_x| + |v_y| + |v_z|}$$

Sur l'hémisphère Nord ($v_y \ge 0$), la projection plane est directement $(p_x, p_z)$.
Sur l'hémisphère Sud ($v_y < 0$), les quatre triangles d'arêtes se replient vers l'extérieur.

#### Implémentation GLSL Branchless Optimisée :
```glsl
// Direction 3D normalisée vers Coordonnées UV [0, 1]^2
vec2 dirToOctahedral(vec3 v)
{
    vec2 p = v.xz * (1.0 / (abs(v.x) + abs(v.y) + abs(v.z)));
    // Dépliage branchless de l'hémisphère Sud
    if (v.y < 0.0) {
        p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
    }
    return p * 0.5 + 0.5;
}

// Coordonnées UV [0, 1]^2 vers Direction 3D normalisée
vec3 octahedralToDir(vec2 uv)
{
    vec2 p = uv * 2.0 - 1.0;
    vec3 v = vec3(p.x, 1.0 - abs(p.x) - abs(p.y), p.y);
    if (v.y < 0.0) {
        v.xz = (1.0 - abs(v.zx)) * vec2(v.x >= 0.0 ? 1.0 : -1.0, v.z >= 0.0 ? 1.0 : -1.0);
    }
    return normalize(v);
}
```

---

### 5.2. Évaluation Exhaustive des Risques de Régressions

L'adoption de ce mapping modifie le système de coordonnées de base de l'IBL. Voici les 5 risques majeurs identifiés :

| Risque Identifié | Gravité | Mécanisme de Déclenchement | Impact sur la Codebase |
| :--- | :--- | :--- | :--- |
| **1. Invalidation des Golden References** | **Critique** | Tous les texels IBL changent de position et d'interpolation | [`tests/gl/test_visual_regression.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/gl/test_visual_regression.odin) échouera sur les 6 vues (`ref_front`, `ref_top`, etc.). Règle stricte : **Interdiction de régénérer sans accord humain**. |
| **2. Coutures Diagonales aux Arêtes (Seams)** | **Élevée** | Filtrage bilinéaire GPU le long des arêtes de repliement de l'hémisphère Sud | Lignes sombres ou coutures diagonales en "X" sur les surfaces lisses traversant $v_y = 0$. |
| **3. Bruit sur Mipmaps Grossiers (`glGenerateMipmap`)** | **Élevée** | `glGenerateMipmap` standard 2D ne connaît pas la topologie de l'octaèdre | Mélange de texels non adjacents sur les bords aux mips $6 \dots 10$. Rupture sur les matériaux à forte rugosité (`roughness > 0.6`). |
| **4. Désynchronisation Skybox vs PBR** | **Moyenne** | Le fond d'écran skybox reste en équirectangulaire alors que les reflets sont en octaédrique | Décalage visuel (phase ou orientation) entre la réflexion sur la sphère et l'arrière-plan visible ([`shaders/background.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/background.frag)). |
| **5. Régression Streaming PBO & Allocations VRAM** | **Moyenne** | Passage d'un ratio $2:1$ ($1024 \times 512$) à $1:1$ ($512 \times 512$ ou $1024 \times 1024$) | Tailles de buffers fixes dans [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin) (`UPLOAD_TOTAL_BYTES`, ring buffer). Risque de débordement mémoire ou assertion de layout. |

---

### 5.3. Difficultés Concrètes d'Intégration Moteur

1. **Gestion de la Gouttière de Bordure (1-Texel Border Gutter / Padding)** :
   * En OpenGL, `GL_REPEAT` répète horizontalement et verticalement sur un plan cartésien.
   * Or sur l'octaèdre, traverser le bord droit en haut ramène sur le bord haut à droite (inversion de coordonnées).
   * **Solution technique obligatoire** : Intégrer un encadrement d'un pixel (border gutter) répliqué dans le compute shader pour que le sampler matériel `GL_LINEAR` interpole correctement sans fuite vers du noir ou le bord opposé.
2. **Recalibration de l'Angle Solide ($\Delta\Omega$) dans `spmap.glsl`** :
   * Actuellement, la formule de `saTexel` suppose un angle solide équirectangulaire $\Delta\Omega \approx \frac{4\pi}{6WH}$.
   * En projection octaédrique, l'angle solide d'un texel varie selon sa position : $\Delta\Omega(\mathbf{p}) \propto \frac{1}{\|\mathbf{v}\|_1^3}$. Il faut corriger la formule de sélection du niveau de MIP d'entrée sous peine d'échantillonner des mips trop flous ou trop nets.
3. **Mise à jour des Inspecteurs ImGui** :
   * Les fenêtres de débogage IBL ([`src/gui/gui.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui.odin) via `draw_ibl_debug_irradiance`) dimensionnent les textures au format $2:1$. Un affichage carré $1:1$ sans ajustement produira un étirement anamorphique dans l'UI.

---

### 5.4. Protocole de Vérification Pas à Pas (5 Jalons Stricts)

Pour intégrer l'Octahedral Mapping sans guesswork et sans régression silencieuse :

```
[JALON 1] Test Unitaire Mathématique CPU (Odin) : Bijection S² <-> Octaèdre
   |
[JALON 2] Test Shader Unitaire Hors-Ligne (glslangValidator + Roundtrip Fixture)
   |
[JALON 3] Validation Visuelle de la Grille / Mire de Calibrage (Vérification des Seams)
   |
[JALON 4] Rendu PBR Isolant par Buffers Diagnostics (Mode 6 Irradiance & Mode 7 Prefilter)
   |
[JALON 5] Comparaison Paires Visuelles A/B sous Contrôle Humain (Revue Golden Images)
```

1. **Jalon 1 (CPU Pure Unit Test)** :
   * Fichier : `tests/test_octahedral.odin`.
   * Échantillonner $10^6$ vecteurs aléatoires sur la sphère $S^2$, incluant les cas limites ($x=0$, $y=0$, $z=0$, pôles $\pm Y$, arêtes diagonales).
   * Vérifier que $\|\mathbf{v} - \text{octahedral\_to\_dir}(\text{dir\_to\_octahedral}(\mathbf{v}))\| < 10^{-6}$.
   * Critère d'arrêt : 100% vert sous `task test-unit`.
2. **Jalon 2 (Shader Roundtrip Test)** :
   * Shader test fixture exécuté offscreen pour vérifier que la conversion GLSL produit une erreur angulaire nulle sur GPU (gestion des zéros et signes IEEE 754).
3. **Jalon 3 (Test de Continuité des Bords - Seam Detector)** :
   * Remplacer l'environnement HDR par une grille de coordonnées ou une couleur unie avec bruit haute fréquence.
   * Observer la sphère sous rotation complète de caméra : aucune ligne, couture sombre ou pli ne doit apparaître sur les diagonales de repliement.
4. **Jalon 4 (Vérification PBR sur Scène Réelle)** :
   * Activer `u_pbr_debug_mode = 7` (Prefilter).
   * Pointer la caméra vers le zénith sous différents niveaux de rugosité ($0.05, 0.2, 0.5, 0.8$).
   * Vérifier que la singularité étoilée observée initialement a **strictement disparu**.
5. **Jalon 5 (Validation Humaine & Images de Référence)** :
   * Générer des captures paires avant/après.
   * Présenter formellement les résultats à l'opérateur avant toute mise à jour de `tests/references/ref_*.png`.

---

### 5.5. Audit de l'Outillage de Test Existant & Gaps à Combler

> [!IMPORTANT]
> **Réponse sans détour : NON, le projet n'est PAS suffisamment outillé actuellement pour mener cette refonte en toute sécurité.**

#### Forces de l'outillage actuel
- `task test-unit` : Suite rapide et stable (117 tests en $7.8\text{ s}$).
- `task test-shader` : Contrôle de syntaxe et de compilation shader loader instantané ($< 1\text{ ms}$).
- `test_visual_regression.odin` : Harnais automatisé comparant 6 angles cardinaux avec calcul de métriques d'erreur et production d'images diffs (`failed_diff_*.png`).
- `task lint` : Tolérance zéro warnings et vérification stricte des liens de documentation.

#### Faiblesses & Gaps Critiques à Combler AVANT la migration

1. **Absence totale de tests unitaires de projection sphérique** :
   * Actuellement, la fonction `dirToUV` n'est couverte par **aucun** test unitaire mathématique.
   * **Action requise** : Créer `tests/test_octahedral.odin` pour verrouiller les propriétés bijectives avant d'écrire la moindre ligne de shader.
2. **Inadéquation du seuil de tolérance de `test_visual_regression.odin`** :
   * Le test compare la vue globale à distance 25 avec `DIFF_PERCENTAGE_TOLERANCE = 0.02` ($2\%$).
   * L'artefact de singularité polaire ne couvre que $\approx 0.05\%$ des pixels de l'image.
   * Un artefact polaire catastrophique ou une couture diagonale fine de 1 pixel passe aujourd'hui **TOTALEMENT INAPERÇUE** (test visuel vert !).
   * **Action requise** : Ajouter un test de détection de singularité zénithale ciblé (ROI focalisée sur le sommet de la sphère avec seuil d'écart-type de gradient très strict).
3. **Contrainte de préservation CPU locale (`AGENTS.md`)** :
   * Les tests graphiques complets sous Xvfb/llvmpipe (`task test-gl-xvfb`) sont strictement restreints pour préserver le matériel hôte.
   * La validation doit donc impérativement s'appuyer sur des **tests unitaires mathématiques CPU légers** et des sessions de validation opérateur interactives.

---

## 6. Synthèse Comparative Globale & Tableau de Décision

| Solution | Type de Texture | ALU Frag Shader | Coût Compute IBL | Élimination Pôle | Élimination Seam $360^\circ$ | Complexité Migration | Verdict Technique |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Moyenne Azimutale Zénith** | `sampler2D` (Équi $2:1$) | **0 cycle** (1 tap) | $+0.1\%$ (LDS average) | **Oui** (Total) | Non (Persiste) | **Minimale** (2h) | **Recommandé Court Terme (Quick Fix)** |
| **2. Filtre Longitudinal $1/\cos\theta$** | `sampler2D` (Équi $2:1$) | **0 cycle** (1 tap) | $+5\%$ (Passe 1D) | **Oui** (Progressif) | Non (Persiste) | Moyenne (1 jour) | Trop complexe pour un gain marginal |
| **3. Octahedral Mapping** | `sampler2D` (Carré $1:1$) | **Optimal** (0 trigo) | Équivalent | **Oui** (Absolu) | **Oui** (Intégrée) | Moyenne (2-3 jours) | **Meilleure Alternative 2D Pure** |
| **4. Dual Paraboloid** | `sampler2D` (ou Array 2D) | Faible (Division) | Équivalent | **Oui** (Au centre) | Non (Couture équateur) | Moyenne | Déconseillé (Défauts équatoriaux) |
| **5. Smoothstep Cap Runtime** | `sampler2D` (Équi $2:1$) | $+4$ taps (divergent) | **0 cycle** | **Oui** (Visuel) | Non (Persiste) | **Minimale** (30 min) | Solution de dépannage temporaire |
| **Target : Cubemap Natif** | `samplerCube` (6 faces) | **Optimal** (3D vector) | $-10\%$ (Pavage régulier) | **Oui** (Absolu) | **Oui** (`SEAMLESS`) | Majeure (Feat dédiée) | **Architecture Cible Définitive** |

---

## 7. Recommandations Techniques Opérationnelles

1. **Option 1 (Médiat / Quick Fix Sans Risque)** :
   * Injecter la **Moyenne Azimutale Zénithale** dans [`shaders/IBL/spmap.glsl`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/IBL/spmap.glsl) et [`shaders/IBL/irmap.glsl`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/IBL/irmap.glsl).
   * Zéro régression sur les golden images globales, zéro modification d'architecture, correction immédiate de la singularité observée.
2. **Option 2 (Transition Octahedral Mapping)** :
   * Créer au préalable l'outillage de test unitaire mathématique et le test de détection de singularité ciblé.
   * Réaliser la migration sur une branche courte dédiée avec validation visuelle humaine systématique à chaque jalon.
