package search

import "core:testing"

// --- fuzzy_match ---

@(test)
test_empty_filter_matches_everything :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("", "Anything", "keywords"), "empty filter should match")
}

@(test)
test_single_term_in_label :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("speed", "Speed", "camera movement"), "single term should match label")
}

@(test)
test_single_term_in_keywords :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("movement", "Speed", "camera movement"), "single term should match keywords")
}

@(test)
test_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("GPU", "gpu memory", "vram"), "should be case-insensitive (filter upper)")
	testing.expect(t, fuzzy_match("gpu", "GPU Memory", "VRAM"), "should be case-insensitive (label/keywords upper)")
	testing.expect(t, fuzzy_match("Gpu MeMoRy", "GPU memory", "vram"), "should be case-insensitive (mixed case)")
}

@(test)
test_multi_term_all_present :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("gpu memory", "GPU Memory Estimate", "vram textures"),
		"all terms present should match")
}

@(test)
test_multi_term_one_missing :: proc(t: ^testing.T) {
	testing.expect(t, !fuzzy_match("gpu foobar", "GPU Memory Estimate", "vram textures"),
		"missing term should not match")
}

@(test)
test_substring_match :: proc(t: ^testing.T) {
	// "pre" is a prefix of "prefilter"
	testing.expect(t, fuzzy_match("pre", "Prefilter Map", "specular"), "prefix should match")
	// "filter" is a substring of "prefilter"
	testing.expect(t, fuzzy_match("filter", "Prefilter Map", "specular"), "inner substring should match")
	// "estim" is a prefix of "estimation"
	testing.expect(t, fuzzy_match("estim", "", "estimation"), "common stem prefix should match")
	// "estimate" vs "estimation": Levenshtein distance = 3, but prefix truncation
	// levenshtein("estimate", "estimati") = 1, within threshold max(1, 8/4)=2.
	testing.expect(t, fuzzy_match("estimate", "", "estimation"),
		"'estimate' should fuzzy-match 'estimation' via prefix-truncated Levenshtein")
}

@(test)
test_multi_term_with_substring :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("gpu memory estim", "", "gpu memory estimation vram"),
		"'estim' prefix should match 'estimation'")
	// "estimate" now matches "estimation" via Levenshtein
	testing.expect(t, fuzzy_match("gpu memory estimate", "", "gpu memory estimation vram"),
		"'estimate' should fuzzy-match 'estimation' via Levenshtein")
}

@(test)
test_no_match :: proc(t: ^testing.T) {
	testing.expect(t, !fuzzy_match("nonexistent", "Speed", "camera movement"),
		"completely unrelated term should not match")
}

@(test)
test_extra_spaces_in_filter :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("gpu  memory", "GPU Memory", "vram"),
		"double space should be treated as empty term (ignored)")
}

@(test)
test_filter_with_leading_trailing_spaces :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match(" gpu ", "GPU Memory", "vram"),
		"leading/trailing spaces should not break matching")
}

// --- section_has_matches ---

@(test)
test_section_matches_single_keyword :: proc(t: ^testing.T) {
	keywords :: "ibl debug irradiance prefilter specular gpu memory estimation vram"
	testing.expect(t, section_has_matches("gpu", keywords), "single keyword should match section")
}

@(test)
test_section_matches_multi_keyword :: proc(t: ^testing.T) {
	keywords :: "ibl debug irradiance prefilter specular gpu memory estimation vram"
	testing.expect(t, section_has_matches("gpu memory estimate", keywords),
		"'estimate' should fuzzy-match 'estimation' via Levenshtein")
}

@(test)
test_section_no_match :: proc(t: ^testing.T) {
	keywords :: "ibl debug irradiance prefilter specular gpu memory estimation vram"
	testing.expect(t, !section_has_matches("foobar", keywords), "unrelated term should not match section")
}

// --- Real-world regression cases ---

@(test)
test_levenshtein_basic :: proc(t: ^testing.T) {
	testing.expect_value(t, levenshtein("", ""), 0)
	testing.expect_value(t, levenshtein("a", ""), 1)
	testing.expect_value(t, levenshtein("", "b"), 1)
	testing.expect_value(t, levenshtein("kitten", "sitting"), 3)
	testing.expect_value(t, levenshtein("saturday", "sunday"), 3)
	testing.expect_value(t, levenshtein("estimate", "estimation"), 3)
	testing.expect_value(t, levenshtein("gpu", "gpu"), 0)
	testing.expect_value(t, levenshtein("color", "colour"), 1)
}

@(test)
test_levenshtein_fuzzy_matching :: proc(t: ^testing.T) {
	// Typo tolerance: "specualr" → "specular" (transposition = 2 edits)
	testing.expect(t, fuzzy_match("specualr", "Specular Map", ""), "typo should fuzzy-match via Levenshtein")
	// "irradiance" vs "irradianc" (missing 'e' at end = distance 1)
	testing.expect(t, fuzzy_match("irradianc", "", "irradiance"), "missing trailing char should match")
	// "prefiltr" vs "prefilter" (distance 1)
	testing.expect(t, fuzzy_match("prefiltr", "Prefilter Map", ""), "minor typo should match")
	// "xyz" should NOT match "abc" (distance 3, threshold for 3-char = max(1,3/4)=1)
	testing.expect(t, !fuzzy_match("xyz", "abc", ""), "completely different short words should not match")
}

@(test)
test_ibl_debug_search :: proc(t: ^testing.T) {
	ibl_keywords :: "ibl debug irradiance prefilter specular diffuse brdf lut split sum texture gpu memory estimation vram mip roughness preview environment map hdr convolution ggx"

	testing.expect(t, section_has_matches("ibl", ibl_keywords), "'ibl' should match IBL section")
	testing.expect(t, section_has_matches("IBL debug", ibl_keywords), "'IBL debug' should match IBL section")
	testing.expect(t, section_has_matches("irrad", ibl_keywords), "'irrad' should match IBL section")
	testing.expect(t, section_has_matches("GPU estimation", ibl_keywords), "'GPU estimation' should match IBL section")
	testing.expect(t, section_has_matches("GPU memory estimate", ibl_keywords),
		"'GPU memory estimate' should match via Levenshtein (no explicit 'estimate' keyword needed)")
	testing.expect(t, section_has_matches("brdf lut", ibl_keywords), "'brdf lut' should match IBL section")
	testing.expect(t, section_has_matches("specul", ibl_keywords), "'specul' should match IBL section")
	testing.expect(t, section_has_matches("LUT", ibl_keywords), "'LUT' should match IBL section")
}
