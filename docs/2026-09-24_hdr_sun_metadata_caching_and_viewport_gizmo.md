# Cache des Métadonnées Solaires HDR, Contrôles ImGui & Manipulation ImGuizmo 3D

**Date** : 24 Septembre 2026  
**Auteur** : Antigravity  
**Statut** : ☀️ Spécification Technique & Guide d'Implémentation  
**Fichiers concernés** :
- [`assets/textures/hdr/env_metadata.json`](file:///home/latty/Prog/__PERSO__/suckless-odin/assets/textures/hdr/env_metadata.json)
- [`src/scene/env_metadata_cache.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_metadata_cache.odin)
- [`src/scene/async_loader.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/async_loader.odin)
- [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin)
- [`src/scene/scene.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/scene.odin)
- [`src/rendering/sun_shadow.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/sun_shadow.odin)
- [`src/rendering/types/types.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/types/types.odin)
- [`src/core/session/session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/core/session/session.odin)
- [`src/app/session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/app/session.odin)
- [`src/gui/gui.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui.odin)
- [`src/gui/gui_env_map.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_env_map.odin)
- [`src/gui/gui_volumetric.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_volumetric.odin)
- [`tests/test_sun_detection.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/test_sun_detection.odin)
- [`tests/test_session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/test_session.odin)

---

## 1. Contexte & Problématique

Dans le moteur, l'éclairage volumétrique et les ombres directionnelles exploitent la position géométrique et statistique du soleil calculée à partir des textures d'environnement panoramiques HDR (4K).

Auparavant, la détection du soleil s'exécutait systématiquement lors de chaque chargement d'image HDR via la procédure [`sun_detect_from_fp16`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/sun_shadow.odin) :
- Parsing intégral de **$33.5\times 10^6$ half-floats (FP16)** sur le worker thread.
- Recherche du pic de luminance par projection cosinus pondérée.
- Analyse statistique de clustering (seuil à $0.80 \times I_{\max}$ pour quantifier la confiance et le diamètre angulaire).

Sur une image 4K ($4096 \times 2048$), cette passe nécessitait entre **$1.8\text{ s}$ et $2.2\text{ s}$ de temps CPU**, retardant d'autant la finalisation du chargement asynchrone IBL alors même que les environnements HDR distribués sont statiques.

De plus :
1. L'utilisateur ne disposait d'aucun moyen pour forcer manuellement le recalcul sans redémarrer le moteur.
2. Il était impossible de réorienter manuellement la direction du soleil (azimuth / élévation) dans les environnements diffus ou studio sans écrasement automatique.
3. Aucune manipulation directe du soleil n'existait dans le viewport 3D.

---

## 2. Architecture du Cache Persistant (`env_metadata.json`)

Le module [`src/scene/env_metadata_cache.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_metadata_cache.odin) introduit un cache persistant au format JSON stocké dans [`assets/textures/hdr/env_metadata.json`](file:///home/latty/Prog/__PERSO__/suckless-odin/assets/textures/hdr/env_metadata.json).

### 2.1. Structure des Entrées

Chaque environnement est indexé par son nom de fichier brut (ex. `"cedar_bridge_2_4k.hdr"`) :
```json
{
  "cedar_bridge_2_4k.hdr": {
    "direction": [0.4526, 0.8326, 0.3197],
    "azimuth": 35.24,
    "elevation": 56.36,
    "peak_intensity": 18520.0,
    "confidence": 163,
    "sun_detected": true
  }
}
```

### 2.2. Intégration dans le Loader Asynchrone

Dans [`src/scene/async_loader.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/async_loader.odin) :
1. Lors d'une requête de chargement `async_loader_request`, un drapeau optionnel `force_recompute_sun: bool` est transmis.
2. Si `force_recompute_sun == false`, le worker thread interroge le cache via `env_metadata_cache_lookup(hdr_path)`.
   - **Cache HIT** : temps de résolution = **$0.0\text{ ms}$** (gain immédiat de $\approx 2\text{ s}$).
   - **Cache MISS** ou `force_recompute_sun == true` : exécution de `sun_detect_from_fp16`, puis sauvegarde automatique via `env_metadata_cache_save`.

---

## 3. Contrôles ImGui & Mappage Bidirectionnel

### 3.1. Onglet Environment Map (`src/gui/gui_env_map.odin`)

L'onglet Env Map expose désormais la section **"Sun Lighting & Direction"** :
- **Statut dynamique** :
  - Vert : `[Sun Detected (Direct Sunlight)]` si `sun_detected == true`.
  - Orange : `[Fallback Direction (Indoor / Diffuse)]` si le soleil n'est pas détecté.
- **Métriques d'analyse** : Affichage d'Azimuth, Elevation, Confidence (nombre de texels au-dessus du seuil), Peak Intensity.
- **Bouton `Recompute Sun Analysis (CPU)`** : Déclenche `scene_change_env(..., force_recompute_sun = true)` pour réanalyser l'HDR en mémoire et régénérer le JSON.
- **Checkbox `Manual Override`** : Active ou désactive le forçage manuel.
- **Checkbox `Show 3D Gizmo`** : Affiche ou masque la sphère solaire et le gizmo dans le viewport 3D.
- **Sliders `Azimuth` (-180° à +180°) & `Elevation` (0° à 90°)** : Pilotent la direction unitaire et recalculent en temps réel les matrices d'ombres et le raymarching volumétrique.

### 3.2. Onglet Volumétrique (`src/gui/gui_volumetric.odin`)

Les contrôles de direction du soleil sont également synchronisés dans l'onglet **Volumétrique** sous le mode `Sun (Directional)` :
- Modification conjointe des paramètres de raymarching (intensité volumétrique, distance max des rayons).
- Contrôle de la direction solaire (azimuth / élévation) avec invalidation automatique de l'historique TAA (`vr.history_valid = false`) pour éliminer le ghosting lors des rotations rapides.

---

## 4. Manipulation Directe par ImGuizmo 3D dans le Viewport

Le soleil est une source **directionnelle à l'infini** (vecteur unitaire $\hat{\mathbf{d}}$ sans position physique). Pour l'afficher et le manipuler dans le frustum fini de la caméra sans dépasser le plan lointain (`FAR_PLANE = 60.0` / `100.0`), le moteur projette une ancre géométrique sur la voûte céleste :

### 4.1. Positionnement Céleste & Raycast Picking

1. **Ancrage relatif à la caméra (Zéro Parallaxe)** :
   - La skybox est rendue sans translation (`view_no_translate[3] = 0`), simulant un environnement à distance infinie.
   - Pour que le gizmo 3D soit **strictement superposé au soleil visuel de la skybox** quel que soit le déplacement de la caméra dans la scène ($\mathbf{C}_{\text{cam}}$), la position de l'ancre est centrée sur la caméra :
     $$\mathbf{P}_{\text{gizmo}} = \mathbf{C}_{\text{cam}} + \hat{\mathbf{d}}_{\text{sun}} \times R_{\text{virtuel}} \quad (R_{\text{virtuel}} \approx 25.0\text{ unités})$$
   - Cela élimine toute parallaxe : le vecteur caméra-gizmo $(\mathbf{P}_{\text{gizmo}} - \mathbf{C}_{\text{cam}})$ est strictement colinéaire à $\hat{\mathbf{d}}_{\text{sun}}$.
2. **Raycast Picking 3D** ([`scene_pick_entity`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/scene.odin#L902)) :
   - Un clic dans la direction du soleil dans le ciel teste l'intersection rayon-sphère contre $(\mathbf{P}_{\text{gizmo}}, r = 1.8)$.
   - En cas d'impact, la sélection passe à `.Sun` et le gizmo apparaît.

### 4.2. Mécanique de Translation & Dérivation Astronomique

Dans [`draw_point_light_gizmo`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui.odin#L438) :
1. **Translation $\rightarrow$ Direction** :
   - L'utilisateur déplace le gizmo (axes $X, Y, Z$) sur la voûte céleste.
   - Le moteur calcule le nouveau vecteur direction par soustraction de la position caméra :
     $$\mathbf{V} = \mathbf{P}' - \mathbf{C}_{\text{cam}}, \quad \hat{\mathbf{d}}_{\text{sun}} = \frac{\mathbf{V}}{\|\mathbf{V}\|}$$
   - La distance $\|\mathbf{V}\|$ met à jour dynamiquement `gizmo_distance` si l'utilisateur souhaite approcher ou éloigner le repère.
2. **Dérivation astronomique** ([`sun_dir_to_angles`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/sun_shadow.odin)) :
   - **Élévation** : $\theta = \arcsin(y)$ ($0^\circ$ à l'horizon, $90^\circ$ au zénith).
   - **Azimuth** : $\phi = \operatorname{atan2}(z, x)$ (orientation boussole $-180^\circ$ à $+180^\circ$).
3. **Mise à jour immédiate** :
   - `override_enabled = true` (préserve le réglage contre les rechargements d'envmap).
   - Invalidation de l'ortho-projection d'ombres (`sun_shadow.is_dirty = true`).
   - Invalidation de l'historique volumétrique (`vr.history_valid = false`) pour éliminer le ghosting TAA lors du déplacement.
   - Synchronisation des sliders ImGui dans les onglets *Env Map* et *Volumetric*.

### 4.3. Colorimétrie du Soleil : Auto-Détection Chromatique & Contrôle Manuel

1. **Extraction Chromatique Pondérée dans `sun_detect_from_fp16`** :
   - Durant le scan du hotspot solaire (texels au-dessus du seuil de luminance adaptatif), le moteur accumule la couleur pondérée par la luminance :
     $$\mathbf{C}_{\text{acc}} = \sum_{i \in \text{hotspot}} (R_i, G_i, B_i) \times \text{lum}_i$$
   - La chromaticité unitaire est normalisée par la composante maximale afin de conserver la teinte pure sans tronquer l'intensité :
     $$\mathbf{c}_{\text{sun}} = \frac{\mathbf{C}_{\text{acc}}}{\max(R_{\text{acc}}, G_{\text{acc}}, B_{\text{acc}})}$$
   - Valeurs extraites sur les cartes de référence :
     - `cedar_bridge_2_4k.hdr` : $\text{RGB}(1.00, 0.89, 0.90)$ (soleil chaud naturel d'après-midi).
     - `river_alcove_4k.hdr` : $\text{RGB}(1.00, 0.99, 0.98)$ (lumière blanche directe zénithale).
     - `small_cathedral_02_4k.hdr` : $\text{RGB}(1.00, 0.69, 0.31)$ (lumière ambrée / vitrail cathédrale).
     - `abandoned_garage_4k.hdr` : $\text{RGB}(0.76, 0.87, 1.00)$ (lumière bleutée du ciel diurne à travers la verrière du toit).
     - `neon_photostudio_4k.hdr` : $\text{RGB}(1.00, 0.99, 0.95)$ (lumière blanche extérieure entrant par la grande baie vitrée).

2. **Détection Bi-Mode : Soleil Direct Extérieur vs Entrées de Lumière Intérieures (Apertures)** :
   - **Mode 1 : Plein Soleil Direct (`Direct_Sun`)** : Activé si $I_{\max} \ge 500$ et ratio de contraste $\ge 200$. Isole le disque solaire zénithal avec seuil adaptatif de 99.99ème percentile.
   - **Mode 2 : Entrées de Lumière Intérieures (`Indoor_Aperture`)** : Pour les scènes architecturales et intérieures où le soleil direct est absent ou masqué, le moteur scanne l'hémisphère supérieur ($y \ge H/2$, élévation $\ge 0^\circ$). Il localise l'ouverture dominante (fenêtre, verrière, puits de lumière) via un cône angulaire de $65^\circ$ centré sur le pic céleste et une pondération quadratique $w_i = \text{lum}_i^2$.
   - **Indicateur UI & Réticule Panoramique** :
     - Soleil direct : Badge `[Sun Detected (Direct Sunlight)]` (or) et réticule `"SUN"`.
     - Ouverture intérieure : Badge `[Aperture Detected (Window / Skylight)]` (cyan) et réticule `"APERTURE"`.

3. **Sérialisation dans le Cache Persistant** :
   Les champs `"color": [r, g, b]` et `"is_aperture": bool` sont stockés dans [`assets/textures/hdr/env_metadata.json`](file:///home/latty/Prog/__PERSO__/suckless-odin/assets/textures/hdr/env_metadata.json), évitant tout recalcul CPU au runtime.

3. **Injection Dynamique dans le Shader Volumétrique** :
   Dans [`src/rendering/volumetric.odin#L716`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/rendering/volumetric.odin#L716) :
   ```odin
   sun_color := sun_shadow_get_effective_color(sun_shadow)
   gl.Uniform3f(vr.loc_dir_sun_color, sun_color.x, sun_color.y, sun_color.z)
   ```
   La couleur transmise à `u_sun_color` dans [`volumetric_raymarch_directional.frag`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/postfx/volumetric_raymarch_directional.frag) teinte fidèlement les god rays volumétriques.

4. **Contrôles Manuels ImGui & Palette Fuzzy Search** :
   - Échantillon de couleur interactif (`imgui.ColorButton`) et label informatif (Auto-détecté vs Override vs Fallback).
   - Checkbox `Override Color` et sélecteur `ColorEdit3("Manual Sun Color")` avec bouton `Reset Color`.
   - Accessible via les onglets *Env Map* et *Volumetric*, et indexé avec les mots-clés `color`, `tint`, `chromaticity`.

---

## 5. Persistance & Restauration Intégrale (100% Session State)

Conformément aux règles de synchronisation UI/UX :

1. **Structure de Persistance** :
   Dans [`src/core/session/session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/core/session/session.odin) (`Volumetric_Session_Settings`) :
   ```odin
   sun_azimuth:          f32     `json:"sun_azimuth"`,
   sun_elevation:        f32     `json:"sun_elevation"`,
   sun_override_enabled: bool    `json:"sun_override_enabled"`,
   sun_show_gizmo:       bool    `json:"sun_show_gizmo"`,
   sun_color:            mt.Vec3 `json:"sun_color"`,
   sun_color_override:   bool    `json:"sun_color_override"`,
   ```
2. **Sauvegarde & Extraction** :
   Dans [`src/app/session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/app/session.odin) (`extract_session_state`).
3. **Restauration Inconditionnelle** :
   Dans [`src/app/session.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/app/session.odin) (`restore_session_state`), si `sun_override_enabled` ou `sun_color_override` étaient actifs, les orientations et couleurs manuelles sont restaurées sans altération.
4. **Immunité au Swap Asynchrone** :
   Dans [`src/scene/env_manager.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/scene/env_manager.odin#L1172), lors du remplacement final des textures IBL :
   ```odin
   prev_dir := scene.sun_shadow.detection.direction
   prev_az := scene.sun_shadow.detection.azimuth
   prev_el := scene.sun_shadow.detection.elevation
   scene.sun_shadow.detection = mgr.async_result.sun_detection
   if scene.sun_shadow.override_enabled {
       scene.sun_shadow.detection.direction = prev_dir
       scene.sun_shadow.detection.azimuth = prev_az
       scene.sun_shadow.detection.elevation = prev_el
   }
   ```
   L'orientation et la couleur définies par l'utilisateur ne risquent ainsi jamais d'être écrasées à la fin du chargement.

---

## 6. Recherchabilité Exhaustive (Fuzzy Search & Go To)

Toutes les commandes liées au soleil sont immédiatement trouvables dans la palette de recherche globale :
- **Mots-clés supportés** : `sun`, `direction`, `azimuth`, `elevation`, `gizmo`, `override`, `recompute`, `analysis`, `lighting`, `position`.
- **Accès direct** :
  - Dans la vue filtrée **Env Map** ([`draw_filtered_env_map`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_env_map.odin#L253)) : accès au statut, au bouton de recalcul, aux toggles et aux sliders. Bouton `Go To` vers l'onglet 11.
  - Dans la vue filtrée **Volumetric** ([`draw_filtered_volumetric`](file:///home/latty/Prog/__PERSO__/suckless-odin/src/gui/gui_volumetric.odin#L527)) : accès à l'intensité, aux toggles et aux sliders. Bouton `Go To` vers l'onglet 10.

---

## 7. Validation Automatisée

| Périmètre | Commande | Résultat |
| :--- | :--- | :--- |
| **Couverture Persistance** | `python3 scripts/check_persistence.py` | **100% SUCCESS** (29 GUI fields, 51 persisted fields, 0 omission) |
| **Tests Unitaires** | `task test-unit` | **119/119 tests réussis** (inclut `test_env_metadata_cache_lookup`, `test_sun_angles_dir_roundtrip`, `test_session.odin`) |
| **Linting & Documentation** | `task lint` | **0 warning, 0 error** (Odin check strict style, GL symbols, Dear ImGui safety, Markdown links audit) |
| **Tests CLI & Commandes** | `task test-cli` | **14/14 tests réussis** |
| **Compilation Native** | `task build` | **Succès** (binaire `build/debug/suckless-odin`) |
