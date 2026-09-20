// +build test
package tests

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:os"
import "core:testing"

import mt "../src/core/math_types"
import rendering "../src/rendering"
import simd "../src/core/simd_utils"

@(test)
test_sun_uv_dir_roundtrip :: proc(t: ^testing.T) {
	// Test various UV points covering the equirectangular sphere
	test_uvs := [?][2]f32{
		{0.5, 0.5},   // Front horizon (X=1, Y=0, Z=0)
		{0.75, 0.5},  // Right horizon (X=0, Y=0, Z=1)
		{0.25, 0.5},  // Left horizon  (X=0, Y=0, Z=-1)
		{0.0, 0.5},   // Back horizon  (X=-1, Y=0, Z=0)
		{0.5, 0.75},  // 45 deg elevation
		{0.5, 1.0},   // Zenith (+Y)
		{0.5, 0.0},   // Nadir  (-Y)
	}

	for uv in test_uvs {
		dir := rendering.sun_uv_to_dir(uv)
		testing.expect(t, math.abs(mt.vec3_length(dir) - 1.0) < 1e-4, "Direction must be unit length")

		// For poles, phi is degenerate, so skip azimuth check
		if uv.y > 0.01 && uv.y < 0.99 {
			uv_rt := rendering.sun_dir_to_uv(dir)
			diff_u := math.abs(uv_rt[0] - uv[0])
			if diff_u > 0.5 do diff_u = math.abs(diff_u - 1.0)
			testing.expect(t, diff_u < 1e-3, fmt.tprintf("U roundtrip error for %v -> %v", uv, uv_rt))
			testing.expect(t, math.abs(uv_rt[1] - uv[1]) < 1e-3, fmt.tprintf("V roundtrip error for %v -> %v", uv, uv_rt))
		}
	}
}

@(test)
test_sun_ortho_projection_mapping :: proc(t: ^testing.T) {
	left: f32 = -15.0
	right: f32 = 15.0
	bottom: f32 = -15.0
	top: f32 = 15.0
	near: f32 = 1.0
	far: f32 = 60.0

	proj := glsl.mat4Ortho3d(left, right, bottom, top, near, far)

	// In OpenGL view space: camera looks down -Z
	// Near plane is at z = -near = -1.0
	// Far plane is at z = -far = -60.0
	p_near := mt.Vec4{0.0, 0.0, -near, 1.0}
	clip_near := proj * p_near
	testing.expect(t, math.abs(clip_near.z - (-1.0)) < 1e-4, "Near plane must map to -1.0 in OpenGL NDC")

	p_far := mt.Vec4{0.0, 0.0, -far, 1.0}
	clip_far := proj * p_far
	testing.expect(t, math.abs(clip_far.z - 1.0) < 1e-4, "Far plane must map to +1.0 in OpenGL NDC")
}

