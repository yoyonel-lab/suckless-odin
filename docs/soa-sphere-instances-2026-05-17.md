# `#soa` — Struct-of-Arrays pour les instances de sphères

> Date : 2026-05-17  
> Fichier impacté : `src/rendering/instanced.odin`  
> Struct concernée : `types.Sphere_Instance`

---

## Problème

Chaque `Sphere_Instance` fait 128 bytes (#align(64), Mat4 + Vec3 + 3×f32 + padding + Vec3 + padding to 128B). En layout AoS (Array of Structs), itérer un seul champ (ex: positions pour le culling) charge 128 bytes par sphère dans le cache (2 cache lines), dont seuls 12 sont utiles.

```
AoS : [model₀|albedo₀|metal₀|rough₀|ao₀|pad₀|prev₀|pad] [model₁|albedo₁|...] ...
       └──────────────── 128 bytes, 2 cache lines ────────────────┘
```

Pour 100 sphères, itérer les positions = 12800 bytes chargés, 1200 utiles → **9% d'efficacité cache**.

---

## Solution : `#soa`

Odin fournit `#soa` comme directive de layout mémoire sur les tableaux. Elle transforme automatiquement un AoS en SoA sans changer l'API d'accès :

```odin
// Avant (AoS) :
instances: [dynamic]types.Sphere_Instance

// Après (SoA) :
instances: #soa [dynamic]types.Sphere_Instance
```

Layout mémoire résultant :

```
SoA : [model₀|model₁|...|model₉₉]  [albedo₀|...|albedo₉₉]  [metal₀|...]  ...
       └── contiguous per field ──┘
```

---

## Accès aux données

### Accès indexé (identique à avant)

```odin
// Lecture d'une instance complète (gather implicite depuis les champs séparés)
sphere := inst.instances[i]

// Écriture d'une instance complète (scatter vers les champs)
inst.instances[i] = types.Sphere_Instance{ model = m, albedo = a, ... }
```

### Accès par champ-slice (nouveau, SoA-only)

```odin
// Slice contiguë de TOUS les modèles — parfait pour itération batch
models := inst.instances.model[:]         // []Mat4, contiguous
prev_centers := inst.instances.prev_center[:]  // []Vec3, contiguous

// Itération cache-friendly : seuls model et prev_center sont touchés
for i in 0..<count {
    prev_centers[i] = {models[i][3][0], models[i][3][1], models[i][3][2]}
}
```

---

## Contrainte GPU : pack SoA → AoS à l'upload

Le SSBO GPU attend un layout AoS (le GLSL `struct` est par-instance). On pack au moment de l'upload :

```odin
instanced_upload :: proc(inst: ^Instanced_Spheres) {
    count := int(inst.count)
    // Pack SoA → AoS via temp_allocator (pas de leak, auto-freed)
    gpu_data := make([]types.Sphere_Instance, count, context.temp_allocator)
    for i in 0..<count {
        gpu_data[i] = inst.instances[i]  // gather depuis SoA
    }
    gl.BufferData(gl.SHADER_STORAGE_BUFFER, count * size_of(types.Sphere_Instance),
                  raw_data(gpu_data), gl.DYNAMIC_DRAW)
}
```

Ce coût (100 × 128 bytes = 12.5 KB memcpy) est négligeable vs le gain sur les itérations CPU répétées.

---

## Cas d'usage bénéficiant du SoA

| Opération | Champs itérés | Gain cache |
|-----------|--------------|------------|
| Frustum culling | `model[3]` (position) | 100% vs 19% |
| Motion blur prep | `model` + `prev_center` | ~50% vs 19% |
| Material animation | `roughness` ou `metallic` seul | 100% vs 6% |
| Distance sort (transparence) | `model[3]` (position) | 100% vs 19% |
| Physics/N-body | `model` + `prev_center` | ~50% vs 19% |

---

## Comparaison avec C11 et C++

### C11

Pas d'équivalent natif. Il faut manuellement déclarer des tableaux séparés :

```c
typedef struct {
    Mat4  models[MAX_SPHERES];
    Vec3  albedos[MAX_SPHERES];
    float metallics[MAX_SPHERES];
    // ... répéter pour chaque champ
} Spheres_SoA;
```

Maintenance lourde : tout ajout de champ nécessite de modifier la struct SoA ET toutes les fonctions d'accès.

### C++

Pas de support natif. Solutions :

- Bibliothèques comme `entt::basic_storage` (ECS)
- `std::tuple<std::vector<Mat4>, std::vector<Vec3>, ...>` (illisible)
- Codegen / macros (fragile)

### Odin

```odin
instances: #soa [dynamic]types.Sphere_Instance
```

**Une seule ligne**. La struct source reste inchangée. L'accès indexé reste identique. Les field-slices sont gratuits.

---

## Allocation

```odin
// Création : même API que [dynamic], le compilateur gère le layout
inst.instances = make(#soa [dynamic]types.Sphere_Instance, total_count)

// Destruction : même API
delete(inst.instances)
```

Le `make` alloue N buffers séparés (un par champ) en interne. `delete` les libère tous.

---

## Limitations

1. **Pas de `raw_data()` direct vers GPU** — Le layout SoA n'est pas compatible avec le GLSL struct layout, d'où le pack explicite
2. **Overhead mémoire** — Chaque champ a son propre allocation header (négligeable pour N > 10)
3. **Pas de SIMD auto-vectorization garanti** — Le compilateur Odin n'auto-vectorise pas encore les boucles SoA (contrairement à `ispc`), mais le gain cache est déjà significatif
