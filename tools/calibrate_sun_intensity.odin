package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import mt "../src/core/math_types"
import sc "../src/scene"
import cam "../src/camera"

save_png :: proc(path: string, pixels: []u8, w, h, channels: i32) -> bool {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	stride := w * channels
	result := stbi.write_png(c_path, c.int(w), c.int(h), c.int(channels), raw_data(pixels), c.int(stride))
	return result != 0
}

flip_vertical :: proc(pixels: []u8, w, h, channels: i32) -> []u8 {
	flipped := make([]u8, int(w * h * channels))
	stride := int(w * channels)
	for y in 0 ..< int(h) {
		src_y := int(h) - 1 - y
		copy(flipped[y * stride : (y + 1) * stride], pixels[src_y * stride : (src_y + 1) * stride])
	}
	return flipped
}

capture_fbo_rgba :: proc(fbo: u32, w, h: i32) -> []u8 {
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	raw_pixels := make([]u8, int(w * h * 4))
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(raw_pixels))
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	flipped := flip_vertical(raw_pixels, w, h, 4)
	delete(raw_pixels)
	return flipped
}

main :: proc() {
	if !glfw.Init() {
		fmt.eprintln("Failed to init GLFW")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)

	width: i32 = 960
	height: i32 = 540

	window := glfw.CreateWindow(width, height, "Sun Godrays Calibrator", nil, nil)
	if window == nil {
		fmt.eprintln("Failed to create offscreen window")
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)

	rt_fbo: u32
	rt_color_tex: u32
	rt_depth_rbo: u32
	gl.GenFramebuffers(1, &rt_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt_fbo)

	gl.GenTextures(1, &rt_color_tex)
	gl.BindTexture(gl.TEXTURE_2D, rt_color_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, rt_color_tex, 0)

	gl.GenRenderbuffers(1, &rt_depth_rbo)
	gl.BindRenderbuffer(gl.RENDERBUFFER, rt_depth_rbo)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, width, height)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, rt_depth_rbo)

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		fmt.eprintln("Failed to create complete RT FBO")
		return
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	defer {
		gl.DeleteFramebuffers(1, &rt_fbo)
		gl.DeleteTextures(1, &rt_color_tex)
		gl.DeleteRenderbuffers(1, &rt_depth_rbo)
	}

	s: sc.Scene
	if !sc.scene_create(&s, width, height) {
		fmt.eprintln("Failed to create scene")
		return
	}
	defer sc.scene_destroy(&s)

	os.make_directory("tests/reports/volumetric/calibration")

	s.camera.position = mt.Vec3{0.0, 1.0, 16.0}
	s.camera.yaw = -90.0
	s.camera.pitch = -3.0
	s.camera.yaw_target = -90.0
	s.camera.pitch_target = -3.0
	cam.update_vectors(&s.camera)

	render_frame :: proc(s: ^sc.Scene, fbo: u32, w, h: i32) {
		sc.scene_update(s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
		gl.Viewport(0, 0, w, h)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(s, w, h)
		gl.Finish()
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	}

	wait_ibl_converged :: proc(s: ^sc.Scene, fbo: u32, w, h: i32) {
		for iter in 0..<5000 {
			render_frame(s, fbo, w, h)
			if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
				break
			}
			time.sleep(2 * time.Millisecond)
		}
		for _ in 0..<20 {
			render_frame(s, fbo, w, h)
		}
	}

	wait_ibl_converged(&s, rt_fbo, width, height)

	env_tests := [?]struct {
		name: string,
		path: string,
	}{
		{"cedar_bridge", "assets/textures/hdr/cedar_bridge_2_4k.hdr"},
		{"small_cathedral", "assets/textures/hdr/small_cathedral_02_4k.hdr"},
	}

	levels := [5]f32{1.0, 0.5, 0.25, 0.10, 0.05}

	fmt.println("=========================================================================================")
	fmt.println("📊 ÉCHELLE DE CALIBRAGE D'INTENSITÉ VOLUMÉTRIQUE (SUN DIRECTIONAL)")
	fmt.println("=========================================================================================")
	fmt.printf("%-16s | %-14s | %-12s | %-18s | %-16s | %s\n",
		"Envmap", "intensity_mult", "God Rays RMS", "Max Pixel (R,G,B)", "Pixels Sat (>=250)", "Capture")
	fmt.println("-----------------------------------------------------------------------------------------")

	for env in env_tests {
		sc.env_manager_trigger_transition(&s.env_mgr, env.path)
		wait_ibl_converged(&s, rt_fbo, width, height)

		// Base Sun settings
		s.volumetric.params.enabled = true
		s.volumetric.params.light_mode = .Sun_Directional
		s.volumetric.params.shadows_enabled = true
		s.volumetric.params.step_count = 20
		s.volumetric.params.scattering_coeff = 0.04
		s.volumetric.params.extinction_coeff = 0.06
		s.volumetric.params.anisotropy_g = 0.62
		s.volumetric.params.sun_intensity = 1.8
		s.volumetric.params.jitter_enabled = true
		s.volumetric.params.taa_mode = 2
		s.volumetric.params.taa_alpha = 0.20
		s.volumetric.params.blur_mode = 2
		s.volumetric.params.upsample_mode = 2
		s.volumetric.params.resolution_divider = 2
		s.point_light.enabled = false

		for level in levels {
			s.volumetric.params.intensity_mult = level

			// 25 frames convergence
			for _ in 0..<25 {
				render_frame(&s, rt_fbo, width, height)
			}

			// 1. Composite frame
			comp_pixels := capture_fbo_rgba(rt_fbo, width, height)
			level_str := fmt.tprintf("%.2f", level)
			comp_path := fmt.tprintf("tests/reports/volumetric/calibration/comp_%s_%s.png", env.name, level_str)
			save_png(comp_path, comp_pixels, width, height, 4)

			// Saturation stats on composite
			total_pixels := int(width * height)
			sat_count := 0
			max_r: u8 = 0
			max_g: u8 = 0
			max_b: u8 = 0

			for i in 0 ..< total_pixels {
				idx := i * 4
				r := comp_pixels[idx + 0]
				g := comp_pixels[idx + 1]
				b := comp_pixels[idx + 2]
				if r > max_r { max_r = r }
				if g > max_g { max_g = g }
				if b > max_b { max_b = b }
				if r >= 250 && g >= 250 && b >= 250 {
					sat_count += 1
				}
			}
			delete(comp_pixels)

			// 2. Isolated volumetric frame for RMS
			s.volumetric.params.isolate_in_scene = true
			render_frame(&s, rt_fbo, width, height)
			iso_pixels := capture_fbo_rgba(rt_fbo, width, height)
			s.volumetric.params.isolate_in_scene = false

			iso_path := fmt.tprintf("tests/reports/volumetric/calibration/iso_%s_%s.png", env.name, level_str)
			save_png(iso_path, iso_pixels, width, height, 4)

			// RMS on isolated ROI [y: 150..390, x: 250..710]
			var_sum: f64 = 0.0
			mean_sum: f64 = 0.0
			roi_count: int = 0
			for y in 150 ..< 390 {
				for x in 250 ..< 710 {
					idx := (y * int(width) + x) * 4
					lum := 0.299 * f64(iso_pixels[idx + 0]) + 0.587 * f64(iso_pixels[idx + 1]) + 0.114 * f64(iso_pixels[idx + 2])
					mean_sum += lum
					roi_count += 1
				}
			}
			mean_lum := mean_sum / f64(roi_count)
			for y in 150 ..< 390 {
				for x in 250 ..< 710 {
					idx := (y * int(width) + x) * 4
					lum := 0.299 * f64(iso_pixels[idx + 0]) + 0.587 * f64(iso_pixels[idx + 1]) + 0.114 * f64(iso_pixels[idx + 2])
					diff_sq := (lum - mean_lum) * (lum - mean_lum)
					var_sum += diff_sq
				}
			}
			rms_contrast := math.sqrt(var_sum / f64(roi_count))
			delete(iso_pixels)

			max_str := fmt.tprintf("(%3d,%3d,%3d)", max_r, max_g, max_b)
			sat_pct := (f32(sat_count) / f32(total_pixels)) * 100.0
			sat_str := fmt.tprintf("%6d (%.2f%%)", sat_count, sat_pct)
			fmt.printf("%-16s | %14.2f | %12.2f | %-18s | %-16s | %s\n",
				env.name, level, rms_contrast, max_str, sat_str, comp_path)
		}
		fmt.println("-----------------------------------------------------------------------------------------")
	}
}
