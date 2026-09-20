# Rapport d'Abandon du Checkerboard 2x2 et Rétention d'Early Exit pour Volumétrique

- **Date** : 20 Septembre 2026
- **Branche** : `feat/perf-volumetric-harness`
- **Statut Checkerboard** : ❌ **ABANDONNÉ & SUPPRIMÉ** (Artefacts de vibration 60Hz intolérables sur silhouettes)
- **Statut Early Exit** : ❌ **REJETÉ & SUPPRIMÉ** (Falsifié par audit A/B/C : ON 1.680 ms vs Master 1.547 ms = régression de +8.6%)

---

## 1. Contexte & Diagnostic du Scintillement Checkerboard

L'optimisation *Checkerboard Raymarching $2\times 2$* visait à diviser par deux le coût ALU et les lectures du shadow cubemap en ne raymarchant qu'un pixel sur deux en damier alterné selon la parité de trame :
$$(x + y + \text{frame\_idx}) \pmod 2 \neq 0 \implies \text{early return}$$

Les pixels sautés étaient ensuite reconstruits spatialement au moyen d'un échantillonnage en croix 4-tap bilatéral guidé par la profondeur dans le shader TAA.

### Détection par le Harnais de Sécurité Visuelle
L'audit visuel automatisé (`task audit-volumetric`) et l'inspection de l'opérateur ont immédiatement révélé une régression visuelle majeure :
* **Oscillation sub-pixel à 60Hz** : Alternance entre valeur analytique calculée $X$ et moyenne spatiale interpolée $Y$.
* **Delta sub-pixel mesuré** : $\Delta = 52.00 / 255$ (+20.4% de saut brusque de luminance entre trames successives).
* **Verdict de l'opérateur** : "ça vibre, c'est très moche".

---

## 2. Décision & Suppression Complète du Checkerboard

Conformément à la directive opérateur et aux règles de rendu, le mode Checkerboard a été entièrement retiré :
1. **Shaders** :
   - `shaders/postfx/volumetric_raymarch.frag` : Suppression du discard de pixels en damier et du uniform `u_checkerboard_enabled`.
   - `shaders/postfx/volumetric_taa.frag` : Suppression de la passe de reconstruction en croix 4-tap et de `u_frame_idx`.
2. **Code Odin & UI** :
   - `src/rendering/volumetric.odin` : Retrait de `checkerboard_enabled` et des locations d'uniformes associées.
   - `src/core/session/session.odin` & `src/app/session.odin` : Nettoyage de la persistance JSON.
   - `src/gui/gui_volumetric.odin` & `src/gui/gui_optimizations.odin` : Retrait des cases à cocher et filtres de recherche.
   - `src/gui/gui.odin` : Nettoyage des mots-clés de recherche (`checkerboard`, `damier`).
   - `src/rendering/optimization_profiles.odin` : Suppression de la référence dans les profils de performance.
   - `tests/test_session.odin` : Mise à jour des tests de persistance (114/114 PASS).

---

## 3. Rejet Définitif de l'Optimisation Early Exit (Audit A/B/C)

L'optimisation Early Exit (Early Shadow Rejection + Early Ray Termination via `u_early_exit_enabled`) a été rigoureusement auditée sur banc matériel identique (1920x1200, 300 frames, profil Quality, 2 runs chacun) :

### Tableau Comparatif 3 Colonnes (Preuve Mathématique)

| Métrique GPU | `master` (vectorisé plat) | Branche `ON` (Early Exit) | Branche `OFF` (Désactivé) | Delta `ON` vs `MASTER` | Delta `ON` vs `OFF` |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Raymarch Pass (Moyenne)** | **1.547 ms** | **1.680 ms** | **2.016 ms** | **+0.133 ms (+8.6%)** | **-0.336 ms (-16.7%)** |
| *Variance Raymarch* | *±0.095 ms* | *±0.083 ms* | *±0.131 ms* | *bruit* | *mesure réelle* |
| **Frametime (Moyenne)** | **17.248 ms** | **17.544 ms** | **17.848 ms** | **+0.296 ms (+1.7%)** | **-0.304 ms (-1.7%)** |
| *Variance Frametime* | *±0.201 ms* | *±0.163 ms* | *±0.268 ms* | *bruit thermique* | *bruit thermique* |

### Conclusion de l'Audit & Verdict NO-GO
1. **Gain réel vs Master = 0.000 ms** : L'Early Exit n'apporte aucun gain sur GPU vs `master`. Le dynamic branching introduit une légère pénalité (+0.133 ms) liée à la divergence de threads au sein des warps SIMD.
2. **Biais méthodologique élucidé** : La comparaison A/B initiale (0.279 ms vs 0.316 ms, soit ~11.7%) mesurait en réalité une **désoptimisation auto-infligée** de l'état `OFF` induite par l'uniform dynamique, et non une accélération par rapport à la baseline vectorisée de production.
3. **Action** : Retrait intégral de l'Early Exit dans le shader et le code Odin (commit `55d0717` ISO master). Redirection exclusive vers **C1 (16 pas stochastique)**.
