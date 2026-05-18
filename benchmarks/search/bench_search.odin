// Benchmark: fuzzy search engine performance.
//
// Run:   just bench-search
// Usage: validates that refactoring doesn't regress performance.
//        Compare ns/call across commits to catch regressions.
package bench_search

import harness "../harness"
import search "../../src/core/search"

// Representative workloads covering all matching tiers.
FILTERS := [?]string{
	"gpu memory estimate",       // multi-term + Levenshtein
	"ibl",                       // single short term, substring
	"specualr",                  // typo → Levenshtein
	"prefilter mip roughness",   // multi-term, mixed substring/prefix
	"brdf lut split",            // multi-term, all substring
	"xyz nonexistent",           // no match (worst case)
	"",                          // empty filter (fast path)
}

LABELS := [?]string{
	"GPU Memory Estimate",
	"Prefilter Map",
	"Specular Map",
	"BRDF LUT",
	"Irradiance Map",
	"Speed",
	"Anything",
}

KEYWORDS := [?]string{
	"gpu vram memory estimation usage size textures",
	"ibl specular prefilter ggx split sum texture gpu mip roughness",
	"ibl specular prefilter ggx split sum texture gpu",
	"ibl split sum brdf lookup table texture gpu",
	"ibl diffuse irradiance convolution texture gpu",
	"camera movement velocity",
	"ibl debug irradiance prefilter specular diffuse brdf lut split sum texture gpu memory estimation vram mip roughness preview environment map hdr convolution ggx",
}

// Levenshtein test pairs.
LEV_PAIRS := [?][2]string{
	{"estimate", "estimation"},
	{"specualr", "specular"},
	{"kitten", "sitting"},
	{"saturday", "sunday"},
	{"irradianc", "irradiance"},
	{"prefiltr", "prefilter"},
}

// --- Bench functions (return match count as checksum) ---

bench_fuzzy_match :: proc() -> int {
	matches := 0
	for f in FILTERS {
		for l_idx in 0 ..< len(LABELS) {
			if search.fuzzy_match(f, LABELS[l_idx], KEYWORDS[l_idx]) {
				matches += 1
			}
		}
	}
	return matches
}

bench_levenshtein :: proc() -> int {
	total := 0
	for pair in LEV_PAIRS {
		total += search.levenshtein(pair[0], pair[1])
	}
	return total
}

bench_section_has_matches :: proc() -> int {
	section_kw :: "ibl debug irradiance prefilter specular diffuse brdf lut split sum texture gpu memory estimation vram mip roughness preview environment map hdr convolution ggx"
	queries := [?]string{"ibl", "GPU memory estimate", "brdf lut", "specul", "nonexistent xyz"}
	matches := 0
	for q in queries {
		if search.section_has_matches(q, section_kw) {
			matches += 1
		}
	}
	return matches
}

main :: proc() {
	cases := [?]harness.Bench_Case{
		{"fuzzy_match (49 combos)", 100_000, bench_fuzzy_match},
		{"levenshtein (6 pairs)", 1_000_000, bench_levenshtein},
		{"section_has_matches (5 queries)", 500_000, bench_section_has_matches},
	}
	harness.run_suite("Fuzzy Search", cases[:])
}
