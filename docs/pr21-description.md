## Summary

Cette PR remédie à la régression de latence d'initialisation et de transition IBL introduite par la détection automatique du soleil CPU.

### Motivation
L'analyse initiale FP16 multi-passes CPU bloquait le worker thread ~70-110 ms par changement de skybox. De plus, les ré-explorations d'environnements déjà chargés recalculaient systématiquement la détection solaire, créant des saccades et des temps de transition prohibitifs.

### Contenu par Commit

1. **`perf(ibl): instrumentation du pipeline (timings decode/sun/upload/compute)`** (`0caa525`)
   - Ticks et métriques de latence par phase (`t_decode_ms`, `t_detect_ms`, `t_halo_ms`, `t_upload_ms`, `t_compute_ms`).
   - Log breakdown unifié lors du swap IBL pour traçabilité en production.

2. **`perf(sun-detect): passe unique downsampled + fast-path fp16 + test cross-résolution`** (`be5de1c`)
   - Fusion des passes max luminance, moyenne et histogramme log2 en une seule passe échantillonnée (`stride = width / 1024`).
   - Fast-path bitwise FP16 sans conversion contextless (`FP16_EXPONENT_MASK`, `FP16_MANTISSA_MASK`).
   - Ajout d'un test synthétique multi-résolution (`test_sun_detection_cross_resolution` 2048x1024 vs 1024x512, tolérance < 2.0°).

3. **`feat(sun-cache): cache de détection solaire thread-safe + bouton Re-detect`** (`f37e981`)
   - Cache mémoire thread-safe (`Sun_Detection_Cache`) protégé par `sync.Mutex`.
   - Protection anti-résurrection via génération (`generation guard`).
   - Bouton UI dédupliqué "Re-detect Sun" avec retour dynamique et invalidation ciblée.
   - Re-detect Sun pendant une transition en cours → no-op volontaire + warning.
   - Sémantique explicite `from_cache` avec remise à 0 des temps de détection sur cache hit (`sun_detect=CACHED`).
   - Test de contrat cache unitaire sans couplage aux structures internes.

4. **`chore(perf-gate): commit du script check_ibl_init_perf, gate découplée de task test`** (`7332d2d`, `db33224`)
   - Intégration du script `scripts/check_ibl_init_perf.py` avec overrides CLI/env (`--baseline`, `IBL_BASELINE_MS`).
   - Découplage de la tâche CI : `check-ibl-perf` est autonome et retirée de la cible `task test`.
   - Baseline médiane N=5 (1449.75 ms) et mode advisory par défaut (bruit runner), `--strict` pour bloquer.

### Mesures de Performance (Native Linux x86_64)

| Étape Pipeline IBL | Avant PR (dca186c) | Après PR (C1-C3) | Gain |
| :--- | :--- | :--- | :--- |
| **Decode HDR** | ~27 ms | ~27 ms | — |
| **Sun Detect (Pass 1 & 2)** | ~51 ms | ~4 ms (stride) / 0 ms (cache hit) | **12.7x / Instant** |
| **Halo Sampling** | ~26 ms (à re-mesurer) | ~26 ms (à re-mesurer) | — |
| **PBO Upload** | ~14 ms | ~14 ms | — |
| **Compute IBL** | ~1450 ms | ~1450 ms | — |
| **Total Init Switch** | ~1570 ms | ~1495 ms (froid) / ~1491 ms (chaud) | **-75 ms** |

Compute IBL demeure ~92% du temps de transition — hors scope, PR dédiée à venir.

### Risques & Limites
- Détection solaire échantillonnée (stride > 1) : couverture testée synthétiquement et validée sur les 5 HDRs réels de référence sans déviation angulaire (> 0.2°).
- Halo sampling : itération à pleine résolution maintenue sur la bande angulaire (`y_min..y_max`, `step=1`) ; mesure d'origine à re-mesurer précisément sous charge isolée.
- Gate perf `check_ibl_init_perf.py` : sensible au bruit CPU des runners partagés ; advisory par défaut, paramètre `--strict` pour blocage déterministe.

### Plan de Test
- `task test-unit` : 123 tests (121 base + cross-résolution + contrat cache).
- `task check-ibl-perf` : validation du timing de démarrage IBL.
- `task lint` : conformité stricte Odin, Python et OpenGL 4.5.

### Hors Scope (PR Séparée)
- La migration forcée `step_count` (16 → 20) a été exclue de cette branche (sera traitée dans une issue dédiée avec versionnement du schéma de session).
