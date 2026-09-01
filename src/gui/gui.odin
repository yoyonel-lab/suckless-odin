package gui

import "core:math"
import "vendor:glfw"
import gl "vendor:OpenGL"

import imgui "../../deps/odin-imgui"
import "../../deps/odin-imgui/imgui_impl_glfw"
import "../../deps/odin-imgui/imgui_impl_opengl3"

import cam "../camera"
import mt "../core/math_types"
import "../core/search"
import settings "../core/settings"
import perf_mode "../core/perf_mode"
import postfx "../rendering/postfx"
import rendering "../rendering"
import types "../rendering/types"

// Forward-declare scene data needed by GUI panels.
// Avoids circular import by accepting raw pointers from app.
Scene_State :: struct {
	camera:            ^cam.Camera,
	skybox_visible:    ^bool,
	wireframe_enabled: ^bool,
	exposure:          ^f32,
	skybox_blur_lod:   ^f32,
	skybox_mode:       ^rendering.Skybox_Mode,
	mipmap_mode:       ^rendering.Mipmap_Mode,
	blur_source:       ^rendering.Blur_Source,
	cubemap_dirty:     ^bool,
	show_mipmap_diff:  ^bool,
	diff_gain:         ^f32,
	sort_mode:         ^rendering.Sort_Mode,
	edge_aa_enabled:   ^bool,
	edge_aa_debug:     ^bool,
	specular_aa_enabled: ^bool,
	specular_aa_mode:    ^types.Specular_AA_Mode,
	specular_aa_debug_mode: ^types.Specular_AA_Debug_Mode,
	specular_aa_split_enabled:  ^bool,
	specular_aa_split_position: ^f32,

	// Post-processing pipeline (live controls)
	postfx: ^postfx.Pipeline,

	// Performance mode (optional — nil if not available)
	perf: ^perf_mode.Perf_Mode,

	// Point Light & Shadows (Phase 1)
	point_light:    ^rendering.Point_Light,
	shadow_cubemap: ^rendering.Shadow_Cubemap,

	// Volumetric Lighting & Depth Downsampling (Phase 2 & 3)
	depth_downsample: ^rendering.Depth_Downsample,
	volumetric:       ^rendering.Volumetric_Renderer,

	// Smoothed frame time from overlay (single source of truth)
	frame_time_ms: f32,

	// IBL debug textures (GL handles)
	ibl_irradiance_map: u32,
	ibl_prefilter_map:  u32,
	ibl_brdf_lut:       u32,
	env_texture_id:     u32,
	env_texture_width:  i32,
	env_texture_height: i32,

	// Compute tuning callback & live reference
	live_compute_tuning:  ^settings.Compute_Tuning_Params,
	apply_compute_tuning: proc(scene_ptr: rawptr, params: settings.Compute_Tuning_Params) -> bool,
	scene_ptr:            rawptr,
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
	active_tab:       i32,
	restore_tab:      i32, // Frame counter for SetSelected (needs 2 frames)
	search_buf:       [SEARCH_BUF_SIZE]u8,
	focus_search:     bool,
	ibl_debug_open:   bool,
	ibl_scroll_target: IBL_Scroll_Target,
	ibl_preview_size: f32,
	ibl_mip_level:    i32,
	ibl_prefilter_id: u32, // Tracked for LOD restore after render
	ibl_debug_exposure: f32, // EV stops for debug preview tint (0 = neutral)
	inspector_fbo:    u32, // Reusable FBO for pixel readback

	// Pixel inspector state (click-to-lock)
	inspect_active:   bool,
	inspect_uv:       [2]f32, // Locked UV position
	inspect_tex_id:   u32,    // Which texture is being inspected
	inspect_tex_w:    i32,
	inspect_tex_h:    i32,
	inspect_mip:      i32,
	inspect_pixel:    [4]f32, // Last read pixel value

	// Compute Tuning interface state
	compute_tuning_loaded:       bool,
	compute_tuning_config:       settings.Compute_Tuning_Config,
	compute_tuning_selected_idx: i32,
	compute_tuning_draft:        settings.Compute_Tuning_Params,
	compute_tuning_save_name:    [64]u8,
	compute_tuning_status_msg:   cstring,
	compute_tuning_status_timer: f32,
	compute_tuning_error_msg:    cstring,
	compute_tuning_error_timer:  f32,
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

	guizmo_set_imgui_context(g.ctx)

	return true
}

