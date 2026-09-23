# TODO: Internal Automation / Replay Mode Architecture

## Objectif
Remplacer à terme l'orchestration externe de l'application (via des scripts Bash et `xdotool`) par un mode d'auto-pilotage interne 100% déterministe, synchronisé avec la boucle de rendu et la machine à états interne.

## Problématique Actuelle
L'utilisation d'outils de capture externes pose des problèmes de fiabilité (focus de la fenêtre) et de synchronisation (dépendance au parsing de logs stdout/stderr, qui varient selon les niveaux de verbosité comme `-o:speed`).

## Architecture Cible (Replay Mode)
1. **Fichier de séquence** : Création d'un format (JSON/YAML) décrivant une séquence d'actions et de conditions d'attente.
   Exemple : `[{"action": "load_hdr", "target": "env1.hdr", "wait_for": "idle"}, {"action": "screenshot", "output": "ref.png"}]`
2. **Système de Tick** : L'application est lancée avec `./suckless-odin --replay script.json`.
3. **Consommateur d'événements** : Dans la boucle principale (main loop), un sous-système lit l'instruction courante, injecte l'input synthétique ou appelle l'API interne correspondante (ex: `env_manager_trigger_transition`), puis surveille directement l'état interne (`mgr.transition_state == .Idle`) avant de passer à la suivante.
4. **Auto-terminaison** : Fermeture propre de l'application (`glfwSetWindowShouldClose`) à la fin de la séquence, garantissant des flushs complets pour les profileurs comme Tracy.

## Avantages
* Immunité totale aux pertes de focus (Zéro OS-level inputs).
* Cohérence absolue frame-perfect : la condition d'attente lit la RAM directement, pas un flux texte.
* Permettra la génération automatisée de références visuelles (golden images) pour la CI.
