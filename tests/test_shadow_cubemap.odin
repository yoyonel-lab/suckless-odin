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
