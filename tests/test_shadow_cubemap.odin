// +build test
package tests

import "core:math"
import "core:math/linalg"
import "core:testing"

import mt        "../src/core/math_types"
import rendering "../src/rendering"

EPSILON :: 1e-4

@(test)
test_shadow_cubemap_face_view_matrices :: proc(t: ^testing.T) {
	light_pos := mt.Vec3{5.0, 10.0, -3.0}

	// 1. Positive X
	mat_px := rendering.cubemap_face_view_matrix(.Positive_X, light_pos)
	dir_px := mt.Vec4{1.0, 0.0, 0.0, 0.0}
	view_dir_px := mat_px * dir_px
	testing.expect(t, math.abs(view_dir_px.x) < EPSILON, "PX view dir X must be 0")
	testing.expect(t, math.abs(view_dir_px.y) < EPSILON, "PX view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_px.z - (-1.0)) < EPSILON, "PX view dir Z must be -1 (forward)")

	// 2. Negative X
	mat_nx := rendering.cubemap_face_view_matrix(.Negative_X, light_pos)
	dir_nx := mt.Vec4{-1.0, 0.0, 0.0, 0.0}
	view_dir_nx := mat_nx * dir_nx
	testing.expect(t, math.abs(view_dir_nx.x) < EPSILON, "NX view dir X must be 0")
	testing.expect(t, math.abs(view_dir_nx.y) < EPSILON, "NX view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_nx.z - (-1.0)) < EPSILON, "NX view dir Z must be -1 (forward)")

	// 3. Positive Y
	mat_py := rendering.cubemap_face_view_matrix(.Positive_Y, light_pos)
	dir_py := mt.Vec4{0.0, 1.0, 0.0, 0.0}
	view_dir_py := mat_py * dir_py
	testing.expect(t, math.abs(view_dir_py.x) < EPSILON, "PY view dir X must be 0")
	testing.expect(t, math.abs(view_dir_py.y) < EPSILON, "PY view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_py.z - (-1.0)) < EPSILON, "PY view dir Z must be -1 (forward)")

	// 4. Negative Y
	mat_ny := rendering.cubemap_face_view_matrix(.Negative_Y, light_pos)
	dir_ny := mt.Vec4{0.0, -1.0, 0.0, 0.0}
	view_dir_ny := mat_ny * dir_ny
	testing.expect(t, math.abs(view_dir_ny.x) < EPSILON, "NY view dir X must be 0")
	testing.expect(t, math.abs(view_dir_ny.y) < EPSILON, "NY view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_ny.z - (-1.0)) < EPSILON, "NY view dir Z must be -1 (forward)")

	// 5. Positive Z
	mat_pz := rendering.cubemap_face_view_matrix(.Positive_Z, light_pos)
	dir_pz := mt.Vec4{0.0, 0.0, 1.0, 0.0}
	view_dir_pz := mat_pz * dir_pz
	testing.expect(t, math.abs(view_dir_pz.x) < EPSILON, "PZ view dir X must be 0")
	testing.expect(t, math.abs(view_dir_pz.y) < EPSILON, "PZ view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_pz.z - (-1.0)) < EPSILON, "PZ view dir Z must be -1 (forward)")

	// 6. Negative Z
	mat_nz := rendering.cubemap_face_view_matrix(.Negative_Z, light_pos)
	dir_nz := mt.Vec4{0.0, 0.0, -1.0, 0.0}
	view_dir_nz := mat_nz * dir_nz
	testing.expect(t, math.abs(view_dir_nz.x) < EPSILON, "NZ view dir X must be 0")
	testing.expect(t, math.abs(view_dir_nz.y) < EPSILON, "NZ view dir Y must be 0")
	testing.expect(t, math.abs(view_dir_nz.z - (-1.0)) < EPSILON, "NZ view dir Z must be -1 (forward)")
}

@(test)
test_shadow_cubemap_projection_matrix :: proc(t: ^testing.T) {
	near := f32(0.01)
	far := f32(25.0)
	proj := mt.perspective(mt.radians(90.0), 1.0, near, far)

	// In 90 degree FOV with aspect 1.0: 1/tan(45 deg) = 1.0
	testing.expect(t, math.abs(proj[0][0] - 1.0) < EPSILON, "Proj[0][0] must be 1.0 for 90 deg FOV")
	testing.expect(t, math.abs(proj[1][1] - 1.0) < EPSILON, "Proj[1][1] must be 1.0 for 90 deg FOV")
	testing.expect(t, math.abs(proj[2][3] - (-1.0)) < EPSILON, "Proj[2][3] must be -1.0 for perspective")

	// Project point at near plane along -Z: (0, 0, -near, 1)
	p_near := mt.Vec4{0.0, 0.0, -near, 1.0}
	clip_near := proj * p_near
	ndc_near_z := clip_near.z / clip_near.w
	testing.expect(t, math.abs(ndc_near_z - (-1.0)) < EPSILON, "Near plane must project to NDC z = -1.0")

	// Project point at far plane along -Z: (0, 0, -far, 1)
	p_far := mt.Vec4{0.0, 0.0, -far, 1.0}
	clip_far := proj * p_far
	ndc_far_z := clip_far.z / clip_far.w
	testing.expect(t, math.abs(ndc_far_z - 1.0) < EPSILON, "Far plane must project to NDC z = 1.0")
}

@(test)
test_point_light_orbit_animation :: proc(t: ^testing.T) {
	light := rendering.Point_Light{
		position     = mt.Vec3{0.0, 5.0, 0.0},
		radius       = 15.0,
		color        = mt.Vec3{1.0, 0.9, 0.8},
		intensity    = 2.0,
		enabled      = true,
		is_animated  = true,
		orbit_speed  = 1.0,
		orbit_radius = 4.0,
		orbit_center = mt.Vec3{0.0, 5.0, 0.0},
	}

	// At t = 0: pos = center + (radius * cos(0), 0, radius * sin(0)) = (4, 5, 0)
	p0 := rendering.point_light_get_position(&light, 0.0)
	testing.expect(t, math.abs(p0.x - 4.0) < EPSILON, "t=0 X should be 4.0")
	testing.expect(t, math.abs(p0.y - 5.0) < EPSILON, "t=0 Y should be 5.0")
	testing.expect(t, math.abs(p0.z - 0.0) < EPSILON, "t=0 Z should be 0.0")

	// At t = PI/2: pos = (0, 5, 4)
	p1 := rendering.point_light_get_position(&light, math.PI / 2.0)
	testing.expect(t, math.abs(p1.x - 0.0) < EPSILON, "t=PI/2 X should be 0.0")
	testing.expect(t, math.abs(p1.y - 5.0) < EPSILON, "t=PI/2 Y should be 5.0")
	testing.expect(t, math.abs(p1.z - 4.0) < EPSILON, "t=PI/2 Z should be 4.0")
}

@(test)
test_shadow_normal_offset_and_slope_bias :: proc(t: ^testing.T) {
	// 1. Normal Offset Bias on perpendicular surface (NdotL = 1.0)
	// Normal offset should be 0 (no offset needed on front-facing surface)
	normal_bias: f32 = 0.025
	ndotl_front: f32 = 1.0
	offset_front := normal_bias * (1.0 - ndotl_front)
	testing.expect_value(t, offset_front, 0.0)

	// 2. Normal Offset Bias on grazing angle (NdotL = 0.0)
	// Normal offset should be maximal (0.025m) to push sample point away from surface
	ndotl_grazing: f32 = 0.0
	offset_grazing := normal_bias * (1.0 - ndotl_grazing)
	testing.expect_value(t, math.abs(offset_grazing - normal_bias) < EPSILON, true)

	// 3. Slope-Scaled Depth Bias: increases tolerance on grazing angles
	base_bias: f32 = 0.0015
	slope_bias: f32 = 0.0010
	slope_factor_front := math.sqrt(math.clamp(1.0 - ndotl_front * ndotl_front, 0.0, 1.0)) / math.max(ndotl_front, 0.05)
	bias_front := base_bias + slope_bias * slope_factor_front
	testing.expect_value(t, math.abs(bias_front - base_bias) < EPSILON, true)

	ndotl_edge: f32 = 0.10
	slope_factor_edge := math.sqrt(math.clamp(1.0 - ndotl_edge * ndotl_edge, 0.0, 1.0)) / math.max(ndotl_edge, 0.05)
	bias_edge := base_bias + slope_bias * slope_factor_edge
	testing.expect(t, bias_edge > base_bias * 5.0, "Slope-scaled bias must significantly increase on grazing angle edges")
}

@(test)
test_shadow_pcf_vogel_disk_sampling :: proc(t: ^testing.T) {
	GOLDEN_ANGLE :: 2.39996323
	filter_radius: f32 = 0.015
	num_samples: i32 = 16

	// 1. Verify monotonic radius scaling in Vogel-Disk
	prev_r: f32 = -1.0
	for i in 0..<num_samples {
		r := math.sqrt((f32(i) + 0.5) / f32(num_samples)) * filter_radius
		testing.expect(t, r > prev_r, "Vogel-Disk radius should be strictly monotonically increasing")
		testing.expect(t, r <= filter_radius, "Sample radius must be within filter_radius")
		prev_r = r
	}

	// 2. Verify Orthonormal Basis (ONB) construction
	dir := mt.Vec3{0.0, 0.0, -1.0}
	up := mt.Vec3{0.0, 1.0, 0.0} if math.abs(dir.y) < 0.999 else mt.Vec3{1.0, 0.0, 0.0}
	tangent := linalg.normalize(linalg.cross(up, dir))
	bitangent := linalg.cross(dir, tangent)

	// Tangent & Bitangent orthogonality
	testing.expect(t, math.abs(linalg.dot(tangent, dir)) < EPSILON, "Tangent must be orthogonal to Ray Direction")
	testing.expect(t, math.abs(linalg.dot(bitangent, dir)) < EPSILON, "Bitangent must be orthogonal to Ray Direction")
	testing.expect(t, math.abs(linalg.dot(tangent, bitangent)) < EPSILON, "Tangent and Bitangent must be mutually orthogonal")
	testing.expect(t, math.abs(linalg.length(tangent) - 1.0) < EPSILON, "Tangent must be unit length")
	testing.expect(t, math.abs(linalg.length(bitangent) - 1.0) < EPSILON, "Bitangent must be unit length")

	// 3. Verify sample points coverage and bounding radius
	rotation: f32 = 1.234 // Arbitrary IGN rotation
	cos_rot := math.cos(rotation)
	sin_rot := math.sin(rotation)

	for i in 0..<num_samples {
		r := math.sqrt((f32(i) + 0.5) / f32(num_samples)) * filter_radius
		theta := f32(i) * GOLDEN_ANGLE

		x := r * (math.cos(theta) * cos_rot - math.sin(theta) * sin_rot)
		y := r * (math.sin(theta) * cos_rot + math.cos(theta) * sin_rot)

		dist := math.sqrt(x*x + y*y)
		testing.expect(t, dist <= filter_radius + EPSILON, "Rotated sample must stay within kernel radius")
	}
}

@(test)
test_shadow_debug_modes_and_delta :: proc(t: ^testing.T) {
	// 1. Validate Shadow_Debug_Mode enum values
	testing.expect_value(t, i32(rendering.Shadow_Debug_Mode.Off), 0)
	testing.expect_value(t, i32(rendering.Shadow_Debug_Mode.Mask), 1)
	testing.expect_value(t, i32(rendering.Shadow_Debug_Mode.Penumbra), 2)
	testing.expect_value(t, i32(rendering.Shadow_Debug_Mode.Delta_Vs_Hard), 3)
	testing.expect_value(t, i32(rendering.Shadow_Debug_Mode.Split_Screen), 4)

	// 2. Validate Penumbra Softness factor (1.0 - abs(s * 2.0 - 1.0))
	calc_penumbra :: proc(s: f32) -> f32 {
		return 1.0 - math.abs(s * 2.0 - 1.0)
	}
	testing.expect_value(t, calc_penumbra(0.0), 0.0) // Full shadow -> 0 penumbra
	testing.expect_value(t, calc_penumbra(1.0), 0.0) // Full light  -> 0 penumbra
	testing.expect_value(t, calc_penumbra(0.5), 1.0) // 50% penumbra -> max softness (1.0)
	testing.expect(t, calc_penumbra(0.25) > 0.0 && calc_penumbra(0.25) < 1.0, "Intermediate penumbra factor")

	// 3. Validate Delta vs Hard comparison logic
	hard_shadow: f32 = 0.0 // Hard edge
	pcf_8_shadow: f32 = 0.375 // 3 of 8 taps lit
	pcf_16_shadow: f32 = 0.4375 // 7 of 16 taps lit

	delta_8 := math.abs(pcf_8_shadow - hard_shadow)
	delta_16 := math.abs(pcf_16_shadow - hard_shadow)
	testing.expect(t, delta_8 > 0.0, "Delta between Hard and Vogel 8 must be non-zero in penumbra")
	testing.expect(t, delta_16 > 0.0, "Delta between Hard and Vogel 16 must be non-zero in penumbra")

	// 4. Validate Split Screen comparison selection
	split_pos: f32 = 0.5
	uv_left: f32 = 0.25
	uv_right: f32 = 0.75

	shadow_left := hard_shadow if (uv_left < split_pos) else pcf_16_shadow
	shadow_right := hard_shadow if (uv_right < split_pos) else pcf_16_shadow

	testing.expect_value(t, shadow_left, hard_shadow)
	testing.expect_value(t, shadow_right, pcf_16_shadow)
}
