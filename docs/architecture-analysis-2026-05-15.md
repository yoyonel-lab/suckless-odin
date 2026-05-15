# Analyse architecturale — suckless-odin

**Date :** 2026-05-15
**Auteur :** Analyse automatisée (GitHub Copilot)
**État du port :** 17 fichiers Odin, 9 shaders, pipeline PBR/IBL/Skybox fonctionnel

---

## Glossaire

- **Module** — tout ce qui a une interface et une implémentation (fichier, struct + procs, package).
- **Interface** — tout ce qu'un appelant doit connaître pour utiliser le module : types, invariants, erreurs, config.
- **Profondeur** — levier à l'interface : beaucoup de comportement derrière une petite interface. **Profond** = fort levier. **Peu profond** = interface presque aussi complexe que l'implémentation.
- **Couture** (seam) — l'endroit où vit une interface ; un point où le comportement peut être modifié sans éditer en place.
- **Localité** — ce que les mainteneurs gagnent de la profondeur : changements, bugs et connaissances concentrés en un seul endroit.
- **Levier** — ce que les appelants gagnent de la profondeur.
- **Test de suppression** — imaginer la suppression du module : si la complexité disparaît, c'était un passe-plat. Si elle réapparaît chez N appelants, le module méritait sa place.

---

## Opportunité 1 — `app/app.odin` : l'input comme passe-plat, pas comme module

### Fichiers concernés

`src/app/app.odin`

### Problème

La gestion des entrées vit comme des callbacks privés dans `app.odin`, accédant directement aux champs de `app.scene.camera` (`move_forward`, `yaw_target`, etc.). Aujourd'hui il y a 3 handlers de touches (Escape, F, WASD) ; le document de portage en annonce 67. Chaque nouveau binding nécessitera de modifier `key_callback` et `process_keyboard` — deux procs qui brisent déjà l'encapsulation de `Scene` et `Camera` en manipulant des champs à travers deux niveaux d'indirection (`app.scene.camera.move_forward`). Il n'y a aucune couture entre « un événement input s'est produit » et « l'application réagit ».

Le C legacy avait `AppInputContext`, `PostProcessInputContext`, `camera_input.c` — trois modules séparés derrière la couture input. Le port Odin en a zéro.

### Test de suppression

Si on supprimait `key_callback` et `process_keyboard`, la complexité ne disparaîtrait pas — elle réapparaîtrait, exactement aussi complexe, dans ce qui les remplacerait. Ce sont des passe-plats : ils n'ajoutent aucun levier. Le vrai travail est « associer touche → action » et « dispatcher l'action vers le bon sous-système ».

### Solution proposée

Extraire un module **Input** qui possède le mapping touche→action (un registre de bindings) et dispatche les actions via l'`App` vers le bon sous-système. `key_callback` devient un trampoline de 3 lignes : récupérer le pointeur App, appeler `input.handle_key(app, key, action, mods)`. Les touches continues (WASD) passent par `input.poll_continuous(app)`. Le module Input détient le registre ; chaque sous-système déclare les actions qu'il accepte.

### Bénéfices

- **Localité** — ajouter un keybinding = une entrée dans le registre + un handler dans le sous-système cible, pas une modification d'un switch/case dans `app.odin`.
- **Levier** — le module Input absorbe la description des bindings, la gestion des modifieurs, la sémantique toggle/cycle/action, le futur mapping gamepad, et les données du help overlay F2 — le tout derrière une seule interface.
- **Testabilité** — on peut tester « touche F déclenche fullscreen » sans fenêtre GLFW.

---

## Opportunité 2 — `scene/scene.odin` : god struct sans couture entre scene graph et passe de rendu

### Fichiers concernés

`src/scene/scene.odin`

### Problème

