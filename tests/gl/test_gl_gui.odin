// +build test
// GL context tests for Dear ImGui integration.
// Validates init/destroy lifecycle, keyboard/mouse capture queries, and toggle behavior.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
package test_gl

import "core:testing"

import imgui "../../deps/odin-imgui"
import gui "../../src/gui"
import cam "../../src/camera"
import rendering "../../src/rendering"
import types "../../src/rendering/types"

// --- ImGui lifecycle tests ---

@(test)
test_gui_init_destroy :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed with valid GL context")
	testing.expect(t, g.ctx != nil, "ImGui context should be non-nil after init")
	testing.expect(t, !g.visible, "GUI should be hidden by default")

	gui.destroy(&g)
	testing.expect(t, g.ctx == nil, "ImGui context should be nil after destroy")
}

@(test)
test_gui_toggle :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	testing.expect(t, !g.visible, "initially hidden")

	gui.toggle(&g)
	testing.expect(t, g.visible, "should be visible after first toggle")

	gui.toggle(&g)
	testing.expect(t, !g.visible, "should be hidden after second toggle")
}

@(test)
test_gui_wants_keyboard_when_hidden :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	g.visible = false
	testing.expect(t, !gui.wants_keyboard(&g),
		"wants_keyboard should be false when GUI is hidden")
}

@(test)
test_gui_wants_mouse_when_hidden :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	g.visible = false
	testing.expect(t, !gui.wants_mouse(&g),
		"wants_mouse should be false when GUI is hidden")
}

@(test)
test_gui_wants_keyboard_no_focus :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	// Run one frame without clicking anything — no widget has focus
	gui.new_frame(&g)
	imgui.EndFrame()

	testing.expect(t, !gui.wants_keyboard(&g),
		"wants_keyboard should be false when no widget has focus")
}

@(test)
test_gui_frame_cycle :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	// A full frame cycle should not crash
	gui.new_frame(&g)

	skybox_vis := true
	wireframe := false
	exposure: f32 = 1.0
	blur_lod: f32 = 0.0
	c: cam.Camera

	state := gui.Scene_State{
		camera           = &c,
		skybox_visible   = &skybox_vis,
		wireframe_enabled = &wireframe,
		exposure         = &exposure,
		skybox_blur_lod  = &blur_lod,
	}
	gui.update(&g, state)
	gui.render(&g)
}

@(test)
test_gui_focus_search_flag :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	// Setting focus_search should be consumed after one frame
	g.visible = true
	g.focus_search = true

	gui.new_frame(&g)

	skybox_vis := true
	wireframe := false
	exposure: f32 = 1.0
	blur_lod: f32 = 0.0
	c: cam.Camera

	state := gui.Scene_State{
		camera           = &c,
		skybox_visible   = &skybox_vis,
		wireframe_enabled = &wireframe,
		exposure         = &exposure,
		skybox_blur_lod  = &blur_lod,
	}
	gui.update(&g, state)
	gui.render(&g)

	testing.expect(t, !g.focus_search,
		"focus_search should be consumed (reset to false) after update")
}

@(test)
test_gui_gizmo_active_when_hidden :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	g.visible = false

	gui.new_frame(&g)

	skybox_vis := true
	wireframe := false
	exposure: f32 = 1.0
	blur_lod: f32 = 0.0
	c: cam.Camera
	cam.init(&c, 5.0, -90.0, 0.0)

	light := rendering.Point_Light{
		position    = {0, 2, 0},
		enabled     = true,
		show_gizmo  = true,
		gizmo_op    = 0, // Translate
		gizmo_mode  = 0, // World
	}

	state := gui.Scene_State{
		camera            = &c,
		skybox_visible    = &skybox_vis,
		wireframe_enabled = &wireframe,
		exposure          = &exposure,
		skybox_blur_lod   = &blur_lod,
		point_light       = &light,
	}

	gui.update(&g, state)
	gui.render(&g)

	testing.expect(t, !g.visible, "GUI should remain hidden")
	testing.expect(t, !gui.wants_keyboard(&g), "wants_keyboard should be false when GUI is hidden")
}

