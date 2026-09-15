# Architecture des Shadow Maps Omnidirectionnelles : Analyse Technique MRT (Depth-Only vs Color R32F + Depth Buffer)

**Date** : 1er Septembre 2026  
**Projet** : [`suckless-odin`](file:///home/latty/Prog/__PERSO__/suckless-odin) (`OpenGL 4.4 Core`)  
**Fichiers Associés** :
- Module Shadow : [`src/rendering/shadow_cubemap.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin)
- Shader Passe d'Ombre : [`shaders/shadow_cube.vert`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.vert), [`shaders/shadow_cube.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.frag)
- Shader Raymarching Volumétrique : [`shaders/postfx/volumetric_raymarch.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_raymarch.frag)
- Shader Surface PBR : [`shaders/pbr_billboard.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag)

---

## 1. Problématique & Question Technique Fondamentale

Dans une passe de rendu de Shadow Map classique (ex. lumière directionnelle ou projecteur spot), le Framebuffer Object (FBO) n'attache qu'un **Depth Attachment** (`GL_DEPTH_ATTACHMENT`), avec désactivation explicite des tampons de couleur via :
```odin
gl.DrawBuffer(gl.NONE)
gl.ReadBuffer(gl.NONE)
```

Pourquoi alors, dans le cas d'une **Point Light Omnidirectionnelle (Shadow Cubemap)** dédiée au rendu volumétrique et surfacique, déclare-t-on et attache-t-on un **Color Attachment** supplémentaire en format flottant [`GL_R32F`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin#L168-L188) ? Cela est-il superflu ou structurellement indispensable ?

---

## 2. Analyse Géométrique & Mathématique : Planar NDC Depth vs Distance Radiale Euclidienne

```mermaid
flowchart LR
    subgraph Planar Depth (Depth-Only GL_DEPTH_COMPONENT)
        L1((Lumière)) -->|Z = p.z| P1[Plan de Projection Face Cubemap]
        P1 -.->|Distorsion cos theta dans les coins| C1[Coins déformés]
    end
    subgraph Radial Distance (Color Attachment GL_R32F)
        L2((Lumière)) -->|d = ||p - L|| / R| S2((Sphère d'Influence))
        S2 -.->|Isotropie sphérique parfaite 360°| C2[Zéro distorsion]
    end
```

### 2.1 Le Depth Buffer standard (`GL_DEPTH_COMPONENT32F`)
Pour chaque face du cubemap, le pipeline de rastérisation applique une projection perspective standard à $90^\circ$ (aspect $1.0$). La profondeur projetée stockée dans le Z-buffer est une valeur non-linéaire normalisée dans l'espace NDC :
$$Z_{\text{NDC}} = \frac{f + n}{f - n} + \frac{2 \cdot f \cdot n}{(f - n) \cdot z_{\text{eye}}}$$

Cette profondeur mesure la **distance orthogonale au plan de projection de la face**, et non la distance euclidienne radiale à la source lumineuse :
* Au centre de la face ($\theta = 0$) : $d = z_{\text{eye}}$.
* Dans les coins de la face ($\theta = 45^\circ$) : la distance réelle est $d = \frac{z_{\text{eye}}}{\cos\theta} = \sqrt{2} \cdot z_{\text{eye}} \approx 1.414 \cdot z_{\text{eye}}$.

Si l'on utilise un depth cubemap standard pour le raymarching volumétrique :
1. Chaque échantillon le long d'un rayon arbitraire nécessite de recalculer la déprojection perspective non-linéaire et de diviser par $\cos\theta$.
2. Cela génère des discontinuités et des artefacts de couture (seams) le long des 12 arêtes du cubemap où les plans de projection se rejoignent à $90^\circ$.

### 2.2 Le Color Attachment linéaire (`GL_R32F`)
En stockant la **distance radiale euclidienne normalisée** calculée analytiquement dans le fragment shader :
$$\text{LinearDepth} = \frac{\|\mathbf{p}_{\text{hit}} - \mathbf{p}_{\text{light}}\|}{R_{\text{light}}} = \frac{t}{R} \in [0.0, 1.0]$$

* La valeur est **intrinsèquement isotrope et sphérique**.
* Elle ne dépend d'aucun plan de projection ni de la face particulière du cubemap.
* La valeur lue est identique quelle que soit la direction 3D de consultation.

---

## 3. Rôle du Multiple Render Targets (MRT) dans [`shadow_cubemap.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin)

Dans [`shadow_cubemap_create_fbo_textures`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/shadow_cubemap.odin#L191-L210), le FBO est configuré avec 2 attachments :
```odin
gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_CUBE_MAP_POSITIVE_X, sc.depth_cubemap, 0)
gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_CUBE_MAP_POSITIVE_X, sc.linear_depth_cubemap, 0)
draw_bufs := [1]u32{gl.COLOR_ATTACHMENT0}
gl.DrawBuffers(1, &draw_bufs[0])
```

Le Fragment Shader [`shaders/shadow_cube.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/shadow_cube.frag#L3-L9) écrit simultanément dans les deux :
```glsl
layout(depth_greater) out float gl_FragDepth;
layout(location = 0) out float LinearDepth;

void main()
{
    vec3 rayDir = normalize(WorldPos - u_light_pos);
    float t;
    if (!intersectSphere(u_light_pos, rayDir, SphereCenter, SphereRadius, t)) {
        discard;
    }

    vec3 hitPos = u_light_pos + t * rayDir;

    // 1. Z-Buffer matériel : Utilisé pour le GL_DEPTH_TEST inter-objets
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    gl_FragDepth = clipPos.z / clipPos.w * 0.5 + 0.5;

    // 2. Linear Radial Distance : Utilisé pour le Raymarching volumétrique et le PBR
    LinearDepth = t / u_light_radius;
}
```

### Pourquoi conserver le `GL_DEPTH_ATTACHMENT` si on utilise `GL_R32F` ?
Si l'on supprimait le `GL_DEPTH_ATTACHMENT` :
1. Le test de profondeur matériel (`glEnable(GL_DEPTH_TEST)`) deviendrait inopérant.
2. Lorsque plusieurs sphères instanciées se projettent sur la même face du cubemap dans la même ligne de visée, l'ordre de tracé prévaudrait (le dernier objet rendu écraserait la valeur dans `GL_COLOR_ATTACHMENT0`, même s'il est plus éloigné).
3. `GL_DEPTH_ATTACHMENT` est donc le **garde-fou de visibilité** (Z-culling inter-géométries) pendant la rastérisation, tandis que `GL_COLOR_ATTACHMENT0` est le **support de stockage physique** de la distance exploité par les shaders consommateurs.

---

## 4. Comparatif Architectural : Filtrage Matériel & Performance

```mermaid
flowchart TD
    subgraph Solution A: Depth-Only (GL_DEPTH_COMPONENT)
        A1[Sampler samplerCubeShadow] --> A2[Comparaison matérielle binaire 0 / 1]
        A2 --> A3[❌ Impossible de lire la distance brute flottante avec lerp GL_LINEAR]
        A3 --> A4[❌ Déprojection trigonométrique requise dans chaque step de raymarch]
    end
    subgraph Solution B: MRT Color R32F + Depth (Notre architecture)
        B1[Sampler samplerCube sur texture R32F] --> B2[Filtrage trilinéaire matériel GL_LINEAR natif]
        B2 --> B3[✅ Lecture 1-tap directe de la distance radiale d in 0..1]
        B3 --> B4[✅ 0 division, 0 matrice, 0 trigonométrie dans la boucle interne]
    end
```

### 4.1 Filtrage Matériel (`GL_LINEAR`)
* **Sur `GL_DEPTH_COMPONENT`** : Le hardware OpenGL ne permet pas de filtrer linéairement la valeur brute flottante de profondeur. L'activation de `GL_LINEAR` sur une texture de profondeur active le mode de comparaison d'ombre PCF (`GL_COMPARE_REF_TO_TEXTURE`), renvoyant un pourcentage d'ombrage binaire et non une distance continue.
* **Sur `GL_R32F`** : Le GPU interpole nativement les distances flottantes en matériel (`GL_LINEAR`), ce qui produit un adoucissement naturel des transitions d'ombres volumétriques sans surcoût d'échantillonnage multi-tap.

### 4.2 Impact sur la Boucle Interne de Raymarching Volumétrique
Dans [`shaders/postfx/volumetric_raymarch.frag:148-156`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_raymarch.frag#L148-L156), le test d'occlusion est exécuté $N$ fois par pixel ($N \in [16..64]$) :

```glsl
// Solution B (Actuelle) : 1 seule instruction texture() directe ultra-rapide
vec3 light_to_sample = -light_dir;
float shadow_depth_norm = texture(u_shadow_cubemap, light_to_sample).r;
if (dist_light - u_shadow_bias > shadow_depth_norm * u_light_radius) {
    shadow_factor = 0.0;
}
```

Avec la Solution A (Depth-Only), cette boucle nécessiterait pour chaque pas :
* La reconstruction de la coordonnée de face active ($\pm X, \pm Y, \pm Z$).
* L'inversion de la projection perspective.
* Le calcul de correction de l'angle zénithal $\cos\theta$.
* Ce surcoût ALU multiplierait le temps GPU du raymarching par un facteur $\approx 1.8\times$ à $2.5\times$.

---

## 5. Synthèse & Pratiques de l'Industrie

| Critère | Depth-Only (`GL_DEPTH_COMPONENT`) | MRT : Depth + Color (`GL_R32F`) *(Notre implémentation)* |
| :--- | :---: | :---: |
| **Type de données** | $Z_{\text{NDC}}$ perspective planaire | Distance radiale euclidienne $t / R$ |
| **Isotropie sphérique 360°** | ❌ Biais angulaire $\cos\theta$ aux coins | ✅ Parfaite et continue sans artefacts de coins |
| **Filtrage matériel `GL_LINEAR`** | ❌ Non (uniquement PCF binaire) | ✅ Oui (adoucissement matériel natif) |
| **Coût Raymarching Shader** | ❌ Élevé (déprojection par step) | ✅ Optimal (1 lecture mémoire 1-tap directe) |
| **Gestion des occlusions géométriques** | ✅ Z-Buffer matériel natif | ✅ Z-Buffer matériel natif via MRT |
| **Usage Standard** | Ombres directionnelles / CSM 2D | **Point Lights, God Rays & Rendu Volumétrique** |

### Conclusion
La présence de `GL_COLOR_ATTACHMENT0` (`GL_R32F`) conjointement à `GL_DEPTH_ATTACHMENT` n'est pas un artefact superflu : c'est le design optimal et standardisé pour concilier **Z-culling matériel précis à la rastérisation** et **échantillonnage radial continu à haute performance pour le rendu volumétrique**.