`Scene` possède 11 champs couvrant 4 préoccupations : état caméra, ressources GPU (programme shader, locations d'uniforms), géométrie (billboard, sphères, matériaux), et environnement (skybox, texture HDR, IBL). `scene_render` appelle directement `gl.UseProgram`, `gl.UniformMatrix4fv`, `gl.Uniform3fv` — c'est à la fois le « quoi » (quels objets, quelle caméra) et le « comment » (quels appels GL, quels slots d'uniforms).

Ajouter le post-processing signifie ajouter un FBO, une seconde passe de rendu, et plus d'état — tout dans cette struct unique. Ajouter le cycling d'environnements signifie ajouter l'état env_manager. Chaque nouvelle feature élargit `Scene` davantage.

### Test de suppression

Supprimer `Scene` disperserait la gestion de la caméra, du shader, de l'IBL, du billboard, de l'instanciation, de la skybox et des matériaux partout. Il *mérite* sa place en tant que compositeur. Mais son interface (11 champs, 4 procs) est presque aussi complexe que son implémentation — il est **peu profond**. La profondeur est dans les sous-systèmes qu'il appelle, pas dans `Scene` lui-même.

### Solution proposée

Séparer en deux modules avec une couture entre eux :
- **Scene** — possède le *quoi* : caméra, instances de sphères, matériaux, référence d'environnement.
- **Renderer** — possède le *comment* : programmes shader, cache d'uniforms, dispatch des draw calls, future chaîne FBO/post-process.

`Scene` appelle `renderer.draw(view, proj, cam_pos, &spheres, &ibl, &skybox)`. Le Renderer devient le foyer naturel pour le pipeline de post-processing, les FBOs MRT, et la visualisation debug — sans toucher à Scene.

### Bénéfices

- **Localité** — post-processing, modes debug, wireframe atterrissent tous dans Renderer sans toucher Scene.
- **Levier** — Renderer peut être testé avec une scène factice (fausses sphères, pas de HDR) et un vrai contexte GL, ou vice versa.
- **Clarté** — la couture clarifie où le cycling d'environnements appartient (Scene gère quel HDR est actif ; Renderer reçoit juste l'ID de texture).

---

## Opportunité 3 — `rendering/` : six fichiers dans un package plat, aucune frontière de module

### Fichiers concernés

Les 6 fichiers dans `src/rendering/` : `billboard.odin`, `instanced.odin`, `skybox.odin`, `ibl.odin`, `texture.odin`, `material.odin`

### Problème

Tous sont `package rendering`. Ils partagent un namespace mais ont zéro couplage entre eux — `ibl.odin` n'importe pas `material.odin`, `skybox.odin` n'importe pas `billboard.odin`. Le package plat signifie que tout futur fichier dans `rendering/` peut accéder aux internals de n'importe quel autre (les packages Odin n'ont pas de visibilité fichier-privée, seulement package-privée). Plus important, `scene.odin` doit `import "../rendering"` et préfixer chaque appel avec `rendering.` — 24 fois dans le fichier. Il n'y a aucun moyen d'importer *seulement* ce dont on a besoin.

### Test de suppression

Supprimer la frontière du package et transformer chacun en son propre package ne changerait rien pour les implémentations — elles sont déjà indépendantes. Cela *ajouterait* de la clarté : `scene.odin` importerait `ibl`, `skybox`, `instanced` explicitement, et l'interface de chaque module serait autonome.

### Solution proposée

Promouvoir chacun en sous-package : `rendering/ibl/`, `rendering/skybox/`, `rendering/instanced/`, `rendering/billboard/`, `rendering/texture/`, `rendering/material/`. Les types partagés (`Sphere_Instance`, `AA_Mode`) restent dans `rendering/types/` (existe déjà). Chaque sous-package obtient une interface propre : une struct + les procs create/destroy/bind/draw.

### Bénéfices

- **Localité** — les changements au dispatch compute IBL ne peuvent pas accidentellement affecter la géométrie billboard, même au niveau package.
- **Levier** — chaque sous-package devient testable indépendamment (créer, dispatcher, vérifier la texture de sortie).
- **Imports explicites** — `import ibl "rendering/ibl"` au lieu du monolithique `import rendering`.

