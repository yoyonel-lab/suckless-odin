package gui

import "vendor:glfw"
import gl "vendor:OpenGL"

import imgui "../../deps/odin-imgui"
import "../../deps/odin-imgui/imgui_impl_glfw"
import "../../deps/odin-imgui/imgui_impl_opengl3"

import cam "../camera"
import "../core/search"
import postfx "../rendering/postfx"

// Forward-declare scene data needed by GUI panels.
// Avoids circular import by accepting raw pointers from app.
Scene_State :: struct {
	camera:            ^cam.Camera,
	skybox_visible:    ^bool,
	wireframe_enabled: ^bool,
	exposure:          ^f32,
	skybox_blur_lod:   ^f32,

	// Post-processing pipeline (live controls)
	postfx: ^postfx.Pipeline,

	// Smoothed frame time from overlay (single source of truth)
	frame_time_ms: f32,

	// IBL debug textures (GL handles)
	ibl_irradiance_map: u32,
	ibl_prefilter_map:  u32,
	ibl_brdf_lut:       u32,
	env_texture_id:     u32,
	env_texture_width:  i32,
	env_texture_height: i32,
}

IBL_Scroll_Target :: enum {
	None,
	Env_Map,
	Irradiance,
	Prefilter,
	BRDF_LUT,
}

SEARCH_BUF_SIZE :: 128

// GUI state — manages Dear ImGui lifecycle.
Gui :: struct {
	ctx:              ^imgui.Context,
	visible:          bool,
	docking_enabled:  bool,
	search_buf:       [SEARCH_BUF_SIZE]u8,
	focus_search:     bool,
	ibl_debug_open:   bool,
	ibl_scroll_target: IBL_Scroll_Target,
	ibl_preview_size: f32,
	ibl_mip_level:    i32,
	ibl_prefilter_id: u32, // Tracked for LOD restore after render
	inspector_fbo:    u32, // Reusable FBO for pixel readback

	// Pixel inspector state (click-to-lock)
	inspect_active:   bool,
	inspect_uv:       [2]f32, // Locked UV position
	inspect_tex_id:   u32,    // Which texture is being inspected
	inspect_tex_w:    i32,
	inspect_tex_h:    i32,
	inspect_mip:      i32,
	inspect_pixel:    [4]f32, // Last read pixel value
}

GLSL_VERSION :: "#version 440 core"

init :: proc(g: ^Gui, window: glfw.WindowHandle) -> bool {
	imgui.CHECKVERSION()

	g.ctx = imgui.CreateContext()
	if g.ctx == nil {
		return false
	}

	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}

	g.docking_enabled = true
	g.visible = false
	g.ibl_preview_size = 256.0
	g.ibl_mip_level = 0

	imgui.StyleColorsDark()

	if !imgui_impl_glfw.InitForOpenGL(window, true) {
		imgui.DestroyContext(g.ctx)
		g.ctx = nil
		return false
	}

	if !imgui_impl_opengl3.Init(GLSL_VERSION) {
		imgui_impl_glfw.Shutdown()
		imgui.DestroyContext(g.ctx)
		g.ctx = nil
		return false
	}

	return true
}

new_frame :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui_impl_opengl3.NewFrame()
	imgui_impl_glfw.NewFrame()
	imgui.NewFrame()
}

