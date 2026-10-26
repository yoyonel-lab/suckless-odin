#!/usr/bin/env bash
# Pack branch diffs and modified files into an AI-friendly markdown bundle using repomix
set -euo pipefail

# Resolve repomix executable
REPOMIX_CMD=""
if command -v repomix >/dev/null 2>&1; then
  REPOMIX_CMD="repomix"
elif command -v npx >/dev/null 2>&1; then
  REPOMIX_CMD="npx repomix"
else
  echo "❌ Error: Neither 'repomix' nor 'npx' was found in PATH." >&2
  exit 1
fi

# Detect default target branch (origin/master, master, origin/main, main, or HEAD~1)
if [[ -n "${1:-}" ]]; then
  TARGET_BRANCH="$1"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
  TARGET_BRANCH="origin/master"
elif git rev-parse --verify master >/dev/null 2>&1; then
  TARGET_BRANCH="master"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  TARGET_BRANCH="origin/main"
elif git rev-parse --verify main >/dev/null 2>&1; then
  TARGET_BRANCH="main"
else
  TARGET_BRANCH="HEAD~1"
fi

OUTPUT_FILE="${2:-repomix-branch-review.md}"
TMP_HEADER="$(mktemp /tmp/review-header-XXXXXX.md)"
TMP_REPOMIX="$(mktemp /tmp/repomix-XXXXXX.md)"

trap 'rm -f "${TMP_HEADER}" "${TMP_REPOMIX}"' EXIT

echo "Generating code review bundle comparing HEAD with ${TARGET_BRANCH}..."

# Collect all files to pack: committed differences + working tree changes + untracked files
COMMITTED_FILES="$(git diff --name-only "${TARGET_BRANCH}...HEAD" 2>/dev/null || true)"
WORKTREE_FILES="$(git diff --name-only "${TARGET_BRANCH}" 2>/dev/null || true)"
UNTRACKED_FILES="$(git ls-files --others --exclude-standard 2>/dev/null || true)"

# Filter strictly to source implementations (Odin, C/C++, GLSL shaders, Python, Shell, YAML/TOML configs)
# Exclude: binaries, golden image references, third-party deps, docs, build dirs
FILES_TO_PACK="$(printf "%s\n%s\n%s" "${COMMITTED_FILES}" "${WORKTREE_FILES}" "${UNTRACKED_FILES}" |
  sed '/^$/d' |
  grep -E '\.(odin|c|h|cpp|hpp|glsl|frag|vert|comp|geom|sh|py|ya?ml|toml)$' |
  grep -v -E '^(build/|build-release/|\.tmp/|deps/|tests/references/|docs/|\.gl_symbols_cache\.json)' |
  sort -u)"

if [[ -z "${FILES_TO_PACK}" ]]; then
  echo "⚠️ No modified or untracked source files found compared to ${TARGET_BRANCH}." >&2
  echo "💡 Tip: If this branch was already merged, specify the base commit (e.g. 'task review:pack -- HEAD~1')." >&2
  exit 1
fi

mapfile -t SOURCE_FILES_ARRAY <<<"${FILES_TO_PACK}"

COMMITS_LOG="$(git log --oneline "${TARGET_BRANCH}...HEAD" 2>/dev/null || true)"
if [[ -z "${COMMITS_LOG}" ]]; then
  COMMITS_LOG="(Working tree uncommitted changes against ${TARGET_BRANCH})"
fi

DIFF_STAT="$(git diff --stat "${TARGET_BRANCH}" -- "${SOURCE_FILES_ARRAY[@]}" 2>/dev/null || true)"
UNIFIED_DIFF="$(git diff "${TARGET_BRANCH}" -- "${SOURCE_FILES_ARRAY[@]}" 2>/dev/null || true)"

cat <<EOF >"${TMP_HEADER}"
# Code Review Bundle: ${TARGET_BRANCH}...HEAD

## Review Context & Strategic Objectives
You are conducting an in-depth senior architectural, graphics, and code review of this pull request branch compared to \`${TARGET_BRANCH}\`.

### Architectural Scope
1. **Separation of Concerns (SoC) & Engine Architecture**:
   - \`src/renderer/\`: OpenGL 4.5 Core graphics pipeline, PBR, IBL (cubemaps, prefilter, irradiance, BRDF LUT), shadow mapping, volumetric lighting & fog, post-processing.
   - \`src/core/\`: Session state management, types, math, profiler, thread pool, logging.
   - \`src/ui/\`: Dear ImGui docking/viewports, fuzzy search, immediate UI dispatch, inspector panels.
   - \`src/app/\`: Application lifecycle, main loop, input polling, session state persistence.
   - \`shaders/\`: Modern GLSL raster & compute pipelines.
2. **Graphics & Rendering Correctness**:
   - Bit-for-bit stability, no visual regressions or artifacts.
   - Golden reference protection: no unauthorized regeneration of references.
   - Shader safety, uniform binding integrity, OpenGL state tracking, compute workgroup synchronization.
3. **Session State & UI/UX Synchronization (100% Rule)**:
   - Every parameter exposed in ImGui MUST be in \`Session_State\` (\`src/core/session/session.odin\`).
   - Extracted in \`extract_session_state\` and restored in \`restore_session_state\` (\`src/app/session.odin\`).
   - Indexed and searchable in ImGui fuzzy search (\`draw_filtered_*\`).
4. **Performance, Memory & Zero Allocation**:
   - Real-time frame budgets (60/144+ FPS), avoiding per-frame heap allocations.
   - Tracy profiler instrumentation (\`task profile-tracy\`).
   - Clean resource cleanup (textures, FBOs, buffers) upon reload/exit.

### Strict Repository Standards
- **Zero Magic Constants**: All numbers, thresholds, timeouts, and dimensions must be named, typed, and documented constants.
- **Pure Taskfile Orchestrator**: Declarative targets only, zero inline logic.
- **Zero Tolerance for Warnings/Style Issues**: \`task lint\` must pass with zero warnings (\`-vet -strict-style -warnings-as-errors\`).
- **Fact-First Rigor & Anti-Hallucination**: Clear distinction between Empirically Proven, Hermetically Mocked, and Hypothetical/Untested.

## Commits in this Branch
\`\`\`text
${COMMITS_LOG}
\`\`\`

## Diff Stat
\`\`\`text
${DIFF_STAT}
\`\`\`

## Unified Git Diff
\`\`\`diff
${UNIFIED_DIFF}
\`\`\`

---

# Modified Files Full Source Code (Packed via Repomix)

EOF

# Pack modified source files via repomix
echo "${FILES_TO_PACK}" | ${REPOMIX_CMD} --stdin --style markdown --no-security-check -o "${TMP_REPOMIX}"

# Combine header and repomix output
cat "${TMP_HEADER}" "${TMP_REPOMIX}" >"${OUTPUT_FILE}"

echo "✓ Code review bundle successfully generated at: ${OUTPUT_FILE}"
echo "  Total lines: $(wc -l <"${OUTPUT_FILE}")"
echo "  Total size : $(du -h "${OUTPUT_FILE}" | cut -f1)"
