package main

import "core:fmt"
import "core:os"
import "core:c"
import "core:c/libc"
import "core:strings"
import "core:time"

import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import sc "../../src/scene"
import cam "../../src/camera"
import postfx "../../src/rendering/postfx"
import types "../../src/rendering/types"
import rendering "../../src/rendering"
import gl_state "../../src/core/gl_state"
import mt "../../src/core/math_types"

WIDTH  :: 1280
HEIGHT :: 720
CHANNELS :: 4

gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
}

save_webp :: proc(path_webp: string, pixels: []u8, width, height: i32) -> bool {
	temp_png := fmt.tprintf("/tmp/doc_cap_%d.png", time.now()._nsec)
	c_temp := strings.clone_to_cstring(temp_png)
	defer delete(c_temp)
	stride := width * CHANNELS
	res := stbi.write_png(c_temp, c.int(width), c.int(height), CHANNELS, raw_data(pixels), c.int(stride))
	if res == 0 { return false }

	cmd := fmt.tprintf("cwebp -q 90 %s -o %s >/dev/null 2>&1 && rm -f %s", temp_png, path_webp, temp_png)
	c_cmd := strings.clone_to_cstring(cmd)
	defer delete(c_cmd)
	ret := libc.system(c_cmd)
	return ret == 0
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

	pixels := capture_current_framebuffer(width, height)

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.DeleteFramebuffers(1, &fbo)
	return pixels
}

generate_glasbey_swatches :: proc() {
	SWATCH_SIZE :: 32
	GRID_DIM    :: 16
	IMG_SIZE    :: GRID_DIM * SWATCH_SIZE // 512x512

	pixels := make([]u8, IMG_SIZE * IMG_SIZE * CHANNELS)
	defer delete(pixels)

	palette := postfx.GLASBEY_256
	for idx in 0..<256 {
		col := palette[idx]
		r := u8(col[0] * 255.0)
		g := u8(col[1] * 255.0)
		b := u8(col[2] * 255.0)

		gx := idx % GRID_DIM
		gy := idx / GRID_DIM

		for sy in 0..<SWATCH_SIZE {
			py := gy * SWATCH_SIZE + sy
			for sx in 0..<SWATCH_SIZE {
				px := gx * SWATCH_SIZE + sx
				pixel_offset := (py * IMG_SIZE + px) * CHANNELS
				
				// Border 1px dark
				if sx == 0 || sx == SWATCH_SIZE - 1 || sy == 0 || sy == SWATCH_SIZE - 1 {
					pixels[pixel_offset + 0] = 20
					pixels[pixel_offset + 1] = 20
					pixels[pixel_offset + 2] = 20
					pixels[pixel_offset + 3] = 255
				} else {
					pixels[pixel_offset + 0] = r
					pixels[pixel_offset + 1] = g
					pixels[pixel_offset + 2] = b
					pixels[pixel_offset + 3] = 255
				}
			}
		}
	}

	save_webp("docs/images/materials/05_glasbey_palette_256_swatches.webp", pixels, IMG_SIZE, IMG_SIZE)
	fmt.println("  [OK] docs/images/materials/05_glasbey_palette_256_swatches.webp")
}