@(test)
test_gui_search_bar_all_queries_e2e :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed")
	defer gui.destroy(&g)

	g.visible = true

	skybox_vis := true
	wireframe := false
	exposure: f32 = 1.0
	blur_lod: f32 = 0.0
	skybox_mode: rendering.Skybox_Mode = .Cubemap
	mipmap_mode: rendering.Mipmap_Mode = .Seamless
	blur_src: rendering.Blur_Source = .IBL_Prefilter
	cubemap_dirty := false
	show_diff := false
	diff_gain: f32 = 10.0
	sort_mode: rendering.Sort_Mode = .CPU
	edge_aa := true
	edge_dbg := false
	spec_aa := true
	spec_aa_mode: types.Specular_AA_Mode = .Curvature
	spec_aa_dbg: types.Specular_AA_Debug_Mode = .Off
	spec_aa_split := false
	spec_aa_split_pos: f32 = 0.5
	c: cam.Camera
	cam.init(&c, 5.0, -90.0, 0.0)

	light := rendering.Point_Light{
		position                   = {0, 2, 0},
		radius                     = 15.0,
		color                      = {1, 1, 1},
		intensity                  = 2.5,
		enabled                    = true,
		direct_shadows_enabled     = true,
		shadow_bias                = 0.0015,
		shadow_normal_bias         = 0.025,
		shadow_slope_bias          = 0.0010,
		shadow_darkening           = 0.5,
		shadow_debug_mask          = false,
		shadow_debug_mode          = 0,
		shadow_split_position      = 0.5,
		shadow_pcf_samples         = 8,
		shadow_filter_radius       = 0.015,
		shadow_pcf_jitter          = true,
		shadow_temporal_jitter     = true,
		shadow_taa_enabled         = true,
		shadow_taa_mode            = 2,
		shadow_taa_alpha           = 0.15,
		shadow_taa_depth_threshold = 0.30,
		shadow_taa_clamping        = true,
		show_bulb                  = true,
		bulb_radius                = 0.45,
		show_gizmo                 = true,
		gizmo_op                   = 0,
		gizmo_mode                 = 0,
	}

	sc: rendering.Shadow_Cubemap
	rendering.shadow_cubemap_create(&sc, 256)
	defer rendering.shadow_cubemap_destroy(&sc)

	depth_down: rendering.Depth_Downsample
	rendering.depth_downsample_create(&depth_down, 800, 600)
	defer rendering.depth_downsample_destroy(&depth_down)

	vol: rendering.Volumetric_Renderer
	rendering.volumetric_create(&vol, 800, 600)
	defer rendering.volumetric_destroy(&vol)

	opt_prof: rendering.Optimization_Profile = .Quality
	curr_hdr: i32 = 0

	state := gui.Scene_State{
		camera                     = &c,
		skybox_visible             = &skybox_vis,
		wireframe_enabled          = &wireframe,
		exposure                   = &exposure,
		skybox_blur_lod            = &blur_lod,
		skybox_mode                = &skybox_mode,
		mipmap_mode                = &mipmap_mode,
		blur_source                = &blur_src,
		cubemap_dirty              = &cubemap_dirty,
		show_mipmap_diff           = &show_diff,
		diff_gain                  = &diff_gain,
		sort_mode                  = &sort_mode,
		edge_aa_enabled            = &edge_aa,
		edge_aa_debug              = &edge_dbg,
		specular_aa_enabled        = &spec_aa,
		specular_aa_mode           = &spec_aa_mode,
		specular_aa_debug_mode     = &spec_aa_dbg,
		specular_aa_split_enabled  = &spec_aa_split,
		specular_aa_split_position = &spec_aa_split_pos,
		point_light                = &light,
		shadow_cubemap             = &sc,
		depth_downsample           = &depth_down,
		volumetric                 = &vol,
		optimization_profile       = &opt_prof,
		env_texture_id             = 1,
		env_texture_width          = 4096,
		env_texture_height         = 2048,
		hdr_files                  = []string{"assets/textures/hdr/cedar_bridge_2_4k.hdr"},
		current_hdr_index          = &curr_hdr,
		env_thumbnails             = []rendering.Env_Thumbnail{
			{path = "assets/textures/hdr/cedar_bridge_2_4k.hdr", filename = "cedar_bridge_2_4k.hdr", display_name = "Cedar Bridge", width = 4096, height = 2048},
		},
	}

	queries := [?]string{
		"c", "s", "p", "a", "l", "shadow", "split", "pbr", "vogel", "pcf",
		"darkening", "bias", "normal", "slope", "taa", "bulb", "gizmo",
		"light", "volumetric", "raymarch", "beer", "mie", "step", "jbu",
		"downsample", "camera", "scene", "rendering", "blur", "tonemap",
		"exposure", "bloom", "dof", "motion", "fxaa", "opt", "quality",
		"balanced", "ultra", "env", "cube", "resolution", "slice",
	}

	for q in queries {
		gui.new_frame(&g)

		// Inject query into search buffer
		g.search_buf = {}
		copy(g.search_buf[:], q)

		gui.update(&g, state)
		gui.render(&g)
	}

	testing.expect(t, true, "All search filter queries processed without crashing")
}