@(test)
test_sun_detection_all_envmaps :: proc(t: ^testing.T) {
	Env_Test_Expectation :: struct {
		path:            string,
		expected_sun:    bool,
		min_elevation:   f32,
		max_elevation:   f32,
		min_azimuth:     f32,
		max_azimuth:     f32,
		expected_color:  mt.Vec3,
		color_tolerance: f32,
	}

	expectations := [?]Env_Test_Expectation{
		{
			path            = "assets/textures/hdr/abandoned_garage_4k.hdr",
			expected_sun    = false, // Indoor garage -> Fallback fixed direction & color
			min_elevation   = 44.9, max_elevation = 45.1,
			min_azimuth     = 89.9, max_azimuth   = 90.1,
			expected_color  = rendering.SUN_FALLBACK_COLOR,
			color_tolerance = 0.01,
		},
		{
			path            = "assets/textures/hdr/cedar_bridge_2_4k.hdr",
			expected_sun    = true,  // Outdoor sun detected (slightly warm daylight)
			min_elevation   = 45.0, max_elevation = 65.0,
			min_azimuth     = 25.0, max_azimuth   = 45.0,
			expected_color  = mt.Vec3{1.145, 0.960, 0.970},
			color_tolerance = 0.05,
		},
		{
			path            = "assets/textures/hdr/neon_photostudio_4k.hdr",
			expected_sun    = false, // Indoor studio -> Fallback fixed direction & color
			min_elevation   = 44.9, max_elevation = 45.1,
			min_azimuth     = 89.9, max_azimuth   = 90.1,
			expected_color  = rendering.SUN_FALLBACK_COLOR,
			color_tolerance = 0.01,
		},
		{
			path            = "assets/textures/hdr/river_alcove_4k.hdr",
			expected_sun    = true,  // Outdoor sun detected (neutral crisp daylight)
			min_elevation   = 35.0, max_elevation = 55.0,
			min_azimuth     = 25.0, max_azimuth   = 45.0,
			expected_color  = mt.Vec3{0.991, 0.999, 1.032},
			color_tolerance = 0.05,
		},
		{
			path            = "assets/textures/hdr/small_cathedral_02_4k.hdr",
			expected_sun    = true,  // Direct sun through window (warm golden amber)
			min_elevation   = 5.0,  max_elevation = 20.0,
			min_azimuth     = 25.0, max_azimuth   = 45.0,
			expected_color  = mt.Vec3{1.514, 0.911, 0.371},
			color_tolerance = 0.05,
		},
	}

	for exp in expectations {
		actual_path := exp.path
		data, err := os.read_entire_file_from_path(actual_path, context.allocator)
		if err != nil {
			actual_path = fmt.tprintf("../%s", exp.path)
			data, err = os.read_entire_file_from_path(actual_path, context.allocator)
		}
		testing.expect(t, err == nil, fmt.tprintf("Failed to read HDR: %s", exp.path))
		defer delete(data)

		w, h: i32
		simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
		pixel_count := uint(w) * uint(h) * 4
		bytes_fp16 := (pixel_count * size_of(u16) + 63) & ~uint(63)
		half_data := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
		defer libc.free(half_data)

		simd.fast_hdr_decode_fp16(raw_data(data), uint(len(data)), &w, &h, half_data, pixel_count, 1)

		det := rendering.sun_detect_from_fp16(half_data, w, h)

		testing.expect_value(t, det.sun_detected, exp.expected_sun)
		testing.expect(t, det.elevation >= exp.min_elevation && det.elevation <= exp.max_elevation,
			fmt.tprintf("%s: elevation %.2f not in [%.2f, %.2f]", exp.path, det.elevation, exp.min_elevation, exp.max_elevation))
		testing.expect(t, det.azimuth >= exp.min_azimuth && det.azimuth <= exp.max_azimuth,
			fmt.tprintf("%s: azimuth %.2f not in [%.2f, %.2f]", exp.path, det.azimuth, exp.min_azimuth, exp.max_azimuth))

		// Check normalized direction
		dir_len := mt.vec3_length(det.direction)
		testing.expect(t, math.abs(dir_len - 1.0) < 1e-4, "Sun direction must be unit vector")

		// Check halo chromatic tint
		testing.expect(t, math.abs(det.sun_color.x - exp.expected_color.x) <= exp.color_tolerance,
			fmt.tprintf("%s: sun_color.r %.3f != expected %.3f", exp.path, det.sun_color.x, exp.expected_color.x))
		testing.expect(t, math.abs(det.sun_color.y - exp.expected_color.y) <= exp.color_tolerance,
			fmt.tprintf("%s: sun_color.g %.3f != expected %.3f", exp.path, det.sun_color.y, exp.expected_color.y))
		testing.expect(t, math.abs(det.sun_color.z - exp.expected_color.z) <= exp.color_tolerance,
			fmt.tprintf("%s: sun_color.b %.3f != expected %.3f", exp.path, det.sun_color.z, exp.expected_color.z))
	}
}

@(test)
test_sun_halo_synthetic_color :: proc(t: ^testing.T) {
	w: i32 = 256
	h: i32 = 128
	total_pixels := int(w) * int(h)
	half_data := make([]u16, total_pixels * 4)
	defer delete(half_data)

	// Sun positioned at azimuth 0, elevation 30
	sun_dir := rendering.sun_angles_to_dir(0.0, 30.0)

	// Planted tint: Sunset orange
	planted_raw_rgb := mt.Vec3{2500.0, 750.0, 150.0}
	planted_lum := 0.2126 * planted_raw_rgb.x + 0.7152 * planted_raw_rgb.y + 0.0722 * planted_raw_rgb.z
	planted_tint := planted_raw_rgb / planted_lum

	cos_core := math.cos(math.to_radians(f32(2.5)))
	cos_halo := math.cos(math.to_radians(f32(12.0)))

	for y in 0 ..< int(h) {
		for x in 0 ..< int(w) {
			idx := (y * int(w) + x) * 4
			u := (f32(x) + 0.5) / f32(w)
			v := (f32(y) + 0.5) / f32(h)
			dir := rendering.sun_uv_to_dir([2]f32{u, v})
			d := glsl.dot(dir, sun_dir)

			r, g, b: f32 = 0.5, 0.5, 0.6 // Ambient sky
			if d >= cos_core {
				// Clipped white solar disc
				r, g, b = 65500.0, 65500.0, 65500.0
			} else if d >= cos_halo {
				// Planted colored halo
				r = planted_raw_rgb.x
				g = planted_raw_rgb.y
				b = planted_raw_rgb.z
			}

			half_data[idx + 0] = transmute(u16)f16(r)
			half_data[idx + 1] = transmute(u16)f16(g)
			half_data[idx + 2] = transmute(u16)f16(b)
			half_data[idx + 3] = transmute(u16)f16(1.0)
		}
	}

	det := rendering.sun_detect_from_fp16(raw_data(half_data), w, h)
	testing.expect(t, det.sun_detected, "Synthetic sun must be detected")

	// Verify that detected sun_color extracted the planted halo tint, NOT clipped white (1,1,1)
	testing.expect(t, math.abs(det.sun_color.x - planted_tint.x) < 0.05,
		fmt.tprintf("Planted R tint error: got %f, expected %f", det.sun_color.x, planted_tint.x))
	testing.expect(t, math.abs(det.sun_color.y - planted_tint.y) < 0.05,
		fmt.tprintf("Planted G tint error: got %f, expected %f", det.sun_color.y, planted_tint.y))
	testing.expect(t, math.abs(det.sun_color.z - planted_tint.z) < 0.05,
		fmt.tprintf("Planted B tint error: got %f, expected %f", det.sun_color.z, planted_tint.z))
}
