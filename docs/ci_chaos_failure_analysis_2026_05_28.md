# Analyse Technique de l'Échec de la CI Nocturne (Run #26578536989)

Ce document présente l'analyse post-mortem détaillée des échecs constatés lors de la première exécution du fuzzer temporel et du test de stress en environnement d'intégration continue (GitHub Actions).

---

## 1. Description des Symptômes

Le run de CI [26578536989](https://github.com/yoyonel/suckless-odin/actions/runs/26578536989) a échoué avec le rapport suivant :
```
Finished 79 tests in 10m0.895562077s. 2 tests failed.
 - test_gl.test_env_manager_chaos_stress
   State machine failed to recover and settle to .Idle after fuzzer completion
 - test_gl.test_env_manager_nonexistent_hdr_deadlock
   subsequent transition should be accepted after a load failure
```

Les deux échecs concernent la réinitialisation de la State Machine de l'environnement (`Env_Manager`) vers son état stable `.Idle`.

---

## 2. Analyse Comparative des Environnements

Pour comprendre l'échec, nous avons extrait le seed stochastique utilisé par la CI (`3234`) et exécuté localement la même commande de reproduction :
```bash
task test-chaos-seed 3234
```

### Résultats de la comparaison :
*   **En local** : 100% de réussite. Les 79 tests passent avec succès en **1 minute 11 secondes**.
*   **En CI (GitHub Runner)** : Échec de 2 tests. Exécution globale extrêmement lente en **10 minutes 0 secondes**.

Le facteur de ralentissement sur la machine virtuelle de CI est d'environ **x10**.

### Pourquoi cette différence ?
Le projet utilise OpenGL 4.5. Sur ton poste de développement local, le moteur bénéficie d'une **accélération graphique matérielle (GPU)**.
Sur le runner GitHub Actions (headless), il n'y a pas de GPU physique. Le pilote graphique utilisé est **Mesa / LLVMpipe**, qui émule l'intégralité du pipeline OpenGL et des calculs de Compute Shaders (génération de l'IBL, mips de spéculaire, irradiance harmonique) de manière logicielle sur un CPU virtuel limité à 2 cœurs.

---

## 3. Autopsie Détaillée des Échecs

### Échec A : `test_env_manager_nonexistent_hdr_deadlock`

Le code d'origine du test utilisait une attente statique basée sur des hypothèses de timing matériel local :
```odin
// Déclenche le chargement d'un fichier inexistant
accepted := sc.env_manager_trigger_transition(&s.env_mgr, "nonexistent_file_that_does_not_exist.hdr")

// Attente codée en dur de 200ms
time.sleep(200 * time.Millisecond)

// Polling
sc.scene_update(&s, 0.016)

// Asserte le retour à Idle
testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)
```

#### Cause de l'échec :
1.  Le thread principal s'endort pendant 200ms.
2.  Le thread secondaire d'arrière-plan (`AsyncLoader`) doit être planifié par l'OS de la VM, ouvrir un fichier inexistant et lever une erreur via STBI.
3.  En environnement matériel, cela prend < 5ms. 200ms est largement suffisant.
4.  Sur un processeur virtuel de CI fortement sollicité avec rendu logiciel, l'OS peut mettre plus de 200ms à simplement planifier (schedule) le thread secondaire, ou la résolution de fichier système peut être ralentie.
5.  Le thread principal se réveille, effectue sa mise à jour alors que le thread secondaire n'a pas encore fini de lever l'échec. L'état est toujours `.Loading` (busy). Le test échoue à tort en concluant à un deadlock, alors qu'il s'agit simplement d'un retard de planification !

---

### Échec B : `test_env_manager_chaos_stress`

Ce test bombarde le gestionnaire de transitions concurrentes à haute fréquence pendant 5 secondes, puis coupe le fuzzer et applique une phase de drainage avec un timeout de **5.0 secondes** pour laisser la dernière transition active se terminer proprement.

#### Cause de l'échec :
1.  Dans les logs de la CI, nous constatons qu'une seule itération de calcul d'IBL logicielle (irradiance + spéculaire progressive) met **plus de 3,1 secondes** à s'exécuter sous Mesa.
2.  Si le fuzzer soumet une transition valide juste avant l'arrêt du bombardement, cette transition commence son cycle.
3.  Le temps de charger le fichier + calculer l'IBL logiciel + réaliser le fondu dépasse la limite de 5.0 secondes imposée par la phase de drainage.
4.  Le test expire et échoue en affirmant que la State Machine a fui ou s'est bloquée, alors qu'elle était simplement en train de calculer sagement sa transition ralentie par le rendu logiciel.

---

## 4. Plan de Résolution (Timing-Safe Testing)

La State Machine et le moteur de transition sont parfaitement sains et robustes contre les deadlocks (preuve en est le succès local instantané sous le même seed). Le problème réside uniquement dans les contraintes temporelles rigides des assertions de tests.

La correction consiste à **rendre les tests insensibles à la vitesse d'exécution** en adoptant un paradigme de **polling dynamique** :

### Correction A : Rendre `test_env_manager_nonexistent_hdr_deadlock` dynamique
Au lieu de dormir stupidement pendant 200ms, nous mettons en place une boucle de polling avec un timeout de sauvegarde de 10 secondes :
```odin
deadline = time.now()
for s.env_mgr.transition_state == .Loading {
    if time.duration_milliseconds(time.diff(deadline, time.now())) > 10000.0 {
        break
    }
    sc.scene_update(&s, 0.016)
    time.sleep(10 * time.Millisecond)
}
```
*   **Bénéfice local** : S'exécutera en 1 ou 2ms (au lieu d'attendre 200ms inutiles).
*   **Bénéfice CI** : S'adaptera dynamiquement à la vitesse du runner sans jamais générer de faux positifs.

### Correction B : Sécuriser la phase de drainage du Test Chaos
Augmenter le timeout de drainage post-stress de **5.0 secondes** à **15.0 secondes**.
*   **Bénéfice** : Laisse une marge de sécurité colossale pour l'exécution logicielle sur la CI, tout en s'arrêtant immédiatement dès que la machine redevient Idle (aucun surcoût temporel en local).
