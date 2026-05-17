# Analyse comparative des idiomes Odin vs C11 / C++ / Python

> Date : 2026-05-17  
> Contexte : Port ISO de suckless-ogl (C11) vers Odin — suckless-odin

---

## Table des matières

1. [Système de types et déclarations](#1-système-de-types-et-déclarations)
2. [Structures et initialisation](#2-structures-et-initialisation)
3. [Enums et constantes](#3-enums-et-constantes)
4. [Gestion des erreurs](#4-gestion-des-erreurs-analyse-approfondie)
5. [Gestion mémoire](#5-gestion-mémoire)
6. [Fonctions et appels](#6-fonctions-et-appels)
7. [Boucles et itération](#7-boucles-et-itération)
8. [Interop C et FFI](#8-interop-c-et-ffi)
9. [Modules et visibilité](#9-modules-et-visibilité)
10. [Idiomes non encore exploités](#10-idiomes-non-encore-exploités)

---

## 1. Système de types et déclarations

### Constantes compile-time

```odin
// Odin : constante typée évaluée au compile-time
FONT_ATLAS_SIZE :: 512
DEFAULT_CAMERA_SPEED :: 15.0
```

```c
// C11 : macro préprocesseur (pas de type, pas de scope)
#define FONT_ATLAS_SIZE 512
// ou enum anonyme (limité aux entiers)
enum { FONT_ATLAS_SIZE = 512 };
// ou static const (occupe de la mémoire, pas constexpr)
static const float DEFAULT_CAMERA_SPEED = 15.0f;
```

```cpp
// C++ : constexpr (depuis C++11), vrai compile-time
constexpr int FONT_ATLAS_SIZE = 512;
constexpr float DEFAULT_CAMERA_SPEED = 15.0f;
```

```python
# Python : convention ALL_CAPS, aucune garantie d'immutabilité
FONT_ATLAS_SIZE = 512
DEFAULT_CAMERA_SPEED = 15.0
```

**Verdict Odin** : `::` combine la simplicité du `#define` C avec la sûreté de `constexpr` C++ — typé, scopé, sans overhead runtime.

---

### Alias de types

```odin
Vec3 :: glsl.vec3          // alias transparent
Mat4 :: glsl.mat4x4
```

```c
// C11 : typedef (pas de "vrai" alias, crée un type compatible)
typedef vec3 cglm_vec3;
```

```cpp
// C++ : using (depuis C++11), supporte les templates
using Vec3 = glm::vec3;
```

```python
# Python : simple assignation (alias = même objet)
Vec3 = glm.vec3
```

---

## 2. Structures et initialisation

```odin
Camera :: struct {
    position:    mt.Vec3,
    yaw:         f32,
    move_forward: bool,
}

// Instanciation : TOUT est zero-init par défaut
cam := Camera{}                        // position={0,0,0}, yaw=0, move_forward=false
cam2 := Camera{ yaw = -90.0 }         // named fields, reste à zéro
```

```c
// C11 : designated initializers (depuis C99)
typedef struct {
    vec3 position;
    float yaw;
    bool move_forward;
} Camera;

Camera cam = {0};                              // zero-init explicite
Camera cam2 = { .yaw = -90.0f };              // designated init
// ATTENTION : sans = {0}, les valeurs sont indéterminées !
```

```cpp
// C++ : constructeur ou aggregate init (C++20 pour designated)
struct Camera {
    glm::vec3 position{};     // value-init via {}
    float yaw = 0.0f;        // default member initializer (C++11)
    bool move_forward = false;
};

Camera cam{};                               // value-init
Camera cam2{ .yaw = -90.0f };              // designated (C++20 only)
```

```python
@dataclass
class Camera:
    position: Vec3 = field(default_factory=Vec3)
    yaw: float = 0.0
    move_forward: bool = False
```

**Verdict Odin** : Zero-init garanti sans effort. Pas de bug de "variable non initialisée" comme en C11. Pas besoin de constructeur comme en C++.

---

## 3. Enums et constantes

```odin
Overlay_Mode :: enum {
    Off = 0,
    FPS_Position,
    FPS_Position_Env,
}

// Usage : le type est inféré du contexte
overlay.mode = .Off

// Switch exhaustif (le compilateur prévient si un cas manque)
switch overlay.mode {
case .Off:             // ...
case .FPS_Position:    // ...
case .FPS_Position_Env: // ...
}
```

```c
// C11 : enum non scopé, pollue le namespace global
typedef enum {
    OVERLAY_OFF = 0,
    OVERLAY_FPS_POSITION,
    OVERLAY_FPS_POSITION_ENV,
} OverlayMode;

// Pas de vérification d'exhaustivité par le standard
switch (mode) {
case OVERLAY_OFF: break;
// oublier un cas = bug silencieux (sauf -Wswitch avec gcc/clang)
}
```

```cpp
// C++ : enum class (C++11), scopé et typé
enum class OverlayMode {
    Off = 0,
    FPS_Position,
    FPS_Position_Env,
};

// Usage : préfixe obligatoire
overlay.mode = OverlayMode::Off;
```

```python
from enum import Enum

class OverlayMode(Enum):
    OFF = 0
    FPS_POSITION = 1
    FPS_POSITION_ENV = 2

# match/case (Python 3.10+)
match mode:
    case OverlayMode.OFF: ...
```

**Verdict Odin** : Le `.Off` sans préfixe (quand le type est déduit) combine l'ergonomie du C avec la sûreté du `enum class` C++.

---

## 4. Gestion des erreurs (analyse approfondie)

C'est la différence **la plus fondamentale** entre Odin et les autres langages.

### Philosophie Odin

Odin rejette explicitement les exceptions (comme C, contrairement à C++/Python). Mais contrairement à C11, il fournit des **mécanismes ergonomiques** pour gérer les erreurs via les valeurs de retour :

1. **Retours multiples** — pas besoin de pointeur out ou de variable globale (`errno`)
2. **`or_return`** — propagation automatique sans boilerplate
3. **`or_else`** — valeur par défaut en cas d'erreur
4. **Pas d'exceptions** — le flow de contrôle est toujours explicite et local

---

### Pattern 1 : Retours multiples `(result, ok)`

```odin
// Déclaration : le dernier retour est conventionnellement le succès/erreur
texture_hdr_load :: proc(path: cstring) -> (tex: Texture_HDR, ok: bool) {
    data := stbi.loadf(path, &w, &h, &channels, 4)
    if data == nil {
        log.log_error("texture", "Failed to load HDR: %s", path)
        return tex, false   // tex est zero-init, ok=false
    }
    defer stbi.image_free(data)

    // ... setup texture ...
    return tex, true
}

// Appel : destructuring obligatoire (impossible d'ignorer l'erreur par accident)
tex, ok := texture_hdr_load("env.hdr")
if !ok {
    // gérer l'erreur
}
```

Équivalent C11 :
```c
// C11 : pointeur out + return code (3 patterns en compétition dans un même projet)
// Pattern 1 : return bool, résultat via pointeur
bool texture_hdr_load(const char* path, Texture_HDR* out_tex) {
    float* data = stbi_loadf(path, &w, &h, &channels, 4);
    if (!data) {
        LOG_ERROR("texture", "Failed to load HDR: %s", path);
        return false;
    }
    // ...
    *out_tex = tex;
    return true;
}

// Pattern 2 : return pointeur (NULL = erreur)
Texture_HDR* texture_hdr_load(const char* path);

// Pattern 3 : return int (0 = succès, négatif = erreur)
int texture_hdr_load(const char* path, Texture_HDR* out_tex);

// Problème : RIEN n'empêche d'ignorer le retour
texture_hdr_load("env.hdr", &tex);  // return value ignorée = bug silencieux
```

Équivalent C++ :
```cpp
// C++ : exceptions (approche dominante)
Texture_HDR texture_hdr_load(const std::string& path) {
    float* data = stbi_loadf(path.c_str(), &w, &h, &channels, 4);
    if (!data) {
        throw std::runtime_error("Failed to load HDR: " + path);
    }
    // ...
    return tex;
}

// Appel : si on oublie try/catch, l'exception se propage silencieusement
try {
    auto tex = texture_hdr_load("env.hdr");
} catch (const std::exception& e) {
    // ...
}

// Problème : le flow de contrôle est INVISIBLE au call site.
// Aucune indication dans la signature que ça peut throw.
// (noexcept existe mais n'est pas vérifié par le compilateur pour les appelants)
```

Ou avec `std::optional`/`std::expected` (C++23) :
```cpp
// C++23 : std::expected (se rapproche d'Odin)
std::expected<Texture_HDR, std::string> texture_hdr_load(const std::string& path);

auto result = texture_hdr_load("env.hdr");
if (!result) {
    // result.error() contient le message
}
```

Équivalent Python :
```python
# Python : exceptions partout (EAFP = "Easier to Ask Forgiveness than Permission")
def texture_hdr_load(path: str) -> TextureHDR:
    data = stbi.loadf(path)
    if data is None:
        raise IOError(f"Failed to load HDR: {path}")
    return tex

# Appel : try/except optionnel — l'exception se propage sinon
try:
    tex = texture_hdr_load("env.hdr")
except IOError as e:
    ...
```

---

### Pattern 2 : `or_return` — propagation sans boilerplate

C'est **l'innovation clé** d'Odin pour la gestion d'erreurs.

```odin
// Fonction qui peut échouer (retourne ..., bool)
ibl_create :: proc(ibl: ^IBL_Resources, env_tex: u32) -> bool {
    // or_return : si load_compute_shader retourne (_, false),
    //            propage immédiatement le `false` au retour de ibl_create
    ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl") or_return
    ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl") or_return
    ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl") or_return

    // Si on arrive ici, les 3 shaders sont chargés avec succès
    return true
}
```

Ce que `or_return` remplace en C11 :
```c
// C11 : cascade de if/goto (le fameux "pyramid of doom")
bool ibl_create(IBL_Resources* ibl, GLuint env_tex) {
    ibl->irmap_program = load_compute_shader("shaders/IBL/irmap.glsl");
    if (ibl->irmap_program == 0) return false;

    ibl->spmap_program = load_compute_shader("shaders/IBL/spmap.glsl");
    if (ibl->spmap_program == 0) return false;

    ibl->spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl");
    if (ibl->spbrdf_program == 0) return false;

    return true;
}
// Ou pire avec goto cleanup pour libérer les ressources partielles
```

Ce que `or_return` remplace en C++ :
```cpp
// C++ : exceptions (flow implicite) — si load_compute_shader throw,
// on sort automatiquement... mais SANS cleanup des shaders déjà chargés !
void ibl_create(IBL_Resources& ibl, GLuint env_tex) {
    ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl");  // throws?
    ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl");  // throws?
    ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl"); // throws?
}
// Le problème : si spmap throw, irmap est leaked. Il faut un RAII wrapper.
```

Ce que `or_return` remplace en Python :
```python
# Python : les exceptions propagent naturellement (mais invisiblement)
def ibl_create(ibl, env_tex):
    ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl")
    ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl")
    ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl")
# Si load_compute_shader raise, on sort. Simple mais :
# - Aucune indication au call site que ça peut fail
# - Le caller doit "deviner" quelles exceptions sont possibles
```

---

### Pattern 3 : `or_else` — valeur par défaut en cas d'échec

```odin
// Si parse_int échoue, utiliser 1280 par défaut
width := strconv.parse_int(arg) or_else 1280
```

Équivalents :
```c
// C11 : variable temporaire + ternaire
int width;
int parsed;
if (parse_int(arg, &parsed)) {
    width = parsed;
} else {
    width = 1280;
}
```

```cpp
// C++ avec std::optional (C++17)
auto width = parse_int(arg).value_or(1280);
```

```python
# Python : try/except ou walrus operator
try:
    width = int(arg)
except ValueError:
    width = 1280
```

---

### Pattern 4 : `defer` + erreur — cleanup sans RAII ni exceptions

```odin
overlay_create :: proc(overlay: ^Text_Overlay) -> bool {
    // Charge le fichier font
    font_data, font_err := os.read_entire_file_from_path("assets/fonts/FiraCode-Regular.ttf", context.allocator)
    if font_err != nil {
        return false
    }
    defer delete(font_data)  // GARANTI exécuté à la sortie, succès OU échec

    // Bake font atlas — si ça échoue, font_data est quand même libéré
    result := stbtt.BakeFontBitmap(...)
    if result <= 0 {
        return false   // defer delete(font_data) s'exécute ici
    }

    // ... suite du setup ...
    return true        // defer delete(font_data) s'exécute ici aussi
}
```

Équivalent C11 :
```c
// C11 : goto cleanup (le seul pattern fiable)
bool overlay_create(Text_Overlay* overlay) {
    unsigned char* font_data = NULL;
    size_t font_size;

    font_data = read_file("assets/fonts/FiraCode-Regular.ttf", &font_size);
    if (!font_data) return false;

    int result = stbtt_BakeFontBitmap(font_data, ...);
    if (result <= 0) {
        goto cleanup;  // il faut se rappeler de libérer font_data
    }

    // ... suite ...
    free(font_data);
    return true;

cleanup:
    free(font_data);
    return false;
}
```

Équivalent C++ :
```cpp
// C++ : RAII (std::unique_ptr ou std::vector prend le ownership)
bool overlay_create(Text_Overlay& overlay) {
    auto font_data = read_file("assets/fonts/FiraCode-Regular.ttf");
    // Le destructeur de font_data libère à la sortie du scope

    if (stbtt_BakeFontBitmap(font_data.data(), ...) <= 0) {
        return false;  // ~font_data() appelé automatiquement
    }
    return true;
}
// Problème : chaque ressource nécessite un wrapper RAII dédié
```

Équivalent Python :
```python
# Python : context manager ou garbage collector
def overlay_create(overlay):
    with open("assets/fonts/FiraCode-Regular.ttf", "rb") as f:
        font_data = f.read()

    # font_data sera GC'd éventuellement (timing non déterministe)
    result = stbtt_bake(font_data, ...)
    if result <= 0:
        return False
    return True
```

---

### Tableau récapitulatif : gestion d'erreurs

| Critère | C11 | C++ | Python | **Odin** |
|---------|-----|-----|--------|----------|
| Mécanisme principal | return code + `errno` | exceptions (`throw`/`catch`) | exceptions (`raise`/`except`) | **retours multiples** |
| Propagation | manuelle (if/goto) | automatique (stack unwinding) | automatique | **`or_return` (explicite, 1 mot)** |
| Visibilité au call site | partielle (signature) | aucune (sauf `noexcept`) | aucune | **totale (signature + `or_return`)** |
| Oubli de gestion | facile (return ignoré) | implicitement OK | implicitement OK | **impossible** (unused value = erreur) |
| Cleanup | `goto cleanup` / discipline | RAII destructeurs | `with`/GC | **`defer`** |
| Coût runtime | nul | stack unwinding (lourd) | traceback (très lourd) | **nul** (juste des branches) |
| Composabilité | faible | bonne (chaining throws) | bonne | **bonne (`or_return` chaîne)** |

---

### Pourquoi Odin > C11 pour les erreurs

1. **Impossible d'ignorer un retour d'erreur** — Le compilateur refuse de discard un retour multiple sans l'assigner
2. **`or_return` élimine 80% du boilerplate** — Pas de pyramide de `if (!ok) return false;`
3. **`defer` rend le cleanup local** — Pas de spaghetti `goto cleanup` avec 5 labels
4. **Named returns** — Le retour peut être documenté dans la signature : `-> (program: u32, ok: bool)`

### Pourquoi Odin > C++ pour les erreurs

1. **Pas de stack unwinding** — Zero overhead, pas de tables d'exception dans le binaire
2. **Flow de contrôle visible** — Chaque point de sortie est explicite dans le code
3. **Pas besoin de RAII wrappers** — `defer` est universel, pas besoin d'écrire une classe par ressource
4. **Pas de `noexcept` puzzle** — Tout est noexcept par construction

### Pourquoi Odin > Python pour les erreurs

1. **Performance** — Pas de traceback, pas d'allocation d'objets exception
2. **Typage statique** — L'erreur est dans la signature, pas cachée dans la doc
3. **Déterministe** — `defer` s'exécute immédiatement à la sortie du scope (pas "un jour quand le GC passe")

---

## 5. Gestion mémoire

### `defer` — le couteau suisse du cleanup

```odin
data := stbi.loadf(path, &w, &h, &channels, 4)
defer stbi.image_free(data)
// ... utilisation ...
// image_free() appelé automatiquement en sortie
```

### Allocators contextuels

```odin
// L'allocator est passé implicitement via le "context"
font_data, _ := os.read_entire_file_from_path(path, context.allocator)

// Temp allocator : reset chaque frame, pas de free nécessaire
line := fmt.tprintf("FPS: %.1f", fps)  // allocation temporaire, auto-libérée
```

| | C11 | C++ | Python | Odin |
|---|---|---|---|---|
| Allocation | `malloc`/`free` | `new`/`delete`, RAII | GC automatique | `new`/`free` + allocators |
| Cleanup | `goto cleanup` | destructeur (RAII) | `with`/GC | `defer` |
| Temp allocs | `alloca` (stack, dangereux) | stack arrays | — | `context.temp_allocator` |
| Custom allocators | `void*` partout | `std::pmr` (C++17) | — | `context.allocator` (implicite) |

---

## 6. Fonctions et appels

### Déclaration

```odin
// Odin : nom :: proc(params) -> retour { }
overlay_create :: proc(overlay: ^Text_Overlay) -> bool { ... }
```

```c
// C11 : type nom(params)
bool overlay_create(Text_Overlay* overlay) { ... }
```

```cpp
// C++ : type nom(params) (+ const, noexcept, virtual, override...)
bool overlay_create(Text_Overlay& overlay) noexcept { ... }
```

### Variadic forwarding

```odin
log_info :: proc(tag: string, format: string, args: ..any) {
    log_message(.Info, tag, format, ..args)  // forwarding avec ..args
}
```

```c
// C11 : va_list (unsafe, pas de type checking)
void log_info(const char* tag, const char* format, ...) {
    va_list args;
    va_start(args, format);
    log_message_v(LOG_INFO, tag, format, args);
    va_end(args);
}
```

```cpp
// C++ : variadic templates (type-safe mais verbeux)
template<typename... Args>
void log_info(const char* tag, const char* format, Args&&... args) {
    log_message(LogLevel::Info, tag, format, std::forward<Args>(args)...);
}
```

```python
def log_info(tag: str, format: str, *args):
    log_message(LogLevel.INFO, tag, format, *args)
```

### `#type` — pointeur de fonction typé

```odin
Log_Callback :: #type proc(level: Log_Level, tag: string, message: string)
```

```c
// C11 : typedef de pointeur de fonction (syntaxe notoirement horrible)
typedef void (*Log_Callback)(LogLevel level, const char* tag, const char* message);
```

```cpp
// C++ : using + std::function (overhead runtime pour std::function)
using Log_Callback = void(*)(LogLevel, const char*, const char*);
// ou
using Log_Callback = std::function<void(LogLevel, std::string_view, std::string_view)>;
```

---

## 7. Boucles et itération

Odin a **un seul mot-clé** `for` qui remplace `for`, `while`, et `do-while` :

```odin
// Boucle conditionnelle (= while en C/Python)
for app.running && !glfw.WindowShouldClose(window) {
    // ...
}

// Range exclusif (= for i in range(n) en Python)
for i in 0..<total_count {
    // ...
}

// Range inclusif
for i in 0..=10 {  // 0, 1, 2, ..., 10
}

// Itération sur string (rune par rune)
for ch in text {
    // ch est de type rune (Unicode codepoint)
}

// Itération avec index
for elem, idx in slice {
    // elem = valeur, idx = index
}

// Boucle infinie (= while True / for(;;))
for {
    if done { break }
}
```

| Pattern | C11 | C++ | Python | Odin |
|---------|-----|-----|--------|------|
| Condition | `while (x)` | `while (x)` | `while x:` | `for x { }` |
| Compteur | `for(i=0;i<n;i++)` | `for(auto i=0;i<n;++i)` | `for i in range(n)` | `for i in 0..<n` |
| Foreach | — | `for(auto& x : vec)` | `for x in list` | `for x in slice` |
| Infini | `while(1)` / `for(;;)` | `while(true)` | `while True:` | `for { }` |

---

## 8. Interop C et FFI

```odin
// Calling convention C pour les callbacks GLFW
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    // CRITIQUE : restaurer le context Odin (allocator, temp_allocator, logger)
    context = runtime.default_context()
    // Maintenant on peut appeler du code Odin normal
    scene.scene_toggle_overlay(&app.scene)
}
```

```c
// C11 : natif, pas de conversion nécessaire
void key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
    // directement du code C
}
```

```cpp
// C++ : extern "C" pour le linkage
extern "C" void key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
    // pas de classes/templates/exceptions ici
}
```

```python
# Python : ctypes ou cffi (lourd)
@CFUNCTYPE(None, POINTER(GLFWwindow), c_int, c_int, c_int, c_int)
def key_callback(window, key, scancode, action, mods):
    ...
```

**Point critique Odin** : Le `context = runtime.default_context()` est **obligatoire** dans tout callback `proc "c"`. Sans ça, toute utilisation d'`fmt`, d'allocations, ou de `defer` provoque un crash (nil allocator).

---

## 9. Modules et visibilité

```odin
package rendering              // Déclaration du package

import gl "vendor:OpenGL"      // Import avec alias
import log "../core/log"       // Import relatif
import types "./types"         // Sous-package local

@(private)                     // Privé au package (non exporté)
ortho_matrix :: proc(...) { }

@(private="file")              // Privé au fichier uniquement
g_internal_state: int
```

| Concept | C11 | C++ | Python | Odin |
|---------|-----|-----|--------|------|
| Module | fichier `.c` + `.h` | namespace / header | module / `__init__.py` | `package` |
| Privé | `static` | `private:` | `_prefix` | `@(private)` |
| Export | dans le `.h` | `public:` | tout sauf `_` | tout sauf `@(private)` |
| Alias import | — | `namespace x = ...` | `import x as y` | `import y "path"` |

**Gain Odin** : Pas de dualité header/implementation. Un seul fichier = déclaration + implémentation. Plusieurs fichiers peuvent partager le même `package`.

---

## 10. Idiomes non encore exploités

### `distinct` — types opaques pour la sûreté

```odin
// Empêche de mélanger des IDs de textures avec des IDs de programs
Texture_ID :: distinct u32
Program_ID :: distinct u32

tex: Texture_ID = 5
prog: Program_ID = tex  // ERREUR DE COMPILATION — types incompatibles
```

Équivalent approximatif :
- **C11** : impossible (tous les `GLuint` sont interchangeables)
- **C++** : `enum class Texture_ID : uint32_t {};` ou wrapper struct
- **Python** : `NewType("Texture_ID", int)` (mypy seulement, pas runtime)

### `union` / tagged union — sum types

```odin
Render_Command :: union {
    Draw_Opaque,
    Draw_Transparent,
    Draw_Overlay,
}

// Pattern matching
switch cmd in render_command {
case Draw_Opaque:      // cmd est typé Draw_Opaque ici
case Draw_Transparent: // cmd est typé Draw_Transparent ici
case Draw_Overlay:     // ...
}
```

### `bit_set` — flags sans masques manuels

```odin
Feature_Flag :: enum {
    HDR,
    IBL,
    Overlay,
    Fullscreen,
}

Features :: bit_set[Feature_Flag]

active: Features = {.HDR, .IBL}
if .Overlay in active { ... }
active += {.Overlay}   // activer
active -= {.HDR}       // désactiver
```

Vs C11 : `#define FLAG_HDR (1<<0)` + `flags |= FLAG_HDR` + `if (flags & FLAG_HDR)`

### `#soa` — struct-of-arrays automatique

```odin
// Transforme automatiquement un tableau de structs en struct de tableaux
// pour une meilleure cache locality (SIMD-friendly)
#soa instances: [100]Sphere_Instance
// instances.model est un [100]Mat4 contigu en mémoire
// instances.albedo est un [100]Vec3 contigu en mémoire
```

### `when` — compilation conditionnelle (remplace `#ifdef`)

```odin
when ODIN_OS == .Linux {
    import "core:sys/linux"
    get_pid :: proc() -> int { return int(linux.getpid()) }
} else when ODIN_OS == .Windows {
    get_pid :: proc() -> int { return int(windows.GetCurrentProcessId()) }
}
```

---

## Conclusion

| Force | C11 | C++ | Python | **Odin** |
|-------|-----|-----|--------|----------|
| Simplicité | ★★★ | ★ | ★★★★ | ★★★★ |
| Sûreté typage | ★★ | ★★★★ | ★★ | ★★★★★ |
| Gestion erreurs | ★ | ★★★ | ★★★ | ★★★★★ |
| Performance | ★★★★★ | ★★★★★ | ★★ | ★★★★★ |
| Interop C | ★★★★★ | ★★★★ | ★★ | ★★★★★ |
| Métaprogrammation | ★ (macros) | ★★★★★ | ★★★ | ★★★ |

Odin se positionne comme un **"meilleur C"** : performances C, ergonomie proche de Python pour la gestion d'erreurs, et sûreté de typage comparable à C++ mais sans la complexité (pas de templates, pas d'héritage, pas d'exceptions, pas de move semantics).
