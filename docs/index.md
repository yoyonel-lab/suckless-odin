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
