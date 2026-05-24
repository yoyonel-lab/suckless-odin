// +build test
package tests

import "core:math"
import "core:strings"
import "core:testing"

import glasbey "../src/core/glasbey"

// --- Color conversion tests ---

@(test)
test_rgb_to_lab_black :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({0, 0, 0})
	testing.expect(t, abs(lab.L) < 0.01, "Black should have L*≈0")
	testing.expect(t, abs(lab.a) < 0.01, "Black should have a*≈0")
	testing.expect(t, abs(lab.b) < 0.01, "Black should have b*≈0")
}

@(test)
test_rgb_to_lab_white :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({255, 255, 255})
	testing.expect(t, abs(lab.L - 100.0) < 0.1, "White should have L*≈100")
	testing.expect(t, abs(lab.a) < 0.5, "White should have a*≈0")
	testing.expect(t, abs(lab.b) < 0.5, "White should have b*≈0")
}

@(test)
test_rgb_to_lab_red :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({255, 0, 0})
	// Pure red: L*≈53.23, a*≈80.11, b*≈67.22
	testing.expect(t, abs(lab.L - 53.23) < 1.0, "Red L* should be ≈53")
	testing.expect(t, lab.a > 70.0, "Red a* should be strongly positive")
	testing.expect(t, lab.b > 50.0, "Red b* should be positive")
}

@(test)
test_rgb_to_lab_green :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({0, 255, 0})
	// Pure green: L*≈87.74, a*≈-86.18, b*≈83.18
	testing.expect(t, lab.L > 80.0, "Green L* should be high")
	testing.expect(t, lab.a < -70.0, "Green a* should be strongly negative")
	testing.expect(t, lab.b > 70.0, "Green b* should be strongly positive")
}

@(test)
test_rgb_to_lab_blue :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({0, 0, 255})
	// Pure blue: L*≈32.30, a*≈79.20, b*≈-107.86
	testing.expect(t, lab.L > 25.0 && lab.L < 40.0, "Blue L* should be ≈32")
	testing.expect(t, lab.a > 60.0, "Blue a* should be positive")
	testing.expect(t, lab.b < -90.0, "Blue b* should be strongly negative")
}

// --- Delta E tests ---

@(test)
test_delta_e_identical :: proc(t: ^testing.T) {
	lab := glasbey.Color_LAB{50, 20, -10}
	testing.expect_value(t, glasbey.delta_e(lab, lab), f32(0.0))
}

@(test)
test_delta_e_black_white :: proc(t: ^testing.T) {
	black := glasbey.rgb_to_lab({0, 0, 0})
	white := glasbey.rgb_to_lab({255, 255, 255})
	de := glasbey.delta_e(black, white)
	// Black-white ΔE ≈ 100
	testing.expect(t, de > 95.0 && de < 105.0, "Black-White ΔE should be ≈100")
}

@(test)
test_delta_e_symmetry :: proc(t: ^testing.T) {
	c1 := glasbey.rgb_to_lab({255, 0, 0})
	c2 := glasbey.rgb_to_lab({0, 255, 0})
	testing.expect_value(t, glasbey.delta_e(c1, c2), glasbey.delta_e(c2, c1))
}

@(test)
test_delta_e_similar_colors_small :: proc(t: ^testing.T) {
	c1 := glasbey.rgb_to_lab({128, 128, 128})
	c2 := glasbey.rgb_to_lab({130, 128, 128})
	de := glasbey.delta_e(c1, c2)
	// Very similar grays — ΔE should be small
	testing.expect(t, de < 2.0, "Nearly identical colors should have small ΔE")
}

// --- Palette generation tests ---

@(test)
test_generate_returns_correct_size :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 8, step = 32})
	defer glasbey.destroy_result(&result)
	testing.expect_value(t, len(result.palette), 8)
}

@(test)
test_generate_all_colors_in_gamut :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 16, step = 32})
	defer glasbey.destroy_result(&result)
	for c in result.palette {
		testing.expect(t, c.r >= 0 && c.r <= 255, "R out of gamut")
		testing.expect(t, c.g >= 0 && c.g <= 255, "G out of gamut")
		testing.expect(t, c.b >= 0 && c.b <= 255, "B out of gamut")
	}
}

