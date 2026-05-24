# Architecture Post-FX : Évaluation Uber-Shader et SPD (Single-Pass Downsampler)

**Date d'analyse :** 2026-05-24  
**Contexte :** Optimisation du moteur de rendu OpenGL (portage Odin) sur architecture hybride NVIDIA Optimus (Bazzite/Linux).

---

## 1. État des lieux : La réussite de l'Uber-Shader Actuel

L'analyse du code source (`pipeline.odin` et `postfx.frag`) démontre que le moteur possède **déjà** une architecture de composition finale de type "Uber-Shader".

Tous les effets dits **"Locaux"** (où le calcul d'un pixel ne dépend que de ce même pixel) sont fusionnés en un seul programme :
- FXAA
- Tonemapping (ACES) & Exposition (Auto/Manuel)
- Correction Gamma & Color Grading (LUT3D)
- Vignette, Banding (Dithering) et Film Grain

> [!NOTE]
> **Pourquoi cette approche est optimale :** L'image source (HDR) est lue depuis la VRAM une seule fois. Les calculs mathématiques s'enchaînent dans les registres rapides de l'ALU du GPU, puis le résultat SDR est écrit à l'écran. Il n'y a aucun goulot d'étranglement mémoire pour ces effets.

---

## 2. Le Goulot d'Étranglement : Les Effets "Spatiaux" (Bloom)

À l'inverse des effets locaux, les effets **"Spatiaux"** (comme le Bloom ou la Profondeur de champ) nécessitent de lire les pixels adjacents sur un très grand rayon. Faire cela dans le fragment shader final ruinerait les performances (des centaines de lectures de texture par pixel).

L'architecture classique (celle actuellement utilisée dans `bloom_render`) consiste à faire des pré-passes de **Ping-Pong / Rasterization** :
1. Prendre l'image 1920x1080, l'écrire dans un Framebuffer (FBO) de 960x540 (Downsample).
2. Prendre la 960x540, l'écrire dans un FBO de 480x270... et ce jusqu'à 6 niveaux de Mipmaps.
3. Faire le chemin inverse (Upsample) en fusionnant les images pour créer un flou large et doux.

---

## 3. Le Problème de Bande Passante VRAM (Memory Bound)

C'est ici que l'évaluation évoque une "Bande Passante (VRAM) très lourde". Détaillons la physique de ce problème, en particulier sur les Laptops (NVIDIA Optimus).

### Le cycle lent (Ping-Pong actuel)
À chaque passe de réduction (Downsample) :
1. Le GPU doit lier un nouveau Framebuffer (State Change coûteux).
2. Le GPU va lire l'image précédente dans la **VRAM** (Video RAM de la carte graphique, qui est physiquement "loin" et lente d'accès comparée au cache interne).
3. Il effectue son calcul de flou.
4. Il force l'écriture du résultat à travers le bus mémoire jusque dans la **VRAM**.
5. Ce processus (Lecture VRAM → Calcul → Écriture VRAM) est répété ~12 fois par frame pour le Bloom.

Sur une architecture de PC portable (Optimus), le bus mémoire graphique est souvent partagé, contraint thermiquement, et les changements de contexte OpenGL (FBO bind) forcent le driver à opérer des synchronisations lourdes. Le GPU passe plus de temps à attendre que la mémoire VRAM réponde qu'à faire des mathématiques.

---

## 4. La Solution Théorique : Single-Pass Downsample (Compute Shader SPD)

La solution la plus moderne (popularisée par la technologie AMD FidelityFX SPD) consiste à abandonner les Framebuffers et les Fragment Shaders au profit d'un **Compute Shader unique**.

### Le cycle ultra-rapide (SPD)
Un Compute Shader n'est pas limité à la logique d'un pixel d'écran. Il manipule la mémoire de manière brute et donne accès à la **Local Shared Memory (LDS)** (ou *Group Shared Memory* en GLSL).

