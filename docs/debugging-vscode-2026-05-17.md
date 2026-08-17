# Debugging Odin dans VS Code

> Date : 2026-05-17

## Prérequis

| Composant | Version testée | Installation |
|-----------|---------------|--------------|
| Odin compiler | dev-2026-05-nightly | `-debug` flag pour DWARF symbols |
| LLDB (lldb-dap) | Homebrew LLVM 22.1.5 | `brew install llvm` |
| Extension VS Code | `llvm-vs-code-extensions.lldb-dap` | Marketplace |
| Task | — | Build orchestration |

### Extension critique

**Utiliser `llvm-vs-code-extensions.lldb-dap`** (extension officielle LLVM), PAS `vadimcn.vscode-lldb` (CodeLLDB) qui ne s'active pas correctement dans certaines configurations VS Code.

Le champ `"type"` dans launch.json doit être **`"lldb-dap"`** (pas `"lldb"`).

## Configuration

### `.vscode/tasks.json`

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "build debug",
            "type": "shell",
            "command": "task",
            "args": ["build"],
            "group": "build",
            "problemMatcher": [],
            "detail": "Build debug binary (odin build src/ -debug)"
        },
        {
            "label": "build sanitize",
            "type": "shell",
            "command": "task",
            "args": ["build-sanitize"],
            "group": "build",
            "problemMatcher": [],
            "detail": "Build with address sanitizer"
        },
        {
            "label": "build release",
            "type": "shell",
            "command": "task",
            "args": ["build-release"],
            "group": "build",
            "problemMatcher": [],
            "detail": "Build release (optimized)"
        }
    ]
}
```

### `.vscode/launch.json`

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug App",
            "type": "lldb-dap",
            "request": "launch",
            "program": "${workspaceFolder}/build/debug/suckless-odin",
            "args": [],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "build debug",
            "env": {}
        },
        {
            "name": "Debug App (with args)",
            "type": "lldb-dap",
            "request": "launch",
            "program": "${workspaceFolder}/build/debug/suckless-odin",
            "args": ["--width", "800", "--height", "600"],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "build debug",
            "env": {}
        },
        {
            "name": "Debug Sanitize",
            "type": "lldb-dap",
            "request": "launch",
            "program": "${workspaceFolder}/build/sanitize/suckless-odin",
            "args": [],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "build sanitize",
            "env": {
                "ASAN_OPTIONS": "detect_leaks=1"
            }
        }
    ]
}
```

## Utilisation

### Lancer une session de debug

1. **F5** ou panneau **Run and Debug** → sélectionner la configuration
2. Le `preLaunchTask` compile automatiquement avant de lancer
3. Le debugger s'attache au binaire compilé avec `-debug`

### Breakpoints

- Cliquer dans la marge gauche (point rouge) sur n'importe quelle ligne de code Odin
- Breakpoints conditionnels : clic droit → "Add Conditional Breakpoint"

### Symboles Odin

Odin génère des symboles DWARF au format `package::procedure` :

| Symbole | Exemple |
|---------|---------|
| Procédure | `main::main`, `app::run` |
| Procédure qualifiée | `rendering::billboard_render` |
| Variables locales | Visibles directement dans le panneau Variables |
| Structs | Champs dépliables (pointeurs, slices, arrays) |

### Inspection des variables

Le panneau **Variables** affiche :
- **Locals** : variables locales de la frame courante
- Pointeurs : affiche l'adresse + les champs de la struct pointée
- Structs imbriquées : dépliables (ex: `application.scene.camera`)
- Slices/arrays : longueur + éléments indexés

### Debug Console (LLDB)

Commandes utiles dans la console de debug :

```
p variable_name          # Print une variable
p *pointer              # Déréférence un pointeur
expr variable = value   # Modifier une valeur à la volée
bt                      # Backtrace complet
frame variable          # Toutes les variables de la frame
```

## Build flags

| Commande | Flag debug | Résultat |
|----------|-----------|----------|
| `task build` | `-debug` | Symboles DWARF complets |
| `task build-sanitize` | `-debug -sanitize:address` | ASAN + symboles |
| `task build-release` | `-o:speed` | Pas de debug info |

## Troubleshooting

### "Configured debug type 'X' is not supported"

**Cause** : l'extension correspondant au `"type"` n'est pas chargée.

**Solutions** :
1. Vérifier que l'extension est installée ET activée (`code --list-extensions | grep lldb`)
2. Utiliser `"type": "lldb-dap"` avec `llvm-vs-code-extensions.lldb-dap`
3. Si persistant : `Ctrl+Q` (quitter VS Code complètement) + relancer

### Pas de symboles / variables vides

**Cause** : le binaire n'est pas compilé avec `-debug`.

**Solution** : vérifier que `task build` utilise bien le flag `-debug` dans la commande odin.

### Breakpoint non atteint (cercle gris)

**Causes possibles** :
- Code inliné ou optimisé (utiliser `-o:none` si nécessaire)
- Mauvais binaire (vérifier que `"program"` pointe vers le bon chemin)
- `preLaunchTask` en erreur (vérifier le terminal de build)