new_frame :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui_impl_opengl3.NewFrame()
	imgui_impl_glfw.NewFrame()
	imgui.NewFrame()
	guizmo_begin_frame()
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
				tab_flags :: proc(g: ^Gui, idx: i32) -> imgui.TabItemFlags {
					if g.restore_tab > 0 && g.active_tab == idx {
						return {.SetSelected}
					}
					return {}
				}
				restoring := g.restore_tab > 0
				if imgui.BeginTabItem("Camera", flags = tab_flags(g, 0)) {
					if !restoring { g.active_tab = 0 }
					draw_tab_camera(state.camera)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Scene", flags = tab_flags(g, 1)) {
					if !restoring { g.active_tab = 1 }
					draw_tab_scene(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Rendering", flags = tab_flags(g, 2)) {
					if !restoring { g.active_tab = 2 }
					draw_tab_rendering(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Post-FX", flags = tab_flags(g, 3)) {
					if !restoring { g.active_tab = 3 }
					draw_postfx_section(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("MBlur", flags = tab_flags(g, 4)) {
					if !restoring { g.active_tab = 4 }
					draw_tab_motion_blur(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Profiling", flags = tab_flags(g, 5)) {
					if !restoring { g.active_tab = 5 }
					draw_gpu_timings_section(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Shaders", flags = tab_flags(g, 6)) {
					if !restoring { g.active_tab = 6 }
					draw_shader_cache_section(state)
					imgui.EndTabItem()
				}
				ibl_flags := tab_flags(g, 7)
				if g.ibl_debug_open {
					ibl_flags += {.SetSelected}
				}
				if imgui.BeginTabItem("IBL Debug", flags = ibl_flags) {
					if !restoring { g.active_tab = 7 }
					g.ibl_debug_open = false
					draw_tab_ibl_debug(g, state)
					imgui.EndTabItem()
				} else {
					g.ibl_debug_open = false
				}
				if imgui.BeginTabItem("Compute Tuning", flags = tab_flags(g, 8)) {
					if !restoring { g.active_tab = 8 }
					draw_tab_compute_tuning(g, state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Shadows", flags = tab_flags(g, 9)) {
					if !restoring { g.active_tab = 9 }
					draw_tab_shadows(g, state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Volumetric", flags = tab_flags(g, 10)) {
					if !restoring { g.active_tab = 10 }
					draw_tab_volumetric(g, state)
					imgui.EndTabItem()
				}
				if g.restore_tab > 0 {
					g.restore_tab -= 1
				}
				imgui.EndTabBar()
			}
		}
	}
	imgui.End()

	// 3D Viewport Interactive Controls (ImGuizmo)
	draw_point_light_gizmo(state)
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
	if g.compute_tuning_loaded {
		settings.destroy_compute_tuning_config(&g.compute_tuning_config)
		g.compute_tuning_loaded = false
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
	if guizmo_is_over() || guizmo_is_using() { return true }
	if !g.visible { return false }
	io := imgui.GetIO()
	return io.WantCaptureMouse
}

// ─── 3D Interactive Viewport Gizmo (ImGuizmo) ──────────────────────────────────

@(private)
draw_point_light_gizmo :: proc(state: Scene_State) {
	light := state.point_light
	c := state.camera
	if light == nil || c == nil || !light.enabled || !light.show_gizmo {
		return
	}

	io := imgui.GetIO()
	guizmo_set_rect(0, 0, io.DisplaySize.x, io.DisplaySize.y)
	guizmo_set_orthographic(false)

	view := cam.get_view_matrix(c)
	aspect := io.DisplaySize.x / max(io.DisplaySize.y, 1.0)
	fov_rad := math.to_radians(c.zoom)
	proj := mt.perspective(fov_rad, aspect, settings.NEAR_PLANE, settings.FAR_PLANE)

	light_pos := light.orbit_center if light.is_animated else light.position
	model := mt.mat4_translate(light_pos)

	op: Guizmo_Operation
	switch light.gizmo_op {
	case 1: op = .Rotate
	case 2: op = .Scale
	case 3: op = .Universal
	case:   op = .Translate
	}

	mode: Guizmo_Mode = .World if light.gizmo_mode == 0 else .Local

	snap_val: [3]f32
	snap_ptr: [^]f32 = nil
	if light.gizmo_snap {
		snap_val = {light.gizmo_snap_value, light.gizmo_snap_value, light.gizmo_snap_value}
		snap_ptr = &snap_val[0]
	}

	manipulated := guizmo_manipulate(
		&view[0][0],
		&proj[0][0],
		op,
		mode,
		&model[0][0],
		nil,
		snap_ptr,
	)

	is_using := guizmo_is_using()
	light.is_interacting = is_using

	if manipulated || is_using {
		new_pos := mt.Vec3{model[3][0], model[3][1], model[3][2]}
		if light.is_animated {
			light.orbit_center = new_pos
		} else {
			light.position = new_pos
		}
		light.motion_cooldown = 0.40
		light.is_dirty = true
	}
}

// ─── Tab: Camera ───────────────────────────────────────────────────────────────

@(private)
draw_tab_camera :: proc(c: ^cam.Camera) {
	if c == nil { return }

	imgui.Text("Position: %.1f, %.1f, %.1f", c.position.x, c.position.y, c.position.z)
	imgui.Text("Yaw: %.1f  Pitch: %.1f", c.yaw, c.pitch)
	imgui.Separator()

	imgui.SliderFloat("Speed", &c.velocity, 1.0, 100.0)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Maximum movement speed (units/sec)\nHigher = faster camera travel")
	}
	imgui.SliderFloat("Acceleration", &c.acceleration, 1.0, 50.0)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("How quickly camera reaches max speed\nHigher = snappier response, Lower = more inertia")
	}
	imgui.SliderFloat("Friction", &c.friction, 0.5, 0.99)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Velocity damping per frame\n0.5 = stops fast (heavy), 0.99 = slides long (ice)")
	}
	imgui.SliderFloat("Sensitivity", &c.sensitivity, 0.01, 1.0)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Mouse look sensitivity\nMultiplier on raw mouse delta for yaw/pitch rotation")
	}
	imgui.SliderFloat("Rotation Smoothing", &c.rotation_smoothing, 0.0, 0.5)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Lerp factor for yaw/pitch interpolation\n0 = instant (no smoothing), 0.5 = heavy lag")
	}
	imgui.SliderFloat("Mouse Smoothing", &c.mouse_smoothing_factor, 0.0, 0.5)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("EMA filter on raw mouse input\n0 = raw (no filter), 0.5 = heavy averaging\nReduces jitter at cost of latency")
	}
	imgui.SliderFloat("FOV", &c.zoom, 10.0, 120.0)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Vertical field of view (degrees)\n60 = standard, 90 = wide, 10 = telephoto zoom")
	}
	imgui.Separator()

	imgui.Checkbox("Head Bobbing", &c.bobbing_enabled)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Simulates head bob during movement\nAdds subtle vertical oscillation to camera position")
	}
	if c.bobbing_enabled {
		imgui.SliderFloat("Bobbing Freq", &c.bobbing_frequency, 0.5, 10.0)
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Oscillation frequency (Hz)\nHigher = faster bobbing cycle")
		}
		imgui.SliderFloat("Bobbing Amp", &c.bobbing_amplitude, 0.0, 0.01)
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Vertical displacement amplitude (world units)\nHigher = more pronounced head movement")
		}
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
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("LOD level for background blur\n0 = sharp, 8 = maximum blur\nUses mipmap or prefilter depending on Blur Source")
	}
	if state.blur_source != nil {
		src_val := i32(state.blur_source^)
		if imgui.Combo("Blur Source", &src_val, "Mipmap LOD\x00IBL Prefilter\x00") {
			state.blur_source^ = rendering.Blur_Source(src_val)
		}
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Mipmap LOD: standard GL mipmaps (box filter)\nIBL Prefilter: physically-based specular convolution\n(smoother, more accurate at high blur)")
		}
	}
	if state.skybox_mode != nil {
		mode_val := i32(state.skybox_mode^)
		if imgui.Combo("Skybox Mode", &mode_val, "Equirectangular\x00Cubemap\x00") {
			state.skybox_mode^ = rendering.Skybox_Mode(mode_val)
			// Trigger lazy cubemap generation when switching to Cubemap mode
			if state.skybox_mode^ == .Cubemap && state.cubemap_dirty != nil {
				state.cubemap_dirty^ = true
			}
		}
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Equirectangular: sample HDR directly (2D texture)\nCubemap: pre-converted 6-face cube\n(required for seamless mipmap filtering)")
		}
	}
	if state.mipmap_mode != nil {
		mip_val := i32(state.mipmap_mode^)
		if imgui.Combo("Cubemap Mipmaps", &mip_val, "glGenerateMipmap\x00Seamless (cross-face)\x00") {
			state.mipmap_mode^ = rendering.Mipmap_Mode(mip_val)
			if state.cubemap_dirty != nil {
				state.cubemap_dirty^ = true
			}
		}
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("glGenerateMipmap: fast, may have seams at cube edges\nSeamless (cross-face): custom downsampler\nthat blends across cube face boundaries")
		}
	}
	if state.show_mipmap_diff != nil {
		imgui.Checkbox("Show Blur Diff", state.show_mipmap_diff)
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Visualize difference between Mipmap and Prefilter blur\nShows where the two methods diverge\nAmplified by Diff Gain slider")
		}
		if state.show_mipmap_diff^ && state.diff_gain != nil {
			imgui.SliderFloat("Diff Gain", state.diff_gain, 1.0, 100.0)
		}
	}
	imgui.Separator()

	imgui.Checkbox("Wireframe", state.wireframe_enabled)
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Render billboard quads as wireframe\nShows the actual quad geometry used for raymarching")
	}
	imgui.Separator()

	// Sort Mode
	if state.sort_mode != nil {
		sort_val := i32(state.sort_mode^)
		if imgui.Combo("Sort Mode", &sort_val, "None\x00CPU (qsort)\x00CPU (Radix)\x00") {
			state.sort_mode^ = rendering.Sort_Mode(sort_val)
		}
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Billboard draw order for correct transparency:\n- None: arbitrary (fast, may have artifacts)\n- CPU qsort: O(n log n) comparison sort\n- CPU Radix: O(n) stable sort (recommended)")
		}
	}
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
	tint := math.pow(f32(2.0), g.ibl_debug_exposure)
	imgui.ImageWithBg(gl_tex_ref(tex_id), display_size, {0, 1}, {1, 0}, {0, 0, 0, 0}, {tint, tint, tint, 1})

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
draw_ibl_debug_env_map :: proc(g: ^Gui, state: Scene_State, preview_w, preview_h: f32) {
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
}