// Single window with search + tab bar for all engine controls.
update :: proc(g: ^Gui, state: Scene_State) {
	if g.ctx == nil { return }
	if !g.visible { return }

	imgui.SetNextWindowSize(imgui.Vec2{400, 560}, .FirstUseEver)

	if imgui.Begin("Engine Controls", &g.visible) {
		// Search bar at the top — focus on Ctrl+F
		if g.focus_search {
			imgui.SetKeyboardFocusHere()
			g.focus_search = false
		}
		imgui.SetNextItemWidth(-1)
		imgui.InputTextWithHint("##search", "Search parameters...",
			cast(cstring)&g.search_buf[0], SEARCH_BUF_SIZE)

		filter := cstring(&g.search_buf[0])
		has_filter := len(filter) > 0

		imgui.Separator()

		if has_filter {
			// Filtered flat view
			draw_filtered_view(g, state, filter)
		} else {
			// Normal tab bar
			if imgui.BeginTabBar("##tabs") {
				if imgui.BeginTabItem("Camera") {
					draw_tab_camera(state.camera)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Scene") {
					draw_tab_scene(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Rendering") {
					draw_tab_rendering(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Post-FX") {
					draw_postfx_section(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("GPU") {
					draw_gpu_timings_section(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Shaders") {
					draw_shader_cache_section(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("IBL Debug", flags = g.ibl_debug_open ? imgui.TabItemFlags{.SetSelected} : {}) {
					g.ibl_debug_open = false
					draw_tab_ibl_debug(g, state)
					imgui.EndTabItem()
				} else {
					g.ibl_debug_open = false
				}
				imgui.EndTabBar()
			}
		}
	}
	imgui.End()
}

render :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui.Render()
	imgui_impl_opengl3.RenderDrawData(imgui.GetDrawData())

	// Restore prefilter LOD after ImGui has actually drawn
	if g.ibl_prefilter_id != 0 {
		gl.BindTexture(gl.TEXTURE_2D, g.ibl_prefilter_id)
		gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MIN_LOD, -1000.0)
		gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MAX_LOD, 1000.0)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		g.ibl_prefilter_id = 0
	}
}

toggle :: proc(g: ^Gui) {
	g.visible = !g.visible
}

destroy :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	if g.inspector_fbo != 0 {
		gl.DeleteFramebuffers(1, &g.inspector_fbo)
		g.inspector_fbo = 0
	}
	imgui_impl_opengl3.Shutdown()
	imgui_impl_glfw.Shutdown()
	imgui.DestroyContext(g.ctx)
	g.ctx = nil
}

wants_keyboard :: proc(g: ^Gui) -> bool {
	if g.ctx == nil { return false }
	if !g.visible { return false }
	io := imgui.GetIO()
	return io.WantCaptureKeyboard
}

wants_mouse :: proc(g: ^Gui) -> bool {
	if g.ctx == nil { return false }
	if !g.visible { return false }
	io := imgui.GetIO()
	return io.WantCaptureMouse
}

// ─── Tab: Camera ───────────────────────────────────────────────────────────────

@(private)
draw_tab_camera :: proc(c: ^cam.Camera) {
	if c == nil { return }

	imgui.Text("Position: %.1f, %.1f, %.1f", c.position.x, c.position.y, c.position.z)
	imgui.Text("Yaw: %.1f  Pitch: %.1f", c.yaw, c.pitch)
	imgui.Separator()

	imgui.SliderFloat("Speed", &c.velocity, 1.0, 100.0)
	imgui.SliderFloat("Acceleration", &c.acceleration, 1.0, 50.0)
	imgui.SliderFloat("Friction", &c.friction, 0.5, 0.99)
	imgui.SliderFloat("Sensitivity", &c.sensitivity, 0.01, 1.0)
	imgui.SliderFloat("Rotation Smoothing", &c.rotation_smoothing, 0.0, 0.5)
	imgui.SliderFloat("Mouse Smoothing", &c.mouse_smoothing_factor, 0.0, 0.5)
	imgui.SliderFloat("FOV", &c.zoom, 10.0, 120.0)
	imgui.Separator()

	imgui.Checkbox("Head Bobbing", &c.bobbing_enabled)
	if c.bobbing_enabled {
		imgui.SliderFloat("Bobbing Freq", &c.bobbing_frequency, 0.5, 10.0)
		imgui.SliderFloat("Bobbing Amp", &c.bobbing_amplitude, 0.0, 0.01)
	}

	imgui.Separator()
	if imgui.Button("Reset Camera") {
		cam.init(c, 20.0, -90.0, 0.0)
	}
}

// ─── Tab: Scene ────────────────────────────────────────────────────────────────

@(private)
draw_tab_scene :: proc(state: Scene_State) {
	imgui.Checkbox("Skybox", state.skybox_visible)
	imgui.SliderFloat("Skybox Blur", state.skybox_blur_lod, 0.0, 8.0)
	imgui.Separator()

	imgui.BeginDisabled()
	imgui.SliderFloat("Exposure", state.exposure, 0.1, 10.0)
	imgui.EndDisabled()
	imgui.Separator()

	imgui.Checkbox("Wireframe", state.wireframe_enabled)
}

// ─── Tab: IBL Debug ────────────────────────────────────────────────────────────

IBL_IRRADIANCE_SIZE :: 64
IBL_PREFILTER_SIZE  :: 1024
IBL_BRDF_LUT_SIZE   :: 512
IBL_PREFILTER_MIP_LEVELS :: 5

// Convert a GL texture handle to an ImGui TextureRef for display.
@(private)
gl_tex_ref :: proc(gl_id: u32) -> imgui.TextureRef {
	return imgui.TextureRef{_TexData = nil, _TexID = imgui.TextureID(gl_id)}
}

// Zoom region size in texels around the cursor
INSPECTOR_REGION :: 16
INSPECTOR_DISPLAY :: 128
INSPECTOR_RECT_COLOR :: 0xFF_00_FF_FF // Yellow (ABGR)

// Display a texture with click-to-inspect pixel inspector shown inline to the right.
@(private)
draw_image_with_inspector :: proc(g: ^Gui, tex_id: u32, display_size: imgui.Vec2, tex_w, tex_h: i32, mip_level: i32 = 0) {
	imgui.Image(gl_tex_ref(tex_id), display_size, {0, 1}, {1, 0})

	item_min := imgui.GetItemRectMin()
	item_max := imgui.GetItemRectMax()

	// On click: lock the inspection point
	if imgui.IsItemClicked(.Left) {
		mouse_pos := imgui.GetMousePos()
		rel_x := (mouse_pos.x - item_min.x) / display_size.x
		rel_y := (mouse_pos.y - item_min.y) / display_size.y

		g.inspect_active = true
		g.inspect_uv = {rel_x, 1.0 - rel_y} // Flip Y for GL
		g.inspect_tex_id = tex_id
		g.inspect_tex_w = tex_w
		g.inspect_tex_h = tex_h
		g.inspect_mip = mip_level

		// Read pixel
		mip_w := max(i32(1), tex_w >> u32(mip_level))
		mip_h := max(i32(1), tex_h >> u32(mip_level))
		tx := clamp(i32(g.inspect_uv[0] * f32(mip_w)), 0, mip_w - 1)
		ty := clamp(i32(g.inspect_uv[1] * f32(mip_h)), 0, mip_h - 1)
		g.inspect_pixel = read_texture_pixel(g, tex_id, tx, ty, mip_level)
	}

	// If this texture is the inspected one: draw overlay + inline inspector
	is_inspected := g.inspect_active && g.inspect_tex_id == tex_id && g.inspect_mip == mip_level
	if !is_inspected { return }

	// --- Draw zoom rectangle overlay on the image ---
	draw_list := imgui.GetWindowDrawList()

	mip_w := max(i32(1), tex_w >> u32(mip_level))
	mip_h := max(i32(1), tex_h >> u32(mip_level))

	half_region_x := f32(INSPECTOR_REGION) * 0.5 / f32(mip_w)
	half_region_y := f32(INSPECTOR_REGION) * 0.5 / f32(mip_h)

	center_screen_x := item_min.x + g.inspect_uv[0] * display_size.x
	center_screen_y := item_min.y + (1.0 - g.inspect_uv[1]) * display_size.y

	rect_half_w := half_region_x * display_size.x
	rect_half_h := half_region_y * display_size.y

	rect_min := imgui.Vec2{
		max(center_screen_x - rect_half_w, item_min.x),
		max(center_screen_y - rect_half_h, item_min.y),
	}
	rect_max := imgui.Vec2{
		min(center_screen_x + rect_half_w, item_max.x),
		min(center_screen_y + rect_half_h, item_max.y),
	}

	imgui.DrawList_AddRect(draw_list, rect_min, rect_max, INSPECTOR_RECT_COLOR, 0.0, {}, 2.0)

	// Crosshair
	imgui.DrawList_AddLine(draw_list,
		imgui.Vec2{center_screen_x - 5, center_screen_y},
		imgui.Vec2{center_screen_x + 5, center_screen_y},
		INSPECTOR_RECT_COLOR, 1.0)
	imgui.DrawList_AddLine(draw_list,
		imgui.Vec2{center_screen_x, center_screen_y - 5},
		imgui.Vec2{center_screen_x, center_screen_y + 5},
		INSPECTOR_RECT_COLOR, 1.0)

	// --- Inline inspector: zoomed view + pixel values on the same line ---
	imgui.SameLine()

	imgui.BeginGroup()

	// Zoomed view
	half_region := f32(INSPECTOR_REGION) * 0.5
	zoom_uv_half_x := half_region / f32(mip_w)
	zoom_uv_half_y := half_region / f32(mip_h)

	zoom_uv0 := imgui.Vec2{
		clamp(g.inspect_uv[0] - zoom_uv_half_x, 0.0, 1.0),
		clamp(g.inspect_uv[1] + zoom_uv_half_y, 0.0, 1.0),
	}
	zoom_uv1 := imgui.Vec2{
		clamp(g.inspect_uv[0] + zoom_uv_half_x, 0.0, 1.0),
		clamp(g.inspect_uv[1] - zoom_uv_half_y, 0.0, 1.0),
	}

	imgui.Image(gl_tex_ref(tex_id),
		imgui.Vec2{INSPECTOR_DISPLAY, INSPECTOR_DISPLAY},
		zoom_uv0, zoom_uv1)

	// Pixel info below zoomed view
	texel_x := clamp(i32(g.inspect_uv[0] * f32(mip_w)), 0, mip_w - 1)
	texel_y := clamp(i32(g.inspect_uv[1] * f32(mip_h)), 0, mip_h - 1)

	pixel := g.inspect_pixel
	imgui.Text("(%d, %d)", texel_x, texel_y)
	imgui.TextColored(imgui.Vec4{1.0, 0.4, 0.4, 1.0}, "R %.4f", pixel[0])
	imgui.TextColored(imgui.Vec4{0.4, 1.0, 0.4, 1.0}, "G %.4f", pixel[1])
	imgui.TextColored(imgui.Vec4{0.4, 0.4, 1.0, 1.0}, "B %.4f", pixel[2])
	imgui.TextColored(imgui.Vec4{0.8, 0.8, 0.8, 1.0}, "A %.4f", pixel[3])

	lum := pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722
	imgui.Text("L %.4f", lum)

	max_c := max(pixel[0], pixel[1], pixel[2], 1.0)
	swatch := imgui.Vec4{pixel[0] / max_c, pixel[1] / max_c, pixel[2] / max_c, 1.0}
	imgui.ColorButton("##swatch", swatch, {.NoTooltip}, imgui.Vec2{24, 24})

	imgui.EndGroup()
}

// Read a single pixel from a GL texture at given coordinates using FBO.
@(private)
read_texture_pixel :: proc(g: ^Gui, tex_id: u32, x, y: i32, mip_level: i32 = 0) -> [4]f32 {
	pixel: [4]f32

	// Lazy-init FBO
	if g.inspector_fbo == 0 {
		gl.GenFramebuffers(1, &g.inspector_fbo)
	}

	// Save current FBO binding
	prev_fbo: i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)

	gl.BindFramebuffer(gl.FRAMEBUFFER, g.inspector_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex_id, mip_level)

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status == gl.FRAMEBUFFER_COMPLETE {
		gl.ReadPixels(x, y, 1, 1, gl.RGBA, gl.FLOAT, &pixel[0])
	}

	// Restore previous FBO
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))

	return pixel
}

