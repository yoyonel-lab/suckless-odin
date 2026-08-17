# Spécification Formelle TLA+ de la Machine à États `Env_Manager`

Ce répertoire contient le projet de preuve formelle mathématique pour l'automate asynchrone de notre `Env_Manager`.

TLA+ (Temporal Logic of Actions) est un langage formel fondé sur la théorie des ensembles et la logique temporelle, conçu par Leslie Lamport (lauréat du prix Turing). Contrairement à des tests unitaires ou de chaos, TLA+ ne s'exécute pas : il modélise le système sous forme de transitions logiques afin d'explorer **exhaustivement et mathématiquement** 100% de l'arbre des états et prouver l'absence totale de deadlocks, de data-races logiques ou d'invariants violés.

---

## 1. À quoi sert le binaire Java `tla2tools.jar` ?

Le fichier `tla2tools.jar` est l'archive Java officielle compilée par Microsoft Research et la communauté TLA+. C'est la boîte à outils officielle qui donne vie à nos formules mathématiques. Il contient quatre composants fondamentaux :

1. **SANY (Semantic Analyzer for Y?)** : Le compilateur/analyseur sémantique qui parse nos fichiers `.tla`, vérifie la syntaxe mathématique et s'assure de la cohérence des définitions logiques.
2. **TLC (Temporal Logic Checker)** : Le **Model Checker de modèle explicite** (Explicit-State Model Checker). Son rôle est d'exécuter une recherche en largeur (BFS) sur l'ensemble de l'arbre des transitions logiques à partir de la formule initiale `Init`.
3. **TLATrace** : L'outil de diagnostic. Si un invariant ou une propriété de vivacité est enfreint, il reconstruit et affiche l'ordonnancement exact étape par étape (Error Trace) qui mène au bug.
4. **L'exportateur de graphes** : Il convertit le graphe complet des états explorés au format standard Graphviz (fichier `.dot`) pour nous permettre de le visualiser.

En résumé, c'est ce binaire qui réalise le calcul intensif d'exploration d'états pour prouver que notre automate est 100% sûr.

---

## 2. Modélisation de notre Automate dans ce Répertoire

### Fichiers sources

* `EnvManagerVerification.tla` : Le modèle formel complet décrivant les variables (`envState`, `loaderState`, `pendingRequest`, `iblComplete`) et les règles de transition (`TriggerTransition`, `ManagerTick`, `LoaderSucceeds`, `LoaderFails`, `GPURendersIBL`).
* `EnvManagerVerification.cfg` : Le fichier de configuration qui indique à TLC quel est le point d'entrée (`Spec`), les invariants à vérifier (`TypeOK`, `SafeTransition`), et les propriétés de vivacité (`Liveness`).

---

## 3. Les Invariants du Modèle

Pour valider notre automate, nous avons défini 3 invariants ciblés :

### Invariant 1 : La Cohérence Structurelle (`TypeOK`)