@(private)
draw_ibl_debug_irradiance :: proc(g: ^Gui, state: Scene_State, preview_w: f32) {
	if state.ibl_irradiance_map != 0 {
		if g.ibl_scroll_target == .Irradiance {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("Irradiance Map (Diffuse IBL)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Format: RGBA16F",
				state.ibl_irradiance_map, IBL_IRRADIANCE_SIZE, IBL_IRRADIANCE_SIZE)
			draw_image_with_inspector(g, state.ibl_irradiance_map,
				imgui.Vec2{preview_w, preview_w},
				IBL_IRRADIANCE_SIZE, IBL_IRRADIANCE_SIZE)
			imgui.Spacing()
		}
	}
}

@(private)
draw_ibl_debug_prefilter :: proc(g: ^Gui, state: Scene_State, preview_w: f32) {
	if state.ibl_prefilter_map != 0 {
		if g.ibl_scroll_target == .Prefilter {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("Prefilter Map (Specular IBL)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Mips: %d  Format: RGBA16F",
				state.ibl_prefilter_map, IBL_PREFILTER_SIZE, IBL_PREFILTER_SIZE,
				IBL_PREFILTER_MIP_LEVELS)

			imgui.SliderInt("Mip Level (Roughness)", &g.ibl_mip_level, 0, IBL_PREFILTER_MIP_LEVELS - 1)
			roughness := f32(g.ibl_mip_level) / f32(IBL_PREFILTER_MIP_LEVELS - 1)
			imgui.Text("Roughness: %.2f", roughness)

			// Clamp LOD to force the selected mip level display.
			mip_f := f32(g.ibl_mip_level)
			gl.BindTexture(gl.TEXTURE_2D, state.ibl_prefilter_map)
			gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MIN_LOD, mip_f)
			gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_MAX_LOD, mip_f)
			gl.BindTexture(gl.TEXTURE_2D, 0)
			g.ibl_prefilter_id = state.ibl_prefilter_map

			draw_image_with_inspector(g, state.ibl_prefilter_map,
				imgui.Vec2{preview_w, preview_w},
				IBL_PREFILTER_SIZE, IBL_PREFILTER_SIZE, g.ibl_mip_level)

			imgui.Spacing()
		}
	}
}

