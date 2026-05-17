// +build test
// GL context tests for Dear ImGui integration.
// Validates init/destroy lifecycle, keyboard/mouse capture queries, and toggle behavior.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
package test_gl

import "core:testing"

import imgui "../../deps/odin-imgui"
import gui "../../src/gui"
import cam "../../src/camera"

// --- ImGui lifecycle tests ---

@(test)
test_gui_init_destroy :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	g: gui.Gui
	ok := gui.init(&g, gl_window)
	testing.expect(t, ok, "gui.init should succeed with valid GL context")
	testing.expect(t, g.ctx != nil, "ImGui context should be non-nil after init")
	testing.expect(t, g.visible, "GUI should be visible by default")

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

	testing.expect(t, g.visible, "initially visible")

	gui.toggle(&g)
	testing.expect(t, !g.visible, "should be hidden after first toggle")

	gui.toggle(&g)
	testing.expect(t, g.visible, "should be visible after second toggle")
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
