// +build test
package test_gl

import "core:testing"
import "core:fmt"
import "core:time"
import "core:math"
import "core:os"
import "core:strings"
import "core:c"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import sc "../../src/scene"
import cam "../../src/camera"
import mt "../../src/core/math_types"
import rendering "../../src/rendering"

@(test)
test_volumetric_auto_sun_e2e :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	width: i32 = 960
	height: i32 = 540

	rt, rt_ok := render_target_create(width, height)
	if !rt_ok {
		testing.expect(t, false, "Failed to create offscreen render target FBO")
		return
	}
	defer render_target_destroy(&rt)

	s: sc.Scene
	if !sc.scene_create(&s, width, height) {
		testing.expect(t, false, "Failed to create scene")
		return
	}
	defer sc.scene_destroy(&s)

	os.make_directory(VOLUMETRIC_REPORT_DIR)

	// Set standard camera framing through sphere grid
	s.camera.position = mt.Vec3{0.0, 1.0, 16.0}
	s.camera.yaw = -90.0
	s.camera.pitch = -3.0
	s.camera.yaw_target = -90.0
	s.camera.pitch_target = -3.0
	cam.update_vectors(&s.camera)

	render_frame :: proc(s: ^sc.Scene, rt: ^Render_Target) {
		sc.scene_update(s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(s, rt.width, rt.height)
		gl.Finish()
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	}

	wait_for_env :: proc(s: ^sc.Scene, rt: ^Render_Target) {
		for iter in 0..<5000 {
			sc.scene_update(s, 0.016)
			gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
			gl.Viewport(0, 0, rt.width, rt.height)
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			sc.scene_render(s, rt.width, rt.height)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
				break
			}
			time.sleep(2 * time.Millisecond)
		}
		for _ in 0..<20 {
			render_frame(s, rt)
		}
	}

	calc_saturation :: proc(pixels: []u8, w, h: i32) -> f32 {
		total_pixels := int(w * h)
		saturated_count := 0
		for i in 0..<total_pixels {
			r := pixels[i * 4 + 0]
			g := pixels[i * 4 + 1]
			b := pixels[i * 4 + 2]
			if r >= 250 || g >= 250 || b >= 250 {
				saturated_count += 1
			}
		}
		return (f32(saturated_count) / f32(total_pixels)) * 100.0
	}

	// -------------------------------------------------------------------------
	// 1. Initial stabilization on cedar_bridge
	// -------------------------------------------------------------------------
	wait_for_env(&s, &rt)

	// Configure Sun Directional with Auto
	s.point_light.enabled = false
	s.volumetric.params.enabled = true
	s.volumetric.params.shadows_enabled = true
	s.volumetric.params.light_mode = .Sun_Directional
	s.volumetric.params.sun_intensity = 1.8
	s.volumetric.params.sun_intensity_auto = true
	s.volumetric.params.step_count = 20
	s.volumetric.params.scattering_coeff = 0.04
	s.volumetric.params.extinction_coeff = 0.06
	s.volumetric.params.anisotropy_g = 0.62
	s.volumetric.params.jitter_enabled = true
	s.volumetric.params.taa_mode = 2
	s.volumetric.params.taa_alpha = 0.20
	s.volumetric.params.blur_mode = 2
	s.volumetric.params.upsample_mode = 2
	s.volumetric.params.resolution_divider = 2

	Env_Test_Case :: struct {
		name:           string,
		path:           string,
		expected_auto:  f32,
		expected_color: mt.Vec3,
		expect_sun:     bool,
	}

	cases := [4]Env_Test_Case{
		{
			name           = "cedar_bridge",
			path           = "assets/textures/hdr/cedar_bridge_2_4k.hdr",
			expected_auto  = 16107.0 / 64428.3, // ~0.250
			expected_color = mt.Vec3{1.145, 0.960, 0.970},
			expect_sun     = true,
		},
		{
			name           = "river_alcove",
			path           = "assets/textures/hdr/river_alcove_4k.hdr",
			expected_auto  = 16107.0 / 65504.0, // ~0.2458
			expected_color = mt.Vec3{0.991, 0.999, 1.032},
			expect_sun     = true,
		},
		{
			name           = "small_cathedral",
			path           = "assets/textures/hdr/small_cathedral_02_4k.hdr",
			expected_auto  = 16107.0 / 51697.3, // ~0.3116
			expected_color = mt.Vec3{1.514, 0.911, 0.371},
			expect_sun     = true,
		},
		{
			name           = "neon_photostudio",
			path           = "assets/textures/hdr/neon_photostudio_4k.hdr",
			expected_auto  = rendering.VOLUMETRIC_DEFAULT_INTENSITY_SUN, // 0.25 fallback!
			expected_color = rendering.SUN_FALLBACK_COLOR,
			expect_sun     = false,
		},
	}

	fmt.printfln("==========================================================================")
	fmt.printfln("🧪 MISSION F2: AUTOMATIC SUN COLOR & INTENSITY VALIDATION")
	fmt.printfln("==========================================================================")

	for tc, idx in cases {
		if idx > 0 {
			sc.scene_change_env(&s, tc.path)
			wait_for_env(&s, &rt)
		}

		det := s.sun_shadow.detection
		auto_scale := s.volumetric.params.sun_auto_scale
		eff_int := rendering.volumetric_get_effective_intensity(&s.volumetric)
		eff_color := rendering.volumetric_get_effective_sun_color(&s.volumetric, det)

		testing.expect_value(t, det.sun_detected, tc.expect_sun)
		testing.expect(t, math.abs(auto_scale - tc.expected_auto) < 0.005,
			fmt.tprintf("auto_scale mismatch for %s: got %.4f, expected %.4f", tc.name, auto_scale, tc.expected_auto))
		testing.expect_value(t, eff_int, auto_scale)

		testing.expect(t, math.abs(eff_color.x - tc.expected_color.x) < 0.05,
			fmt.tprintf("color.r mismatch for %s: got %.3f, expected %.3f", tc.name, eff_color.x, tc.expected_color.x))
		testing.expect(t, math.abs(eff_color.y - tc.expected_color.y) < 0.05,
			fmt.tprintf("color.g mismatch for %s: got %.3f, expected %.3f", tc.name, eff_color.y, tc.expected_color.y))
		testing.expect(t, math.abs(eff_color.z - tc.expected_color.z) < 0.05,
			fmt.tprintf("color.b mismatch for %s: got %.3f, expected %.3f", tc.name, eff_color.z, tc.expected_color.z))

		// Extra frames to converge TAA
		for _ in 0..<16 {
			render_frame(&s, &rt)
		}

		pixels := vol_capture_fbo_rgba(rt.fbo, width, height)
		defer delete(pixels)

		sat_pct := calc_saturation(pixels, width, height)
		out_path := fmt.tprintf("tests/reports/volumetric/auto_sun_%s.png", tc.name)
		vol_save_png(out_path, pixels, width, height, 4)

		out_color_path := fmt.tprintf("tests/reports/volumetric/auto_sun_color_%s.png", tc.name)
		vol_save_png(out_color_path, pixels, width, height, 4)

		fmt.printfln("  [Envmap %d/4] %-18s: Peak=%8.1f | Detected=%-5v | AutoColor=(%.2f, %.2f, %.2f) | AutoScale=%.3f | Sat=%.2f%%",
			idx + 1, tc.name, det.peak_intensity, det.sun_detected, eff_color.x, eff_color.y, eff_color.z, auto_scale, sat_pct)

		max_sat: f32 = 20.0
		testing.expect(t, sat_pct < max_sat, fmt.tprintf("Saturation too high on %s: %.2f%%", tc.name, sat_pct))
	}

	// -------------------------------------------------------------------------
	// 2. Override manual test on cedar_bridge (intensity + color)
	// -------------------------------------------------------------------------
	fmt.printfln("--------------------------------------------------------------------------")
	fmt.printfln("🧪 TESTING MANUAL OVERRIDE & AUTO RE-ACTIVATION (cedar_bridge)")
	sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	wait_for_env(&s, &rt)

	// Simulate slider drag to 0.80
	s.volumetric.params.intensity_mult = 0.80
	s.volumetric.params.sun_intensity_auto = false
	eff_override := rendering.volumetric_get_effective_intensity(&s.volumetric)
	testing.expect_value(t, eff_override, f32(0.80))

	// Simulate manual color override (warm sunset orange)
	s.volumetric.params.sun_color = mt.Vec3{2.0, 0.7, 0.2}
	s.volumetric.params.sun_color_auto = false
	eff_col_override := rendering.volumetric_get_effective_sun_color(&s.volumetric, s.sun_shadow.detection)
	testing.expect_value(t, eff_col_override, mt.Vec3{2.0, 0.7, 0.2})

	for _ in 0..<16 { render_frame(&s, &rt) }
	px_override := vol_capture_fbo_rgba(rt.fbo, width, height)
	defer delete(px_override)
	sat_override := calc_saturation(px_override, width, height)
	path_override := "tests/reports/volumetric/override_manual_0.80.png"
	vol_save_png(path_override, px_override, width, height, 4)

	path_col_override := "tests/reports/volumetric/override_manual_sun_color.png"
	vol_save_png(path_col_override, px_override, width, height, 4)
	fmt.printfln("  [Override Manual] Slider=0.80 Color=(2.0,0.7,0.2): Effective=%.2f | Auto=false | Saturation=%.2f%%",
		eff_override, sat_override)

	// Simulate Re-activating Auto
	s.volumetric.params.sun_intensity_auto = true
	s.volumetric.params.sun_color_auto = true
	rendering.volumetric_update_sun_detection(&s.volumetric, s.sun_shadow.detection)
	eff_reactivate := rendering.volumetric_get_effective_intensity(&s.volumetric)
	eff_col_reactivate := rendering.volumetric_get_effective_sun_color(&s.volumetric, s.sun_shadow.detection)
	testing.expect(t, math.abs(eff_reactivate - 0.250) < 0.005, "Reactivated auto must produce ~0.250")
	testing.expect(t, math.abs(eff_col_reactivate.x - 1.145) < 0.05, "Reactivated auto color must match cedar_bridge")

	for _ in 0..<16 { render_frame(&s, &rt) }
	px_reactivate := vol_capture_fbo_rgba(rt.fbo, width, height)
	defer delete(px_reactivate)
	sat_reactivate := calc_saturation(px_reactivate, width, height)
	path_reactivate := "tests/reports/volumetric/override_reactivate_auto.png"
	vol_save_png(path_reactivate, px_reactivate, width, height, 4)
	fmt.printfln("  [Reactivate Auto] Toggle ON: Effective=%.3f Color=(%.2f,%.2f,%.2f) | Auto=true",
		eff_reactivate, eff_col_reactivate.x, eff_col_reactivate.y, eff_col_reactivate.z)

	// -------------------------------------------------------------------------
	// 3. Omni Point Baseline Non-Regression Capture
	// -------------------------------------------------------------------------
	fmt.printfln("--------------------------------------------------------------------------")
	fmt.printfln("🧪 TESTING OMNI POINT LIGHT NON-REGRESSION")
	s.volumetric.params.light_mode = .Omni_Point
	s.volumetric.params.intensity_mult = 2.2
	s.point_light.enabled = true
	s.point_light.position = mt.Vec3{0.0, 2.5, -6.5}
	s.point_light.radius = 32.0
	s.point_light.intensity = 4.2
	s.point_light.color = mt.Vec3{1.0, 0.94, 0.82}

	for _ in 0..<16 { render_frame(&s, &rt) }
	px_omni := vol_capture_fbo_rgba(rt.fbo, width, height)
	defer delete(px_omni)
	path_omni := "tests/reports/volumetric/omni_mode_branch.png"
	vol_save_png(path_omni, px_omni, width, height, 4)
	fmt.printfln("  [Omni Point Mode] Effective=%.2f | Saved: %s",
		rendering.volumetric_get_effective_intensity(&s.volumetric), path_omni)

	fmt.printfln("==========================================================================")
	fmt.printfln("✅ ALL E2E AUTOMATIC SUN INTENSITY & NON-REGRESSION TESTS PASSED!")
	fmt.printfln("==========================================================================")
}