@(private)
draw_ibl_debug_brdf_lut :: proc(g: ^Gui, state: Scene_State, preview_w: f32) {
	if state.ibl_brdf_lut != 0 {
		if g.ibl_scroll_target == .BRDF_LUT {
			imgui.SetScrollHereY(0.0)
			g.ibl_scroll_target = .None
		}
		if imgui.CollapsingHeader("BRDF LUT (Split-Sum)", {.DefaultOpen}) {
			imgui.Text("ID: %d  Size: %dx%d  Format: RG16F",
				state.ibl_brdf_lut, IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE)
			imgui.Text("X-axis: NdotV | Y-axis: Roughness")
			draw_image_with_inspector(g, state.ibl_brdf_lut,
				imgui.Vec2{preview_w, preview_w},
				IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE)
			imgui.Spacing()
		}
	}
}

@(private)
draw_ibl_debug_memory_estimate :: proc(state: Scene_State) {
	imgui.Separator()
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "GPU Memory Estimate")
	env_kb := (state.env_texture_width * state.env_texture_height * 8 * 4 / 3) / 1024
	irr_kb := i32((IBL_IRRADIANCE_SIZE * IBL_IRRADIANCE_SIZE * 8) / 1024)
	brdf_kb := i32((IBL_BRDF_LUT_SIZE * IBL_BRDF_LUT_SIZE * 4) / 1024)
	pf_bytes: i32 = 0
	for mip in 0 ..< IBL_PREFILTER_MIP_LEVELS {
		mip_w := max(i32(1), IBL_PREFILTER_SIZE >> u32(mip))
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

@(private)
draw_tab_ibl_debug :: proc(g: ^Gui, state: Scene_State) {
	imgui.SliderFloat("Preview Size", &g.ibl_preview_size, 64.0, 512.0)
	imgui.SliderFloat("Preview Exposure (EV)", &g.ibl_debug_exposure, -6.0, 6.0)
	if imgui.IsItemDeactivatedAfterEdit() || imgui.IsItemClicked(.Right) {
		g.ibl_debug_exposure = 0.0
	}
	imgui.Separator()

	preview_w := g.ibl_preview_size
	preview_h := preview_w * 0.5

	draw_ibl_debug_env_map(g, state, preview_w, preview_h)
	draw_ibl_debug_irradiance(g, state, preview_w)
	draw_ibl_debug_prefilter(g, state, preview_w)
	draw_ibl_debug_brdf_lut(g, state, preview_w)
	draw_ibl_debug_memory_estimate(state)
}

@(private)
draw_rendering_edge_aa :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Edge Anti-Aliasing")
	imgui.Separator()
	if state.edge_aa_enabled != nil {
		imgui.Checkbox("Edge AA##edge", state.edge_aa_enabled)
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Analytic billboard edge smoothing\n(smoothstep on ray-sphere discriminant)")
		}
		if state.edge_aa_debug != nil {
			imgui.Checkbox("Debug View (Grayscale)##edge_dbg", state.edge_aa_debug)
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Heatmap of edge factor:\n- Dark interior = fully opaque (factor ~1.0)\n- Red = near edge (factor -> 0)\n- Yellow/Green = transition zone\nBand should be ~1px at silhouette")
			}
		}
	}
}

