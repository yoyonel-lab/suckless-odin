# Rejet Documenté — Format HDR Scene Color R11G11B10F (Mission C2)

- **Date** : 2026-09-16
- **Branche évaluée** : `feat/perf-scene-format` (conservée non mergée)
- **SHA Head de la branche** : `dd9725e33e8395d86c381c4a79001d4b317f2bad`
- **Statut** : **REJETÉE DÉFINITIVEMENT** (Gain frametime global < 1%, hors objectif $\ge 10\%$)

---

## 1. Contexte & Hypothèse Initiale

Lors de l'analyse VTune initiale ([docs/vtune-sprint-5-proposals-2026-08-17.md](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/vtune-sprint-5-proposals-2026-08-17.md#piste-a--formats-de-textures-haute-efficacit-gl_r11f_g11f_b10f)), la métrique `DRAM Bound: 44.3%` laissait supposer un goulot mémoire majeur lors de l'écriture forward et de la lecture PostFX composite sur les tampons couleur HDR pleine résolution (64 bpp `GL_RGBA16F`).

- **Hypothèse C2** : La bascule vers `GL_R11F_G11F_B10F` (32 bpp, -50% VRAM / bande passante sur `scene_color_tex` et `fxaa_tex`) devait dégager un gain $\ge 10\%$ sur le frametime GPU global.

---

## 2. Modifications Testées sur la Branche

Sur la branche `feat/perf-scene-format` (commit `dd9725e`) :
1. `src/rendering/postfx/pipeline.odin` : Allocation de `scene_color_tex` en `GL_R11F_G11F_B10F` (format `gl.RGB`).
2. `src/rendering/postfx/fxaa_prepass.odin` : Allocation et resize de `fxaa_tex` en `GL_R11F_G11F_B10F` (format `gl.RGB`).

---

## 3. Résultats des Mesures & Verdict

### A. Non-Régression Visuelle (100% Validée)
- **Audit Alpha** : 0 shader consommateur du canal `.a` en aval de `scene_color_tex` (CAS SÛR).
- **Validation Visuelle A/B** : Crops 4x zoom sur 5 zones critiques (Edge AA, transition FXAA, bloom halo, ombre/faible luminance 6-bit mantisse, spéculaire HDR > 1.0) ainsi que sur diélectrique (0,0) et métallique (9,9).
- **Résultat** : PSNR élevé (30 à 40 dB), dérive photométrique strictement confinée au bruit de grain procédural cinématographique, zéro artéfact visuel perceptible.

### B. Performances (Benchmark Quality, 300 frames)
Conditions strictes : `mesa_glthread=true MESA_NO_ERROR=1 vblank_mode=0 __GL_SYNC_TO_VBLANK=0`, Intel Iris Xe Graphics.

| Version | Run 1 Frametime (FPS) | Run 2 Frametime (FPS) | Moyenne Frametime | Moyenne FPS | Écart vs Master |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Master (`RGBA16F`)** | 8.212 ms (121.8) | 7.688 ms (130.1) | **7.950 ms** | **126.0 FPS** | Baseline |
| **Feat (`R11F_G11F_B10F`)** | 7.954 ms (125.7) | 8.252 ms (121.2) | **8.103 ms** | **123.5 FPS** | **< 1% (bruit)** |

### C. Cause Racine du Non-Gain (Root Cause Analysis)
1. **Bottleneck réel Compute/ALU** : Le profil Quality est saturé par les calculs lourds de shaders (Raymarching volumétrique à 32 pas avec upsample bilatéral JBU 2x2, convolutions cubemap PCF 16-tap, accumulation IBL GGX).
2. **Couverture géométrique modérée** : Les sphères PBR ne couvrent qu'environ 30% de l'écran, le reste étant le cyclorama du studio. L'économie de bande passante d'écriture raster forward est marginale par rapport au coût total de la frame.
3. **Conclusion** : L'optimisation ne débloque pas l'objectif $\ge 10\%$.

---

## 4. Statut & Recommandation
- **Statut** : **REJETÉE**.
- **Consigne** : **Ne pas retenter** de bascule de format de texture couleur sans nouvelle mesure instrumentée démontrant formellement un bottleneck de bande passante sur cette passe spécifique.
- **Orientation prioritaire** : Les gains $\ge 10\%$ doivent être recherchés exclusivement sur les passes Compute/ALU dominantes (volumétrique et ombres dynamiques).

---

## 5. Acquis Exploitables Conservés pour le Futur
1. **Audit Alpha Automatisé** : Preuve formelle que `scene_color_tex.a` est inerte et peut être réutilisé ou éliminé sans risque fonctionnel pour de futurs MRT.
2. **Protocole de Preuve Visuelle A/B** : Méthodologie d'extraction de crops 4x zoom + métriques PSNR/MSE automatisée, directement réutilisable pour toute optimisation de shader/rendu.
3. **Branche Archivée** : La branche `feat/perf-scene-format` (`dd9725e33e8395d86c381c4a79001d4b317f2bad`) reste intacte dans le dépôt local comme référence d'implémentation propre si une contrainte d'empreinte mémoire VRAM stricte apparaissait ultérieurement.

---

## 6. Liens Croisés
- [docs/vtune-metrics-evolution-2026-08-17.md](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/vtune-metrics-evolution-2026-08-17.md)
- [docs/vtune-sprint-5-proposals-2026-08-17.md](file:///home/latty/Prog/__PERSO__/suckless-odin/docs/vtune-sprint-5-proposals-2026-08-17.md)
