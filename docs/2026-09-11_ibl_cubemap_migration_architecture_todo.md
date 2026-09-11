# Spécification Technique & TODO : Migration IBL vers Cubemap OpenGL Natif

**Date** : 11 Septembre 2026  
**Auteur** : Équipe Moteur (`suckless-odin`)  
**Statut** : 📋 TODO / Architecture Target (Post-Remédiation GLM)  
**Objectif** : Élimination définitive des singularités polaires (pincement au zénith/nadir) et coutures de filtrage via l'adoption de textures cubiques OpenGL 4.4 Core (`GL_TEXTURE_CUBE_MAP_SEAMLESS`).

---

## 🎯 1. Contexte & Problématique

Actuellement, le sous-système IBL ([`src/rendering/ibl.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/ibl.odin), [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin)) stocke la carte d'irradiance et la carte de préfiltrage spéculaire sous forme de textures 2D équirectangulaires sphériques ($2:1$, format longitude/latitude).

### Constat d'artefact
Sur les surfaces à forte rugosité ($\text{roughness} > 0.40$), le déblocage des mips $5$ à $10$ ([`MAX_REFLECTION_LOD = 10.0`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag#L117)) révèle une **singularité polaire** (pincement conique / vortex) lorsque le vecteur de réflexion $R$ pointe vers le zénith ($R_y \approx +1.0$) ou le nadir ($R_y \approx -1.0$).

```
        Projection Équirectangulaire (sampler2D)            Cubemap Sans Couture (samplerCube)
        +----------------------------------------+          +------+
Pôle -> | Toute la rangée supérieure = 1 point ! |          | Top  |  Angles solides homogènes
        | (Bilinear 2D filtre à travers 360°)    |          +------+  Filtrage matériel sans couture
        |                                        |     +----+------+----+----+
        |    Distorsion aux latitudes extrêmes   |     |Left|Front |Righ|Back| (GL_TEXTURE_CUBE_MAP_SEAMLESS)
        |                                        |     +----+------+----+----+
        +----------------------------------------+          |Bottom|  ZÉRO singularité polaire !
                                                            +------+
```

### Causes fondamentales
1. **Dégénérescence de la paramétrisation** : Toute la ligne de texels supérieure $V=1.0$ ($U \in [0, 1]$) correspond mathématiquement à un unique point géométrique dans l'espace 3D (le pôle).
2. **Filtrage matériel inadapté** : Les samplers matériels 2D interpolent en coordonnées cartésiennes planes $(U, V)$. Au pôle, les texels voisins sur l'écran ont des coordonnées $U$ diamétralement opposées ($U \approx 0.0$ et $U \approx 1.0$), forçant le GPU à filtrer horizontalement à travers toute l'image.
3. **Amplification aux faibles résolutions** : Aux mips élevés (mips 6 à 10 : de $16 \times 8$ à $1 \times 1$), la texture ne possède plus assez d'échantillons pour masquer la convergence angulaire.

---

## 🏗️ 2. Architecture Cible (Target Design)

L'architecture de référence industrielle (Filament, Unreal Engine, Frostbite) s'appuie sur des **Cubemaps matériels à 6 faces** avec extension transparente activée (`GL_TEXTURE_CUBE_MAP_SEAMLESS`).

### Comparatif d'Empreinte Mémoire VRAM

| Paramètre | Pipeline Actuel (2D Équirectangulaire) | Pipeline Cible (Cubemap 6 Faces) |
| :--- | :--- | :--- |
| **Résolution Base Prefilter** | $1024 \times 512$ (`RGBA16F`) | $6 \times (512 \times 512)$ (`RGBA16F`) |
| **VRAM Prefilter (Mip chain)** | $\approx 4.0\text{ Mo} \times 1.33 = 5.33\text{ Mo}$ | $\approx 6 \times 0.5\text{ Mo} \times 1.33 = 4.0\text{ Mo}$ |
| **Résolution Base Irradiance** | $64 \times 32$ (`RGBA16F`) | $6 \times (32 \times 32)$ (`RGBA16F`) |
| **VRAM Irradiance** | $\approx 16\text{ Ko}$ | $\approx 24\text{ Ko}$ |
| **Singularité Polaire** | ❌ Présente (Pincement conique au pôle) | ✅ **Éliminée (0 distorsion polaire)** |
| **Continuité des Bords** | ❌ Seam à $360^\circ$ (nécessite wrap repeat) | ✅ **Parfaite via `GL_TEXTURE_CUBE_MAP_SEAMLESS`** |

---

## 📋 3. Plan d'Implémentation & Tâches (Roadmap TODO)

### Étape 1 : Conversion Panoramique HDR $\rightarrow$ Cubemap Brut (`envmap_cube`)
- [ ] Créer un compute shader `shaders/IBL/equirect_to_cubemap.glsl` (ou passe raster FBO 6 faces).
- [ ] Allouer un cubemap maître `GL_TEXTURE_CUBE_MAP` en `GL_RGBA16F` ($1024 \times 1024$ par face).
- [ ] Générer la mip chain cubique matérielle via `glGenerateMipmap(GL_TEXTURE_CUBE_MAP)`.

### Étape 2 : Adaptation des Compute Shaders IBL (`spmap` & `irmap`)
- [ ] Modifier `shaders/IBL/spmap.glsl` :
  - Remplacer `layout(binding = 1, rgba16f) writeonly uniform image2D` par `imageCube` (ou `image2DArray` avec 6 couches).
  - Calculer la direction de rayon non plus via les angles $\phi, \theta$ équirectangulaires, mais via le système de coordonnées standard de face de cube (`cubeUV_to_direction(face, u, v)`).
  - Conserver le sampling Hammersley / GGX d'origine.
- [ ] Modifier `shaders/IBL/irmap.glsl` de manière analogue pour échantillonner et écrire sur 6 faces cubiques.

### Étape 3 : Intégration dans `Env_Manager` & Ring PBO
- [ ] Mettre à jour `src/scene/env_manager.odin` pour allouer les textures du double-buffering sous forme cubique :
  - `gl.TexStorage2D` avec cible `gl.TEXTURE_CUBE_MAP` (ou `gl.TexImage2D` sur les 6 cibles `TEXTURE_CUBE_MAP_POSITIVE_X` à `NEGATIVE_Z`).
- [ ] Adapter le time-slicing progressif : distribuer le calcul par face (6 faces) et par tranche $Y$.

### Étape 4 : Échantillonnage Shaders PBR & Skybox
- [ ] Dans `shaders/pbr_billboard.frag` :
  - Remplacer `uniform sampler2D irradianceMap;` par `uniform samplerCube irradianceMap;`.
  - Remplacer `uniform sampler2D prefilterMap;` par `uniform samplerCube prefilterMap;`.
  - Éliminer la fonction `dirToUV()` au profit d'un échantillonnage vectoriel direct :
    ```glsl
    // Ancien (2D equirectangular avec singularité polaire) :
    // vec3 prefilteredColor = textureLod(prefilterMap, dirToUV(R), lod).rgb;

    // Nouveau (Cubemap transparent sans pôle) :
    vec3 prefilteredColor = textureLod(prefilterMap, R, lod).rgb;
    vec3 irradiance       = textureLod(irradianceMap, N, 0.0).rgb;
    ```
- [ ] S'assurer que `glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS)` est activé dès l'initialisation OpenGL (`src/app/window.odin`).

---

## 🧪 4. Critères d'Acceptation & Validation

1. **Test Visuel de Pôle** : Disparition totale de la singularité conique sur les sphères orientées vers le zénith sous tous les niveaux de rugosité ($0.0 \dots 1.0$).
2. **Continuité des Raccords** : Absence de toute couture visible au croisement des 6 faces du cube.
3. **Parité Performance** : Temps de précalcul IBL progressif équivalent ou inférieur (grâce à l'uniformité du pavage cubique).
4. **Zéro Régression** : Tests unitaires, shader checks et tests E2E 100% verts.