@(private)
draw_tab_ibl_debug :: proc(g: ^Gui, state: Scene_State) {
	imgui.SliderFloat("Preview Size", &g.ibl_preview_size, 64.0, 512.0)
	imgui.Separator()

	preview_w := g.ibl_preview_size
	// Equirectangular maps are 2:1 aspect ratio
	preview_h := preview_w * 0.5

	// --- Environment Source Map ---
	if state.env_texture_id != 0 {
		if g.ibl_scroll_target == .Env_Map {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("Environment Map (Source HDR)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Format: RGBA16F",
				state.env_texture_id, state.env_texture_width, state.env_texture_height)
			draw_image_with_inspector(g, state.env_texture_id,
				imgui.Vec2{preview_w, preview_h},
				state.env_texture_width, state.env_texture_height)
			imgui.Spacing()
		}
	}

	// --- Irradiance Map (diffuse IBL) ---
	if state.ibl_irradiance_map != 0 {
		if g.ibl_scroll_target == .Irradiance {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("Irradiance Map (Diffuse IBL)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Format: RGBA16F",
				state.ibl_irradiance_map, IBL_IRRADIANCE_SIZE * 2, IBL_IRRADIANCE_SIZE)
			draw_image_with_inspector(g, state.ibl_irradiance_map,
				imgui.Vec2{preview_w, preview_h},
				IBL_IRRADIANCE_SIZE * 2, IBL_IRRADIANCE_SIZE)
			imgui.Spacing()
		}
	}

	// --- Prefilter Map (specular IBL) with mip level selector ---
	if state.ibl_prefilter_map != 0 {
		if g.ibl_scroll_target == .Prefilter {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("Prefilter Map (Specular IBL)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Mips: %d  Format: RGBA16F",
				state.ibl_prefilter_map, IBL_PREFILTER_SIZE * 2, IBL_PREFILTER_SIZE,
				IBL_PREFILTER_MIP_LEVELS)

			imgui.SliderInt("Mip Level (Roughness)", &g.ibl_mip_level, 0, IBL_PREFILTER_MIP_LEVELS - 1)
			roughness := f32(g.ibl_mip_level) / f32(IBL_PREFILTER_MIP_LEVELS - 1)
			imgui.Text("Roughness: %.2f", roughness)

			// Clamp LOD to force the selected mip level display.
			// LOD is restored after RenderDrawData() in render().
			mip_f := f32(g.ibl_mip_level)
			gl.BindTexture(gl.TEXTURE_2D, state.ibl_prefilter_map)
			gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MIN_LOD, mip_f)
			gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MAX_LOD, mip_f)
			gl.BindTexture(gl.TEXTURE_2D, 0)
			g.ibl_prefilter_id = state.ibl_prefilter_map

			draw_image_with_inspector(g, state.ibl_prefilter_map,
				imgui.Vec2{preview_w, preview_h},
				IBL_PREFILTER_SIZE * 2, IBL_PREFILTER_SIZE, g.ibl_mip_level)

			imgui.Spacing()
		}
	}

	// --- BRDF LUT ---
	if state.ibl_brdf_lut != 0 {
		if g.ibl_scroll_target == .BRDF_LUT {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("BRDF LUT (Split-Sum)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Format: RG16F",
				state.ibl_brdf_lut, IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE)
			imgui.Text("X-axis: NdotV | Y-axis: Roughness")
			// Square aspect for LUT
			draw_image_with_inspector(g, state.ibl_brdf_lut,
				imgui.Vec2{preview_w, preview_w},
				IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE)
			imgui.Spacing()
		}
	}

	// --- Summary ---
	imgui.Separator()
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "GPU Memory Estimate")
	// Env HDR: width*height * RGBA16F(8B) + mipmaps (~1.33x)
	env_kb := (state.env_texture_width * state.env_texture_height * 8 * 4 / 3) / 1024
	// Irradiance: 128x64 * RGBA16F(8B) = 64KB
	irr_kb := i32((IBL_IRRADIANCE_SIZE * 2 * IBL_IRRADIANCE_SIZE * 8) / 1024)
	brdf_kb := i32((IBL_BRDF_LUT_SIZE * IBL_BRDF_LUT_SIZE * 4) / 1024)
	// Prefilter with mip chain: sum of mip areas * 8 bytes
	pf_bytes: i32 = 0
	for mip in 0 ..< IBL_PREFILTER_MIP_LEVELS {
		mip_w := max(i32(1), (IBL_PREFILTER_SIZE * 2) >> u32(mip))
		mip_h := max(i32(1), IBL_PREFILTER_SIZE >> u32(mip))
		pf_bytes += mip_w * mip_h * 8
	}
	pf_kb := pf_bytes / 1024
	total_kb := env_kb + irr_kb + brdf_kb + pf_kb
	imgui.Text("  Env HDR:    %d KB (%dx%d + mips)", env_kb, state.env_texture_width, state.env_texture_height)
	imgui.Text("  Irradiance: %d KB", irr_kb)
	imgui.Text("  Prefilter:  %d KB (%d mips)", pf_kb, IBL_PREFILTER_MIP_LEVELS)
	imgui.Text("  BRDF LUT:   %d KB", brdf_kb)
	imgui.Text("  Total:      %.1f MB", f32(total_kb) / 1024.0)
}

