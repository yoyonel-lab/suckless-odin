// +build test
// E2E Headless GPU Screen Recording & AO Camera Motion Stability Verification
package test_gl

import "core:testing"
import "core:fmt"
import "core:time"
import "core:math"
import "core:c/libc"
import "core:os"

import sc "../../src/scene"
import cam "../../src/camera"
import mt "../../src/core/math_types"
import rendering "../../src/rendering"
import gl "vendor:OpenGL"

@(test)
test_ao_camera_sweep_recording :: proc(t: ^testing.T) {
	RECORD_AO_SWEEP :: #config(RECORD_AO_SWEEP, false)
	when !RECORD_AO_SWEEP {
		return
	}

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

	// Ensure Baked AO is enabled and radix sort active
	s.use_baked_ao = true
	s.sort_mode = .Radix
	s.postfx_pipeline.enabled = false
	s.volumetric.params.enabled = false

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

	render_and_capture :: proc(s: ^sc.Scene, rt: ^Render_Target) -> []u8 {
		sc.scene_update(s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(s, rt.width, rt.height)
		gl.Finish()

		pixels := make([]u8, rt.width * rt.height * 4, context.temp_allocator)
		gl.ReadPixels(0, 0, rt.width, rt.height, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		// Flip vertically
		flipped := make([]u8, rt.width * rt.height * 4)
		stride := int(rt.width * 4)
		for y in 0..<int(rt.height) {
			src_y := int(rt.height) - 1 - y
			copy(flipped[y * stride : (y + 1) * stride], pixels[src_y * stride : (src_y + 1) * stride])
		}
		return flipped
	}

	os.make_directory("docs/images")
	libc.system("mkdir -p /tmp/ao_motion_frames")

	total_frames :: 60
	for f in 0..<total_frames {
		t_norm := f32(f) / f32(total_frames)
		angle := t_norm * math.PI * 2.0
		radius: f32 = 16.0 + 4.0 * math.sin(angle * 2.0)

		cam_x := math.sin(angle) * radius
		cam_z := math.cos(angle) * radius
		cam_y := 2.5 + 3.0 * math.sin(angle)

		s.camera.position = mt.Vec3{cam_x, cam_y, cam_z}
		s.camera.yaw = -90.0 - (t_norm * 360.0)
		s.camera.pitch = -math.atan2(cam_y, radius) * (180.0 / math.PI)
		s.camera.yaw_target = s.camera.yaw
		s.camera.pitch_target = s.camera.pitch
		cam.update_vectors(&s.camera)

		frame_pix := render_and_capture(&s, &rt)
		frame_filename := fmt.tprintf("/tmp/ao_motion_frames/frame_%03d.png", f)
		save_png(frame_filename, frame_pix, width, height)
		delete(frame_pix)
	}

	libc.system("ffmpeg -y -framerate 30 -i /tmp/ao_motion_frames/frame_%03d.png -vf \"split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3\" docs/images/ao_camera_sweep.gif >/dev/null 2>&1")
	libc.system("ffmpeg -y -framerate 30 -i /tmp/ao_motion_frames/frame_%03d.png -c:v libx264 -pix_fmt yuv420p docs/images/ao_camera_sweep.mp4 >/dev/null 2>&1")
	libc.system("rm -rf /tmp/ao_motion_frames")

	testing.expect(t, os.exists("docs/images/ao_camera_sweep.mp4"), "Generated AO camera sweep MP4 should exist")
}
