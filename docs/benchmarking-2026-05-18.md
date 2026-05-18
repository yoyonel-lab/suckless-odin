# Benchmarking & Performance Optimization

## Quick Start

```bash
just bench              # Run all benchmarks
just bench-search       # Fuzzy search only

# Export results as JSON for historical tracking:
BENCH_JSON=/tmp/results.json just bench-search
```

## Framework Structure

```
benchmarks/
├── harness/
│   └── harness.odin          # Shared runner (warmup, timing, JSON export)
└── search/
    └── bench_search.odin     # Fuzzy match + Levenshtein µ-bench
```

### Harness API

```odin
import harness "../harness"

// Define bench functions that return a checksum (prevents dead code elimination)
my_bench :: proc() -> int {
    // ... work ...
    return checksum
}

main :: proc() {
    cases := [?]harness.Bench_Case{
        {"my_case", 100_000, my_bench},
    }
    harness.run_suite("My Feature", cases[:])
}
```

Each `Bench_Case` is: name, iteration count, function. The harness handles warmup (1% or 1000 iters), timing, and reporting.

### Adding a New Benchmark (3 steps)

1. Create `benchmarks/<name>/bench_<name>.odin` importing the harness + target package
2. Add Justfile recipe:
   ```just
   bench-<name>:
       odin run benchmarks/<name>/ -o:speed -out:/tmp/odin-bench-<name>
   ```
3. Add to aggregate: `bench: bench-search bench-<name>`

### JSON Output for CI/Historical Tracking

Set `BENCH_JSON=<path>` environment variable to export results:

```bash
BENCH_JSON=bench_results.json just bench-search
```

Output:
```json
[
  {"suite":"Fuzzy Search","name":"fuzzy_match (49 combos)","iterations":100000,"ns_per_call":1844,"checksum":2100000},
  {"suite":"Fuzzy Search","name":"levenshtein (6 pairs)","iterations":1000000,"ns_per_call":248,"checksum":13000000}
]
```

This can be consumed by CI to detect regressions (e.g., fail if ns/call increases > 20%).

## Methodology

### How to Validate an Optimization

1. **Measure baseline**: `just bench-search` on current commit, note `ns/call`
2. **Apply refactoring**: make your changes
3. **Re-measure**: `just bench-search` again
4. **Compare**: ns/call must decrease (or stay equal) with identical checksums
5. **Verify assembly** (optional): inspect generated code with `-build-mode:asm`

### Important: Function Pointer Overhead

The harness uses `proc() -> int` function pointers, which **prevents LLVM from inlining** the benchmark body. This adds ~2x constant overhead vs a hand-written direct loop.

**This is acceptable** because:
- Relative comparisons between commits are valid (overhead is constant)
- Checksums guarantee functional correctness
- For absolute numbers, write a one-off direct-loop benchmark (like the comparative one used during the refactor)

### Benchmark Design Principles

| Principle | Rationale |
|-----------|-----------|
| Use `-o:speed` | Matches production optimization level |
| Warmup phase (1000 iters) | Fills CPU caches, avoids cold-start skew |
| Large iteration count (100K+) | Amortizes timer overhead |
| Diverse inputs | Cover all code paths (fast path, Levenshtein, no-match) |
| Report match count | Detects functional regression (wrong results) |
| Zero allocations | Benchmarks should not measure allocator noise |

### Reading Results

```
=== Fuzzy Search Benchmark ===
  Iterations: 100000
  Combos/iter: 7 filters × 7 entries = 49
  Total calls: 4900000

  Duration:   9.039067402s
  Throughput: 1844 ns/call (1.84 µs/call)
  Matches:    2100000 / 4900000 (42.9%)
```

- **ns/call**: primary metric — lower is better
- **Matches**: must stay identical across refactorings (functional consistency)

## Assembly Analysis

For deeper investigation, generate and compare assembly:

```bash
# Generate assembly for the search package
odin build src/core/search/ -build-mode:asm -o:speed -out:/tmp/search.S

# Key things to look for:
grep -c "string_decode_rune" /tmp/search.S    # UTF-8 overhead (should be 0)
grep "callq" /tmp/search.S | grep -v error    # Function call overhead
```

### Known Assembly Wins (2026-05-18 refactor)

| Optimization | Before | After | Evidence |
|---|---|---|---|
| `transmute([]u8)` byte iteration | 3× `callq string_decode_rune` | 0 calls | Eliminates UTF-8 decode |
| `prev, curr = curr, prev` slice swap | O(n) copy loop (65 ints) | O(1) pointer swap | 2 `movq` vs loop |
| `strings.split_iterator` | Manual index tracking | Iterator (LLVM inlines) | Cleaner hot path |

**Combined speedup: 1.36x (+36.5%)**

## Adding a New Benchmark

Already covered above in "Adding a New Benchmark (3 steps)".

### Future benchmark candidates

| Feature | What to measure | When |
|---------|-----------------|------|
| Scene rendering | Frame time, draw calls | When optimizing render loop |
| Material loading | JSON parse time | When adding material variants |
| IBL compute | Shader dispatch time | When tuning workgroup sizes |
| Camera update | Physics step time | When adding collision |

## Baseline Reference

| Benchmark | CPU | ns/call | Date | Commit |
|-----------|-----|---------|------|--------|
| fuzzy_match (OLD) | AMD Ryzen | 2517 | 2026-05-18 | pre-refactor |
| fuzzy_match (NEW) | AMD Ryzen | 1844 | 2026-05-18 | post-refactor |
| levenshtein | AMD Ryzen | ~50 | 2026-05-18 | post-refactor |

> Note: Absolute numbers are machine-dependent. Compare ratios on the same machine.
