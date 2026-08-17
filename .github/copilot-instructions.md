# RTK — Token-Optimized CLI

**rtk** is a CLI proxy that filters and compresses command outputs, saving 60-90% tokens.

## Rule

Always prefix shell commands with `rtk`:

```bash
# Instead of:              Use:
git status                 rtk git status
git log -10                rtk git log -10
cargo test                 rtk cargo test
docker ps                  rtk docker ps
kubectl get pods           rtk kubectl pods
```

## Meta commands (use directly)

```bash
rtk gain              # Token savings dashboard
rtk gain --history    # Per-command savings history
rtk discover          # Find missed rtk opportunities
rtk proxy <cmd>       # Run raw (no filtering) but track usage
```

## Langue de communication

Toujours communiquer en français avec l'utilisateur. Toutes les réponses, explications, documentations, commits et rapports d'artefacts doivent être rédigés en français, sauf si l'utilisateur demande explicitement le contraire.

## Politique de Commit et de Push (Sécurité)

Ne jamais effectuer de commits (sauf demande explicite) ni aucun push sur les dépôts distants sans l'accord explicite et préalable de l'utilisateur. Cet accord est strictement conditionné à l'exécution complète des tests et à une validation visuelle et manuelle de non-régression effectuée par l'utilisateur.

Ne jamais modifier ni mettre à jour les images de référence (comme `tests/references/ref_*.png`). L'IA n'a pas l'autorisation de le faire ; seul l'utilisateur HUMAIN décide de générer ou de valider la mise à jour de ces fichiers.