---

## Opportunité 4 — `scene_update` : logique physique caméra fuitée dans Scene

### Fichiers concernés

`src/scene/scene.odin` (lignes 118–140), `src/camera/camera.odin`

### Problème

`scene_update` exécute manuellement la boucle physique de la caméra : incrémente `physics_accumulator`, appelle `fixed_update` en boucle, interpole `yaw`/`pitch` vers leurs cibles, clamp le pitch, et appelle `update_vectors`. Ce sont ~25 lignes d'internals caméra que `Scene` n'a aucune raison de connaître. Le module `Camera` a déjà `update()` qui fait une partie de ce travail — mais pas tout, car `scene_update` fait une partie du travail *en dehors* du module Camera. L'interface est coupée en deux : une partie de la logique de mise à jour caméra dans `camera.update()`, l'autre dans `scene_update()`.

### Test de suppression

Si on supprimait le code caméra de `scene_update` et qu'on le déplaçait dans `camera.update(cam, dt)`, Scene se réduirait à `cam.update(&s.camera, dt)` — une seule ligne. La complexité se concentre dans Camera, qui possède déjà le modèle physique.

### Solution proposée

Replier toute la logique caméra de `scene_update` dans `camera.update(cam, dt)`. Scene appelle une seule proc.

### Bénéfices

- **Localité** — toute la physique caméra dans un seul fichier.
- **Levier** — `camera.update(dt)` devient une interface complète et testable.
- **Fin du cerveau coupé** — plus de partage de responsabilité entre ce que Scene fait à la caméra et ce que Camera fait à elle-même.

---

## Opportunité 5 — Chargement de shaders dupliqué entre `scene.odin` et `rendering/shader/shader.odin`

### Fichiers concernés

`src/scene/scene.odin` (`load_shader`, `read_shader_file`), `src/rendering/shader/shader.odin`

### Problème

`scene.odin` a ses propres procs `load_shader` et `read_shader_file` (privées, ~40 lignes), tandis que `rendering/shader/shader.odin` possède une struct `Shader` complète avec `load`, `compile`, `use`, `set_*`, cache d'uniforms. Scene n'utilise pas le module `Shader` — il en duplique une version simplifiée. Deux chemins de chargement de shaders = deux endroits à maintenir pour les includes `@header`, la gestion d'erreur, et le futur hot-reload.

### Solution proposée

Scene devrait utiliser `rendering/shader/shader.odin` au lieu de rouler sa propre version. Supprimer les `load_shader`/`read_shader_file` privées de `scene.odin`.

### Bénéfices

- **Localité** — un seul chemin de chargement de shaders.
- **Levier** — le hot-reload (touche R) peut être implémenté une seule fois, dans le module Shader, et Scene l'obtient gratuitement.
- **Moins de code** — ~40 lignes supprimées de `scene.odin`.

---

## Matrice de priorité

| # | Opportunité | Impact sur le portage | Effort | Recommandation |
|---|-------------|----------------------|--------|----------------|
| 1 | Module Input | **Critique** — bloquant pour 60+ keybindings | Moyen | Faire en premier |
| 4 | Camera update dans Scene | **Élevé** — quick win, réduit Scene | Faible | Faire en parallèle de 1 |
| 5 | Shader loading dupliqué | **Élevé** — quick win, supprime du code mort | Faible | Faire en parallèle de 1 |
| 2 | Scene/Renderer split | **Élevé** — bloquant pour post-processing | Élevé | Faire après 1, 4, 5 |
| 3 | Packages rendering | **Moyen** — hygiène, pas bloquant | Moyen | Faire quand rendering grossit |

---

## Prochaines étapes

Ces opportunités sont des candidats. Pour chacune, il faudrait :
1. Choisir laquelle explorer en premier
2. Creuser les contraintes, dépendances, forme du module approfondi
3. Implémenter de façon incrémentale (MVP first)
