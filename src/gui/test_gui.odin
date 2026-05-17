// +build test
package gui

import "core:testing"

// --- to_lower_ascii tests ---

@(test)
test_to_lower_ascii_uppercase :: proc(t: ^testing.T) {
	testing.expect_value(t, to_lower_ascii('A'), 'a')
	testing.expect_value(t, to_lower_ascii('Z'), 'z')
	testing.expect_value(t, to_lower_ascii('M'), 'm')
}

@(test)
test_to_lower_ascii_lowercase_unchanged :: proc(t: ^testing.T) {
	testing.expect_value(t, to_lower_ascii('a'), 'a')
	testing.expect_value(t, to_lower_ascii('z'), 'z')
}

@(test)
test_to_lower_ascii_non_alpha_unchanged :: proc(t: ^testing.T) {
	testing.expect_value(t, to_lower_ascii('0'), '0')
	testing.expect_value(t, to_lower_ascii('-'), '-')
	testing.expect_value(t, to_lower_ascii(' '), ' ')
}

// --- fuzzy_match tests ---

@(test)
test_fuzzy_match_empty_filter_matches_all :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("", "Bloom", "glow post effect"),
		"empty filter should match everything")
}

@(test)
test_fuzzy_match_single_term_in_label :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("bloom", "Bloom", "glow post effect"),
		"'bloom' should match label 'Bloom'")
}

@(test)
test_fuzzy_match_single_term_in_keywords :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("glow", "Bloom", "glow post effect"),
		"'glow' should match keyword")
}

@(test)
test_fuzzy_match_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("BLOOM", "Bloom", "glow post effect"),
		"case-insensitive: 'BLOOM' should match 'Bloom'")
	testing.expect(t, fuzzy_match("Post-Processing", "Bloom", "post-processing rendering glow effect"),
		"'Post-Processing' should match keyword 'post-processing'")
}

@(test)
test_fuzzy_match_multi_term_all_must_match :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("post bloom", "Bloom", "post-processing rendering glow effect"),
		"both 'post' and 'bloom' present")
	testing.expect(t, !fuzzy_match("post xyz", "Bloom", "post-processing rendering glow effect"),
		"'xyz' not present, should fail")
}

@(test)
test_fuzzy_match_no_match :: proc(t: ^testing.T) {
	testing.expect(t, !fuzzy_match("vignette", "Bloom", "glow post effect"),
		"'vignette' should not match 'Bloom'")
}

@(test)
test_fuzzy_match_partial_word :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("bloo", "Bloom", "glow post effect"),
		"partial 'bloo' should match 'bloom'")
}

@(test)
test_fuzzy_match_hyphenated :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_match("post-processing", "FXAA", "post-processing rendering anti-aliasing antialiasing smooth"),
		"hyphenated search should match hyphenated keyword")
}

// --- section_has_matches tests ---

@(test)
test_section_has_matches_positive :: proc(t: ^testing.T) {
	testing.expect(t, section_has_matches("bloom", RENDERING_KEYWORDS),
		"'bloom' should match rendering section keywords")
}

@(test)
test_section_has_matches_negative :: proc(t: ^testing.T) {
	testing.expect(t, !section_has_matches("xyz123", RENDERING_KEYWORDS),
		"'xyz123' should not match rendering section")
}

@(test)
test_section_has_matches_post_processing :: proc(t: ^testing.T) {
	testing.expect(t, section_has_matches("post-processing", RENDERING_KEYWORDS),
		"'post-processing' should match rendering section")
	testing.expect(t, section_has_matches("post processing", RENDERING_KEYWORDS),
		"'post processing' (with space) should match rendering section")
}

@(test)
test_section_has_matches_camera :: proc(t: ^testing.T) {
	testing.expect(t, section_has_matches("speed", CAMERA_KEYWORDS),
		"'speed' should match camera section")
	testing.expect(t, !section_has_matches("bloom", CAMERA_KEYWORDS),
		"'bloom' should not match camera section")
}

@(test)
test_section_has_matches_empty_filter :: proc(t: ^testing.T) {
	testing.expect(t, section_has_matches("", RENDERING_KEYWORDS),
		"empty filter should match any section")
}