// ─── Tab: Rendering (all debug views & post-FX, greyed until implemented) ────

@(private)
draw_tab_rendering :: proc(state: Scene_State) {
	// --- PBR Debug Modes ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "PBR Debug Modes")
	imgui.Separator()
	imgui.BeginDisabled()

	pbr_debug_mode: i32 = 0
	imgui.Combo("Debug Mode", &pbr_debug_mode,
		"Final PBR\x00Albedo\x00Normal\x00Metallic\x00Roughness\x00AO\x00Irradiance (Diff)\x00Prefilter (Spec)\x00BRDF LUT\x00GI Probes\x00")

	specular_aa := false
	imgui.Checkbox("Specular Anti-Aliasing", &specular_aa)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Debug Views ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Debug Views")
	imgui.Separator()
	imgui.BeginDisabled()

	placeholder := false
	imgui.Checkbox("Bloom Debug", &placeholder)
	imgui.Checkbox("DoF Debug", &placeholder)
	imgui.Checkbox("Exposure Histogram", &placeholder)
	imgui.Checkbox("Motion Blur Debug", &placeholder)
	imgui.Checkbox("FXAA Debug", &placeholder)
	imgui.Checkbox("Stencil Debug", &placeholder)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- GPU Profiling ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Profiling")
	imgui.Separator()
	imgui.BeginDisabled()

	imgui.Checkbox("GPU Timeline", &placeholder)
	imgui.Checkbox("GPU Metrics Log", &placeholder)
	imgui.Checkbox("Perf Mode", &placeholder)
	imgui.Checkbox("Effect Benchmark", &placeholder)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Scene Debug ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Scene Debug")
	imgui.Separator()
	imgui.BeginDisabled()

	placeholder_f: f32 = 0.0
	imgui.Checkbox("Light Probes Debug", &placeholder)
	imgui.Checkbox("N-Body Simulation", &placeholder)
	imgui.SliderFloat("Sim Speed", &placeholder_f, 0.0, 5.0)
	imgui.SliderFloat("Gravity", &placeholder_f, 0.0, 10.0)
	imgui.Checkbox("Time Reversal", &placeholder)

	gi_mode: i32 = 0
	imgui.Combo("GI Mode", &gi_mode, "OFF\x00Volume 3D Tex\x00SSBO\x00")

	sort_mode: i32 = 0
	imgui.Combo("Sort Mode", &sort_mode, "None\x00CPU\x00GPU\x00")

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Environment ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Environment")
	imgui.Separator()
	imgui.BeginDisabled()

	env_idx: i32 = 0
	imgui.SliderInt("HDR Env Index", &env_idx, 0, 5)
	imgui.SliderFloat("Env LOD Blur", &placeholder_f, 0.0, 8.0)
	imgui.Checkbox("Screenshot", &placeholder)
	imgui.Checkbox("Hot-Reload Shaders", &placeholder)

	imgui.EndDisabled()
}

