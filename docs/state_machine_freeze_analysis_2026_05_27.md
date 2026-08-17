# Analyse Diagnostique : Freezes Aléatoires de la Machine à États (Wayland + Nvidia)
**Date :** 27 mai 2026  
**Auteur :** Antigravity AI  
**Statut :** Recherche & Instrumentation  

---

## 1. Contexte du Problème

Dans certains environnements de développement (notamment sous **Fedora/Bazzite (Wayland)** avec une carte graphique hybride **Nvidia GTX 950m**), des freezes aléatoires de la machine à états de l' `Env_Manager` surviennent lors des transitions de cartes d'environnement (HDR swaps). 

Le symptôme visible dans la console est la répétition continue de l'avertissement suivant :
```text
suckless-odin.env - WARNING - Transition already in progress, ignoring
```

Cela indique que la machine à états reste bloquée indéfiniment dans un état de transition (`transition_state != .Idle`), ignorant toutes les requêtes ultérieures et bloquant le pipeline de chargement IBL.

---

## 2. Pistes et Hypothèses Diagnostiques

Trois hypothèses techniques majeures ont été identifiées à la suite d'une analyse approfondie du code source et des spécificités d'Nvidia et Wayland.

### 🔍 Hypothèse A : Impasse logique suite à un échec de chargement asynchrone (Deadlock Applicatif)
*C'est la faille de logique logicielle la plus probable au niveau applicatif.*

*   **Mécanisme d'action** :
    1. Lors d'un changement d'environnement, `env_manager_trigger_transition` fait passer `transition_state` à `.Loading` et envoie une requête au thread d'arrière-plan via `async_loader_request`.
    2. Si, pour une raison quelconque (latence disque sous Wayland, fichier HDR corrompu ou inaccessible, restrictions de sandbox/conteneurs sous Bazzite), le décodage échoue, le thread d'arrière-plan marque la requête comme `.Failed`.
    3. Au prochain tick du thread principal, `env_manager_poll_loader` interroge le chargeur via `async_loader_poll`.
    4. Dans `async_loader_poll` :
       ```odin
       if loader.request.state == .Failed {
           log.log_error("suckless-odin.async", "Async load failed for: %s", cstring(&loader.request.path[0]))
           loader.request.state = .Idle
       }
       return false
       ```
    5. Comme la fonction renvoie `false`, l' `Env_Manager` n'active jamais son pipeline GPU (`ibl_state` reste `.Idle`).
    6. **La faille** : La variable `transition_state` n'est jamais réinitialisée à `.Idle`. La machine à états se retrouve définitivement gelée en `transition_state = .Loading` et `ibl_state = .Idle`. Toute tentative de transition future est définitivement bloquée.

---

### 🔍 Hypothèse B : Blocage de synchronisation matérielle OpenGL (`gl.MapBuffer`) sous Nvidia/Wayland
*C'est la faille liée à la gestion asynchrone du pilote graphique.*

*   **Mécanisme d'action** :
    1. Dans l'état `.Generate_Mipmaps`, le thread de rendu principal déclenche l'extraction asynchrone des pixels de luminance vers le PBO (`luminance_pbo`) via `gl.GetTexImage`.
    2. À la frame immédiatement suivante, dans l'état `.Luminance`, le thread principal appelle :
       ```odin
       ptr := gl.MapBuffer(gl.PIXEL_PACK_BUFFER, gl.READ_ONLY)
       ```
    3. Si le processeur graphique (GPU) Nvidia n'a pas encore terminé la génération de mipmaps et l'écriture dans le PBO, cet appel force le CPU à s'arrêter et à attendre de manière synchrone le GPU.
    4. Sous Wayland, les pilotes propriétaires Nvidia souffrent parfois de verrous mortels (*deadlocks*) internes lorsque le thread principal OpenGL effectue un blocage CPU synchrone au moment même où le compositeur Wayland (via EGL/Wayland-fences) réclame ou libère la surface d'affichage (*swap chain*). 
    5. Le GPU se retrouve bloqué en attendant la libération du buffer d'affichage Wayland, tandis que le CPU reste bloqué dans `gl.MapBuffer` en attendant que le GPU termine sa tâche.

---

### 🔍 Hypothèse C : Aléas de cohérence de cache et barrières manquantes (`gl.MemoryBarrier`)
*C'est la faille liée à l'exécution parallèle agressive du GPU.*

*   **Mécanisme d'action** :
    1. Pendant le traitement par tranches (*progressive frame-slicing*) de la specular et de l'irradiance, les compute shaders écrivent dans les textures VRAM cibles via `imageStore()`.
    2. Les pilotes Nvidia propriétaires respectent la spécification OpenGL de manière extrêmement rigide et effectuent des optimisations de cache et des réorganisations d'instructions agressives.
    3. Si une barrière de mémoire est manquante ou si une synchronisation fine (`gl.PIXEL_BUFFER_BARRIER_BIT` ou `gl.TEXTURE_FETCH_BARRIER_BIT`) n'invalide pas correctement les caches du GPU Nvidia, les processeurs de flux du GPU peuvent lire des données incohérentes ou périmées, entraînant un gel matériel de l'unité de calcul (GPU Hang), bloquant la progression du tick de l'application.

---

## 3. Rôle de l'Instrumentation Récente

La nouvelle instrumentation mise en place (et validée par nos tests de non-régression) est conçue spécifiquement pour identifier laquelle de ces 3 hypothèses est la cause réelle du problème lors de la prochaine occurrence du bug.

### 📊 Indicateurs de diagnostic introduits :
*   **`transition_elapsed` & `ibl_elapsed`** : Temps exact passé dans les états en cours.
*   **`transition_prev_state` & `ibl_prev_state`** : Historique immédiat des états précédents pour retracer l'origine du blocage.
*   **`STUCK TRANSITION WARNING`** : Surveillance automatisée ("watchdog") émettant une alerte détaillée en console toutes les 2 secondes si un état est actif depuis plus de 5 secondes.

### 🎯 Clé de décodage des futurs logs de freeze :

1.  **Si les logs indiquent :** `Transition: .Loading, IBL: .Idle`
    *   👉 **Vainqueur : Hypothèse A (Deadlock applicatif)**. 
    *   *Solution* : Ajouter un chemin de repli dans `env_manager_poll_loader` pour réinitialiser proprement la transition à `.Idle` en cas d'échec du loader.

2.  **Si les logs indiquent :** `Transition: .Loading, IBL: .Luminance` avec un temps écoulé important.
    *   👉 **Vainqueur : Hypothèse B (Deadlock gl.MapBuffer)**.
    *   *Solution* : Introduire un délai supplémentaire de 1 ou 2 frames avant de mapper le PBO, ou utiliser une requête de synchronisation matérielle (`gl.FenceSync`/`gl.ClientWaitSync`) pour ne mapper le buffer que lorsqu'il est garanti prêt sans forcer de blocage CPU synchrone.

3.  **Si les logs indiquent :** `Transition: .Loading, IBL: .Specular_Mips` (ou `.Irradiance`) bloqué.
    *   👉 **Vainqueur : Hypothèse C (GPU Hang sur compute)**.
    *   *Solution* : Renforcer les barrières mémoires après chaque compute dispatch ou investiguer des conflits de ressources.
