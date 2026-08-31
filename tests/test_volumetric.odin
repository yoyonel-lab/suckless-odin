package tests

import "core:testing"
import "core:math"

import mt "../src/core/math_types"
import rendering "../src/rendering"

// Verifies that Henyey-Greenstein produces normalized isotropic value 1.0 for g = 0 (ISO legacy)
@(test)
test_henyey_greenstein_isotropic :: proc(t: ^testing.T) {
	expected_iso: f32 = 1.0

	for angle_deg in 0..=180 {
		theta := math.to_radians(f32(angle_deg))
		cos_theta := math.cos(theta)
		val := rendering.volumetric_henyey_greenstein(cos_theta, 0.0)

		testing.expect_value(t, math.abs(val - expected_iso) < 0.0001, true)
	}
}

// Verifies forward scattering peak for g > 0 and backward peak for g < 0
@(test)
test_henyey_greenstein_anisotropy_peaks :: proc(t: ^testing.T) {
	// Forward scattering (g = 0.6)
	p_forward := rendering.volumetric_henyey_greenstein(1.0, 0.6)  // cos(theta) = 1 (forward)
	p_backward := rendering.volumetric_henyey_greenstein(-1.0, 0.6) // cos(theta) = -1 (backward)
	testing.expect(t, p_forward > p_backward * 10.0, "Forward scattering should heavily exceed backward scattering for g > 0")

	// Backward scattering (g = -0.6)
	p_forward_neg := rendering.volumetric_henyey_greenstein(1.0, -0.6)
	p_backward_neg := rendering.volumetric_henyey_greenstein(-1.0, -0.6)
	testing.expect(t, p_backward_neg > p_forward_neg * 10.0, "Backward scattering should heavily exceed forward scattering for g < 0")
}

// Verifies normalization of Henyey-Greenstein across the sphere: \int_0^\pi P(theta, g) * 0.5*sin(theta) d_theta == 1.0
@(test)
test_henyey_greenstein_energy_conservation :: proc(t: ^testing.T) {
	g_values := [5]f32{ -0.75, -0.35, 0.0, 0.40, 0.80 }

	N_SAMPLES :: 10000
	d_theta := math.PI / f32(N_SAMPLES)

	for g in g_values {
		integral: f32 = 0.0
		for i in 0..<N_SAMPLES {
			theta := (f32(i) + 0.5) * d_theta
			cos_theta := math.cos(theta)
			sin_theta := math.sin(theta)

			p := rendering.volumetric_henyey_greenstein(cos_theta, g)
			integral += p * (0.5 * sin_theta) * d_theta
		}

		testing.expect_value(t, math.abs(integral - 1.0) < 0.01, true)
	}
}

// Verifies analytic Ray-Sphere intersection
@(test)
test_ray_sphere_intersection :: proc(t: ^testing.T) {
	sphere_center := mt.Vec3{ 0.0, 0.0, 10.0 }
	radius: f32 = 2.0

	// 1. Ray through sphere center
	ray_orig := mt.Vec3{ 0.0, 0.0, 0.0 }
	ray_dir := mt.Vec3{ 0.0, 0.0, 1.0 }

	hit, t0, t1 := rendering.volumetric_intersect_ray_sphere(ray_orig, ray_dir, sphere_center, radius)
	testing.expect(t, hit, "Central ray should hit sphere")
	testing.expect_value(t, math.abs(t0 - 8.0) < 0.001, true)
	testing.expect_value(t, math.abs(t1 - 12.0) < 0.001, true)

	// 2. Ray clearly missing sphere
	miss_dir := mt.Vec3{ 1.0, 0.0, 0.0 }
	miss_hit, _, _ := rendering.volumetric_intersect_ray_sphere(ray_orig, miss_dir, sphere_center, radius)
	testing.expect(t, !miss_hit, "Perpendicular ray should miss sphere")

	// 3. Camera inside sphere
	inside_orig := mt.Vec3{ 0.0, 0.0, 10.5 }
	inside_hit, in_t0, in_t1 := rendering.volumetric_intersect_ray_sphere(inside_orig, ray_dir, sphere_center, radius)
	testing.expect(t, inside_hit, "Ray from inside sphere should hit")
	testing.expect(t, in_t0 < 0.0, "t0 should be negative when camera inside")
	testing.expect(t, in_t1 > 0.0, "t1 should be positive when camera inside")
}
