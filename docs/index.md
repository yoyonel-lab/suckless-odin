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

-   :material-view-dashboard-outline:{ .lg .middle } __Plan de Rationalisation UI/UX ImGui__

    ---

    Plan de refactoring et d'assainissement de l'interface Dear ImGui : audit de câblage, élimination des placeholders fantômes et consolidation vers 5 hubs thématiques.

    [:octicons-arrow-right-24: Consulter le Plan](2026-09-07_imgui_ui_ux_refactoring_and_rationalization_plan.md)

-   :material-clipboard-check-outline:{ .lg .middle } __Plan de Remédiation Audit GLM 5.3-Flash__

    ---

    Analyse critique, matrice de validation et feuille de route pour les 7 retours P1 (PBR, IBL, ombres, timing) et 6 nits P2.

    [:octicons-arrow-right-24: Voir la Feuille de Route](2026-09-10_glm_feedback_remediation_plan.md)

-   :material-image-multiple-outline:{ .lg .middle } __Hub de Revue des Références Visuelles (Golden)__

    ---

    Galerie comparative interactive plein écran (GLightbox, multi-onglets 6 vues, métriques pixels) pour l'inspection des écarts de rendu et la mise à jour des baselines.

    [:octicons-arrow-right-24: Accéder au Hub de Revue](visual_regression_review.md)

-   :material-cube-outline:{ .lg .middle } __TODO Architecture : Migration IBL vers Cubemap__

    ---

    Spécification technique d'architecture pour migrer l'IBL 2D équirectangulaire vers un Cubemap OpenGL natif sans singularités polaires.

    [:octicons-arrow-right-24: Voir la Spécification](2026-09-11_ibl_cubemap_migration_architecture_todo.md)

-   :material-axis-arrow:{ .lg .middle } __Manuel ImGuizmo 3D, Ombres & Éclairage Volumétrique__

    ---

    Manuel technique complet : contrôle 3D interactif via ImGuizmo, adaptation TAA dynamique lors du déplacement, architecture multi-phases volumétrique et catalogue exhaustif des réglages ImGui.

    [:octicons-arrow-right-24: Consulter le Manuel de Référence](2026-09-01_imguizmo_shadow_volumetric_gui_reference_guide.md)

-   :material-cursor-default-click:{ .lg .middle } __Sélection 3D Viewport & Picking ImGuizmo__

    ---

    Spécification technique & état de l'art (Unreal, Unity, Godot, Blender) : picking analytique CPU zero-stall, unprojection écran/monde, sélection interactive des sphères/lumière et activation d'ImGuizmo.

    [:octicons-arrow-right-24: Consulter la Spécification Picking](2026-09-06_3d_viewport_picking_and_selection_architecture.md)

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
