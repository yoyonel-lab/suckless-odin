package main

import "core:fmt"
import "core:os"
import "core:c"
import "core:strings"
import "core:time"

import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import imgui "../../deps/odin-imgui"
import sc "../../src/scene"
import cam "../../src/camera"
import postfx "../../src/rendering/postfx"
import rendering "../../src/rendering"
import gl_state "../../src/core/gl_state"
import gui "../../src/gui"

WIDTH  :: 1440
HEIGHT :: 960
CHANNELS :: 4

gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
}

save_png :: proc(path: string, pixels: []u8, width, height: i32) -> bool {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	stride := width * CHANNELS
	res := stbi.write_png(c_path, c.int(width), c.int(height), CHANNELS, raw_data(pixels), c.int(stride))
	return res != 0
}

capture_current_framebuffer :: proc(width, height: i32) -> []u8 {
	pixel_count := int(width * height)
	raw_pixels := make([]u8, pixel_count * CHANNELS)
	defer delete(raw_pixels)

	gl.ReadPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(raw_pixels))

	// Flip vertically (OpenGL origin is bottom-left)
	flipped := make([]u8, pixel_count * CHANNELS)
	row_size := int(width) * CHANNELS
	for y in 0 ..< int(height) {
		src_offset := (int(height) - 1 - y) * row_size
		dst_offset := y * row_size
		copy(flipped[dst_offset:][:row_size], raw_pixels[src_offset:][:row_size])
	}
	return flipped
}

capture_texture_2d :: proc(tex_id: u32, width, height: i32) -> []u8 {
	fbo: u32
	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex_id, 0)
	gl.Viewport(0, 0, width, height)
	pixels := capture_current_framebuffer(width, height)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.DeleteFramebuffers(1, &fbo)
	return pixels
}

make_scene_state :: proc(s: ^sc.Scene) -> gui.Scene_State {
	return gui.Scene_State{
		camera                     = &s.camera,
		skybox_visible             = &s.skybox_visible,
		wireframe_enabled          = &s.wireframe_enabled,
		exposure                   = &s.exposure,
		skybox_blur_lod            = &s.skybox.blur_lod,
		skybox_mode                = &s.skybox.mode,
		mipmap_mode                = &s.skybox.mipmap_mode,
		blur_source                = &s.skybox.blur_source,
		cubemap_dirty              = &s.skybox.cubemap_dirty,
		show_mipmap_diff           = &s.skybox.show_diff,
		diff_gain                  = &s.skybox.diff_gain,
		sort_mode                  = &s.sort_mode,
		edge_aa_enabled            = &s.edge_aa_enabled,
		edge_aa_debug              = &s.edge_aa_debug,
		specular_aa_enabled        = &s.specular_aa_enabled,
		specular_aa_mode           = &s.specular_aa_mode,
		specular_aa_debug_mode     = &s.specular_aa_debug_mode,
		specular_aa_split_enabled  = &s.specular_aa_split_enabled,
		specular_aa_split_position = &s.specular_aa_split_position,
		specular_occlusion_enabled  = &s.specular_occlusion_enabled,
		specular_occlusion_strength = &s.specular_occlusion_strength,
		horizon_clipping_enabled    = &s.horizon_clipping_enabled,
		specular_occlusion_debug_mode = &s.specular_occlusion_debug_mode,
		specular_occlusion_split_enabled = &s.specular_occlusion_split_enabled,
		specular_occlusion_split_position = &s.specular_occlusion_split_position,
		pbr_debug_mode             = &s.pbr_debug_mode,
		grid_ao_enabled            = &s.grid_ao_enabled,
		grid_ao_intensity          = &s.grid_ao_intensity,
		use_baked_ao               = &s.use_baked_ao,
		ibl_irradiance_map         = s.ibl.irradiance_map,
		ibl_prefilter_map          = s.ibl.prefilter_map,
		ibl_brdf_lut               = s.ibl.brdf_lut,
		env_texture_id             = s.env_texture.id,
		env_texture_width          = s.env_texture.width,
		env_texture_height         = s.env_texture.height,
		postfx                     = &s.postfx_pipeline,
		point_light                = &s.point_light,
		shadow_cubemap             = &s.shadow_cubemap,
		depth_downsample           = &s.depth_downsample,
		volumetric                 = &s.volumetric,
		ao_baker                   = &s.ao_baker,
		spheres                    = &s.spheres,
		selection                  = &s.selection,
		frame_time_ms              = s.overlay.frame_time_display,
		live_compute_tuning        = &s.env_mgr.compute_tuning,
		scene_ptr                  = s,
		hdr_files                  = s.hdr_files[:],
		current_hdr_index          = &s.current_hdr_index,
		env_thumbnails             = s.env_thumbs.thumbnails[:],
		env_transitioning          = (s.env_mgr.transition_state != .Idle),
		env_transition_alpha       = s.env_mgr.transition_alpha,
		optimization_profile       = &s.optimization_profile,
	}
}

