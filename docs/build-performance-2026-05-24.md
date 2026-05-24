# Build Performance Analysis

Date: 2026-05-24

## Context

Investigation into why `just build-release` takes ~10s for a ~11.5k LOC project.
Odin uses LLVM as its backend, which produces highly optimized code but has
inherent compilation overhead from optimization passes.

## Project Size

| Component | Lines | Files |
|---|---|---|
| `src/` (application) | 11,524 | 49 |
| `deps/odin-imgui` (bindings) | 9,320 | — |
| `vendor:OpenGL` | 7,301 | — |
| `vendor:glfw` | 1,060 | — |
| **Total compiled** | **~29,000+** | — |

## Compiler Timing Breakdown (`-o:speed -use-separate-modules`)

Using `odin build ... -show-timings -show-more-timings`:

```
Total Time                         - 11,114 ms - 100.00%
├─ initialization                  -     13 ms -   0.11%
├─ parse files                     -    170 ms -   1.53%
├─ type check                      -    613 ms -   5.51%
├─ LLVM API Code Gen (97 modules)  - 10,029 ms -  90.23%
│  ├─ Module Pass & Verification   -  5,377 ms -  48.05%
│  ├─ Object Generation (64 used)  -  4,227 ms -  37.77%
│  ├─ Procedure Generation         -    456 ms -   4.08%
│  └─ Other                        -     ~0 ms
└─ lld-link                        -    288 ms -   2.59%
```

**Key insight**: 90% of build time is LLVM backend (optimization passes +
machine code emission). The Odin frontend (parse + typecheck) is fast at ~783ms.

## Benchmark Matrix

All builds on the same machine (nightly `dev-2026-05`):

| Configuration | Wall-clock | User | Sys | Notes |
|---|---|---|---|---|
| `-o:none` | 2.2s | 8.7s | 4.3s | No optimization |
| `-o:none -use-separate-modules` | 2.3s | 8.7s | 4.3s | Parallelism irrelevant without optim |
| `-o:minimal -use-separate-modules` | 3.0s | 11.4s | 7.2s | Light passes (inline, mem2reg, DCE) |
| `-debug -use-separate-modules` | 3.0s | 12.2s | 5.9s | Debug info, minimal opt |
| `-o:speed -use-separate-modules` | 10.0s | 44.1s | 21.8s | Full LLVM -O2 passes |
| `-o:speed` (single module) | 14.9s | 15.3s | 1.4s | Single-threaded LLVM |
| `-o:speed` single + `-thread-count:N` | 26.3s | 26.5s | 1.8s | No effect without separate modules |
| `-o:size -use-separate-modules` | 9.6s | 42.6s | 24.0s | Similar to -o:speed |

## Why Jai is Faster

Jonathan Blow's Jai compiles ~300k LOC in ~1.7s because it uses a **custom
backend** designed for compilation speed. Odin uses LLVM which prioritizes
runtime code quality over compilation speed — a fundamental architectural
trade-off.

## Optimization Decisions

1. **`-use-separate-modules` is essential** for `-o:speed` builds (26s → 10s
   via LLVM parallelism across 97 modules)
2. **Linker is NOT a bottleneck** — lld already used internally (289ms)
3. **`-o:minimal`** provides the best compile-time/performance ratio for
   iteration (3s vs 10s, with basic optimizations retained)

## Build Tiers

| Tier | Build | Run | Time | Use case |
|---|---|---|---|---|
| Debug | `just build` | `just br` | 3.0s | Development iteration |
| Fast release | `just build-fast-release` | `just br-fr` | 3.0s | Quick release testing |
| Release | `just build-release` | `just br-release` | 10s | CI / shipping |
| Ultra | `just build-ultra` | `just br-ultra` | ~10s | Benchmarking |

## `-internal-cached` Flag (Undocumented)

### Verified Facts