Garantit que chaque variable contient toujours une valeur légitime appartenant à notre univers (pas de corruption ou d'état impossible).

### Invariant 2 : L'Exclusion Mutuelle GPU (`SafeTransition`)

Garantit qu'aucune génération IBL GPU ne commence tant que le loader asynchrone n'a pas entièrement cédé la propriété de ses données (le loader doit être revenu à `Idle` quand l'automate est en `Wait_IBL`). Cela garantit l'absence de data-race.

### Invariant 3 : L'Absence de Deadlock et Vivacité (`Liveness`)

Garantit que, peu importe les interruptions de requêtes ou les échecs disques du loader, le système est contraint de toujours revenir à son état stable `Idle` (vivacité temporelle `[]<> (envState = "Idle")`).

---

## 4. Automatisation via le `Taskfile.yml`

Pour rendre la vérification et la visualisation 100% reproductibles sans aucune installation manuelle pénible (ni pollution de l'historique Git par des fichiers binaires), nous avons intégré deux recettes dédiées dans notre `Taskfile.yml`.

### Comment lancer la vérification formelle ?

Exécute simplement la commande suivante à la racine :

```bash
task formal-verify
```

**Ce que fait cette commande en arrière-plan :**

1. Elle crée un répertoire `.tla-cache/` local (ignoré par Git) et y télécharge automatiquement le binaire officiel `tla2tools.jar` s'il n'est pas déjà présent.
2. Elle lance un conteneur Docker `alpine:latest` isolé.
3. Elle y installe à la volée le JRE OpenJDK 17 de manière éphémère.
4. Elle exécute TLC sur notre spécification formelle.

### Comment régénérer les visualisations graphiques ?

Pour reconstruire et mettre à jour le schéma graphique de l'automate :

```bash
task formal-visualize
```

**Ce que fait cette commande en arrière-plan :**

1. Elle demande à TLC de générer et d'exporter le graphe complet de transition au format Graphviz `EnvManagerVerification.dot`.
2. Elle utilise l'outil `dot` de ton système hôte pour compiler ce fichier textuel en deux formats d'images (PNG et SVG vectoriel).
3. Ces images générées (`verification/EnvManagerVerification.png` et `.svg`) sont ignorées par Git pour ne pas polluer l'historique, mais restent instantanément consultables localement pour ton plaisir d'analyse !

---

## 5. Guide d'Interprétation des Rapports TLC

Pour assurer la maintenabilité de la spécification formelle par l'équipe, cette section détaille la structure des sorties de TLC, fournit les clés d'analyse pour chaque métrique et récapitule les erreurs classiques documentées dans l'ouvrage de référence de Leslie Lamport, *Specifying Systems*.

### 5.1 Analyse pas-à-pas d'un rapport nominal

Voici le décodage technique des lignes émises lors d'une exécution sans erreur :

#### `Implied-temporal checking--satisfiability problem has 1 branches.`

* **Signification** : Indique l'initialisation du moteur de vérification temporelle. TLC convertit les propriétés temporelles (telles que `Liveness`) en un automate de Büchi équivalent. Cette ligne signale le nombre de branches logiques évaluées pour démontrer la validité temporelle.

#### `Finished computing initial states: 1 distinct state generated.`

* **Signification** : Résultat de l'évaluation du prédicat `Init`. TLC identifie et instancie tous les états de départ possibles. Pour notre modèle, il existe un unique état initial déterministe où toutes les variables d'état sont fixées à leur valeur de repos.

#### `Progress(6) at [timestamp]: 9 states generated, 7 distinct states found, 0 states left on queue.`

* **Signification** : Métriques de progression de la recherche en largeur (Breadth-First Search) :
  * `states generated` : Nombre total de transitions calculées en appliquant la relation `Next`.
  * `distinct states found` : Nombre de configurations d'état uniques découvertes. Ici, sur 9 transitions calculées, seules 7 mènent à des états physiques distincts, traduisant la présence de cycles retournant à des états connus.
  * `states left on queue` : Nombre d'états restants à explorer. La valeur `0` indique la fin de l'exploration exhaustive de l'espace d'états accessible.

#### `Checking temporal properties for the complete state space with 7 total distinct states...`

* **Signification** : Phase d'évaluation des formules temporelles complexes. Une fois l'arbre des états cartographié, TLC valide la conformité des propriétés temporelles sur l'ensemble des chemins d'exécution infinis représentés par le graphe.

#### `Model checking completed. No error has been found.`

* **Signification** : L'espace d'états a été entièrement parcouru et validé. Tous les invariants de sécurité (`TypeOK`, `SafeTransition`) sont vrais sur chaque état, et les formules de vivacité temporelle (`Liveness`) sont satisfaites sur tous les comportements infinis possibles.

#### `Estimates of the probability that TLC did not check all reachable states... (optimistic): val = 7.6E-19`

* **Signification** : Évaluation de la probabilité de collision de signature (fingerprint). TLC identifie chaque état par une empreinte de 64 bits. En théorie, deux configurations d'états distinctes pourraient générer la même empreinte, masquant ainsi une partie de l'espace de recherche.
* **Généralisation** : La valeur de probabilité fournie (ici $7.6 \times 10^{-19}$) estime la probabilité mathématique qu'une telle collision ait eu lieu. Dans les modèles à forte volumétrie d'états, cette métrique croît. Si le risque devient significatif, TLC permet de changer de polynôme de hachage via l'option `-fp` ou d'activer d'autres ensembles de fingerprints.

#### `The depth of the complete state graph search is 6.`

* **Signification** : La distance maximale (en nombre de transitions) séparant l'état initial de l'état accessible le plus éloigné dans le graphe orienté. Cela mesure la longueur du cycle séquentiel le plus long.

#### `The average outdegree of the complete state graph is 1 (minimum is 0, maximum 2).`

* **Signification** : Le nombre d'actions habilitées (transitions sortantes autorisées par la relation `Next`) depuis un état :
  * `minimum` : Si égal à 0 dans un système sans état terminal attendu, cela indique un blocage (deadlock).
  * `maximum` : Représente le niveau maximal de divergence asynchrone concurrente (ici 2, correspondant aux choix de succès/échec lors d'une tâche asynchrone).

---

### 5.2 Erreurs de vérification courantes et diagnostic

TLC interrompt immédiatement l'exploration en cas d'anomalie logique et produit des diagnostics standardisés.

#### 1. Erreur : `Deadlock reached`

* **Description** : TLC a atteint une configuration d'état à partir de laquelle aucune action de la relation `Next` n'est activée (outdegree = 0), alors que le système n'est pas conçu pour se terminer.
* **Résolution** : Inspecter le contre-exemple (Error Trace) fourni par TLC. Identifier la variable ou la condition d'activation bloquante dans le dossier d'erreurs et ajuster la relation `Next` pour traiter cette branche (comme nous l'avons fait pour l'échec de chargement).

#### 2. Erreur : `Invariant [Nom] is violated`

* **Description** : Un prédicat devant être vrai à chaque étape (comme `SafeTransition` ou `TypeOK`) a été évalué à FALSE sur un état accessible.
* **Résolution** : Analyser l'état incriminé dans l'historique d'erreurs. Déterminer si la violation provient d'un bug de transition dans la spécification `Next` ou d'une mauvaise définition des plages de types ou de contraintes de l'invariant.

#### 3. Erreur : `Temporal property [Nom] is violated`

* **Description** : Une propriété temporelle (ex: `Liveness` `[]<> (envState = "Idle")`) n'est pas satisfaite sur au moins un comportement infini.
* **Résolution** :
  * Le graphe d'états doit être vérifié pour s'assurer qu'il ne contient pas de cycle stérile (livelock) empêchant le retour à l'état attendu.
  * S'assurer que des contraintes d'équité (**Fairness**) appropriées (telles que `WF_vars(Next)` ou `SF_vars(Action)`) ont été associées à la formule de spécification `Spec` pour exclure les scénarios où l'exécution se fige arbitrairement alors que des transitions sont activées.

#### 4. Erreur : `TLC Out of Memory (OOM)`

* **Description** : L'arbre des états explorés dépasse la mémoire vive allouée à la machine virtuelle Java exécutant TLC.
* **Résolution** : Utiliser des paramètres d'allocation mémoire plus élevés lors du lancement de TLC via l'argument `-workers` et l'option de configuration mémoire de la machine virtuelle, ou abstraire certaines variables pour réduire la taille de l'espace d'états (State Space Reduction).

---

## 6. Références Officielles

Pour approfondir les concepts de modélisation TLA+ et l'usage des outils de vérification :

* **Livre de Référence** : *Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers*, Leslie Lamport, Microsoft Research. (Partie III : "The Tools" détaille exhaustivement le fonctionnement de TLC).
* **Documentation du Projet** : [TLA+ Home Page](https://lamport.azurewebsites.net/tla/tla.html) de Leslie Lamport pour les ressources universitaires et industrielles.

---

## 7. Limites de la Modélisation : Le Fossé Sémantique (Conformance Gap)

### 7.1 Décorrélation par défaut

Il est important de souligner que le modèle mathématique TLA+ (`.tla`) et l'implémentation concrète en Odin (`env_manager.odin`) sont deux artefacts fondamentalement **découplés et disjoints**. Une validation formelle réussie par le model-checker TLC prouve uniquement que la *logique conceptuelle* de l'automate est exempte de défauts de conception (deadlocks, blocages concurrents), mais elle ne garantit en rien que le code de production respecte cette spécification. Si un développeur modifie la logique de transition dans le code Odin, la spécification TLA+ ne se mettra pas à jour et l'implémentation pourra dériver silencieusement.

### 7.2 Mécanismes de synchronisation partielle actuels

Pour atténuer cette dérive par défaut, le projet utilise actuellement des garde-fous manuels qui servent de passerelles :

1. **Assertions de Contrat (`when ODIN_DEBUG`)** : Les invariants logiques issus du TLA+ (ex: le fait que le chargeur asynchrone doive être à l'état `Idle` lorsque l'automate de transition est en phase `Wait_IBL`) sont traduits et écrits sous forme d'assertions à l'intérieur du tick de l'application dans `src/scene/env_manager.odin`. En cas de déviation d'état à l'exécution, l'application s'arrête instantanément.
2. **Chaos Testing en CI** : Le fuzzer stochastique temporel (`nightly.yml`) simule des milliers d'ordonnancements concurrents pour forcer le code de production à explorer ses états limites et déclencher ces assertions si le code dévie de la trajectoire prouvée.

Ces contrôles sont des mesures réactives et partielles ("pansements" de détection) ; ils ne préviennent pas proactivement les modifications de code erronées lors de la compilation.

### 7.3 Solution cible : Génération de code depuis une Source Unique de Vérité (SSOT)

Pour supprimer définitivement tout risque de désynchronisation entre la spécification formelle et l'implémentation technique, l'étape ultime consiste à faire dériver automatiquement le code Odin (`env_manager.odin`) et la spécification TLA+ (`EnvManagerVerification.tla`) d'une même description logique déclarative (ex: un schéma JSON ou YAML de machine à états).