@(private)
draw_rendering_pbr_debug :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "PBR Debug Modes")
	imgui.Separator()

	imgui.BeginDisabled()
	pbr_debug_mode: i32 = 0
	imgui.Combo("Debug Mode", &pbr_debug_mode,
		"Final PBR\x00Albedo\x00Normal\x00Metallic\x00Roughness\x00AO\x00Irradiance (Diff)\x00Prefilter (Spec)\x00BRDF LUT\x00GI Probes\x00")
	imgui.EndDisabled()

	if state.specular_aa_enabled != nil {
		imgui.Checkbox("Specular Anti-Aliasing", state.specular_aa_enabled)
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Screen-space roughness clamping to mitigate specular aliasing\nusing variance-based (Varef) microfacet distribution filtering")
		}

		if state.specular_aa_enabled^ && state.specular_aa_mode != nil {
			mode_val := i32(state.specular_aa_mode^)
			if imgui.Combo("Specular AA Mode", &mode_val, "Screen-Space\x00Curvature\x00") {
				state.specular_aa_mode^ = types.Specular_AA_Mode(mode_val)
			}
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Screen-Space: GPU derivatives based on normal maps/geometry\nCurvature: Analytic pixel-to-sphere radius ratio")
			}

			if state.specular_aa_debug_mode != nil {
				debug_val := i32(state.specular_aa_debug_mode^)
				if imgui.Combo("Debug View##spec_dbg", &debug_val, "Off\x00Grayscale Variance\x00Amplified Difference\x00") {
					state.specular_aa_debug_mode^ = types.Specular_AA_Debug_Mode(debug_val)
				}
				imgui.SameLine()
				imgui.TextDisabled("(?)")
				if imgui.IsItemHovered() {
					imgui.SetTooltip("Debug views for Specular AA:\n- Off: Normal rendering\n- Grayscale Variance: Heatmap of added variance (white = max variance/clamping)\n- Amplified Difference: Absolute difference between rendering with vs without Specular AA (amplified 10x)")
				}
			}

			if state.specular_aa_split_enabled != nil {
				imgui.Checkbox("A/B Split##specular", state.specular_aa_split_enabled)
				imgui.SameLine()
				imgui.TextDisabled("(?)")
				if imgui.IsItemHovered() {
					imgui.SetTooltip("Compare Specular AA on the left vs bypassed on the right")
				}
				if state.specular_aa_split_enabled^ && state.specular_aa_split_position != nil {
					pos_pct := state.specular_aa_split_position^ * 100.0
					if imgui.SliderFloat("##split_pos_specular", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
						state.specular_aa_split_position^ = pos_pct / 100.0
					}
				}
			}
		}
	}
}

