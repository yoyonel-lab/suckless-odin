# Analyse & Abandon Préalable — Scissor 2D Bounding Box pour Volumétrique

- **Date** : 20 Septembre 2026
- **Branche** : `feat/perf-volumetric-harness`
- **Statut** : ❌ **ABANDONNÉE SANS IMPLÉMENTATION** (Gain effectif mesuré/simulé à 0.0% sur la scène de référence)

---

## 1. Hypothèse Initiale

L'idée théorique consistait à projeter la sphère 3D de la source lumineuse (`position`, `radius`) sous forme de boîte englobante 2D en coordonnées écran, puis à activer `glEnable(GL_SCISSOR_TEST)` et `glScissor` pendant la passe de raymarching pour épargner au GPU le calcul des pixels hors de portée.
Le gain escompté annoncé était de **-25% à -50% de pixels raymarchés**.

---

## 2. Évaluation Géométrique Préalable (Simulation Réelle)

Conformément à l'exigence de validation stricte avant modification de code, une simulation géométrique a été conduite sur les coordonnées effectives du moteur (`session.json` et `--benchmark`) :

* **Position Caméra** : $(0.0, 0.0, 20.0)$
* **Position Point Light** : $(16.75, 13.37, -1.80)$
* **Rayon de la Lumière (`radius`)** : $50.0\text{ m}$ (valeur nominale dans `session.json:231`)
* **Distance Réelle Caméra $\leftrightarrow$ Lumière** :
  $$d = \sqrt{16.75^2 + 13.37^2 + (20.0 - (-1.80))^2} = \mathbf{30.57\text{ m}}$$

### Constat Bloquant (Immersion de Caméra)
$$d\ (30.57\text{m}) < \text{Radius}\ (50.0\text{m})$$

La caméra est **entièrement immergée à l'intérieur de la sphère lumineuse**.
En conséquence :
1. La boîte englobante projetée de la sphère enveloppe tout le champ visuel ($100\%$ de la surface écran).
2. Le scissor rectangle résultant est $[0, 0, W, H]$ $\implies$ **0 pixel éliminé (0.0% de gain)**.

---

## 3. Redondance avec le Shader Existant

L'inspection de [`shaders/postfx/volumetric_raymarch.frag:91`](../shaders/postfx/volumetric_raymarch.frag#L91) a par ailleurs démontré que le test d'exclusion est **déjà implémenté au niveau du fragment shader** :
```glsl
if (!intersect_ray_sphere(u_cam_pos, ray_dir, u_light_pos, u_light_radius, t_enter, t_exit)) {
    FragColor = vec4(0.0, 0.0, 0.0, 1.0); // Completely outside light volume
    return;
}
```
Pour les pixels dont le rayon ne traverse pas la lumière, le GPU effectue déjà une sortie précoce (`return`) sans exécuter les 32 pas de raymarching ni les 32 lectures du shadow cubemap.

---

## 4. Conclusion & Décision Opérationnelle

* **Verdict** : L'optimisation Scissor 2D ne produit aucun gain sur les scènes réelles où le rayon de lumière englobe la scène.
* **Décision** : **Abandon immédiat sans écriture de code inutile**.
* **Orientation retenue** : Se concentrer sur les optimisations intrinsèques à l'intérieur de la boucle de raymarching :
  1. **Early Ray Termination** (sortie de boucle dès saturation de transmittance).
  2. **Checkerboard Raymarching $2\times 2$ + TAA** (réduction de 50% des itérations et fetches de texture).
