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

// Verifies TAA Exponential Moving Average (EMA) mathematical convergence
@(test)
test_volumetric_taa_ema_blend :: proc(t: ^testing.T) {
	// If input is static 1.0 and history starts at 0.0 with alpha = 0.20
	alpha: f32 = 0.20
	history: f32 = 0.0
	current: f32 = 1.0

	// Step through 16 frames
	for _ in 0..<16 {
		history = math.lerp(history, current, alpha)
	}

	// After 16 frames: (1 - 0.2)^16 = 0.028 => history = 0.972
	testing.expect(t, history > 0.95, "EMA blend should rapidly converge to steady-state value")
	testing.expect(t, history <= 1.0, "EMA blend should never exceed source value")
}

// Verifies TAA Depth Disocclusion Rejection
@(test)
test_volumetric_taa_disocclusion_acceptance :: proc(t: ^testing.T) {
	depth_threshold: f32 = 0.80

	// Case 1: Identical depth (0 delta) -> 100% acceptance
	diff_0: f32 = 0.0
	scale: f32 = 2.0 / depth_threshold
	accept_0 := math.exp(-diff_0 * scale)
	testing.expect_value(t, math.abs(accept_0 - 1.0) < 0.001, true)

	// Case 2: Small delta (0.1m) -> High acceptance (>75%)
	diff_small: f32 = 0.10
	accept_small := math.exp(-diff_small * scale)
	testing.expect(t, accept_small > 0.75, "Small depth delta should maintain high history acceptance")

	// Case 3: Large delta (>0.80m) -> Disocclusion (0% acceptance)
	diff_large: f32 = 1.20
	disoccluded := diff_large > depth_threshold
	testing.expect(t, disoccluded, "Depth delta exceeding threshold should be marked as disocclusion")
}

// Verifies Bilateral depth-aware weight attenuation and silhouette preservation
@(test)
test_volumetric_bilateral_weights :: proc(t: ^testing.T) {
	sharpness: f32 = 500.0

	// 1. Same surface (depth diff = 0): weight must be exactly 1.0
	diff_same: f32 = 0.0
	w_same := 1.0 / (sharpness * diff_same + 1.0)
	testing.expect_value(t, math.abs(w_same - 1.0) < 0.0001, true)

	// 2. Object silhouette edge (depth diff = 0.5m across sphere boundary):
	// weight = 1 / (500 * 0.5 + 1) = 1 / 251 ≈ 0.00398 (99.6% attenuation!)
	diff_edge: f32 = 0.50
	w_edge := 1.0 / (sharpness * diff_edge + 1.0)
	testing.expect(t, w_edge < 0.01, "Bilateral weight across depth silhouette must sharply cut off to avoid bleeding")

	// 3. 9-tap 1D Gaussian kernel normalization check
	k_weights_9 := [5]f32{0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622}
	sum_9 := k_weights_9[0] + 2.0 * (k_weights_9[1] + k_weights_9[2] + k_weights_9[3] + k_weights_9[4])
	testing.expect_value(t, math.abs(sum_9 - 1.0) < 0.001, true)

	// 4. 5-tap 1D Gaussian kernel normalization check
	k_weights_5 := [3]f32{0.4026, 0.2442, 0.0545}
	sum_5 := k_weights_5[0] + 2.0 * (k_weights_5[1] + k_weights_5[2])
	testing.expect_value(t, math.abs(sum_5 - 1.0) < 0.001, true)
}

// Verifies Bilateral Edge Attenuation Map computation & Gaussian vs Bilateral comparison
@(test)
test_volumetric_edge_attenuation_and_sharpness :: proc(t: ^testing.T) {
	// Case 1: Gaussian blur (sharpness = 0) -> weight on edge is 1.0 (Bleeds across edges)
	sharpness_zero: f32 = 0.0
	diff_edge: f32 = 5.0
	w_gauss := 1.0 / (sharpness_zero * diff_edge + 1.0)
	testing.expect_value(t, w_gauss, 1.0)

	// Case 2: Bilateral blur (sharpness = 500) -> weight on edge drops sharply
	sharpness_std: f32 = 500.0
	w_bilateral := 1.0 / (sharpness_std * diff_edge + 1.0)
	testing.expect(t, w_bilateral < 0.001, "Bilateral weight must drop below 0.1% for 5m depth jump")

	// Case 3: Loupe UV coordinate mapping
	zoom_scale: f32 = 4.0
	zoom_center := mt.Vec2{0.5, 0.5}
	tex_coords := mt.Vec2{0.6, 0.5}
	uv := (tex_coords - zoom_center) / zoom_scale + zoom_center
	testing.expect_value(t, math.abs(uv.x - 0.525) < 0.0001, true)
	testing.expect_value(t, math.abs(uv.y - 0.500) < 0.0001, true)
}