Source: [GitHub Discussion #5409](https://github.com/odin-lang/Odin/discussions/5409)
(Jun–Jul 2025, gingerBill + Kelimion maintainers)

Odin has an **undocumented** `-internal-cached` flag that provides a
whole-program cache:

```
# First build (cold, writes cache):     11.0s
# Rebuild (no source changes):           0.9s  ← 12x faster
# Rebuild (any file modified):          ~10.0s  (full invalidation)
```

Timing breakdown on cache hit:
```
Total Time                              -   850 ms - 100%
├─ parse files                          -   170 ms -  20%
├─ check cached build (pre-semantic)    -     1 ms -   0%
├─ type check                           -   661 ms -  78%
├─ check cached build                   -     6 ms -   1%
└─ write cached build                   -     0 ms -   0%
   (LLVM skipped entirely)
```

### Limitations (confirmed by gingerBill, Jul 3 2025)

> "internal-cached does not accomplish anything you envisioned. It's extremely
> dumb. It just checks to see if any file has changed, and if not, don't
> recompile. It's not meant to be used by anyone. It was just an idea I made
> in a day."

- **All-or-nothing**: any file change invalidates the entire cache (all 97
  modules recompiled)
- **Not per-module/incremental**: modifying `main.odin` still recompiles
  `vendor:OpenGL`, `imgui`, etc.
- **Not officially supported**: prefixed with `-internal-`, not in `odin help`
- **Useful for**: repeated builds without changes (e.g., testing different run
  args, accidental rebuilds, CI caching)

### Why `-use-separate-modules` Exists

Confirmed by Kelimion (maintainer, Jun 25 2025):

> "That's not why -use-separate-modules was added [for caching], but something
> that becomes possible as a result. The original impetus behind it is that
> LLVM has quadratic behavior that can be minimized by submitting each package
> as its own module."

## Precompiled Vendor Libraries — Analysis

### The Problem

Every `odin build` recompiles all vendor code from scratch:

| Package | Lines | Changes between builds? |
|---|---|---|
| `vendor:OpenGL` | 7,301 | Never |
| `vendor:glfw` | 1,060 | Never |
| `deps/odin-imgui` | 9,320 | Rarely (dep updates only) |
| **Total static** | **~17,700** | |
| `src/` (user code) | 11,524 | Frequently |

~60% of compiled code is identical every build.

### What's Actually Possible Today

1. **`-build-mode:obj`** — Odin can emit `.o` files from a package
2. **`-internal-cached`** — whole-program cache (no changes = skip LLVM)
3. **Manual `-extra-linker-flags`** — you can link prebuilt `.o`/`.a` files

### What's NOT Possible Today (Architectural Limitation)

**Odin cannot import precompiled packages.** The type-checker requires source
files — there's no `.pch`, `.mod`, or binary module format. You cannot:
- Precompile `vendor:OpenGL` into a `.a` and import it as a package
- Skip parsing/typechecking of vendor sources
- Do per-module incremental LLVM (cache invalidation is whole-program)

### What's Being Discussed (Real Status)

Source: [Discussion #5409](https://github.com/odin-lang/Odin/discussions/5409)

- Kelimion (maintainer): **"Caching may be picked up again"** — no active
  development, but acknowledged as desirable
- `-use-separate-modules` makes per-module caching *architecturally possible*
  (each package = 1 LLVM module = 1 `.o` file)
- No timeline, no assigned developer, no RFC/proposal

### What's Speculative (No Source)

The following are reasonable extrapolations but **NOT confirmed by maintainers**:

- ⚠️ "Odin custom backend" — The FAQ mentions LLVM as "the current backend."
  There is **no official roadmap** (FAQ: "There is no official roadmap."). No
  public announcement of a non-LLVM backend exists. This is speculation based
  on other languages (Jai) having done it.
- ⚠️ "Per-module object caching" (like ccache for Odin) — architecturally
  feasible with `-use-separate-modules` but not implemented or announced.
- ⚠️ Precompiling vendor as shared library (`.so`) and `foreign import` — would
  require wrapper packages and lose type safety on the Odin side.

## Comparison with Jai

Jonathan Blow's Jai compiles ~300k LOC in ~1.7s because:

- **Custom backend**: no LLVM, purpose-built for compilation speed
- **Incremental by design**: module-level caching from day one
- **No optimization by default**: optimized builds use LLVM as optional backend

Odin's trade-off: LLVM produces better runtime code at the cost of compilation
speed. Both approaches are valid engineering decisions.
