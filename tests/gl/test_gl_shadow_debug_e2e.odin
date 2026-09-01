// +build test
// E2E Headless GPU Screen Recording & Shadow Debug Verification
// Runs offscreen on local GPU with full hardware acceleration without creating any visible desktop window.
package test_gl

import "core:testing"
import "core:fmt"
import "core:time"
import "core:math"
import "core:c/libc"

import sc "../../src/scene"
import cam "../../src/camera"
import mt "../../src/core/math_types"
import app_pkg "../../src/app"
import sess_pkg "../../src/core/session"
import postfx "../../src/rendering/postfx"
import gl "vendor:OpenGL"

@(test)
test_shadow_debug_offscreen_e2e :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	width: i32 = 800
	height: i32 = 600

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

	// Configure camera framing for clear shadow observation on sphere grid
	s.camera.position = mt.Vec3{0.0, 1.5, 14.0}
	s.camera.yaw = -90.0
	s.camera.pitch = -4.0
	s.camera.yaw_target = -90.0
	s.camera.pitch_target = -4.0
	cam.update_vectors(&s.camera)

	// Wait for async IBL pipeline to stabilize
	for _ in 0..<5000 {
		sc.scene_update(&s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, rt.width, rt.height)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle { break }
		time.sleep(1 * time.Millisecond)
	}

	// Configure point light for crisp casting and penumbra inspection
	s.point_light.position = mt.Vec3{0.0, 2.5, -2.5}
	s.point_light.radius = 22.0
	s.point_light.intensity = 3.2
	s.point_light.color = mt.Vec3{1.0, 0.65, 0.35}
	s.point_light.enabled = true
	s.point_light.direct_shadows_enabled = true
	s.point_light.shadow_bias = 0.0015
	s.point_light.shadow_normal_bias = 0.025
	s.point_light.shadow_slope_bias = 0.0010
	s.point_light.shadow_darkening = 0.85
	s.point_light.shadow_filter_radius = 0.025
	s.point_light.shadow_pcf_jitter = true
	s.point_light.is_animated = false
	s.volumetric.params.enabled = false

	// Helper closure to render and capture FBO
	render_and_capture :: proc(s: ^sc.Scene, rt: ^Render_Target) -> []u8 {
		sc.scene_update(s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(s, rt.width, rt.height)
		gl.Finish()
		return capture_framebuffer(rt)
	}

	// 1. Capture Key Comparative Showcase Images
	libc.system("mkdir -p docs/images/shadows")

	// Frame 1: Hard 1-tap Normal Shading
	s.point_light.shadow_pcf_samples = 1
	s.point_light.shadow_debug_mode = 0
	pix_hard := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/01_normal_hard_1tap.png", pix_hard, width, height)
	delete(pix_hard)

	// Frame 2: Vogel 8-tap Normal Shading
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_debug_mode = 0
	pix_v8 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/02_normal_vogel_8tap.png", pix_v8, width, height)
	delete(pix_v8)

	// Frame 3: Vogel 16-tap Normal Shading
	s.point_light.shadow_pcf_samples = 16
	s.point_light.shadow_debug_mode = 0
	pix_v16 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/03_normal_vogel_16tap.png", pix_v16, width, height)
	delete(pix_v16)

	// Frame 4: Mask Hard 1-tap (Green/Red)
	s.point_light.shadow_pcf_samples = 1
	s.point_light.shadow_debug_mode = 1
	pix_mask_hard := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/04_mask_hard_1tap.png", pix_mask_hard, width, height)
	delete(pix_mask_hard)

	// Frame 5: Mask Vogel 16-tap (Smooth Green/Red gradient)
	s.point_light.shadow_pcf_samples = 16
	s.point_light.shadow_debug_mode = 1
	pix_mask_v16 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/05_mask_vogel_16tap.png", pix_mask_v16, width, height)
	delete(pix_mask_v16)

	// Frame 6: Penumbra / Softness Heatmap (Yellow = Transition)
	s.point_light.shadow_pcf_samples = 16
	s.point_light.shadow_debug_mode = 2
	pix_penumbra := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/06_penumbra_heatmap.png", pix_penumbra, width, height)
	delete(pix_penumbra)

	// Frame 7: Delta vs Hard Heatmap (|PCF - Hard|)
	s.point_light.shadow_pcf_samples = 16
	s.point_light.shadow_debug_mode = 3
	pix_delta := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/07_delta_vs_hard_heatmap.png", pix_delta, width, height)

	// Verify Delta Heatmap has non-zero diff pixels (validates mathematical correction)
	has_diff := false
	for i := 0; i < int(width * height * CHANNELS); i += 4 {
		if pix_delta[i] > 10 || pix_delta[i+1] > 10 || pix_delta[i+2] > 10 {
			has_diff = true
			break
		}
	}
	testing.expect(t, has_diff, "Delta Heatmap should contain active difference pixels between Hard and Vogel 16-tap")
	delete(pix_delta)

	// Frame 8: Split-Screen Comparison (Left=Hard 1-tap, Right=Vogel 16-tap)
	s.point_light.shadow_pcf_samples = 16
	s.point_light.shadow_debug_mode = 4
	s.point_light.shadow_split_position = 0.5
	pix_split := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/08_split_screen_50_50.png", pix_split, width, height)
	delete(pix_split)

	// Frame 9: Temporal Jitter Phase Distribution Heatmap
	s.point_light.shadow_debug_mode = 5
	s.point_light.shadow_temporal_jitter = true
	pix_phase := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/09_temporal_jitter_heatmap.png", pix_phase, width, height)
	delete(pix_phase)

	// Frame 10: TAA Denoised Smooth Normal Shading
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_debug_mode = 0
	s.point_light.shadow_temporal_jitter = true
	s.point_light.shadow_taa_enabled = true
	// Warm up TAA history over 10 frames
	for _ in 0..<10 {
		pix_warm := render_and_capture(&s, &rt)
		delete(pix_warm)
	}
	pix_taa_smooth := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/10_taa_denoised_smooth.png", pix_taa_smooth, width, height)
	delete(pix_taa_smooth)

	// Step-by-Step Multi-Frame Temporal Amortissement / Convergence Series
	s.point_light.is_animated = false
	s.point_light.position = mt.Vec3{0.0, 2.5, -2.5}
	s.point_light.shadow_debug_mode = 0
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_temporal_jitter = true
	s.point_light.shadow_taa_enabled = true
	s.point_light.shadow_taa_alpha = 0.15

	// Reset TAA history to start convergence cycle from Frame 1
	s.shadow_taa.history_valid = false

	// Frame 1: Initial stochastic sample (Raw IGN noise pattern)
	pix_f01 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/11_temporal_damping_frame_01.png", pix_f01, width, height)
	delete(pix_f01)

	// Frames 2..3
	for _ in 0..<2 {
		p := render_and_capture(&s, &rt)
		delete(p)
	}
	// Frame 4: 50% temporal damping
	pix_f04 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/12_temporal_damping_frame_04.png", pix_f04, width, height)
	delete(pix_f04)

	// Frames 5..7
	for _ in 0..<3 {
		p := render_and_capture(&s, &rt)
		delete(p)
	}
	// Frame 8: 85% temporal damping
	pix_f08 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/13_temporal_damping_frame_08.png", pix_f08, width, height)
	delete(pix_f08)

	// Frames 9..15
	for _ in 0..<7 {
		p := render_and_capture(&s, &rt)
		delete(p)
	}
	// Frame 16: Fully converged, noise-free penumbra
	pix_f16 := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/14_temporal_damping_frame_16.png", pix_f16, width, height)
	delete(pix_f16)

	// Frame 15: Split-Screen Comparison (Left=Hard 1-tap Off, Right=Converged Shadow TAA)
	s.point_light.shadow_debug_mode = 4
	s.point_light.shadow_split_position = 0.5
	pix_split_hard_taa := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/15_split_hard_vs_taa_converged.png", pix_split_hard_taa, width, height)
	delete(pix_split_hard_taa)

	// Frame 16: Delta vs Hard Heatmap with TAA Converged (|TAA - Hard|)
	s.point_light.shadow_debug_mode = 3
	pix_delta_taa := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/16_delta_taa_vs_hard_heatmap.png", pix_delta_taa, width, height)
	delete(pix_delta_taa)

	// Frame 17: Penumbra / Softness Heatmap with TAA Converged
	s.point_light.shadow_debug_mode = 2
	pix_penumbra_taa := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/17_penumbra_taa_heatmap.png", pix_penumbra_taa, width, height)
	delete(pix_penumbra_taa)

	// Frame 18: Shadow Mask with TAA Converged (Smooth Green/Red)
	s.point_light.shadow_debug_mode = 1
	pix_mask_taa := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/18_mask_taa_converged.png", pix_mask_taa, width, height)
	delete(pix_mask_taa)

	// Frame 19: Only Shadow Factor (Pure Grayscale White=Lit, Black=Shadow)
	s.point_light.shadow_debug_mode = 6
	s.point_light.shadow_pcf_samples = 16
	pix_only_shadow := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/19_only_shadow_grayscale.png", pix_only_shadow, width, height)
	delete(pix_only_shadow)

	// 2. Offscreen Screen Recording 1: 60-frame Split-Screen PCF sweep animation
	libc.system("mkdir -p /tmp/shadow_sweep_frames")
	total_frames :: 60
	for f in 0..<total_frames {
		t_norm := f32(f) / f32(total_frames - 1)
		s.point_light.shadow_split_position = 0.05 + 0.90 * (0.5 - 0.5 * math.cos(t_norm * math.PI * 2.0))
		s.point_light.shadow_debug_mode = 4
		s.point_light.shadow_pcf_samples = 16
		s.point_light.shadow_temporal_jitter = false

		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/shadow_sweep_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_sweep_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/shadow_debug_split_sweep.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_sweep_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/shadow_debug_split_sweep.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/shadow_sweep_frames")

	// 3. Offscreen Screen Recording 2: 60-frame Temporal Convergence & Damping Evolution Loop
	libc.system("mkdir -p /tmp/shadow_conv_frames")
	s.point_light.shadow_debug_mode = 0
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_temporal_jitter = true
	s.point_light.shadow_taa_enabled = true
	s.point_light.is_animated = false

	for f in 0..<total_frames {
		// Reset every 30 frames to show repeated damping cycle
		if f % 30 == 0 {
			s.shadow_taa.history_valid = false
		}
		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/shadow_conv_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_conv_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/shadow_taa_temporal_convergence.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_conv_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/shadow_taa_temporal_convergence.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/shadow_conv_frames")

	// 4. Offscreen Screen Recording 3: 60-frame Split Sweep comparing Hard 1-Tap (Off) vs Converged TAA
	libc.system("mkdir -p /tmp/shadow_hard_taa_frames")
	s.point_light.shadow_debug_mode = 4
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_temporal_jitter = true
	s.point_light.shadow_taa_enabled = true
	s.point_light.is_animated = false

	// Warm up history
	for _ in 0..<16 {
		p := render_and_capture(&s, &rt)
		delete(p)
	}

	for f in 0..<total_frames {
		t_norm := f32(f) / f32(total_frames - 1)
		s.point_light.shadow_split_position = 0.05 + 0.90 * (0.5 - 0.5 * math.cos(t_norm * math.PI * 2.0))

		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/shadow_hard_taa_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_hard_taa_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/shadow_hard_vs_taa_split_sweep.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_hard_taa_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/shadow_hard_vs_taa_split_sweep.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/shadow_hard_taa_frames")

	// 5. Offscreen Screen Recording 4: 60-frame Dynamic Orbiting Light with Shadow TAA
	libc.system("mkdir -p /tmp/shadow_taa_frames")
	s.point_light.is_animated = true
	s.point_light.orbit_speed = 0.8
	s.point_light.orbit_radius = 4.0
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_debug_mode = 0
	s.point_light.shadow_temporal_jitter = true
	s.point_light.shadow_taa_enabled = true

	for f in 0..<total_frames {
		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/shadow_taa_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_taa_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/shadow_taa_denoising_sweep.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_taa_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/shadow_taa_denoising_sweep.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/shadow_taa_frames")

	// 6. Diagnostic: Exact User Scene Framing (Camera Z=20, 10x10 grid)
	// Compare: (A) Edge AA On vs Off (Golden Rim), (B) Temporal Jitter vs Static PCF 8/16 (Flicker)
	s.camera.position = mt.Vec3{0.0, 0.0, 20.0}
	s.camera.yaw = -90.0
	s.camera.pitch = 0.0
	s.camera.zoom = 60.0
	cam.update_vectors(&s.camera)

	s.point_light.position = mt.Vec3{0.0, 2.0, -3.0}
	s.point_light.radius = 22.0
	s.point_light.color = mt.Vec3{1.0, 0.50, 0.25}
	s.point_light.intensity = 2.8
	s.point_light.enabled = true
	s.point_light.direct_shadows_enabled = true
	s.point_light.shadow_bias = 0.0020
	s.point_light.shadow_normal_bias = 0.0030
	s.point_light.shadow_slope_bias = 0.0010
	s.point_light.shadow_filter_radius = 0.020
	s.point_light.shadow_pcf_samples = 8
	s.point_light.shadow_pcf_jitter = true
	s.point_light.is_animated = true
	s.point_light.orbit_speed = 0.25
	s.point_light.orbit_radius = 5.0
	s.point_light.orbit_center = mt.Vec3{0.0, 2.0, -3.0}
	s.point_light.show_bulb = true
	s.point_light.bulb_radius = 0.45

	// Capture (A): Edge AA ON (Reproduces golden rim) vs Edge AA OFF (Clean edge)
	s.edge_aa_enabled = true
	pix_halo_on := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/diagnostic_halo_edge_aa_on.png", pix_halo_on, width, height)
	delete(pix_halo_on)

	s.edge_aa_enabled = false
	pix_halo_off := render_and_capture(&s, &rt)
	save_png("docs/images/shadows/diagnostic_halo_edge_aa_off.png", pix_halo_off, width, height)
	delete(pix_halo_off)

	// Record 60-frame video of Clean Stable Vogel 16-tap (Edge AA OFF, Temporal Jitter OFF, Spatial Jitter ON)
	libc.system("mkdir -p /tmp/diag_clean_pcf_frames")
	s.edge_aa_enabled = false
	s.point_light.shadow_temporal_jitter = false
	s.point_light.shadow_pcf_jitter = true
	s.point_light.shadow_pcf_samples = 16
	for f in 0..<total_frames {
		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/diag_clean_pcf_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}
	libc.system("ffmpeg -y -framerate 30 -i /tmp/diag_clean_pcf_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/diagnostic_clean_pcf16_spatial_jitter.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/diag_clean_pcf_frames")

	// Record 60-frame video of Pure Geometric Vogel 16-tap (Zero Jitter, Zero Noise, Pure Smooth Penumbra)
	libc.system("mkdir -p /tmp/diag_nojitter_pcf_frames")
	s.point_light.shadow_pcf_jitter = false
	s.point_light.shadow_pcf_samples = 16
	for f in 0..<total_frames {
		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/diag_nojitter_pcf_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}
	libc.system("ffmpeg -y -framerate 30 -i /tmp/diag_nojitter_pcf_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/diagnostic_clean_pcf16_nojitter.mp4 >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/diag_nojitter_pcf_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/diagnostic_clean_pcf16_nojitter.gif >/dev/null 2>&1")
	libc.system("rm -rf /tmp/diag_nojitter_pcf_frames")
}

@(test)
test_exact_session_json_offscreen_verification :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	width: i32 = 800
	height: i32 = 600

	rt, rt_ok := render_target_create(width, height)
	if !rt_ok {
		testing.expect(t, false, "Failed to create offscreen render target FBO")
		return
	}
	defer render_target_destroy(&rt)

	app: app_pkg.App
	app.width = width
	app.height = height

	if !sc.scene_create(&app.scene, width, height) {
		testing.expect(t, false, "Failed to create scene")
		return
	}
	defer sc.scene_destroy(&app.scene)

	// Load session.json exactly as the application does at startup
	sess_state: sess_pkg.Session_State
	has_session := sess_pkg.load_session(&sess_state, "session.json")
	testing.expect(t, has_session, "Failed to load session.json")

	// Restore session state into app.scene
	app_pkg.restore_session_state(&app, sess_state)
	sess_pkg.session_free(&sess_state)

	// Wait for async IBL pipeline to stabilize
	for _ in 0..<5000 {
		sc.scene_update(&app.scene, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&app.scene, rt.width, rt.height)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		if !app.scene.env_mgr.is_first_load && app.scene.env_mgr.transition_state == .Idle && app.scene.env_mgr.ibl_state == .Idle { break }
		time.sleep(1 * time.Millisecond)
	}

	// Set EXACT camera from user screenshot: Pos=(5.66, -1.18, -8.06), Yaw=230.7, Pitch=-15.9
	app.scene.camera.position = mt.Vec3{5.66, -1.18, -8.06}
	app.scene.camera.yaw = 230.7
	app.scene.camera.pitch = -15.9
	cam.update_vectors(&app.scene.camera)
	app.scene.point_light.shadow_debug_mode = 6

	// Test A: PostFX Enabled with 0 active effects
	app.scene.postfx_pipeline.enabled = true
	app.scene.postfx_pipeline.active_effects = {}
	app.scene.postfx_pipeline.ubo_dirty = true
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&app.scene, rt.width, rt.height)
	gl.Finish()
	pix_postfx_on := capture_framebuffer(&rt)
	save_png("docs/images/shadows/diag_user_view_postfx_ON_0effects.png", pix_postfx_on, width, height)
	delete(pix_postfx_on)

	// Test B: PostFX Disabled completely
	app.scene.postfx_pipeline.enabled = false
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&app.scene, rt.width, rt.height)
	gl.Finish()
	pix_postfx_off := capture_framebuffer(&rt)
	save_png("docs/images/shadows/diag_user_view_postfx_OFF.png", pix_postfx_off, width, height)
	delete(pix_postfx_off)
	app.scene.postfx_pipeline.enabled = true

	// Test each PostFX effect in isolation
	effects_list := [?]postfx.Post_Effect{
		.Vignette, .Grain, .Exposure, .Chrom_Abbr, .Bloom, .Color_Grading,
		.Dof, .Auto_Exposure, .Motion_Blur, .FXAA, .Tonemap, .Banding, .Fog, .LUT3D,
	}

	for eff in effects_list {
		app.scene.postfx_pipeline.enabled = true
		app.scene.postfx_pipeline.active_effects = {eff}
		app.scene.postfx_pipeline.ubo_dirty = true
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&app.scene, rt.width, rt.height)
		gl.Finish()
		pix_eff := capture_framebuffer(&rt)
		filename := fmt.tprintf("docs/images/shadows/diag_effect_%v.png", eff)
		save_png(filename, pix_eff, width, height)
		delete(pix_eff)
	}
	app.scene.point_light.position = mt.Vec3{0.0, 2.0, 4.0}
	app.scene.point_light.orbit_center = mt.Vec3{0.0, 2.0, 4.0}
	app.scene.point_light.is_animated = false
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&app.scene, rt.width, rt.height)
	gl.Finish()
	pix_front := capture_framebuffer(&rt)
	save_png("docs/images/shadows/diag_light_front_z_plus4.png", pix_front, width, height)
	delete(pix_front)

	// Diagnostic 6: Point Light DISABLED (Pure Ambient IBL skybox)
	app.scene.point_light.enabled = false
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&app.scene, rt.width, rt.height)
	gl.Finish()
	pix_nolight := capture_framebuffer(&rt)
	save_png("docs/images/shadows/diag_light_disabled.png", pix_nolight, width, height)
	delete(pix_nolight)

	// Diagnostic 7: Black background (Skybox hidden, showing pure spheres)
	app.scene.skybox_visible = false
	app.scene.point_light.enabled = true
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&app.scene, rt.width, rt.height)
	gl.Finish()
	pix_nosky := capture_framebuffer(&rt)
	save_png("docs/images/shadows/diag_nosky_black_bg.png", pix_nosky, width, height)
	delete(pix_nosky)
}
