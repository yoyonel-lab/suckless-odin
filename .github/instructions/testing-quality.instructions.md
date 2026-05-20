---
description: "Use when running tests, validating changes, checking CI, or completing any task. Covers CI validation, test coverage, quality gates, and documentation requirements."
applyTo: ["**/*"]
---
# Testing & Quality Gates

## Commit Authorization — MANDATORY

**NEVER commit without explicit written validation from the user.**

Workflow:
1. Implement the change
2. Run `just lint && just test` — must be green
3. Present the diff / result to the user
4. **Wait for explicit "go" / "ok" / "commit" from the user**
5. Only then commit

This applies to ALL commits: fixes, features, docs, assets. No exceptions.

## Quality Gate — Before Every Commit

```bash
just lint    # Must pass: odin check -vet -strict-style -warnings-as-errors
just test    # Must pass: all unit + CLI + shader + GL tests
```

Both must succeed with zero warnings before committing.

## Test Categories

| Recipe | Scope | GPU Required |
|--------|-------|:---:|
| `just test-unit` | Camera, settings, material, rendering | No |
| `just test-cli` | CLI arg parsing (in src/ package) | No |
| `just test-shader` | Shader CPU helpers (in-package) | No |
| `just test-gl` | GL shader compilation, visual regression | Yes |

## Visual Regression Tests

- Reference images in `tests/references/ref_*.png` are the baseline
- **NEVER modify reference images** without user's explicit visual validation
- Generate new refs: `just gen-refs` (or `just gen-refs-xvfb` headless)
- Comparison: per-pixel RGB euclidean distance, threshold 5.0, max 2% differ
- On failure: diff artifacts saved as `tests/references/failed_*.png`

## CI Pipeline (GitHub Actions)

Jobs must all pass:
1. **lint** — `odin check -vet -strict-style -warnings-as-errors`
2. **build** — debug + release (matrix)
3. **test-unit** — unit + CLI + shader CPU tests
4. **test-gl** — GL shader tests + visual regression (Mesa + xvfb)

## Local CI

```bash
just ci              # Full pipeline with xvfb
just test-gl-xvfb   # GL tests only, headless
```

## No Suppression Policy

- Never suppress compiler warnings — fix the code
- Never skip failing tests — fix the code
- Never add `// @(disabled)` or equivalent to bypass checks
- If a test is genuinely flaky, document why and fix root cause

## Documentation Gate

Every change that modifies behavior must:
1. Update relevant docs in `docs/`
2. Update `docs/PORTING_C11_TO_ODIN.md` if porting from legacy
3. Document new Odin paradigms used (`#soa`, `or_return`, etc.)

## Code Review Checklist

- [ ] `just lint` passes
- [ ] `just test` passes
- [ ] No new warnings introduced
- [ ] Docs updated if behavior changed
- [ ] SoC commit discipline followed
- [ ] User approved before push