1. **Zéro State Change :** On ne lie aucun Framebuffer. Le Compute Shader est "dispatché" une seule fois.
2. **Utilisation du Cache L1/L2 :** Le shader lit l'image HDR depuis la VRAM. Il calcule le premier niveau de réduction (MIP 1).
3. **Le miracle de la Shared Memory :** *Au lieu d'écrire ce MIP 1 en VRAM*, les threads du GPU stockent ce résultat dans la **Local Shared Memory** (une mémoire SRAM située physiquement à l'intérieur du bloc de calcul du GPU, aussi rapide qu'un cache L1).
4. **Calcul en cascade :** Les threads lisent immédiatement le MIP 1 depuis cette Shared Memory ultra-rapide pour calculer le MIP 2, puis le MIP 3, etc.
5. **Écriture finale :** Une fois tous les niveaux calculés dans le cache interne, le GPU fait une seule écriture groupée vers la VRAM.

---

## 5. Synthèse des Gains Potentiels (Évaluation)

Si ce remaniement est entrepris dans le futur, voici l'évaluation formelle des gains attendus :

| Métrique | Actuel (Fragment Ping-Pong) | Objectif (Compute SPD) | Impact Technique |
| :--- | :--- | :--- | :--- |
| **Appels de Dessin (Draw Calls)** | ~12 (Render Quads) | **1 (DispatchCompute)** | Effondrement de l'overhead CPU du pilote NVIDIA. |
| **Changements d'États (FBO)** | ~12 (BindFramebuffer) | **0** | Disparition des "trous" sur la timeline GPU de Tracy Profiler. |
| **VRAM Bandwidth (Lectures/Écritures)**| ~12x cycles VRAM lents | **1x cycle VRAM** (le reste en cache L1) | Gain direct de millisecondes GPU, refroidissement du bus mémoire (Crucial sur Laptop Optimus). |

> [!WARNING]
> **Complexité d'implémentation : Très Haute.** 
> L'architecture SPD exige une maîtrise absolue des `Work Groups` GLSL, des `glMemoryBarrier` (pour éviter les conditions de course entre les cœurs du GPU), et nécessite que la carte graphique supporte les opérations atomiques avancées (généralement OpenGL 4.3+).

---

## 6. Références Officielles et Papiers Techniques

Pour approfondir ces concepts ou préparer une future implémentation, voici les ressources techniques officielles recommandées :

### AMD (FidelityFX SPD)
AMD a été le premier à standardiser et open-sourcer cette technique de *Single-Pass Downsampling* sous la bannière FidelityFX, prouvant qu'elle était universellement applicable et performante sur toutes les architectures (y compris NVIDIA).
- **Dépôt GitHub (Source & Implémentations) :** [GPUOpen-Effects / FidelityFX-SPD](https://github.com/GPUOpen-Effects/FidelityFX-SPD)
- **Documentation et Page Officielle :** [GPUOpen - FidelityFX SPD](https://gpuopen.com/fidelityfx-spd/)

### NVIDIA (Architecture Maxwell & Compute Shaders)
Bien que NVIDIA n'ait pas de "nom commercial" public concurrent direct pour le SPD d'AMD, la fondation matérielle qui rend cette technique si performante (l'accès massif et ultrarapide à la *Local Shared Memory* - LDS) a été la pierre angulaire de l'architecture **Maxwell** (la génération de ta GTX 950M).
- Les présentations de NVIDIA de l'ère Maxwell/Pascal insistent particulièrement sur le transfert des effets de Post-Processing complexes (Mipmapping, DOF, Bloom) depuis des passes de *Fragment Shaders* vers des **Compute Shaders**.
- **Référence d'Architecture NVIDIA :** Le blog post officiel [Advanced API Performance: Shaders](https://developer.nvidia.com/blog/advanced-api-performance-shaders/) détaille l'occupation des ondes (Warps) et la gestion matérielle des shaders.
- **Le cœur mathématique du Downsample :** Pour comprendre comment la *Shared Memory* évite les allers-retours VRAM lors de la création de mipmaps, il faut se référer au papier fondateur de NVIDIA : [Optimizing Parallel Reduction in CUDA](https://developer.download.nvidia.com/assets/cuda/files/reduction.pdf). Bien qu'écrit pour CUDA, ce document dicte la façon dont les *Compute Shaders* OpenGL doivent structurer leur `Local Shared Memory` pour maximiser la bande passante de l'architecture NVIDIA.
