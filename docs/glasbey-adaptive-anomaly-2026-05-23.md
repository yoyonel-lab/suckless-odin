# Glasbey Adaptive Strategy: Anomalous Quality Result

**Date**: 2026-05-23T20:37:18+02:00
**Branch**: `feat/postfx-pipeline` @ `681dba0`
**System**: Linux 6.12.73+deb13-amd64, Odin dev-2026-05-nightly:ea5175d
**Benchmark**: `benchmarks/glasbey/bench_glasbey.odin`

## Summary

The adaptive strategy (step=32, coarse+refine) produces a **higher minimum
pairwise ΔE** (47.48) than the exhaustive greedy scan (step=1, 46.74) for 16
colors. This is NOT a bug — it demonstrates that the greedy sequential algorithm
is NOT globally optimal, and different traversal orders explore different local
optima.

## Benchmark Results

All results: 16 colors, full sRGB gamut [0,255]³, CIE76 ΔE (Euclidean distance
in CIELAB), D65 illuminant, black background constraint.

| Strategy | Step | Adaptive | min ΔE | Time | Closest Pair |
| --- | --- | --- | --- | --- | --- |
| Full scan | 1 | No | 46.7386 | 5.73 s | (11, 15) |
| Coarse | 4 | No | 43.3892 | 85 ms | (4, 15) |
| Coarse | 16 | No | 42.4332 | 0.9 ms | (7, 15) |
| Adaptive | 16 | Yes | 43.9692 | 67 ms | (2, 15) |
| **Adaptive** | **32** | **Yes** | **47.4784** | **672 ms** | **(13, 14)** |
| Adaptive+bounds | 16 | Yes | 43.3488 | 137 ms | (5, 14) |

Bounds for last row: L\* ∈ [20, 90], C\* ∈ [20, 100].

## Step=32 Adaptive Palette (Reproducible)

The palette achieving min ΔE = 47.4784:

| # | R | G | B | L\* | a\* | b\* | C\* |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0 | 255 | 32.3 | 79.2 | -107.9 | 133.8 |
| 1 | 0 | 255 | 0 | 87.7 | -86.2 | 83.2 | 119.8 |
| 2 | 255 | 0 | 0 | 53.2 | 80.1 | 67.2 | 104.6 |
| 3 | 255 | 64 | 187 | 60.4 | 79.9 | -22.4 | 83.0 |
| 4 | 255 | 209 | 0 | 85.4 | 1.1 | 86.1 | 86.1 |
| 5 | 0 | 137 | 255 | 57.2 | 13.2 | -66.9 | 68.2 |
| 6 | 13 | 137 | 64 | 49.9 | -47.8 | 30.4 | 56.6 |
| 7 | 135 | 75 | 1 | 38.2 | 20.9 | 47.3 | 51.7 |
| 8 | 71 | 0 | 94 | 16.2 | 43.5 | -36.9 | 57.0 |
| 9 | 0 | 135 | 160 | 51.7 | -21.5 | -22.0 | 30.7 |
| 10 | 178 | 113 | 138 | 55.2 | 29.2 | -2.9 | 29.3 |
| 11 | 202 | 0 | 70 | 42.8 | 69.0 | 21.3 | 72.3 |
| 12 | 175 | 92 | 255 | 56.1 | 62.6 | -68.3 | 92.6 |
| 13 | 134 | 195 | 2 | 72.3 | -42.6 | 72.0 | 83.7 |
| 14 | 197 | 188 | 111 | 75.4 | -7.7 | 40.0 | 40.7 |
| 15 | 0 | 255 | 224 | 90.3 | -56.6 | 0.7 | 56.6 |

Closest pair: colors 13 and 14, ΔE = 47.4784.

## Step=1 Full-Scan Palette (Reference)

The palette achieving min ΔE = 46.7386:

| # | R | G | B | L\* | a\* | b\* | C\* |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0 | 255 | 32.3 | 79.2 | -107.9 | 133.8 |
| 1 | 0 | 255 | 0 | 87.7 | -86.2 | 83.2 | 119.8 |
| 2 | 255 | 0 | 0 | 53.2 | 80.1 | 67.2 | 104.6 |
| 3 | 255 | 70 | 189 | 61.1 | 78.4 | -22.5 | 81.5 |
| 4 | 255 | 209 | 0 | 85.4 | 1.1 | 86.1 | 86.1 |
| 5 | 0 | 139 | 255 | 57.7 | 12.0 | -66.0 | 67.1 |
| 6 | 0 | 137 | 65 | 49.8 | -48.5 | 29.7 | 56.9 |
| 7 | 169 | 102 | 58 | 49.8 | 22.8 | 35.8 | 42.5 |
| 8 | 7 | 0 | 85 | 6.3 | 35.2 | -47.4 | 59.1 |
| 9 | 19 | 129 | 151 | 49.6 | -20.5 | -20.0 | 28.6 |
| 10 | 0 | 255 | 237 | 90.6 | -53.1 | -5.5 | 53.4 |
| 11 | 218 | 255 | 155 | 95.5 | -27.8 | 43.9 | 51.9 |
| 12 | 120 | 0 | 62 | 24.8 | 48.9 | -1.0 | 48.9 |
| 13 | 195 | 142 | 197 | 65.7 | 29.3 | -20.6 | 35.8 |
| 14 | 170 | 92 | 253 | 55.4 | 61.1 | -68.3 | 91.7 |
| 15 | 0 | 255 | 147 | 88.7 | -73.6 | 37.8 | 82.7 |