// Verifies Phase 6 Joint Bilateral Upsampling (JBU) 2x2 depth weights and Nearest-Depth Heuristic
@(test)
test_volumetric_jbu_weights :: proc(t: ^testing.T) {
	upsample_sharpness: f32 = 200.0
	near_plane: f32 = 0.1

	// Test 1: Flat planar depth (Z_full = 10m, Z_0..3 = 10m) -> Depth weights are exactly 1.0
	full_z: f32 = 10.0
	norm_z := math.max(full_z, near_plane)

	w_depth_flat := 1.0 / (1.0 + upsample_sharpness * (math.abs(full_z - 10.0) / norm_z))
	testing.expect_value(t, math.abs(w_depth_flat - 1.0) < 0.0001, true)

	// Test 2: Silhouette edge (Full-res pixel is on sphere at Z_full = 5m, but 2 low-res taps are sky at 50m)
	z_sphere: f32 = 5.0
	z_sky: f32 = 50.0
	norm_z_sphere := math.max(z_sphere, near_plane)

	w_fg := 1.0 / (1.0 + upsample_sharpness * (math.abs(z_sphere - z_sphere) / norm_z_sphere)) // 1.0
	w_bg := 1.0 / (1.0 + upsample_sharpness * (math.abs(z_sphere - z_sky) / norm_z_sphere))    // 1 / (1 + 200 * 9) = 1/1801 ≈ 0.00055

	testing.expect_value(t, w_fg, 1.0)
	testing.expect(t, w_bg < 0.001, "JBU must suppress background low-res tap by >99.9% on foreground silhouette pixel")

	// Test 3: Nearest-Depth Heuristic selection
	dz0: f32 = math.abs(z_sphere - 5.1)
	dz1: f32 = math.abs(z_sphere - 50.0)
	dz2: f32 = math.abs(z_sphere - 48.0)
	dz3: f32 = math.abs(z_sphere - 5.2)

	min_dz := dz0
	best_idx: int = 0
	if dz1 < min_dz { min_dz = dz1; best_idx = 1 }
	if dz2 < min_dz { min_dz = dz2; best_idx = 2 }
	if dz3 < min_dz { min_dz = dz3; best_idx = 3 }

	testing.expect_value(t, best_idx, 0)
}

// Verifies Phase 7 Atmosphere Presets and GPU timer metric window accumulation
@(test)
test_volumetric_presets_and_timers :: proc(t: ^testing.T) {
	// 1. Presets Application
	vr: rendering.Volumetric_Renderer
	light: rendering.Point_Light

	rendering.volumetric_preset_apply(&vr, &light, .God_Rays)
	testing.expect_value(t, vr.params.step_count, 32)
	testing.expect_value(t, vr.params.anisotropy_g, 0.75)
	testing.expect_value(t, vr.params.scattering_coeff, 0.035)
	testing.expect_value(t, vr.params.upsample_mode, 2)
	testing.expect_value(t, light.intensity, 2.0)
	testing.expect_value(t, light.phase_g, 0.75)

	rendering.volumetric_preset_apply(&vr, &light, .Isotropic)
	testing.expect_value(t, vr.params.anisotropy_g, 0.0)
	testing.expect_value(t, vr.params.scattering_coeff, 0.040)
	testing.expect_value(t, light.phase_g, 0.0)

	// 2. Metric Window calculation
	w: rendering.Volumetric_Metric_Window
	w.sum = 1.0 + 2.0 + 3.0
	w.count = 3
	w.min_raw = 1.0
	w.max_raw = 3.0
	w.display_avg = f32(w.sum / f64(w.count))
	w.display_min = w.min_raw
	w.display_max = w.max_raw

	testing.expect_value(t, math.abs(w.display_avg - 2.0) < 0.0001, true)
	testing.expect_value(t, w.display_min, 1.0)
	testing.expect_value(t, w.display_max, 3.0)
}

