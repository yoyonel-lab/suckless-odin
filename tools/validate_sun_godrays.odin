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
import rendering "../src/rendering"
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

	window := glfw.CreateWindow(width, height, "Sun Godrays Validator", nil, nil)
	if window == nil {
		fmt.eprintln("Failed to create offscreen window")
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)

	// Create offscreen render target FBO
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

	os.make_directory("tests/reports/volumetric/envmaps")

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

	// Wait initial environment load
	wait_ibl_converged(&s, rt_fbo, width, height)

	env_tests := [?]struct {
		name:        string,
		path:        string,
		is_fallback: bool,
	}{
		{"cedar_bridge", "assets/textures/hdr/cedar_bridge_2_4k.hdr", false},
		{"river_alcove", "assets/textures/hdr/river_alcove_4k.hdr", false},
		{"neon_photostudio", "assets/textures/hdr/neon_photostudio_4k.hdr", true},
		{"abandoned_garage", "assets/textures/hdr/abandoned_garage_4k.hdr", true},
		{"small_cathedral", "assets/textures/hdr/small_cathedral_02_4k.hdr", true},
	}

	fmt.println("=========================================================================================")
	fmt.println("🌌 VALIDATION GOD RAYS PAR ENVMAP (Direction du soleil & shafts)")
	fmt.println("=========================================================================================")
	fmt.printf("%-18s | %-10s | %-10s | %-10s | %-10s | %s\n",
		"Environment Map", "Type", "Azimuth", "Elevation", "Confidence", "Faisceaux (Shafts)")
	fmt.println("-----------------------------------------------------------------------------------------")

	for env in env_tests {
		sc.env_manager_trigger_transition(&s.env_mgr, env.path)
		wait_ibl_converged(&s, rt_fbo, width, height)

		det := s.sun_shadow.detection

		// Configure Sun Directional Volumetric
		s.volumetric.params.enabled = true
		s.volumetric.params.light_mode = .Sun_Directional
		s.volumetric.params.shadows_enabled = true
		s.volumetric.params.step_count = 20
		s.volumetric.params.scattering_coeff = 0.04
		s.volumetric.params.extinction_coeff = 0.06
		s.volumetric.params.anisotropy_g = 0.62
		s.volumetric.params.sun_intensity = 1.8
		s.volumetric.params.intensity_mult = rendering.volumetric_get_default_intensity(.Sun_Directional)
		s.volumetric.params.jitter_enabled = true
		s.volumetric.params.taa_mode = 2
		s.volumetric.params.taa_alpha = 0.20
		s.volumetric.params.blur_mode = 2
		s.volumetric.params.upsample_mode = 2
		s.volumetric.params.resolution_divider = 2
		s.point_light.enabled = false

		// 20 frames to accumulate stable TAA
		for _ in 0..<20 {
			render_frame(&s, rt_fbo, width, height)
		}

		// 1. Capture Composite Scene with God Rays
		pixels_comp := capture_fbo_rgba(rt_fbo, width, height)
		path_comp := fmt.tprintf("tests/reports/volumetric/envmaps/godrays_%s.png", env.name)
		save_png(path_comp, pixels_comp, width, height, 4)
		delete(pixels_comp)

		// 2. Capture Pure Isolated God Rays on Black
		s.volumetric.params.isolate_in_scene = true
		render_frame(&s, rt_fbo, width, height)
		pixels_iso := capture_fbo_rgba(rt_fbo, width, height)
		path_iso := fmt.tprintf("tests/reports/volumetric/envmaps/isolated_%s.png", env.name)
		save_png(path_iso, pixels_iso, width, height, 4)
		delete(pixels_iso)
		s.volumetric.params.isolate_in_scene = false

		type_str := "SUN DETECT" if det.sun_detected else "FALLBACK"
		shaft_desc := fmt.tprintf("Provient Az=%.1f° El=%.1f°", det.azimuth, det.elevation)
		fmt.printf("%-18s | %-10s | %8.1f°  | %8.1f°  | %8d px | %s\n",
			env.name, type_str, det.azimuth, det.elevation, det.confidence, shaft_desc)
	}

	fmt.println("=========================================================================================")
	fmt.println("⏱️ BENCHMARK COMPARATIF OMNI POINT vs SUN DIRECTIONAL (300 frames, 2 runs)")
	fmt.println("=========================================================================================")

	// Switch back to cedar_bridge for benchmarking
	sc.env_manager_trigger_transition(&s.env_mgr, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	wait_ibl_converged(&s, rt_fbo, width, height)

	Benchmark_Result :: struct {
		raymarch_ms: f32,
		total_vol_ms: f32,
		frametime_ms: f32,
		fps: f32,
	}

	run_benchmark :: proc(s: ^sc.Scene, fbo: u32, w, h: i32, is_sun: bool, frames: int) -> Benchmark_Result {
		s.volumetric.params.enabled = true
		s.volumetric.params.step_count = 20
		s.volumetric.params.scattering_coeff = 0.04
		s.volumetric.params.extinction_coeff = 0.06
		s.volumetric.params.anisotropy_g = 0.62
		s.volumetric.params.taa_mode = 2
		s.volumetric.params.taa_alpha = 0.20
		s.volumetric.params.blur_mode = 2
		s.volumetric.params.upsample_mode = 2
		s.volumetric.params.resolution_divider = 2

		if is_sun {
			s.volumetric.params.light_mode = .Sun_Directional
			s.volumetric.params.sun_intensity = 1.8
			s.volumetric.params.intensity_mult = rendering.volumetric_get_default_intensity(.Sun_Directional)
			s.point_light.enabled = false
		} else {
			s.volumetric.params.light_mode = .Omni_Point
			s.volumetric.params.intensity_mult = 2.2
			s.point_light.enabled = true
			s.point_light.position = mt.Vec3{0.0, 2.5, -6.5}
			s.point_light.radius = 32.0
			s.point_light.intensity = 4.2
			s.point_light.is_animated = true
			s.point_light.orbit_center = mt.Vec3{0.0, 2.5, -6.5}
			s.point_light.orbit_radius = 2.0
			s.point_light.orbit_speed = 1.0
		}

		// Warmup 30 frames
		for _ in 0..<30 {
			render_frame(s, fbo, w, h)
		}

		start_tick := time.tick_now()
		for _ in 0..<frames {
			render_frame(s, fbo, w, h)
		}
		gl.Finish()
		elapsed := time.tick_since(start_tick)

		total_sec := f32(time.duration_seconds(elapsed))
		avg_frametime := (total_sec / f32(frames)) * 1000.0
		avg_fps := f32(frames) / total_sec

		rm_avg, _, _ := rendering.volumetric_timer_get_metrics(&s.volumetric.timers, .Raymarching)
		vol_total, _, _ := rendering.volumetric_timer_get_total_metrics(&s.volumetric.timers)

		return Benchmark_Result{
			raymarch_ms  = rm_avg,
			total_vol_ms = vol_total,
			frametime_ms = avg_frametime,
			fps          = avg_fps,
		}
	}

	FRAMES :: 300
	fmt.println("Running Omni Point Run 1...")
	omni_r1 := run_benchmark(&s, rt_fbo, width, height, false, FRAMES)
	fmt.println("Running Omni Point Run 2...")
	omni_r2 := run_benchmark(&s, rt_fbo, width, height, false, FRAMES)

	fmt.println("Running Sun Directional Run 1...")
	sun_r1 := run_benchmark(&s, rt_fbo, width, height, true, FRAMES)
	fmt.println("Running Sun Directional Run 2...")
	sun_r2 := run_benchmark(&s, rt_fbo, width, height, true, FRAMES)

	omni_rm_avg := (omni_r1.raymarch_ms + omni_r2.raymarch_ms) * 0.5
	omni_vol_avg := (omni_r1.total_vol_ms + omni_r2.total_vol_ms) * 0.5
	omni_ft_avg := (omni_r1.frametime_ms + omni_r2.frametime_ms) * 0.5
	omni_fps_avg := (omni_r1.fps + omni_r2.fps) * 0.5

	sun_rm_avg := (sun_r1.raymarch_ms + sun_r2.raymarch_ms) * 0.5
	sun_vol_avg := (sun_r1.total_vol_ms + sun_r2.total_vol_ms) * 0.5
	sun_ft_avg := (sun_r1.frametime_ms + sun_r2.frametime_ms) * 0.5
	sun_fps_avg := (sun_r1.fps + sun_r2.fps) * 0.5

	diff_rm := sun_rm_avg - omni_rm_avg
	diff_vol := sun_vol_avg - omni_vol_avg
	diff_ft := sun_ft_avg - omni_ft_avg

	fmt.println("-----------------------------------------------------------------------------------------")
	fmt.printf("%-20s | %-12s | %-12s | %-12s | %-10s\n", "Mode d'Éclairage", "Raymarch GPU", "Total Vol GPU", "Frametime", "FPS")
	fmt.println("-----------------------------------------------------------------------------------------")
	fmt.printf("%-20s | %8.3f ms   | %8.3f ms   | %8.2f ms   | %6.1f fps (Run 1: %.3f / %.2fms, Run 2: %.3f / %.2fms)\n",
		"Omni Point (Legacy)", omni_rm_avg, omni_vol_avg, omni_ft_avg, omni_fps_avg,
		omni_r1.raymarch_ms, omni_r1.frametime_ms, omni_r2.raymarch_ms, omni_r2.frametime_ms)
	fmt.printf("%-20s | %8.3f ms   | %8.3f ms   | %8.2f ms   | %6.1f fps (Run 1: %.3f / %.2fms, Run 2: %.3f / %.2fms)\n",
		"Sun Directional", sun_rm_avg, sun_vol_avg, sun_ft_avg, sun_fps_avg,
		sun_r1.raymarch_ms, sun_r1.frametime_ms, sun_r2.raymarch_ms, sun_r2.frametime_ms)
	fmt.println("-----------------------------------------------------------------------------------------")
	fmt.printf("Écart de coût (Sun vs Omni) : Raymarch: %+6.3f ms  |  Total Vol: %+6.3f ms  |  Frametime: %+6.2f ms\n",
		diff_rm, diff_vol, diff_ft)
	fmt.println("Explication honnête : Le mode Sun Directional raymarche 100% de l'écran jusqu'à la géométrie/horizon (plein écran),")
	fmt.println("contrairement au mode Omni Point qui s'élague analytiquement via l'intersection rayon-sphère de la source.")
	fmt.println("=========================================================================================")
}
