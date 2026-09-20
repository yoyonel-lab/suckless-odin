# Harnais de Sécurité Visuelle & Audit Opérateur du Rendu Volumétrique

- **Date** : 20 Septembre 2026
- **Branche** : `feat/perf-volumetric-harness`
- **Statut** : ✅ **Validé & Opérationnel**
- **Cible** : Pré-requis obligatoire à l'optimisation des performances du raymarching volumétrique (Scissor 2D, Checkerboard TAA, Early Termination)

---

## 1. Contexte & Problématique

Les profils de mesure GPU récents ([`docs/2026-09-02_uncapped_gpu_benchmark_volumetric_shadows_cost_analysis.md`](2026-09-02_uncapped_gpu_benchmark_volumetric_shadows_cost_analysis.md)) ont identifié le raymarching volumétrique à 32 pas comme le **goulot d'étranglement Compute/ALU majeur** du moteur (~25% à 30% du temps total de trame).

Cependant, un audit du harnais de test a révélé que :
1. Dans [`tests/gl/test_visual_regression.odin:348`](../tests/gl/test_visual_regression.odin#L348), **`s.volumetric.params.enabled = false`**.
2. Les golden references `ref_*.png` existantes ne couvraient pas le volumétrique.
3. Aucune validation automatisée ne protégeait contre l'apparition de scintillements (*flickering*), de fuites bilatérales (*edge bleeding* sur les sphères opaques) ou de traînées fantômes (*ghosting*) lors des mouvements de caméra.

Conformément à [`AGENTS.md`](../AGENTS.md) (*Protocole de Fix & Sanctuarisation des Références*), ce harnais a été développé pour intégrer directement **l'opérateur humain dans la boucle de décision** avec des artefacts visuels concrets.

---

## 2. Architecture du Harnais (`tests/gl/test_gl_volumetric_visual.odin`)

Le harnais exécute un scénario physique reproductible en rendu offscreen $960\times 540$ sur GPU local :

```
                  Z = -6.5 m            Z = 0.0 m                 Z = +16.0 m
               [ Point Light ]   --->   [ Grille Sphères ]   --->   [ Caméra ]
                 (Source HDR)             (Occlusion)                (Capteur)
```

* **Positionnement en contre-jour direct** : La Point Light ($Z = -6.5\text{m}$) éclaire la caméra ($Z = +16.0\text{m}$) à travers la grille de 100 sphères PBR ($Z = 0.0\text{m}$). Chaque sphère découpe un faisceau d'ombre volumétrique net, maximisant la sensibilité du test.
* **Paramètres physiques (Profil Quality)** : 32 pas, anisotropie $g = 0.62$ (diffusion Mie avant), TAA $\alpha = 0.20$, JBU $2\times 2$, filtre bilatéral 9-tap.

---

## 3. Les 4 Piliers de l'Audit

### A. Convergence Temporelle & Zéro Scintillement (Flicker Test)
* Exécution de 16 trames pour convergence complète de l'historique TAA.
* Calcul de la variance inter-trames :
  $$\text{TVar} = \frac{1}{W \times H} \sum_{x,y} |I_{15}(x,y) - I_{14}(x,y)|$$
* Génération de [`02_static_flicker_map_20x.png`](../tests/reports/volumetric/02_static_flicker_map_20x.png) (amplification $20\times$) : une image noire atteste d'une stabilité $0\Delta$.

### B. Contraste des Puits de Lumière (God Rays Contrast)
* Mesure du contraste RMS sur la région des faisceaux :
  $$\text{RMS Contrast} = \frac{\sqrt{\frac{1}{N} \sum (L - \bar{L})^2}}{\bar{L}}$$
* Capture isolée du brouillard sur fond noir pur : [`03_static_volumetric_isolated.png`](../tests/reports/volumetric/03_static_volumetric_isolated.png).

### C. Préservation Sub-Pixel des Silhouettes (JBU 2x2 Edge Test)
* Extraction d'un crop $80\times 80$ au centre de l'écran où une sphère coupe un faisceau lumineux intense, agrandi $4\times$ en plus proche voisin : [`07_crop_silhouette_jbu_4x.png`](../tests/reports/volumetric/07_crop_silhouette_jbu_4x.png).
* Vérifie que le Joint Bilateral Upsampling n'introduit aucune bavure de brouillard sur la surface opaque.

### D. Cohérence en Mouvement & Non-Ghosting (Camera Sweep Strip)
* Travelling horizontal de caméra ($X = -2.5\text{m} \to +2.5\text{m}$) sur 12 frames.
* Montage d'un strip chronologique 4 panneaux : [`06_camera_sweep_strip_4panels.png`](../tests/reports/volumetric/06_camera_sweep_strip_4panels.png).
* Inspection de la texture GPU d'acceptation TAA : [`05_dynamic_taa_acceptance.png`](../tests/reports/volumetric/05_dynamic_taa_acceptance.png) (Vert = reprojecté sainement, Rouge = disocclusion propre sans smearing).

---

## 4. Utilisation & Restitution

### Commande unique
```bash
task audit-volumetric
```
Exécution en **~1.38 seconde** sur GPU physique.

### Restitution Opérateur
Tous les artefacts et le rapport de synthèse sont générés dans [`tests/reports/volumetric/`](../tests/reports/volumetric/) :
* [`tests/reports/volumetric/README.md`](../tests/reports/volumetric/README.md) : Tableau de bord des métriques et galerie d'images avec guide d'interprétation.
* 7 captures PNG haute résolution couvrant l'ensemble des diagnostics spatiaux et temporels.

---

## 5. Valeurs de Référence Baseline (Master Actuel)

| Métrique | Valeur Mesurée | Seuil Nominal | Statut |
| :--- | :---: | :---: | :---: |
| **Temporal Variance (TVar)** | **0.4028 / 255** | $< 0.80$ | ✅ PASS |
| **God Rays RMS Contrast** | **81.81** | $> 12.00$ | ✅ PASS |
| **TAA Acceptance Statique** | **98.5% vert** | $> 95.0\%$ | ✅ PASS |
| **Durée d'audit** | **1.38s** | $< 3.00\text{s}$ | ✅ PASS |
