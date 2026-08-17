---
description: "Use when making commits, creating branches, pushing, or planning work iterations. Covers git safety, SoC commit discipline, Conventional Commits format, and branching strategy."
applyTo: ["**/*"]
---
# Commit & Workflow Discipline

## Git Safety — ABSOLUTE RULES

1. **NEVER push to any remote (origin, upstream, etc.) without user's EXPLICIT approval**
2. **NEVER commit to master without user's EXPLICIT approval**
3. **NEVER `git push --force`** without user's explicit approval
4. **NEVER `git reset --hard`** without user's explicit approval
5. **Always use feature branches** for new work — branch off master

## Separation of Concerns (SoC) — MANDATORY

Every commit must have a **single concern**. Never mix:
- Application code (`feat:`, `fix:`, `refactor:`) with CI (`ci:`) or docs (`docs:`)
- Test changes (`test:`) with the code they test (separate commits)
- Script/tooling changes (`chore:`) with application logic

## Conventional Commits Format

```text
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code restructuring without feature change
- `test`: Test additions/modifications
- `docs`: Documentation only
- `build`: Build system, Taskfile.yml, dependencies
- `ci`: GitHub Actions, CI pipeline
- `chore`: Config, tooling, git config
- `perf`: Performance optimization

**Scope** (optional but recommended):
- `rendering`, `ibl`, `camera`, `scene`, `shader`, `material`, `cli`, `overlay`, `settings`, etc.

## Pre-Commit Workflow

1. Make code changes
2. Run `task lint` → must pass with no errors/warnings
3. Run `task test` → all tests must pass
4. Commit with SoC discipline
5. **ASK user before pushing**

## Branching Strategy

- `master` — stable, CI must be green, user-approved only
- `feat/<name>` — feature branches
- `fix/<name>` — bug fix branches
- `refactor/<name>` — refactoring branches

## PR Workflow

1. Create feature branch
2. Push branch (with user approval)
3. Create PR targeting master
4. CI must pass on PR
5. User reviews and approves merge
