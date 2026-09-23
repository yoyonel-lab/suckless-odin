# Architecture de Profiling Mémoire Tracy Hybride (Micro & Macro)

**Date :** 2026-09-23  
**Statut :** Validé & Intégré  
**Composants :** [`src/core/tracy/allocator.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/core/tracy/allocator.odin), [`src/core/tracy/rss_linux.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/core/tracy/rss_linux.odin), [`src/core/tracy/rss_windows.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/core/tracy/rss_windows.odin), [`src/main.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/main.odin), [`src/app/app.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/app/app.odin)

---

## 1. Contexte & Problématique

Lors de sessions d'analyse sous **Tracy Profiler v0.13.1**, la consommation mémoire de l'application `suckless-odin` n'était pas visualisable :
1. **Confusion métrique GUI :** L'indicateur mémoire présent dans la barre supérieure de Tracy (ex. `265.1 MB (0.83%)`) reflète exclusivement l'empreinte mémoire du processus serveur Tracy GUI (`tracy-profiler`) pour stocker les traces reçues, et **non** la mémoire de l'application cliente.
2. **Bouton `Memory` inactif :** Le bouton d'inspection mémoire natif de Tracy reste désactivé tant que l'application cliente n'émet pas d'événements d'allocation via l'API Tracy (`___tracy_emit_memory_alloc` / `___tracy_emit_memory_free`).
3. **Absence de courbe temporelle RAM :** Aucune piste timeline n'indiquait la charge mémoire globale du processus hôte et des buffers OpenGL alloués par le driver GPU Mesa.

---

## 2. Architecture Retenue : Option 3 (Hybride)

Pour concilier **diagnostic précis des allocations applicatives** et **visibilité réelle de l'empreinte système**, l'architecture hybride combine deux niveaux complémentaires :

```
┌────────────────────────────────────────────────────────────────────────┐
│                        SUCKLESS-ODIN APPLICATION                       │
│                                                                        │
│   ┌──────────────────────────────────┐  ┌───────────────────────────┐  │
│   │ 1. NIVEAU MICRO (Odin Heap)      │  │ 2. NIVEAU MACRO (Process) │  │
│   │                                  │  │                           │  │
│   │ context.allocator                │  │ get_process_rss()         │  │
│   │   └─► tracy.make_tracy_allocator │  │   ├─ Linux: statm         │  │
│   │         ├─► alloc() / free()     │  │   └─ Win: psapi           │  │
│   └─────────────────┬────────────────┘  └─────────────┬─────────────┘  │
└─────────────────────┼─────────────────────────────────┼────────────────┘
                      ▼                                 ▼
      ┌───────────────────────────────┐ ┌───────────────────────────────┐
      │  Tracy Native Memory Tracker  │ │     Tracy Timeline Plots      │
      │  - Bouton toolbar "Memory"    │ │  - Courbe "RAM Process (RSS)" │
      │  - Carte des blocs mémoire    │ │  - Format Plot: .Memory       │
      │  - Détection fuites par ptr   │ │  - Empreinte globale réelle   │
      └───────────────────────────────┘ └───────────────────────────────┘
```

---

## 3. Détails d'Implémentation

### 3.1. Niveau Micro : Tracking Allocator Odin

Un proxy d'allocateur (`make_tracy_allocator`) est injecté sur `context.allocator` au démarrage de [`src/main.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/main.odin) :

```odin
main :: proc() {
    when tracy.TRACY_ENABLE {
        context.allocator = tracy.make_tracy_allocator(context.allocator)
    }
    // ...
}
```

- **Comportement :** Intercepte les modes `.Alloc`, `.Alloc_Non_Zeroed`, `.Free`, `.Resize`, `.Resize_Non_Zeroed` et notifie `tracy.alloc` / `tracy.free`.
- **Bénéfice :** Active le bouton **Memory** dans Tracy Profiler, fournit la pile d'appels des allocations, l'adresse de chaque bloc et la courbe temporelle fine "Memory usage".
- **Garantie temporaire :** `context.temp_allocator` (arène de ring-buffer par frame) reste volontairement non traqué par Tracy pour éviter de fausses alertes de fuites sur la mémoire de travail réinitialisée par `free_all()`.

### 3.2. Niveau Macro : Plot RSS Système Zéro-Allocation

Un collecteur d'empreinte mémoire physique (Resident Set Size) sans allocation heap interroge le système d'exploitation à chaque frame :

- **Linux (`rss_linux.odin`) :** Lecture directe de `/proc/self/statm` sur un buffer stack de 64 octets. Extraction immédiate du 2ᵉ champ (pages résidentes) multiplié par la taille de page (4096 octets).
- **Windows (`rss_windows.odin`) :** Appel à `GetProcessMemoryInfo` (`psapi.lib`) via le pseudo-handle `GetCurrentProcess()` pour lire `PROCESS_MEMORY_COUNTERS.WorkingSetSize`.
- **Fallback (`rss_other.odin`) :** Stub sécurisé retournant 0 sur plateformes non supportées.

La valeur est publiée dans Tracy via :
```odin
tracy.plot_config("RAM Process (RSS)", .Memory, step = false, fill = true, color = tracy.COLOR_MEMORY)
// Dans la boucle principale :
when tracy.TRACY_ENABLE {
    tracy.plot("RAM Process (RSS)", f64(tracy.get_process_rss()))
}
```

---

## 4. Garantie Zéro-Coût (Zero-Cost Invariant)

Conformément aux directives de performance du projet :
- Lorsque `TRACY_ENABLE=false` (compilations `task build`, `task build-release`, `task build-ultra`), `make_tracy_allocator` retourne directement l'allocateur sous-jacent sans wrapper.
- `get_process_rss()` est compilé sous garde conditionnelle `when TRACY_ENABLE` et renvoie une constante `0` éliminée par le compilateur.
- Aucune dépendance externe ni allocation mémoire supplémentaire n'est introduite en production.

---

## 5. Guide d'Utilisation Opérateur

1. **Session Interactive :**
   - Terminal 1 : `task tracy-server` (GUI Tracy avec auto-connexion)
   - Terminal 2 : `task run-profile` (lance l'application instrumentée)
   - Dans le GUI Tracy :
     - Bouton **Memory** (barre d'outils) : carte des allocations Odin vivantes.
     - Graphique **RAM Process (RSS)** (timeline) : courbe de charge mémoire totale.

2. **Capture Automatisée & Validation CI :**
   ```bash
   task profile-tracy
   ```
   Génère la trace complète `build/profiling/tracy/session.tracy` contenant les zones GPU, CPU, Fibers et les séries de plots (`FPS`, `Frame Time`, `RAM Process (RSS)`).