Closest pair: colors 11 and 15, ΔE = 46.7386.

## Independent Verification

A Python script independently computed both results (see `/tmp/verify_glasbey.py`):

- step=1: computed min ΔE = 46.738609 (matches Odin to 6 decimal places)
- step=32 adaptive: computed min ΔE = 47.478363 (matches Odin to 6 decimal places)

Verification method: reconstruct palettes from RGB values, convert to CIELAB,
compute all pairwise ΔE, find minimum.

## Analysis: Why Adaptive Exceeds Full-Scan

### The Greedy Algorithm is Not Globally Optimal

The Glasbey algorithm is a **greedy sequential** heuristic:

1. Start with background constraint(s)
2. At each step, pick the color maximizing min(ΔE) to all previously selected

This is a **local** optimization — each pick is optimal for that step, but the
sequence of picks is NOT guaranteed to produce the globally optimal N-color set.
The algorithm suffers from the classic greedy pathology: an early "optimal" choice
can constrain later choices suboptimally.

### Different Traversal = Different Local Optimum

- **Step=1** scans all 16.7M RGB colors, picks the absolute best at each step
- **Step=32 adaptive** first does a coarse scan (step=32, ~4K candidates), picks a
  coarse winner, then refines in a ±32 neighborhood at step=1

The coarse scan effectively gives the algorithm a **different starting
trajectory**. The coarse pick at step N may select a slightly different color
than the exhaustive pick would — this cascades through all subsequent picks,
potentially landing in a different (and sometimes better) local optimum.

This is analogous to how different random restarts of hill-climbing can find
better peaks than a single deterministic start.

### The Paper Acknowledges This

Glasbey et al. (2007) themselves propose **simulated annealing** as an alternative
to the greedy method (Section 3 of the paper), acknowledging that the sequential
approach does not find the global optimum. Their SA results sometimes exceed
their greedy results.

## Literature Context

### Color Space: Our Implementation vs. Reference

| | Our implementation | taketwo/glasbey (Python) |
| --- | --- | --- |
| Color space | CIELAB (CIE76) | CAM02-UCS (Luo et al. 2006) |
| Distance metric | Euclidean in L\*a\*b\* | Euclidean in J'a'b' |
| Gamut representation | On-the-fly computation | Pre-computed 363 MB LUT |
| Uniformity | Non-uniform for ΔE > 10 | State-of-the-art uniform |

**Key difference**: CIE76 is documented as "known to work poorly on large color
distances (more than 10 units)" (Wikipedia, citing Abasi et al. 2020). For
palette generation where distances are 30–50+, this non-uniformity means:

- Two pairs with equal CIE76 ΔE may NOT be equally distinguishable
- The metric landscape in CIELAB has more "bumps" than in CAM02-UCS
- This makes the greedy algorithm more path-dependent in CIELAB

### There Is No "~47 Theoretical Limit"

The ~47 value from our step=1 result is simply one empirical outcome of the
greedy heuristic. It is NOT a theoretical upper bound. Evidence:

1. Our own adaptive found 47.48 > 46.74 (same algorithm family, same metric)
2. Simulated annealing can find even better solutions (paper Section 3)
3. A global optimum for 16 colors in sRGB/CIELAB is unknown and likely higher
4. The dispersion problem (maximizing min distance among N points in a bounded
   region) is NP-hard in general; no analytical solution exists for the sRGB
   cube in CIELAB space

### Related Work

- **Glasbey et al. (2007)**: Original paper. Sequential greedy + SA comparison.
  DOI: 10.1002/col.20327
- **Luo, Cui, Li (2006)**: CAM02-UCS color space used by reference implementation.
  DOI: 10.1002/col.20227
- **Westland et al. (2024)**: "A computational method for predicting color
  palette discriminability". Color Research & Application.
  DOI: 10.1002/col.22927
- **Viana et al. (2020)**: "An improved local search genetic algorithm [...]
  applied to pseudo-coloring problem." Symmetry 12(10), 1684. Compares greedy,
  SA, and genetic algorithms for categorical color selection.