@(private)
draw_rendering_debug_views :: proc() {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Debug Views")
	imgui.Separator()
	placeholder := false
	imgui.BeginDisabled()
	imgui.Checkbox("Fog Debug", &placeholder)
	imgui.Checkbox("Exposure Histogram", &placeholder)
	imgui.Checkbox("Stencil Debug", &placeholder)
	imgui.EndDisabled()
}

@(private)
draw_rendering_profiling :: proc() {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Profiling")
	imgui.Separator()
	placeholder := false
	imgui.BeginDisabled()
	imgui.Checkbox("GPU Timeline", &placeholder)
	imgui.Checkbox("GPU Metrics Log", &placeholder)
	imgui.Checkbox("Perf Mode", &placeholder)
	imgui.Checkbox("Effect Benchmark", &placeholder)
	imgui.EndDisabled()
}

@(private)
draw_rendering_scene_debug :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Scene Debug")
	imgui.Separator()
	imgui.BeginDisabled()
	placeholder := false
	placeholder_f: f32 = 0.0
	imgui.Checkbox("Light Probes Debug", &placeholder)
	imgui.Checkbox("N-Body Simulation", &placeholder)
	imgui.SliderFloat("Sim Speed", &placeholder_f, 0.0, 5.0)
	imgui.SliderFloat("Gravity", &placeholder_f, 0.0, 10.0)
	imgui.Checkbox("Time Reversal", &placeholder)
	gi_mode: i32 = 0
	imgui.Combo("GI Mode", &gi_mode, "OFF\x00Volume 3D Tex\x00SSBO\x00")
	imgui.EndDisabled()
}

@(private)
draw_rendering_env :: proc() {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Environment")
	imgui.Separator()
	imgui.BeginDisabled()
	placeholder := false
	placeholder_f: f32 = 0.0
	env_idx: i32 = 0
	imgui.SliderInt("HDR Env Index", &env_idx, 0, 5)
	imgui.SliderFloat("Env LOD Blur", &placeholder_f, 0.0, 8.0)
	imgui.Checkbox("Screenshot", &placeholder)
	imgui.Checkbox("Hot-Reload Shaders", &placeholder)
	imgui.EndDisabled()
}

@(private)
draw_tab_rendering :: proc(state: Scene_State) {
	draw_rendering_edge_aa(state)
	imgui.Spacing()
	draw_rendering_pbr_debug(state)
	imgui.Spacing()
	draw_rendering_debug_views()
	imgui.Spacing()
	draw_rendering_profiling()
	imgui.Spacing()
	draw_rendering_scene_debug(state)
	imgui.Spacing()
	draw_rendering_env()
}

@(private)
fuzzy_match :: proc(filter: cstring, label: string, keywords: string) -> bool {
	return search.fuzzy_match(string(filter), label, keywords)
}

@(private)
draw_filtered_camera :: proc(c: ^cam.Camera, filter: cstring) -> int {
	match_count := 0
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
	return match_count
}