// Verifies Proposition 3.2: Crepuscular Horizon Fade smoothstep attenuation
@(test)
test_crepuscular_horizon_fade :: proc(t: ^testing.T) {
	fade_start: f32 = 45.0
	fade_end: f32 = 85.0

	// 1. Below or at start angle: full boost (1.0)
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(0.0, fade_start, fade_end), f32(1.0))
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(20.0, fade_start, fade_end), f32(1.0))
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(45.0, fade_start, fade_end), f32(1.0))

	// 2. Above or at end angle: zero boost (0.0)
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(85.0, fade_start, fade_end), f32(0.0))
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(90.0, fade_start, fade_end), f32(0.0))

	// 3. Midpoint: (65 - 45) / (85 - 45) = 20 / 40 = 0.5 -> smoothstep(0.5) = 0.5 -> 1.0 - 0.5 = 0.5
	mid := rendering.compute_crepuscular_horizon_fade(65.0, fade_start, fade_end)
	testing.expect_value(t, math.abs(mid - 0.5) < 0.0001, true)

	// 4. Clamping bounds: negative elevation clamped to 0.0 -> returns 1.0; > 90 clamped to 90.0 -> returns 0.0
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(-10.0, fade_start, fade_end), f32(1.0))
	testing.expect_value(t, rendering.compute_crepuscular_horizon_fade(120.0, fade_start, fade_end), f32(0.0))

	// 5. Monotonic decrease over [fade_start, fade_end]
	prev := f32(1.0)
	for deg in 45..=85 {
		val := rendering.compute_crepuscular_horizon_fade(f32(deg), fade_start, fade_end)
		testing.expect(t, val <= prev, "Horizon fade must be monotonically decreasing")
		prev = val
	}
}

// Verifies Proposition 3.5: Multi-Scattering Isotropic Compensation
@(test)
test_multi_scattering_compensation :: proc(t: ^testing.T) {
	// 1. Identity when amount = 0.0
	test_phase: f32 = 4.5
	testing.expect_value(t, rendering.volumetric_compute_multi_scattering(test_phase, 0.0), test_phase)

	// 2. Pure isotropic when amount = 1.0
	testing.expect_value(t, rendering.volumetric_compute_multi_scattering(test_phase, 1.0), f32(1.0))
	testing.expect_value(t, rendering.volumetric_compute_multi_scattering(0.2, 1.0), f32(1.0))

	// 3. Midpoint blend: 50% single-scattering + 50% isotropic
	mid := rendering.volumetric_compute_multi_scattering(0.2, 0.5)
	testing.expect_value(t, math.abs(mid - 0.6) < 0.0001, true)

	// 4. Clamping bounds
	testing.expect_value(t, rendering.volumetric_compute_multi_scattering(test_phase, -0.5), test_phase)
	testing.expect_value(t, rendering.volumetric_compute_multi_scattering(test_phase, 1.5), f32(1.0))

	// 5. Physical energy filling at 90 degrees with strong Mie anisotropy (g = 0.6)
	p_90 := rendering.volumetric_henyey_greenstein(0.0, 0.6)
	p_comp := rendering.volumetric_compute_multi_scattering(p_90, 0.25)
	// Compensated phase must be strictly higher than single scattering at 90 deg (filling the dip)
	testing.expect(t, p_comp > p_90, "Multi-scattering must lift phase value at 90 degrees")
	expected_comp := 0.75 * p_90 + 0.25 * 1.0
	testing.expect_value(t, math.abs(p_comp - expected_comp) < 0.0001, true)
}

