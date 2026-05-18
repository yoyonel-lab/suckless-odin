#!/usr/bin/env bash
# bench_compare.sh — Compare benchmark results between two commits.
#
# Usage:
#   ./scripts/bench_compare.sh <bench-name> [commit-a] [commit-b]
#
# If commits are not provided, presents an interactive selector
# showing only commits that touched the benchmarked feature's source files.
#
# Examples:
#   ./scripts/bench_compare.sh search           # interactive selector
#   ./scripts/bench_compare.sh search HEAD~3 HEAD  # explicit commits
#
# Requirements: jq, fzf, odin, git
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

# Map bench names to their source paths (for filtering relevant commits).
declare -A BENCH_SOURCES=(
    [search]="src/core/search/"
    [gui]="src/gui/"
    [rendering]="src/rendering/"
    [camera]="src/camera/"
    [scene]="src/scene/"
)

# Map bench names to their benchmark package path.
declare -A BENCH_PACKAGES=(
    [search]="benchmarks/search/"
)

RESULTS_DIR="/tmp/bench_compare_$$"
mkdir -p "$RESULTS_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
    command -v jq >/dev/null || die "jq not found"
    command -v fzf >/dev/null || die "fzf not found (install: https://github.com/junegunn/fzf)"
    command -v odin >/dev/null || die "odin not found"
    command -v git >/dev/null || die "git not found"
}

