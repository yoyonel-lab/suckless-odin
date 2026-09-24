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
import scene "../src/scene"
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
		path:              string,
		expected_sun:      bool,
		expected_aperture: bool,
		min_elevation:     f32,
		max_elevation:     f32,
		min_azimuth:       f32,
		max_azimuth:       f32,
	}

	expectations := [?]Env_Test_Expectation{
		{
			path              = "assets/textures/hdr/abandoned_garage_4k.hdr",
			expected_sun      = true,  // Indoor skylight/verrière aperture
			expected_aperture = true,
			min_elevation     = 20.0, max_elevation = 45.0,
			min_azimuth       = 10.0, max_azimuth   = 40.0,
		},
		{
			path              = "assets/textures/hdr/cedar_bridge_2_4k.hdr",
			expected_sun      = true,  // Outdoor direct sun
			expected_aperture = false,
			min_elevation     = 45.0, max_elevation = 65.0,
			min_azimuth       = 25.0, max_azimuth   = 45.0,
		},
		{
			path              = "assets/textures/hdr/neon_photostudio_4k.hdr",
			expected_sun      = true,  // Indoor window wall aperture
			expected_aperture = true,
			min_elevation     = 10.0, max_elevation = 30.0,
			min_azimuth       = 80.0, max_azimuth   = 120.0,
		},
		{
			path              = "assets/textures/hdr/river_alcove_4k.hdr",
			expected_sun      = true,  // Outdoor direct sun
			expected_aperture = false,
			min_elevation     = 35.0, max_elevation = 55.0,
			min_azimuth       = 25.0, max_azimuth   = 45.0,
		},
		{
			path              = "assets/textures/hdr/small_cathedral_02_4k.hdr",
			expected_sun      = true,  // Direct sun through cathedral window
			expected_aperture = false,
			min_elevation     = 5.0,  max_elevation = 20.0,
			min_azimuth       = 25.0, max_azimuth   = 45.0,
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
		testing.expect_value(t, det.is_aperture, exp.expected_aperture)
		testing.expect(t, det.elevation >= exp.min_elevation && det.elevation <= exp.max_elevation,
			fmt.tprintf("%s: elevation %.2f not in [%.2f, %.2f]", exp.path, det.elevation, exp.min_elevation, exp.max_elevation))
		testing.expect(t, det.azimuth >= exp.min_azimuth && det.azimuth <= exp.max_azimuth,
			fmt.tprintf("%s: azimuth %.2f not in [%.2f, %.2f]", exp.path, det.azimuth, exp.min_azimuth, exp.max_azimuth))

		// Check normalized direction
		dir_len := mt.vec3_length(det.direction)
		testing.expect(t, math.abs(dir_len - 1.0) < 1e-4, "Sun direction must be unit vector")
	}
}

@(test)
test_sun_angles_dir_roundtrip :: proc(t: ^testing.T) {
	test_cases := [?][2]f32{
		{0.0, 45.0},
		{90.0, 30.0},
		{-90.0, 60.0},
		{180.0, 15.0},
		{-180.0, 80.0},
		{45.0, 0.0},     // Horizon
		{-135.0, 75.0},
		{33.8, 51.5},    // Cedar bridge angles
	}

	for tc in test_cases {
		azimuth_in := tc[0]
		elevation_in := tc[1]

		dir := rendering.sun_angles_to_dir(azimuth_in, elevation_in)
		dir_len := mt.vec3_length(dir)
		testing.expect(t, math.abs(dir_len - 1.0) < 1e-4, "Direction must be unit vector")

		azimuth_out, elevation_out := rendering.sun_dir_to_angles(dir)
		diff_elev := math.abs(elevation_out - elevation_in)
		testing.expect(t, diff_elev < 1e-2, fmt.tprintf("Elevation roundtrip error: in=%.2f, out=%.2f", elevation_in, elevation_out))

		// If near zenith, azimuth is degenerate
		if elevation_in < 89.0 {
			diff_azim := math.abs(azimuth_out - azimuth_in)
			if diff_azim > 359.0 do diff_azim = math.abs(diff_azim - 360.0)
			testing.expect(t, diff_azim < 1e-2, fmt.tprintf("Azimuth roundtrip error: in=%.2f, out=%.2f", azimuth_in, azimuth_out))
		}
	}
}

@(test)
test_env_metadata_cache_lookup :: proc(t: ^testing.T) {
	// 1. Lookup cedar bridge from bundled cache
	det_cedar, ok_cedar := scene.env_metadata_cache_lookup("assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok_cedar, "Cedar bridge must be found in env_metadata.json cache")
	testing.expect(t, det_cedar.sun_detected, "Cedar bridge must have sun_detected=true in cache")
	testing.expect(t, det_cedar.azimuth > 30.0 && det_cedar.azimuth < 40.0, "Cedar bridge azimuth should match cached value (~35.2)")
	testing.expect(t, det_cedar.elevation > 50.0 && det_cedar.elevation < 60.0, "Cedar bridge elevation should match cached value (~56.4)")
	testing.expect(t, det_cedar.color.x > 0.95 && det_cedar.color.y > 0.80 && det_cedar.color.z > 0.80, "Cedar bridge color must be warm golden")

	// 2. Lookup indoor map from bundled cache (verrière aperture detected)
	det_garage, ok_garage := scene.env_metadata_cache_lookup("abandoned_garage_4k.hdr")
	testing.expect(t, ok_garage, "Abandoned garage must be found using bare filename in cache")
	testing.expect(t, det_garage.sun_detected, "Abandoned garage must have sun_detected=true (aperture) in cache")
	testing.expect(t, det_garage.is_aperture, "Abandoned garage must have is_aperture=true in cache")
	testing.expect(t, det_garage.confidence > 0, "Indoor garage should have confidence > 0 in cache")
	testing.expect(t, det_garage.color.z > 0.90, "Garage skylight color must be cool blue daylight")

	// 3. Lookup non-existent file
	_, ok_nonexist := scene.env_metadata_cache_lookup("nonexistent_sky_999.hdr")
	testing.expect(t, !ok_nonexist, "Nonexistent HDR must not be found in cache")
}

@(test)
test_sun_shadow_color_override :: proc(t: ^testing.T) {
	ss: rendering.Sun_Shadow
	ss.detection = rendering.Sun_Detection{
		color        = mt.Vec3{1.0, 0.70, 0.30},
		sun_detected = true,
	}
	ss.color_override_enabled = false
	ss.manual_color = mt.Vec3{0.20, 0.50, 1.0}

	// 1. Without override: should return detected color
	eff1 := rendering.sun_shadow_get_effective_color(&ss)
	testing.expect_value(t, eff1.x, f32(1.0))
	testing.expect_value(t, eff1.y, f32(0.70))
	testing.expect_value(t, eff1.z, f32(0.30))

	// 2. With override: should return manual color
	ss.color_override_enabled = true
	eff2 := rendering.sun_shadow_get_effective_color(&ss)
	testing.expect_value(t, eff2.x, f32(0.20))
	testing.expect_value(t, eff2.y, f32(0.50))
	testing.expect_value(t, eff2.z, f32(1.0))
}