main :: proc() {
	fmt.println("==================================================")
	fmt.println("  Suckless-Odin Documentation Visual Generator (WebP)")
	fmt.println("==================================================")

	if !glfw.Init() {
		fmt.eprintln("GLFW init failed")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.VISIBLE, 0)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 4)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window := glfw.CreateWindow(WIDTH, HEIGHT, "doc_capture", nil, nil)
	if window == nil {
		fmt.eprintln("Headless window creation failed")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 4, gl_set_proc_address)
	gl_state.reset()

	// Create Scene
	s: sc.Scene
	if !sc.scene_create(&s, WIDTH, HEIGHT) {
		fmt.eprintln("Failed to create scene")
		os.exit(1)
	}
	defer sc.scene_destroy(&s)

	// Wait for async IBL pipeline
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
	for _ in 0..<10 {
		sc.scene_update(&s, 0.016)
		gl.Viewport(0, 0, WIDTH, HEIGHT)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, WIDTH, HEIGHT)
	}
	gl.Finish()

	fmt.println("--> Generating PostFX WebP visual captures...")

	// 1. Raw HDR Scene (PostFX disabled)
	s.postfx_pipeline.enabled = false
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/01_scene_raw_hdr.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/01_scene_raw_hdr.webp")
	}

	// 2. Tonemapped + Exposure Only (Clean baseline)
	s.postfx_pipeline.enabled = true
	s.postfx_pipeline.active_effects = {.Exposure, .Tonemap}
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/02_baseline_tonemapped.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/02_baseline_tonemapped.webp")
	}

	// 3. Bloom Multi-Pass Isolated Texture
	s.postfx_pipeline.active_effects = {.Exposure, .Tonemap, .Bloom}
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		bloom_tex := postfx.bloom_get_texture(&s.postfx_pipeline.bloom_fx)
		pix := capture_texture_2d(bloom_tex, WIDTH / 2, HEIGHT / 2)
		defer delete(pix)
		save_webp("docs/images/postfx/03_bloom_texture_isolated.webp", pix, WIDTH / 2, HEIGHT / 2)
		fmt.println("  [OK] docs/images/postfx/03_bloom_texture_isolated.webp")
	}

	// 4. Bloom Combined with Scene
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/04_bloom_composite.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/04_bloom_composite.webp")
	}

	// 5. Depth of Field (DoF) Bokeh
	s.postfx_pipeline.active_effects = {.Exposure, .Tonemap, .Dof}
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.dof.focal_distance = 15.0
	s.postfx_pipeline.dof.focal_range = 8.0
	s.postfx_pipeline.dof.bokeh_scale = 3.5
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/05_dof_focal_blur.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/05_dof_focal_blur.webp")
	}

	// 6. Luminance Stops (Filament False-Color Exposure Zones)
	s.postfx_pipeline.active_effects = {.Exposure, .Tonemap, .Luminance_Debug}
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/06_luminance_stops_false_color.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/06_luminance_stops_false_color.webp")
	}

	// 7. Split-Screen A/B Debug (Left: Raw Scene / Right: Graded PostFX)
	s.postfx_pipeline.active_effects = {
		.Vignette, .Grain, .Exposure, .Chrom_Abbr, .Bloom,
		.Color_Grading, .Tonemap, .FXAA,
	}
	s.postfx_pipeline.debug_split = {.Vignette, .Bloom, .Color_Grading, .Tonemap}
	s.postfx_pipeline.split_positions[.Vignette] = 0.5
	s.postfx_pipeline.split_positions[.Bloom] = 0.5
	s.postfx_pipeline.split_positions[.Color_Grading] = 0.5
	s.postfx_pipeline.split_positions[.Tonemap] = 0.5
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/07_debug_split_ab.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/07_debug_split_ab.webp")
	}

	// 8. Preset "Cinematic"
	postfx.pipeline_apply_preset(&s.postfx_pipeline, .Cinematic)
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/08_preset_cinematic.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/08_preset_cinematic.webp")
	}

	// 9. Preset "Matrix"
	postfx.pipeline_apply_preset(&s.postfx_pipeline, .Matrix)
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/09_preset_matrix.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/09_preset_matrix.webp")
	}

	// 10. Preset "Nordic Noir"
	postfx.pipeline_apply_preset(&s.postfx_pipeline, .Nordic_Noir)
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/postfx/10_preset_nordic_noir.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/postfx/10_preset_nordic_noir.webp")
	}

	fmt.println("--> Generating Specular AA & Material captures...")

	// Reset to baseline postfx
	s.postfx_pipeline.enabled = true
	s.postfx_pipeline.active_effects = {.Exposure, .Tonemap}
	s.postfx_pipeline.debug_split = {}
	s.postfx_pipeline.ubo_dirty = true
	postfx.pipeline_compile_variant(&s.postfx_pipeline)

	// 11. Specular AA OFF
	s.specular_aa_enabled = false
	s.specular_aa_split_enabled = false
	s.specular_aa_debug_mode = .Off
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/materials/01_specular_aa_disabled.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/materials/01_specular_aa_disabled.webp")
	}

	// 12. Specular AA ON (Screen-Space)
	s.specular_aa_enabled = true
	s.specular_aa_mode = .Screen_Space
	s.specular_aa_split_enabled = false
	s.specular_aa_debug_mode = .Off
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/materials/02_specular_aa_screen_space.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/materials/02_specular_aa_screen_space.webp")
	}

	// 13. Specular AA Split A/B (Left: AA ON / Right: AA OFF)
	s.specular_aa_enabled = true
	s.specular_aa_split_enabled = true
	s.specular_aa_split_position = 0.5
	s.specular_aa_debug_mode = .Off
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/materials/03_specular_aa_split_ab.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/materials/03_specular_aa_split_ab.webp")
	}

	// 14. Specular AA Variance Mask Debug View
	s.specular_aa_enabled = true
	s.specular_aa_split_enabled = false
	s.specular_aa_debug_mode = .Grayscale_Variance
	gl.Viewport(0, 0, WIDTH, HEIGHT)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	sc.scene_render(&s, WIDTH, HEIGHT)
	gl.Finish()
	{
		pix := capture_current_framebuffer(WIDTH, HEIGHT)
		defer delete(pix)
		save_webp("docs/images/materials/04_specular_aa_variance_mask.webp", pix, WIDTH, HEIGHT)
		fmt.println("  [OK] docs/images/materials/04_specular_aa_variance_mask.webp")
	}

	// 15. Glasbey 256 Palette Swatches
	generate_glasbey_swatches()

	// 16. BRDF LUT precomputed texture (512x512 RG16F)
	{
		pix := capture_texture_2d(s.ibl.brdf_lut, 512, 512)
		defer delete(pix)
		save_webp("docs/images/ibl/01_brdf_lut_512x512.webp", pix, 512, 512)
		fmt.println("  [OK] docs/images/ibl/01_brdf_lut_512x512.webp")
	}

	fmt.println("==================================================")
	fmt.println("  All WebP captures successfully generated!")
	fmt.println("==================================================")
}