## Theoretical Bounds: Mathematical Analysis

### Complexity Class

**The maximin dispersion problem is NP-hard** (Gonzalez 1985). Given a metric
space $(X, d)$ and integer $k$, selecting $S \subseteq X$ with $|S| = k$ to
maximize $\min_{p,q \in S, p \neq q} d(p,q)$ is computationally intractable.

- **Proof**: Gonzalez, T.F. (1985), "Clustering to minimize the maximum
  intercluster distance", *Theoretical Computer Science*, 38: 293–306.
  DOI: 10.1016/0304-3975(85)90224-5
- **Inapproximability**: No poly-time algorithm achieves factor < 2 unless P=NP
  (Hochbaum & Shmoys 1985)
- **Best poly-time approximation**: Factor 2, via farthest-first traversal
  (which IS the Glasbey algorithm)

### No Proven Tight Bound Exists for Our Case

For N=16 points in the sRGB gamut mapped to CIELAB:

1. **The feasible region is non-convex**: sRGB→CIELAB is nonlinear (gamma +
   chromatic adaptation + cube root). The gamut in CIELAB is an irregular blob
   spanning approximately L\* ∈ [0, 100], a\* ∈ [−86, 98], b\* ∈ [−108, 95].
2. **Volume ≈ 820,000 cubic ΔE**: approximate gamut volume in CIELAB.
3. **Sphere packing density argument** gives a loose upper bound:
   - $16 \times \frac{4\pi}{3} r^3 \leq V / \eta_{FCC}$ where
     $\eta_{FCC} \approx 0.7405$
   - $r \leq (820000 / (16 \times 4.189 \times 0.7405))^{1/3} \approx 25.5$
   - **Upper bound**: $d_{\min} \leq 2r \approx 51$ ΔE (LOOSE — boundary
     effects matter greatly for N=16)
4. **Our result** (47.48) is ~93% of this loose ceiling — remarkably close.

### The Greedy is a 2-Approximation

Since Glasbey's algorithm IS farthest-first traversal, the guarantee is:

$$\text{minΔE}_{\text{Glasbey}} \geq \frac{1}{2} \times \text{minΔE}_{\text{OPT}}$$

For our step=1 result (46.74), this means OPT ≤ 93.48. Combined with the
packing bound (OPT ≤ ~51), we know: **47 ≤ OPT ≤ 51** (approximately).

Our step=32 adaptive (47.48) tightens the lower bound further.

### Proven Optimal Results in Related Problems

| Domain | N | Status |
| --- | --- | --- |
| Sphere packing in unit cube | ≤ 14 | Proven optimal (Joós 2009) |
| Tammes problem (points on sphere) | ≤ 14 | Proven optimal (Musin & Tarasov 2015) |
| Packing circles in a square | ≤ 30 | Proven optimal |

**No proof exists for N=16 in any non-trivial 3D bounded region**, let alone
the irregular sRGB/CIELAB gamut.

### Key References (Theoretical)

- Gonzalez, T.F. (1985). "Clustering to minimize the maximum intercluster
  distance." *Theoretical Computer Science*, 38: 293–306.
- Hochbaum, D.S.; Shmoys, D.B. (1985). "A Best Possible Heuristic for the
  k-Center Problem." *Math. of Operations Research*, 10(2): 180–184.
- Ravi, S.S.; Rosenkrantz, D.J.; Tayi, G.K. (1994). "Heuristic and special
  case algorithms for dispersion problems." *Operations Research*, 42(2): 299–310.
- Melissen, J.B.M. (1998). "How Different Can Colours Be? Maximum Separation of
  Points on a Spherical Octant." *Proc. Royal Society A*, 454(1973): 1499–1508.
- Joós, A. (2009). "On the packing of fourteen congruent spheres in a cube."
  *Geometriae Dedicata*, 140: 49–80.
- Gensane, Th. (2004). "Dense packings of equal spheres in a cube." *Electronic
  J. Combinatorics*, 11(1).

## Implications for Our Implementation

1. **The adaptive strategy is valid and useful**: it can find better-quality
   palettes than full-scan greedy, at lower computational cost (672ms vs 5.7s)
2. **Quality is non-monotonic with step size**: larger steps don't always mean
   worse quality (step=32 > step=1 here)
3. **For production use**: running adaptive with several step sizes and keeping
   the best result is a cheap way to approximate multi-restart optimization
4. **CIE76 is acceptable for our use case** (categorical image visualization)
   even though it's not perceptually perfect for large distances

## Reproducibility

```bash
cd /path/to/suckless-odin
odin run benchmarks/glasbey/ -- 2>&1 | tee /tmp/bench_glasbey_results.txt
```

Algorithm is deterministic (no randomness) — same binary will always produce
identical results on any platform with IEEE 754 float32 arithmetic.