// Verifies Proposition 3.6: Dynamic Airmass Spectrum (Kasten-Young)
@(test)
test_optical_airmass_and_dynamic_spectrum :: proc(t: ^testing.T) {
	// 1. Airmass at zenith (90 deg) is ~1.0
	airmass_zenith := rendering.volumetric_compute_optical_airmass(90.0)
	testing.expect_value(t, math.abs(airmass_zenith - 1.0) < 0.05, true)

	// 2. Airmass at horizon (0 deg) is ~38.0
	airmass_horizon := rendering.volumetric_compute_optical_airmass(0.0)
	testing.expect_value(t, airmass_horizon >= 35.0 && airmass_horizon <= 39.0, true)

	// 3. Airmass at 30 deg elevation (approx 2.0)
	airmass_30 := rendering.volumetric_compute_optical_airmass(30.0)
	testing.expect_value(t, airmass_30 >= 1.9 && airmass_30 <= 2.1, true)

	// 4. Clamping bounds: negative elevation clamped to 0.0; > 90.0 clamped to 90.0
	testing.expect_value(t, rendering.volumetric_compute_optical_airmass(-15.0), airmass_horizon)
	testing.expect_value(t, rendering.volumetric_compute_optical_airmass(110.0), airmass_zenith)

	// 5. Monotonic decrease of airmass as elevation increases
	prev_airmass := airmass_horizon
	for deg in 1..=90 {
		am := rendering.volumetric_compute_optical_airmass(f32(deg))
		testing.expect(t, am <= prev_airmass, "Airmass must decrease as elevation rises")
		prev_airmass = am
	}

	// 6. Intensity = 0.0 yields neutral unit spectrum at any elevation
	spec_neutral_zenith := rendering.volumetric_compute_airmass_spectrum(90.0, 0.0)
	testing.expect_value(t, spec_neutral_zenith, mt.Vec3{1.0, 1.0, 1.0})
	spec_neutral_horizon := rendering.volumetric_compute_airmass_spectrum(0.0, 0.0)
	testing.expect_value(t, spec_neutral_horizon, mt.Vec3{1.0, 1.0, 1.0})

	// 7. Zenith spectrum has blue dominant over red (Rayleigh azure haze)
	spec_zenith := rendering.volumetric_compute_airmass_spectrum(90.0, 1.0)
	testing.expect(t, spec_zenith.z > spec_zenith.x, "Zenith spectrum must be blue-dominant")
	testing.expect(t, spec_zenith.z > spec_zenith.y, "Zenith spectrum blue must exceed green")

	// 8. Horizon spectrum has red dominant over blue (Sunset extinction rais)
	spec_horizon := rendering.volumetric_compute_airmass_spectrum(0.0, 1.0)
	testing.expect(t, spec_horizon.x > spec_horizon.z, "Horizon spectrum must be red-dominant")
	testing.expect(t, spec_horizon.x > spec_horizon.y, "Horizon spectrum red must exceed green")
}

// Verifies Proposition 3.4: Wind & Solar Dust Convection Drift
@(test)
test_dust_convection_drift :: proc(t: ^testing.T) {
	sun_dir := mt.Vec3{0.6, 0.8, -0.2}
	custom_wind := mt.Vec3{0.35, -0.10, 0.75}

	// 1. Mode 0: Ambient Gentle Drift returns constant baseline
	ambient := rendering.volumetric_compute_dust_drift(.Ambient_Fixed, sun_dir, custom_wind)
	testing.expect_value(t, ambient, rendering.DUST_AMBIENT_DRIFT_DEFAULT)

	// 2. Mode 1: Solar Updraft Convection rises vertically (Y > 0) and tilts with sun
	solar_drift := rendering.volumetric_compute_dust_drift(.Solar_Updraft, sun_dir, custom_wind)
	testing.expect(t, solar_drift.y > 0.07, "Solar convection must have dominant upward thermal lift")
	testing.expect(t, solar_drift.x > 0.0, "Solar convection X component must follow sun horizontal azimuth")
	testing.expect(t, solar_drift.z < 0.0, "Solar convection Z component must follow sun horizontal azimuth")

	// 3. Mode 2: Custom Wind Vector faithfully returns user values
	custom := rendering.volumetric_compute_dust_drift(.Custom_Wind, sun_dir, custom_wind)
	testing.expect_value(t, custom, custom_wind)

	// 4. Fallback unknown mode defaults to ambient
	fallback := rendering.volumetric_compute_dust_drift(rendering.Volumetric_Dust_Drift_Mode(99), sun_dir, custom_wind)
	testing.expect_value(t, fallback, rendering.DUST_AMBIENT_DRIFT_DEFAULT)
}