@(test)
test_generate_no_duplicates :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 16, step = 32})
	defer glasbey.destroy_result(&result)
	for i := 0; i < len(result.palette); i += 1 {
		for j := i + 1; j < len(result.palette); j += 1 {
			a := result.palette[i]
			b := result.palette[j]
			same := a.r == b.r && a.g == b.g && a.b == b.b
			testing.expect(t, !same, "Duplicate color in palette")
		}
	}
}

@(test)
test_generate_min_delta_e_excellent :: proc(t: ^testing.T) {
	// With step=32, 16 colors should still be very distinct (ΔE > 30)
	result := glasbey.generate({size = 16, step = 32})
	defer glasbey.destroy_result(&result)
	testing.expect(
		t,
		result.min_delta_e > 30.0,
		"16-color palette should have min ΔE > 30 (excellent distinctness)",
	)
}

@(test)
test_generate_min_delta_e_good_32_colors :: proc(t: ^testing.T) {
	// 32 colors at step=32 should still be discernible (ΔE > 15)
	result := glasbey.generate({size = 32, step = 32})
	defer glasbey.destroy_result(&result)
	testing.expect(
		t,
		result.min_delta_e > 15.0,
		"32-color palette should have min ΔE > 15 (good distinctness)",
	)
}

@(test)
test_generate_closest_pair_valid :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 8, step = 32})
	defer glasbey.destroy_result(&result)
	testing.expect(t, result.closest_pair[0] >= 0, "Pair index 0 valid")
	testing.expect(t, result.closest_pair[1] > result.closest_pair[0], "Pair index 1 > 0")
	testing.expect(t, result.closest_pair[1] < len(result.palette), "Pair index 1 in bounds")
}

@(test)
test_generate_monotonically_decreasing_min_de :: proc(t: ^testing.T) {
	// More colors → smaller minimum ΔE (pigeonhole in color space)
	r8 := glasbey.generate({size = 8, step = 32})
	defer glasbey.destroy_result(&r8)
	r16 := glasbey.generate({size = 16, step = 32})
	defer glasbey.destroy_result(&r16)
	r32 := glasbey.generate({size = 32, step = 32})
	defer glasbey.destroy_result(&r32)

	testing.expect(t, r8.min_delta_e >= r16.min_delta_e, "8 colors should have ≥ min ΔE than 16")
	testing.expect(t, r16.min_delta_e >= r32.min_delta_e, "16 colors should have ≥ min ΔE than 32")
}

@(test)
test_generate_backgrounds_constrain :: proc(t: ^testing.T) {
	// If we use red as a background, the first picked color should NOT be red
	red_bg := []glasbey.Color_RGB{{255, 0, 0}, {0, 0, 0}, {255, 255, 255}}
	result := glasbey.generate({size = 1, step = 32, backgrounds = red_bg})
	defer glasbey.destroy_result(&result)

	// First color should be far from red in LAB
	red_lab := glasbey.rgb_to_lab({255, 0, 0})
	pick_lab := glasbey.rgb_to_lab(result.palette[0])
	de := glasbey.delta_e(red_lab, pick_lab)
	testing.expect(t, de > 50.0, "First pick should be far from red background")
}

@(test)
test_compute_min_pairwise_single_color :: proc(t: ^testing.T) {
	single := []glasbey.Color_RGB{{128, 64, 200}}
	min_de, _ := glasbey.compute_min_pairwise_delta_e(single)
	testing.expect(t, min_de == math.INF_F32, "Single color should return INF")
}

@(test)
test_destroy_result_idempotent :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 4, step = 64})
	glasbey.destroy_result(&result)
	testing.expect(t, result.palette == nil, "Palette should be nil after destroy")
	// Second destroy should not crash
	glasbey.destroy_result(&result)
}

// --- Lightness/Chroma bounds tests ---

@(test)
test_bounds_lightness_filters_dark :: proc(t: ^testing.T) {
	// With L* bounds [40, 90], no near-black colors should appear
	result := glasbey.generate({size = 8, step = 32, lightness_bounds = {40, 90}})
	defer glasbey.destroy_result(&result)

	for c in result.palette {
		lab := glasbey.rgb_to_lab(c)
		testing.expect(t, lab.L >= 38.0, "Color too dark for L* bounds [40,90]")
		testing.expect(t, lab.L <= 92.0, "Color too bright for L* bounds [40,90]")
	}
}