step_frame :: proc(g: ^gui.Gui, s: ^sc.Scene) {
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.ClearColor(0.1, 0.1, 0.12, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	sc.scene_render(s, WIDTH, HEIGHT)

	gui.new_frame(g)
	state := make_scene_state(s)
	gui.update(g, state)
	gui.render(g)
	gl.Finish()
}

capture_frame :: proc(path: string) {
	pixels := capture_current_framebuffer(WIDTH, HEIGHT)
	defer delete(pixels)
	save_png(path, pixels, WIDTH, HEIGHT)
	fmt.printf("  [OK] %s\n", path)
}

main :: proc() {
	fmt.println("==================================================")
	fmt.println("  IBL Debug Equirectangular Visual Capture Tool   ")
	fmt.println("==================================================")

	if !glfw.Init() {
		fmt.eprintln("GLFW init failed")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.VISIBLE, 0)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window := glfw.CreateWindow(WIDTH, HEIGHT, "ibl_debug_capture", nil, nil)
	if window == nil {
		fmt.eprintln("Headless window creation failed")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, gl_set_proc_address)
	gl_state.reset()

	// Create Scene
	s: sc.Scene
	if !sc.scene_create(&s, WIDTH, HEIGHT) {
		fmt.eprintln("Failed to create scene")
		os.exit(1)
	}
	defer sc.scene_destroy(&s)

	// Wait for async IBL pipeline stabilization
	fmt.println("--> Waiting for async IBL pipeline stabilization...")
	for _ in 0..<5000 {
		sc.scene_update(&s, 0.016)
		gl.Viewport(0, 0, WIDTH, HEIGHT)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, WIDTH, HEIGHT)
		if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle { break }
		time.sleep(1 * time.Millisecond)
	}

	// Warmup frames
	for _ in 0..<20 {
		sc.scene_update(&s, 0.016)
		gl.Viewport(0, 0, WIDTH, HEIGHT)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, WIDTH, HEIGHT)
	}
	gl.Finish()

	fmt.printf("--> IBL Ready: Prefilter=%d, Irradiance=%d, BRDF_LUT=%d\n",
		s.ibl.prefilter_map, s.ibl.irradiance_map, s.ibl.brdf_lut)

	// Initialize Gui
	g: gui.Gui
	if !gui.init(&g, window) {
		fmt.eprintln("Failed to initialize Gui")
		os.exit(1)
	}
	defer gui.destroy(&g)

	g.visible = true
	g.active_tab = 7
	g.ibl_debug_open = true
	g.ibl_preview_size = 360.0
	g.ibl_debug_tonemap = true
	g.ibl_debug_exposure = 0.0

	os.make_directory("docs/images/ibl")

	// Warmup GUI draw passes
	for _ in 0..<5 {
		g.ibl_debug_open = true
		g.active_tab = 7
		step_frame(&g, &s)
	}

	fmt.println("--> Capturing IBL Debug perspectives...")

	// 1. Prefilter LOD 0 (Roughness = 0.0)
	g.ibl_mip_level = 0
	g.ibl_roughness = 0.0
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/01_prefilter_lod0.png")

	// 2. Prefilter LOD 2 (Roughness = 0.2)
	g.ibl_mip_level = 2
	g.ibl_roughness = 0.2
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/02_prefilter_lod2.png")

	// 3. Prefilter LOD 5 (Roughness = 0.5)
	g.ibl_mip_level = 5
	g.ibl_roughness = 0.5
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/03_prefilter_lod5.png")

	// 4. Prefilter LOD 7 (Roughness = 0.7)
	g.ibl_mip_level = 7
	g.ibl_roughness = 0.7
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/04_prefilter_lod7.png")

	// 5. Prefilter LOD 9 (Roughness = 0.9)
	g.ibl_mip_level = 9
	g.ibl_roughness = 0.9
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/05_prefilter_lod9.png")

	// 6. Irradiance Map (Diffuse IBL)
	g.inspect_active = false
	g.ibl_scroll_target = .Irradiance
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/06_irradiance_map.png")

	// 7. BRDF LUT (Split-Sum)
	g.inspect_active = false
	g.ibl_scroll_target = .BRDF_LUT
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/07_brdf_lut.png")

	// 8. Pixel Inspector Active on Prefilter LOD 2
	g.ibl_scroll_target = .None
	g.ibl_mip_level = 2
	g.ibl_roughness = 0.2
	g.inspect_active = true
	g.inspect_tex_id = s.ibl.prefilter_map
	g.inspect_tex_w = 1024
	g.inspect_tex_h = 1024
	g.inspect_mip = 2
	g.inspect_uv = {0.5, 0.48}
	tx := clamp(i32(g.inspect_uv[0] * 256.0), 0, 255)
	ty := clamp(i32(g.inspect_uv[1] * 256.0), 0, 255)
	g.inspect_pixel = gui.read_texture_pixel(&g, s.ibl.prefilter_map, tx, ty, 2)
	// Set scroll to show full header, controls, image and inspector panel
	g.ibl_scroll_target = .Prefilter
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/08_inspector_active.png")

	// 9. Raw HDR (Tonemapping OFF) comparison capture
	g.ibl_debug_tonemap = false
	g.inspect_active = false
	g.ibl_scroll_target = .Prefilter
	g.ibl_mip_level = 0
	g.ibl_roughness = 0.0
	step_frame(&g, &s)
	step_frame(&g, &s)
	capture_frame("docs/images/ibl/09_prefilter_raw_hdr_no_tonemap.png")

	// Standalone Texture Exports (Cropped / Pure Texture Data)
	fmt.println("--> Exporting standalone 2D texture captures...")
	if g.ibl_pf_preview_tex != 0 {
		mips_to_dump := [?]i32{0, 2, 5, 7, 9}
		for m in mips_to_dump {
			g.ibl_debug_tonemap = true
			g.ibl_mip_level = m
			g.ibl_roughness = f32(m) / 10.0
			step_frame(&g, &s)
			pix := capture_texture_2d(g.ibl_pf_preview_tex, 512, 512)
			defer delete(pix)
			path := fmt.tprintf("docs/images/ibl/tex_prefilter_lod%d.png", m)
			save_png(path, pix, 512, 512)
			fmt.printf("  [OK] %s\n", path)
		}
	}

	if g.ibl_irr_preview_tex != 0 {
		g.ibl_debug_tonemap = true
		step_frame(&g, &s)
		pix := capture_texture_2d(g.ibl_irr_preview_tex, 64, 64)
		defer delete(pix)
		save_png("docs/images/ibl/tex_irradiance_64x64.png", pix, 64, 64)
		fmt.println("  [OK] docs/images/ibl/tex_irradiance_64x64.png")
	}

	if s.ibl.brdf_lut != 0 {
		pix := capture_texture_2d(s.ibl.brdf_lut, 512, 512)
		defer delete(pix)
		save_png("docs/images/ibl/tex_brdf_lut_512x512.png", pix, 512, 512)
		fmt.println("  [OK] docs/images/ibl/tex_brdf_lut_512x512.png")
	}

	fmt.println("=== All requested IBL debug captures successfully generated! ===")
}
