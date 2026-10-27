#!/usr/bin/env bash
# Pack entire repository source code into an AI-friendly markdown bundle using repomix
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

OUTPUT_FILE="${1:-repomix-repo-full.md}"
TMP_HEADER="$(mktemp /tmp/repo-header-XXXXXX.md)"
TMP_REPOMIX="$(mktemp /tmp/repomix-XXXXXX.md)"

trap 'rm -f "${TMP_HEADER}" "${TMP_REPOMIX}"' EXIT

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "Generating full repository code bundle for branch '${BRANCH}' (${COMMIT})..."

FILES_TO_PACK="$(git ls-files |
  grep -E '\.(odin|c|h|cpp|hpp|glsl|frag|vert|comp|geom|sh|py|ya?ml|toml)$' |
  grep -v -E '^(build/|build-release/|\.tmp/|deps/|tests/references/|docs/|\.gl_symbols_cache\.json)' |
  sort -u)"

if [[ -z "${FILES_TO_PACK}" ]]; then
  echo "⚠️ No source files found to pack." >&2
  exit 1
fi

TOTAL_FILES="$(echo "${FILES_TO_PACK}" | wc -l)"

cat <<EOF >"${TMP_HEADER}"
# Full Repository Source Code Bundle: suckless-odin

- **Branch**: \`${BRANCH}\`
- **Commit**: \`${COMMIT}\`
- **Generated At**: \`${TIMESTAMP}\`
- **Total Source Files**: ${TOTAL_FILES}

## Included Source Categories
- Core Engine: \`src/core/\` (math, types, session, profiler, threadpool)
- Renderer: \`src/renderer/\` (OpenGL 4.5 Core, PBR, IBL, shadows, volumetric fog)
- UI: \`src/ui/\` (Dear ImGui docking/viewports, fuzzy search, inspector panels)
- App: \`src/app/\` (lifecycle, main loop, session state persistence)
- Shaders: \`shaders/\` (GLSL compute & raster shaders)
- Tests: \`tests/\` (unit, integration, shaders, smoke tests)
- Tooling: \`scripts/\`, \`Taskfile.yml\`

---

EOF

# Pack source files via repomix
echo "${FILES_TO_PACK}" | ${REPOMIX_CMD} --stdin --style markdown --no-security-check -o "${TMP_REPOMIX}"

# Combine header and repomix output
cat "${TMP_HEADER}" "${TMP_REPOMIX}" >"${OUTPUT_FILE}"

echo "✓ Full repository bundle successfully generated at: ${OUTPUT_FILE}"
echo "  Total source files: ${TOTAL_FILES}"
echo "  Total lines: $(wc -l <"${OUTPUT_FILE}")"
echo "  Total size : $(du -h "${OUTPUT_FILE}" | cut -f1)"
