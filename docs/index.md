# ⚡ Suckless Odin — Documentation Officielle

Bienvenue sur la documentation technique de **Suckless-Odin**, moteur de rendu temps réel 3D basé sur les principes PBR (*Physically-Based Rendering*) et IBL (*Image-Based Lighting*), écrit en langage de programmation **Odin** avec une architecture orientée données (*Data-Oriented Design*).

---

## 🧭 Accès Rapide aux Guides Majeurs

<div class="grid cards" markdown>

-   :material-steam:{ .lg .middle } __Intégration Steam & Proton__

    ---

    Guide exhaustif de cross-compilation Windows PE32+, injection automatique Steam VDF, génération d'artworks Steam Grid et validation in-game.

    [:octicons-arrow-right-24: Consulter le Guide Steam](steam-integration-and-proton-guide.md)

-   :material-controller:{ .lg .middle } __Support Manettes & Gamepads__

    ---

    Détection et mapping multi-protocoles (DualShock 4, DualSense, Xbox 360/One, Logitech F310/F710) via SDL / DirectInput.

    [:octicons-arrow-right-24: Voir le Guide Gamepad](gamepad-controller-integration-and-usage-guide.md)

-   :material-speedometer:{ .lg .middle } __Roadmap d'Optimisation & Benchmarks__

    ---

    Protocole de mesure non-intrusif, profils Tracy, Heaptrack, Callgrind et analyse des performances GPU.

    [:octicons-arrow-right-24: Découvrir la Roadmap](optimization-roadmap-and-benchmarking-protocol-2026-08-18.md)

-   :material-hammer-wrench:{ .lg .middle } __Architecture & Porting C11 $\rightarrow$ Odin__

    ---

    Détail des abstractions bas-niveau, vectorisation SIMD C, gestion mémoire et parité technique avec le moteur C11 `suckless-ogl`.

    [:octicons-arrow-right-24: Lire l'Analyse d'Architecture](PORTING_C11_TO_ODIN.md)

-   :material-lightbulb-on:{ .lg .middle } __Shadow Mapping & Anti-Aliasing (PCF Vogel-Disk)__

    ---

    Pipeline d'ombres omnidirectionnelles temps réel : Auto-Bias (RNOB + SSDB), filtrage PCF Vogel-Disk stochastique IGN (8-16 taps), comparateur split-screen et vues de debug thermiques.

    [:octicons-arrow-right-24: Voir l'Analyse & Démonstrations](2026-09-01_shadow_mapping_improvements_antialiasing_pcf_bias_analysis.md)

-   :material-axis-arrow:{ .lg .middle } __Manuel ImGuizmo 3D, Ombres & Éclairage Volumétrique__

    ---

    Manuel technique complet : contrôle 3D interactif via ImGuizmo, adaptation TAA dynamique lors du déplacement, architecture multi-phases volumétrique et catalogue exhaustif des réglages ImGui.

    [:octicons-arrow-right-24: Consulter le Manuel de Référence](2026-09-01_imguizmo_shadow_volumetric_gui_reference_guide.md)

-   :material-weather-fog:{ .lg .middle } __Calibration Physique : Beer-Lambert, God Rays & RNOB__

    ---

    Analyse approfondie de la calibration de précision : équation de transfert radiatif de Beer-Lambert, puits de lumière contrastés, correction géométrique RNOB et upsampling JBU 2x2.

    [:octicons-arrow-right-24: Lire l'Analyse Physique](2026-09-02_volumetric_godrays_beer_lambert_shadow_rnob_calibration.md)

-   :material-speedometer:{ .lg .middle } __Benchmark GPU Uncapped (VSync OFF) & Analyse de Coût__

    ---

    Rapport de performance brute non-capée : décomposition nanoseconde du raymarch volumétrique Beer-Lambert, ombres PCF 16-tap, goulots d'étranglement iGPU et roadmap d'optimisation.

    [:octicons-arrow-right-24: Consulter le Rapport de Benchmark](2026-09-02_uncapped_gpu_benchmark_volumetric_shadows_cost_analysis.md)

-   :material-palette-swatch:{ .lg .middle } __Plan Directeur : Harmonisation PBR, Ombres & IBL__

    ---

    Feuille de route d'harmonisation physique : décomposition lumière directe Cook-Torrance, découplage ombres/ambiance IBL, Specular Occlusion (Lagarde) et couplage volumétrique.

    [:octicons-arrow-right-24: Consulter le Plan Directeur](2026-09-02_pbr_direct_lighting_shadow_ibl_harmonization_plan.md)

-   :material-lightbulb-cfl:{ .lg .middle } __Intégration PBR Direct, Shadow Mapping & IBL__

    ---

    Spécification d'implémentation : lobe Cook-Torrance direct GGX/Smith, découplage physique des ombres de l'ambiance IBL, vues de debug PBR Split-Screen & Delta Magnifier Turbo Heatmap, et validation E2E.

    [:octicons-arrow-right-24: Consulter la Spécification Technique](2026-09-03_pbr_direct_lighting_shadow_ibl_integration.md)

-   :material-shield-check:{ .lg .middle } __Post-Mortem & Fiabilisation : Steam, Proton & Écran Noir__

    ---

    Analyse des causes racines de l'écran noir sous Steam Proton (FBO state cache, Steam overlay) et architecture des 4 verrous de sécurité automatisés (assertion de pixels réels).

    [:octicons-arrow-right-24: Lire le Guide de Fiabilisation](2026-09-03_windows_cross_compilation_steam_proton_blackscreen_postmortem.md)

</div>

---

## 🛠️ Commandes Fréquentes (Taskfile)

```bash
# Compilation native & lancement
task run

# Suite de tests complète (Unit, Shader, GL, CLI)
task test

# Cross-compilation Windows release & archives
task package-win

# Cycle de mise à jour Steam complet (1-clic)
task steam-update

# Lancement du serveur de documentation MkDocs
task serve-docs
```