@(private)
draw_filtered_scene :: proc(state: Scene_State, filter: cstring) -> int {
	match_count := 0
	if fuzzy_match(filter, "Skybox", "environment background visible toggle") {
		imgui.Checkbox("Skybox", state.skybox_visible)
		match_count += 1
	}
	if fuzzy_match(filter, "Skybox Blur", "environment lod mip") {
		imgui.SliderFloat("Skybox Blur", state.skybox_blur_lod, 0.0, 8.0)
		match_count += 1
	}
	if fuzzy_match(filter, "Blur Source", "ibl prefilter mipmap lod") {
		if state.blur_source != nil {
			src_val := i32(state.blur_source^)
			if imgui.Combo("Blur Source", &src_val, "Mipmap LOD\x00IBL Prefilter\x00") {
				state.blur_source^ = rendering.Blur_Source(src_val)
			}
		}
		match_count += 1
	}
	if fuzzy_match(filter, "Skybox Mode", "equirectangular cubemap projection") {
		if state.skybox_mode != nil {
			mode_val := i32(state.skybox_mode^)
			if imgui.Combo("Skybox Mode", &mode_val, "Equirectangular\x00Cubemap\x00") {
				state.skybox_mode^ = rendering.Skybox_Mode(mode_val)
				if state.skybox_mode^ == .Cubemap && state.cubemap_dirty != nil {
					state.cubemap_dirty^ = true
				}
			}
		}
		match_count += 1
	}
	if fuzzy_match(filter, "Cubemap Mipmaps", "seamless cross-face mipmap generation") {
		if state.mipmap_mode != nil {
			mip_val := i32(state.mipmap_mode^)
			if imgui.Combo("Cubemap Mipmaps", &mip_val, "glGenerateMipmap\x00Seamless (cross-face)\x00") {
				state.mipmap_mode^ = rendering.Mipmap_Mode(mip_val)
				if state.cubemap_dirty != nil {
					state.cubemap_dirty^ = true
				}
			}
		}
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
	if fuzzy_match(filter, "Sort Mode", "sorting back-to-front radix qsort depth order") {
		if state.sort_mode != nil {
			sort_val := i32(state.sort_mode^)
			if imgui.Combo("Sort Mode##filt", &sort_val, "None\x00CPU (qsort)\x00CPU (Radix)\x00") {
				state.sort_mode^ = rendering.Sort_Mode(sort_val)
			}
		}
		match_count += 1
	}
	if fuzzy_match(filter, "Specular Anti-Aliasing", "specular aa roughness clamping varef") {
		if state.specular_aa_enabled != nil {
			imgui.Checkbox("Specular Anti-Aliasing", state.specular_aa_enabled)
			if state.specular_aa_enabled^ && state.specular_aa_mode != nil {
				mode_val := i32(state.specular_aa_mode^)
				if imgui.Combo("Specular AA Mode##filt", &mode_val, "Screen-Space\x00Curvature\x00") {
					state.specular_aa_mode^ = types.Specular_AA_Mode(mode_val)
				}
				if state.specular_aa_debug_mode != nil {
					debug_val := i32(state.specular_aa_debug_mode^)
					if imgui.Combo("Debug View##spec_dbg_filt", &debug_val, "Off\x00Grayscale Variance\x00Amplified Difference\x00") {
						state.specular_aa_debug_mode^ = types.Specular_AA_Debug_Mode(debug_val)
					}
				}
				if state.specular_aa_split_enabled != nil {
					imgui.Checkbox("A/B Split##specular_filt", state.specular_aa_split_enabled)
					if state.specular_aa_split_enabled^ && state.specular_aa_split_position != nil {
						pos_pct := state.specular_aa_split_position^ * 100.0
						if imgui.SliderFloat("##split_pos_specular_filt", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
							state.specular_aa_split_position^ = pos_pct / 100.0
						}
					}
				}
			}
		}
		match_count += 1
	}
	return match_count
}

@(private)
draw_filtered_debug :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	match_count := 0
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
	if fuzzy_match(filter, "Motion Blur Debug", "velocity visualization vector field") {
		if state.postfx != nil {
			p := state.postfx
			mb_dbg := postfx.Post_Effect.Motion_Blur_Debug in p.active_effects
			vf_dbg := postfx.Post_Effect.Vector_Field_Debug in p.active_effects
			current_dbg: i32 = 0
			if mb_dbg { current_dbg = 1 }
			if vf_dbg { current_dbg = 2 }
			debug_modes := [3]cstring{"Off", "Velocity (RG)", "Vector Field"}
			if imgui.BeginCombo("MB Debug##filt", debug_modes[current_dbg]) {
				for i in i32(0) ..< 3 {
					if imgui.Selectable(debug_modes[i], i == current_dbg) {
						if .Motion_Blur_Debug in p.active_effects {
							postfx.pipeline_toggle(p, .Motion_Blur_Debug)
						}
						if .Vector_Field_Debug in p.active_effects {
							postfx.pipeline_toggle(p, .Vector_Field_Debug)
						}
						if i == 1 { postfx.pipeline_toggle(p, .Motion_Blur_Debug) }
						if i == 2 { postfx.pipeline_toggle(p, .Vector_Field_Debug) }
					}
				}
				imgui.EndCombo()
			}
		}
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
	if fuzzy_match(filter, "Perf Mode", "performance gamemode sched nice cpu gpu boost priority") {
		draw_perf_mode_widget(state)
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
	return match_count
}

@(private)
draw_filtered_env :: proc(filter: cstring) -> int {
	match_count := 0
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
	return match_count
}

@(private)
draw_filtered_ibl :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	match_count := 0
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
			state.ibl_irradiance_map, IBL_IRRADIANCE_SIZE, IBL_IRRADIANCE_SIZE)
		match_count += 1
	}
	if fuzzy_match(filter, "Prefilter Map", "ibl specular prefilter ggx split sum texture gpu") {
		ibl_goto_button(g, .Prefilter)
		imgui.Text("Prefilter: ID=%d (%dx%d, %d mips)",
			state.ibl_prefilter_map, IBL_PREFILTER_SIZE, IBL_PREFILTER_SIZE, IBL_PREFILTER_MIP_LEVELS)
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
	return match_count
}

