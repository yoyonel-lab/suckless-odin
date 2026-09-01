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

	// 2. Offscreen Screen Recording: 60-frame Split-Screen sweep animation
	libc.system("mkdir -p /tmp/shadow_sweep_frames")
	total_frames :: 60
	for f in 0..<total_frames {
		// Ping-pong or smooth sweep from 0.05 to 0.95
		t_norm := f32(f) / f32(total_frames - 1)
		s.point_light.shadow_split_position = 0.05 + 0.90 * (0.5 - 0.5 * math.cos(t_norm * math.PI * 2.0))
		s.point_light.shadow_debug_mode = 4
		s.point_light.shadow_pcf_samples = 16

		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/shadow_sweep_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	// 3. Assemble High-Definition Screen Recording using ffmpeg
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_sweep_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/shadows/shadow_debug_split_sweep.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/shadow_sweep_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/shadows/shadow_debug_split_sweep.mp4 >/dev/null 2>&1")

	// Clean up temporary frame directory
	libc.system("rm -rf /tmp/shadow_sweep_frames")
}
