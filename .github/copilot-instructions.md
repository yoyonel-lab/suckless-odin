# suckless-odin Development Guidelines

## Project Context

Suckless OpenGL PBR rendering engine — Odin port of [suckless-ogl](https://github.com/yoyonel/suckless-ogl).
Repository: [yoyonel/suckless-odin](https://github.com/yoyonel/suckless-odin).

## Architecture Overview

| Subsystem | Key Files |
|-----------|-----------|
| **App / Window** | `src/app/app.odin`, `src/app/window.odin` |
| **CLI** | `src/cli.odin`, `src/main.odin` |
| **Camera** | `src/camera/camera.odin` |
| **Scene** | `src/scene/scene.odin` |
| **Rendering** | `src/rendering/billboard.odin`, `instanced.odin`, `ibl.odin`, `skybox.odin`, `material.odin`, `overlay.odin`, `texture.odin` |
| **Shaders** | `src/rendering/shader/` (CPU helpers), `shaders/` (GLSL files) |
| **Core** | `src/core/math_types/`, `src/core/settings/`, `src/core/log/` |
| **Tests** | `tests/` (unit), `tests/gl/` (GL + visual regression) |

## Build & Test

```bash
just build            # Debug build → build/debug/suckless-odin
just build-release    # Release → build/release/suckless-odin
just build-sanitize   # ASan → build/sanitize/suckless-odin
just test             # All tests (unit + CLI + shader + GL)
just lint             # odin check -vet -strict-style -warnings-as-errors
just ci               # Full local CI pipeline (mirrors GitHub Actions)
```

## Golden Rules

1. **NEVER push to any remote without user's EXPLICIT approval** — always ask first
2. **NEVER commit to master without user's EXPLICIT approval** — use feature branches
3. **Format + Lint + Tests REQUIRED** — `just lint && just test` must pass before commit
4. **Docs always in sync** — Update `docs/` with every feature/fix
5. **NO suppression of warnings/errors** — Fix at the source
6. **NEVER modify reference test images** without user's explicit visual validation
7. **MVP first** — Prove on one case, validate, then generalize
8. **SoC commits** — One concern per commit, Conventional Commits format

## Documentation Strategy

- Update `docs/PORTING_C11_TO_ODIN.md` after every legacy→Odin port
- Create docs for new Odin paradigms used (`#soa`, `or_return`, etc.)
- Keep docs synchronized when behavior changes

## Detailed Rules

See instruction files in `.github/instructions/` for specific domains:
- **commit-workflow.instructions.md** — Branching, commits, push policy
- **odin-coding-style.instructions.md** — Odin idioms, style, vet compliance
- **testing-quality.instructions.md** — CI, tests, quality gates