@(private)
draw_filtered_view :: proc(g: ^Gui, state: Scene_State, filter: cstring) {
	match_count := 0

	if section_has_matches(filter, CAMERA_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Camera")
		imgui.Separator()
		match_count += draw_filtered_camera(state.camera, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, SCENE_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Scene")
		imgui.Separator()
		match_count += draw_filtered_scene(state, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, RENDERING_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Rendering")
		imgui.Separator()
		match_count += draw_postfx_filtered(state, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, DEBUG_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Debug")
		imgui.Separator()
		imgui.BeginDisabled()
		match_count += draw_filtered_debug(g, state, filter)
		imgui.EndDisabled()
		imgui.Spacing()
	}

	if section_has_matches(filter, ENV_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Environment")
		imgui.Separator()
		imgui.BeginDisabled()
		match_count += draw_filtered_env(filter)
		imgui.EndDisabled()
		imgui.Spacing()
	}

	if section_has_matches(filter, IBL_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "IBL Debug")
		imgui.SameLine()
		ibl_goto_button(g, .None)
		imgui.Separator()
		match_count += draw_filtered_ibl(g, state, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, COMPUTE_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Compute Tuning")
		imgui.SameLine()
		compute_goto_button(g)
		imgui.Separator()
		match_count += draw_filtered_compute(g, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, SHADOW_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Shadows")
		imgui.SameLine()
		shadows_goto_button(g)
		imgui.Separator()
		match_count += draw_filtered_shadows(g, state, filter)
		imgui.Spacing()
	}

	if section_has_matches(filter, VOLUMETRIC_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Volumetric")
		imgui.SameLine()
		volumetric_goto_button(g)
		imgui.Separator()
		match_count += draw_filtered_volumetric(g, state, filter)
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

// Navigate from search result to the Compute Tuning tab.
@(private)
compute_goto_button :: proc(g: ^Gui) {
	imgui.PushID("goto_compute_tuning")
	if imgui.SmallButton("Go To") {
		g.active_tab = 8
		g.restore_tab = 1
		g.search_buf = {}
	}
	imgui.PopID()
}

// Navigate from search result to the Shadows tab.
@(private)
shadows_goto_button :: proc(g: ^Gui) {
	imgui.PushID("goto_shadows")
	if imgui.SmallButton("Go To") {
		g.active_tab = 9
		g.restore_tab = 1
		g.search_buf = {}
	}
	imgui.PopID()
}

// Navigate from search result to the Volumetric tab.
@(private)
volumetric_goto_button :: proc(g: ^Gui) {
	imgui.PushID("goto_volumetric")
	if imgui.SmallButton("Go To") {
		g.active_tab = 10
		g.restore_tab = 1
		g.search_buf = {}
	}
	imgui.PopID()
}

// Keyword constants for section-level pre-filtering.
@(private)
CAMERA_KEYWORDS :: "camera speed acceleration friction sensitivity smoothing fov bobbing zoom projection mouse movement"

@(private)
SCENE_KEYWORDS :: "scene skybox blur exposure wireframe toggle environment background tone mapping hdr mesh polygon sort mode radix cubemap equirectangular projection"

@(private)
RENDERING_KEYWORDS :: "rendering postfx post-processing post processing pbr debug mode albedo normal metallic roughness ao bloom dof depth field fxaa motion blur vignette grain aberration grading lut irradiance prefilter brdf specular anti-aliasing post effect glow focus exposure tonemap tonemapping saturation contrast gamma"

@(private)
DEBUG_KEYWORDS :: "debug debug views bloom dof exposure luminance stops histogram fxaa stencil gpu timeline metrics perf profiling probes gi n-body simulation physics visualization performance gamemode sched nice cpu boost priority"

@(private)
ENV_KEYWORDS :: "environment hdr env lod blur screenshot capture reload shaders glsl cycling skybox map"

@(private)
IBL_KEYWORDS :: "ibl debug irradiance prefilter specular diffuse brdf lut split sum texture gpu memory estimate estimation vram mip roughness preview environment map hdr convolution ggx"

@(private)
COMPUTE_KEYWORDS :: "compute tuning shader progressive slicing dispatch samples workgroup spbrdf irmap spmap slices profile legacy optimized vram timing optimization"

@(private)
SHADOW_KEYWORDS :: "shadow shadows point light cubemap bias normal offset slope rnob ssdb bulb darkening omnidirectional atlas dirty cache time slicing near far pcf vogel disk filter radius jitter stochastic temporal taa reprojection alpha disocclusion clamping debug heatmap penumbra split delta"

@(private)
VOLUMETRIC_KEYWORDS :: "volumetric raymarch raymarching taa reprojection bilateral blur scattering extinction henyey greenstein anisotropy god rays jbu upsample downsample fog mist smoke atmosphere presets"