// ─── Fuzzy Search ──────────────────────────────────────────────────────────────

// Delegates to the independent search package, converting cstring → string.
@(private)
fuzzy_match :: proc(filter: cstring, label: string, keywords: string) -> bool {
	return search.fuzzy_match(string(filter), label, keywords)
}

// Filtered view: draws all parameters that match, grouped by category.
@(private)
draw_filtered_view :: proc(g: ^Gui, state: Scene_State, filter: cstring) {
	match_count := 0

	c := state.camera

	// ── Camera params ──
	if section_has_matches(filter, CAMERA_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Camera")
		imgui.Separator()

		if c != nil {
			if fuzzy_match(filter, "Speed", "camera movement velocity") {
				imgui.SliderFloat("Speed", &c.velocity, 1.0, 100.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Acceleration", "camera movement accel") {
				imgui.SliderFloat("Acceleration", &c.acceleration, 1.0, 50.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Friction", "camera movement decel damping") {
				imgui.SliderFloat("Friction", &c.friction, 0.5, 0.99)
				match_count += 1
			}
			if fuzzy_match(filter, "Sensitivity", "camera mouse rotation") {
				imgui.SliderFloat("Sensitivity", &c.sensitivity, 0.01, 1.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Rotation Smoothing", "camera interpolation lerp") {
				imgui.SliderFloat("Rotation Smoothing", &c.rotation_smoothing, 0.0, 0.5)
				match_count += 1
			}
			if fuzzy_match(filter, "Mouse Smoothing", "camera input filter") {
				imgui.SliderFloat("Mouse Smoothing", &c.mouse_smoothing_factor, 0.0, 0.5)
				match_count += 1
			}
			if fuzzy_match(filter, "FOV", "camera field of view zoom projection") {
				imgui.SliderFloat("FOV", &c.zoom, 10.0, 120.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Head Bobbing", "camera walk bob oscillation") {
				imgui.Checkbox("Head Bobbing", &c.bobbing_enabled)
				match_count += 1
			}
			if fuzzy_match(filter, "Bobbing Frequency", "camera walk bob speed") {
				imgui.SliderFloat("Bobbing Freq", &c.bobbing_frequency, 0.5, 10.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Bobbing Amplitude", "camera walk bob height") {
				imgui.SliderFloat("Bobbing Amp", &c.bobbing_amplitude, 0.0, 0.01)
				match_count += 1
			}
		}
		imgui.Spacing()
	}

	// ── Scene params ──
	if section_has_matches(filter, SCENE_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Scene")
		imgui.Separator()

		if fuzzy_match(filter, "Skybox", "environment background visible toggle") {
			imgui.Checkbox("Skybox", state.skybox_visible)
			match_count += 1
		}
		if fuzzy_match(filter, "Skybox Blur", "environment lod mip") {
			imgui.SliderFloat("Skybox Blur", state.skybox_blur_lod, 0.0, 8.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Exposure", "tone mapping hdr brightness") {
			imgui.BeginDisabled()
			imgui.SliderFloat("Exposure", state.exposure, 0.1, 10.0)
			imgui.EndDisabled()
			match_count += 1
		}
		if fuzzy_match(filter, "Wireframe", "debug mesh polygon lines") {
			imgui.Checkbox("Wireframe", state.wireframe_enabled)
			match_count += 1
		}
		imgui.Spacing()
	}

	// ── Rendering / Post-FX params ──
	if section_has_matches(filter, RENDERING_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Rendering")
		imgui.Separator()

		// Live PostFX controls
		match_count += draw_postfx_filtered(state, filter)

		// PBR debug (still disabled)
		imgui.BeginDisabled()

		if fuzzy_match(filter, "PBR Debug Mode", "rendering albedo normal metallic roughness ao irradiance prefilter brdf") {
			pbr_debug_mode: i32 = 0
			imgui.Combo("Debug Mode", &pbr_debug_mode,
				"Final PBR\x00Albedo\x00Normal\x00Metallic\x00Roughness\x00AO\x00Irradiance\x00Prefilter\x00BRDF LUT\x00GI Probes\x00")
			match_count += 1
		}
		if fuzzy_match(filter, "Specular Anti-Aliasing", "rendering aa filtering") {
			placeholder_aa := false
			imgui.Checkbox("Specular Anti-Aliasing", &placeholder_aa)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	// ── Debug Views ──
	if section_has_matches(filter, DEBUG_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Debug")
		imgui.Separator()
		imgui.BeginDisabled()

		placeholder := false

		if fuzzy_match(filter, "Bloom Debug", "glow visualization") {
			imgui.Checkbox("Bloom Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "DoF Debug", "depth focus visualization") {
			imgui.Checkbox("DoF Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Exposure Histogram", "luminance distribution") {
			imgui.Checkbox("Exposure Histogram", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Motion Blur Debug", "velocity visualization") {
			imgui.Checkbox("Motion Blur Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "FXAA Debug", "edge detection visualization") {
			imgui.Checkbox("FXAA Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Stencil Debug", "mask buffer") {
			imgui.Checkbox("Stencil Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "GPU Timeline", "profiling performance timing") {
			imgui.Checkbox("GPU Timeline", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "GPU Metrics Log", "profiling performance stats") {
			imgui.Checkbox("GPU Metrics Log", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Perf Mode", "profiling fps benchmark") {
			imgui.Checkbox("Perf Mode", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Light Probes Debug", "gi global illumination") {
			imgui.Checkbox("Light Probes Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "N-Body Simulation", "physics particles gravity") {
			imgui.Checkbox("N-Body Simulation", &placeholder)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	// ── Environment ──
	if section_has_matches(filter, ENV_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Environment")
		imgui.Separator()
		imgui.BeginDisabled()

		placeholder := false
		placeholder_f: f32 = 0.5
		env_idx: i32 = 0

		if fuzzy_match(filter, "HDR Env Index", "environment map cycling skybox") {
			imgui.SliderInt("HDR Env Index", &env_idx, 0, 5)
			match_count += 1
		}
		if fuzzy_match(filter, "Env LOD Blur", "environment mip background") {
			imgui.SliderFloat("Env LOD Blur", &placeholder_f, 0.0, 8.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Screenshot", "capture image save") {
			imgui.Checkbox("Screenshot", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Hot-Reload Shaders", "reload recompile glsl") {
			imgui.Checkbox("Hot-Reload Shaders", &placeholder)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	// ── IBL Debug ──
	if section_has_matches(filter, IBL_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "IBL Debug")
		imgui.SameLine()
		ibl_goto_button(g, .None)
		imgui.Separator()

		if fuzzy_match(filter, "Preview Size", "ibl debug texture preview zoom size") {
			imgui.SliderFloat("Preview Size", &g.ibl_preview_size, 64.0, 512.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Mip Level (Roughness)", "ibl prefilter specular mip roughness level") {
			imgui.SliderInt("Mip Level (Roughness)", &g.ibl_mip_level, 0, IBL_PREFILTER_MIP_LEVELS - 1)
			match_count += 1
		}
		if fuzzy_match(filter, "Environment Map", "ibl hdr source environment map texture gpu") {
			ibl_goto_button(g, .Env_Map)
			imgui.Text("Env HDR: ID=%d (%dx%d)",
				state.env_texture_id, state.env_texture_width, state.env_texture_height)
			match_count += 1
		}
		if fuzzy_match(filter, "Irradiance Map", "ibl diffuse irradiance convolution texture gpu") {
			ibl_goto_button(g, .Irradiance)
			imgui.Text("Irradiance: ID=%d (%dx%d)",
				state.ibl_irradiance_map, IBL_IRRADIANCE_SIZE * 2, IBL_IRRADIANCE_SIZE)
			match_count += 1
		}
		if fuzzy_match(filter, "Prefilter Map", "ibl specular prefilter ggx split sum texture gpu") {
			ibl_goto_button(g, .Prefilter)
			imgui.Text("Prefilter: ID=%d (%dx%d, %d mips)",
				state.ibl_prefilter_map, IBL_PREFILTER_SIZE * 2, IBL_PREFILTER_SIZE, IBL_PREFILTER_MIP_LEVELS)
			match_count += 1
		}
		if fuzzy_match(filter, "BRDF LUT", "ibl split sum brdf lookup table texture gpu") {
			ibl_goto_button(g, .BRDF_LUT)
			imgui.Text("BRDF LUT: ID=%d (%dx%d)",
				state.ibl_brdf_lut, IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE)
			match_count += 1
		}
		if fuzzy_match(filter, "GPU Memory Estimate", "gpu vram memory estimation usage size textures") {
			imgui.PushIDInt(99)
			if imgui.SmallButton("Go To") {
				g.ibl_debug_open = true
				g.search_buf = {}
			}
			imgui.PopID()
			imgui.Text("GPU Memory: see IBL Debug tab")
			match_count += 1
		}
		imgui.Spacing()
	}

	if match_count == 0 {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "No matching parameters")
	}
}

// Check if ANY param in a keyword group matches (used to show/hide section headers).
@(private)
section_has_matches :: proc(filter: cstring, section_keywords: string) -> bool {
	return search.section_has_matches(string(filter), section_keywords)
}

// Navigate from search result to a specific IBL texture section.
@(private)
ibl_goto_button :: proc(g: ^Gui, target: IBL_Scroll_Target) {
	imgui.PushIDInt(i32(target))
	if imgui.SmallButton("Go To") {
		g.ibl_debug_open = true
		g.ibl_scroll_target = target
		g.search_buf = {}
	}
	imgui.PopID()
}

// Keyword constants for section-level pre-filtering.
@(private)
CAMERA_KEYWORDS :: "camera speed acceleration friction sensitivity smoothing fov bobbing zoom projection mouse movement"

@(private)
SCENE_KEYWORDS :: "scene skybox blur exposure wireframe toggle environment background tone mapping hdr mesh polygon"

@(private)
RENDERING_KEYWORDS :: "rendering postfx post-processing post processing pbr debug mode albedo normal metallic roughness ao bloom dof depth field fxaa motion blur vignette grain aberration grading lut irradiance prefilter brdf specular anti-aliasing post effect glow focus exposure tonemap tonemapping saturation contrast gamma"

@(private)
DEBUG_KEYWORDS :: "debug debug views bloom dof exposure histogram fxaa stencil gpu timeline metrics perf profiling probes gi n-body simulation physics visualization"

@(private)
ENV_KEYWORDS :: "environment hdr env lod blur screenshot capture reload shaders glsl cycling skybox map"

@(private)
IBL_KEYWORDS :: "ibl debug irradiance prefilter specular diffuse brdf lut split sum texture gpu memory estimate estimation vram mip roughness preview environment map hdr convolution ggx"