# Get commits (as JSON array) that touched the relevant source files.
# Uses tab-separated format + jq -R to safely handle special chars in subjects.
get_relevant_commits_json() {
    local bench_name="$1"
    local source_path="${BENCH_SOURCES[$bench_name]:-}"
    local bench_path="${BENCH_PACKAGES[$bench_name]:-}"

    local paths=()
    [[ -n "$source_path" ]] && paths+=("$source_path")
    [[ -n "$bench_path" ]] && paths+=("$bench_path")

    local git_cmd=(git log --format=$'%h\t%s')

    if [[ ${#paths[@]} -eq 0 ]]; then
        "${git_cmd[@]}" -20
    else
        "${git_cmd[@]}" -30 -- "${paths[@]}"
    fi | jq -R -s '[split("\n") | .[] | select(length > 0) | split("\t") | {hash: .[0], subject: .[1]}]'
}

# Interactive commit selector using fzf.
select_commit() {
    local prompt="$1"
    local bench_name="$2"

    local commits_json
    commits_json=$(get_relevant_commits_json "$bench_name")

    local count
    count=$(echo "$commits_json" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        die "No commits found for bench '$bench_name'"
    fi

    # Add distance (commits from HEAD) to each entry
    local lines
    lines=$(echo "$commits_json" | jq -r --arg head "$(git rev-parse HEAD)" '.[] |
        .hash as $h |
        "\(.hash) \(.subject)"' | while IFS= read -r line; do
        local hash="${line%% *}"
        local dist
        dist=$(git rev-list --count "$hash"..HEAD 2>/dev/null || echo "?")
        printf "~%-3s %s\n" "$dist" "$line"
    done)

    # Use fzf for selection
    local selected_line
    selected_line=$(echo "$lines" | fzf --height=~20 --reverse \
        --header="$prompt (commits touching ${BENCH_SOURCES[$bench_name]:-all})") \
        || die "No commit selected"

    # Extract hash (second field, after ~N prefix)
    echo "$selected_line" | awk '{print $2}'
}

# Run benchmark at a specific commit and capture JSON output.
# Strategy: checkout the commit (changes source), overlay current benchmark files
# (so we always use the latest harness), run, then restore.
run_bench_at_commit() {
    local commit="$1"
    local bench_name="$2"
    local output_file="$3"
    local bench_pkg="${BENCH_PACKAGES[$bench_name]:-}"

    if [[ -z "$bench_pkg" ]]; then
        die "No benchmark package defined for '$bench_name'"
    fi

    local short_hash
    short_hash=$(git rev-parse --short "$commit")
    local commit_msg
    commit_msg=$(git log --oneline -1 "$commit" | cut -d' ' -f2-)

    echo "  Running bench at $short_hash ($commit_msg)..." >&2

    # Save current benchmark files (they may not exist at older commits).
    local bench_backup="$RESULTS_DIR/bench_backup"
    cp -r benchmarks "$bench_backup"

    # Stash current changes if any
    local stashed=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git stash push -q -m "bench_compare temp stash"
        stashed=true
    fi

    # Checkout the target commit (changes source code under src/)
    git checkout -q "$commit"

    # Overlay current benchmark + harness files (so imports resolve correctly)
    cp -r "$bench_backup"/* benchmarks/ 2>/dev/null || mkdir -p benchmarks && cp -r "$bench_backup"/* benchmarks/

    # Run benchmark with JSON output
    local exit_code=0
    BENCH_JSON="$output_file" odin run "$bench_pkg" -o:speed -out:/tmp/odin-bench-compare 2>/dev/null || exit_code=$?

    # Remove overlayed benchmark files before switching back (avoids untracked file conflicts)
    rm -rf benchmarks/

    # Return to original branch
    git checkout -q -

    # Restore benchmarks/ from git (we deleted them for clean checkout)
    git checkout -q -- benchmarks/ 2>/dev/null || true

    # Restore stash if we stashed
    if [[ "$stashed" == true ]]; then
        git stash pop -q 2>/dev/null || true
    fi

    # Clean up backup
    rm -rf "$bench_backup"

    if [[ $exit_code -ne 0 ]]; then
        die "Benchmark failed at commit $short_hash (exit $exit_code). Source at that commit may not be compatible with current benchmark."
    fi
}

# Compare two JSON result files and display delta.
compare_results() {
    local file_a="$1"
    local file_b="$2"
    local commit_a="$3"
    local commit_b="$4"

    local short_a short_b
    short_a=$(git rev-parse --short "$commit_a")
    short_b=$(git rev-parse --short "$commit_b")

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  Benchmark Comparison: $short_a (baseline) vs $short_b (current)"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Use jq to merge and compute deltas
    jq -r -n --slurpfile a "$file_a" --slurpfile b "$file_b" \
        --arg ca "$short_a" --arg cb "$short_b" '
        def pad($n): . + (" " * ([0, $n - length] | max));

        "  \("Case" | pad(40))  \($ca | pad(12))  \($cb | pad(12))  Delta      Status",
        "  \("-" * 88)",
        (range($a[0] | length) |
            ($a[0][.]) as $ra |
            ($b[0][.]) as $rb |
            ($ra.ns_per_call) as $ns_a |
            ($rb.ns_per_call) as $ns_b |
            (if $ns_a > 0 then (($ns_b - $ns_a) * 1000 / $ns_a | round / 10) else 0 end) as $delta_pct |
            (if $ra.checksum != $rb.checksum then "⚠ MISMATCH"
             elif $delta_pct <= -5 then "✅ FASTER"
             elif $delta_pct >= 5 then "❌ SLOWER"
             else "➖ SAME" end) as $status |
            "  \($ra.name | pad(40))  \("\($ns_a) ns" | pad(12))  \("\($ns_b) ns" | pad(12))  \(if $delta_pct >= 0 then "+" else "" end)\($delta_pct)%\("" | pad(4))  \($status)"
        ),
        "",
        "  Checksum consistency:",
        (range($a[0] | length) |
            ($a[0][.]) as $ra |
            ($b[0][.]) as $rb |
            "    \($ra.name): \(if $ra.checksum == $rb.checksum then "OK (\($ra.checksum))" else "⚠ MISMATCH \($ra.checksum) vs \($rb.checksum)" end)"
        )
    '

    echo ""
}



# ── Main ───────────────────────────────────────────────────────────────────────

main() {
    check_deps

    local bench_name="${1:-}"
    local commit_a="${2:-}"
    local commit_b="${3:-}"

    if [[ -z "$bench_name" ]]; then
        echo "Usage: $0 <bench-name> [commit-a] [commit-b]"
        echo ""
        echo "Available benchmarks:"
        for name in "${!BENCH_PACKAGES[@]}"; do
            echo "  $name  (sources: ${BENCH_SOURCES[$name]:-all})"
        done
        exit 0
    fi

    if [[ -z "${BENCH_PACKAGES[$bench_name]:-}" ]]; then
        die "Unknown benchmark: '$bench_name'. Available: ${!BENCH_PACKAGES[*]}"
    fi

    # Interactive selection if commits not provided.
    if [[ -z "$commit_a" ]]; then
        commit_a=$(select_commit "Select BASELINE commit (older)" "$bench_name")
    fi
    if [[ -z "$commit_b" ]]; then
        commit_b=$(select_commit "Select CURRENT commit (newer)" "$bench_name")
    fi

    echo ""
    echo "Comparing: $(git rev-parse --short "$commit_a") → $(git rev-parse --short "$commit_b")"
    echo ""

    # Run benchmarks at both commits.
    local result_a="$RESULTS_DIR/result_a.json"
    local result_b="$RESULTS_DIR/result_b.json"

    run_bench_at_commit "$commit_a" "$bench_name" "$result_a"
    run_bench_at_commit "$commit_b" "$bench_name" "$result_b"

    # Compare and display.
    compare_results "$result_a" "$result_b" "$commit_a" "$commit_b"

    # Cleanup
    rm -rf "$RESULTS_DIR"
}

main "$@"