@(test)
test_bounds_chroma_filters_grays :: proc(t: ^testing.T) {
	// With C* bounds [30, 100], no desaturated colors should appear
	result := glasbey.generate({size = 8, step = 32, chroma_bounds = {30, 100}})
	defer glasbey.destroy_result(&result)

	for c in result.palette {
		lab := glasbey.rgb_to_lab(c)
		ch := glasbey.chroma(lab)
		testing.expect(t, ch >= 28.0, "Color too desaturated for C* bounds [30,100]")
	}
}

@(test)
test_bounds_combined_still_distinct :: proc(t: ^testing.T) {
	// Constrained gamut should still produce distinct colors
	result := glasbey.generate({
		size = 12, step = 16,
		lightness_bounds = {20, 90},
		chroma_bounds = {20, 100},
	})
	defer glasbey.destroy_result(&result)

	testing.expect(t, result.min_delta_e > 15.0,
		"Bounded 12-color palette should have min ΔE > 15")
}

// --- Adaptive strategy tests ---

@(test)
test_adaptive_returns_correct_size :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 8, step = 16, adaptive = true})
	defer glasbey.destroy_result(&result)
	testing.expect_value(t, len(result.palette), 8)
}

@(test)
test_adaptive_quality_close_to_full :: proc(t: ^testing.T) {
	// Adaptive step=16 should get within 5 ΔE of full step=16 (non-adaptive)
	full := glasbey.generate({size = 16, step = 16})
	defer glasbey.destroy_result(&full)
	adaptive := glasbey.generate({size = 16, step = 16, adaptive = true})
	defer glasbey.destroy_result(&adaptive)

	// Adaptive refines locally, so it should be >= the coarse-only result
	testing.expect(t, adaptive.min_delta_e >= full.min_delta_e - 5.0,
		"Adaptive should be within 5 ΔE of coarse-only")
}

@(test)
test_adaptive_no_duplicates :: proc(t: ^testing.T) {
	result := glasbey.generate({size = 16, step = 16, adaptive = true})
	defer glasbey.destroy_result(&result)
	for i := 0; i < len(result.palette); i += 1 {
		for j := i + 1; j < len(result.palette); j += 1 {
			a := result.palette[i]
			b := result.palette[j]
			same := a.r == b.r && a.g == b.g && a.b == b.b
			testing.expect(t, !same, "Adaptive: duplicate color in palette")
		}
	}
}

@(test)
test_adaptive_with_bounds :: proc(t: ^testing.T) {
	result := glasbey.generate({
		size = 8, step = 16, adaptive = true,
		lightness_bounds = {20, 90},
		chroma_bounds = {20, 100},
	})
	defer glasbey.destroy_result(&result)

	for c in result.palette {
		lab := glasbey.rgb_to_lab(c)
		testing.expect(t, lab.L >= 18.0, "Adaptive+bounds: L* too low")
		testing.expect(t, lab.L <= 92.0, "Adaptive+bounds: L* too high")
	}
}

// --- Export tests ---

@(test)
test_export_odin_format :: proc(t: ^testing.T) {
	palette := []glasbey.Color_RGB{{255, 0, 0}, {0, 255, 0}}
	s := glasbey.export_odin(palette, "TEST_PAL")
	defer delete(s)

	testing.expect(t, strings.contains(s, "TEST_PAL :: [2][3]f32{"),
		"Odin export should contain constant declaration")
	testing.expect(t, strings.contains(s, "1.0000, 0.0000, 0.0000"),
		"Odin export should contain red values")
}

@(test)
test_export_glsl_format :: proc(t: ^testing.T) {
	palette := []glasbey.Color_RGB{{0, 0, 255}, {128, 128, 0}}
	s := glasbey.export_glsl(palette, "myColors")
	defer delete(s)

	testing.expect(t, strings.contains(s, "const vec3 myColors[2] = vec3[]("),
		"GLSL export should contain const array declaration")
	testing.expect(t, strings.contains(s, "vec3(0.0000, 0.0000, 1.0000)"),
		"GLSL export should contain blue values")
}

// --- Chroma utility test ---

@(test)
test_chroma_pure_gray :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({128, 128, 128})
	ch := glasbey.chroma(lab)
	testing.expect(t, ch < 1.0, "Pure gray should have near-zero chroma")
}

@(test)
test_chroma_saturated_red :: proc(t: ^testing.T) {
	lab := glasbey.rgb_to_lab({255, 0, 0})
	ch := glasbey.chroma(lab)
	testing.expect(t, ch > 90.0, "Saturated red should have high chroma")
}
