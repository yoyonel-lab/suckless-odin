package tests

import "core:testing"
import "core:os"
import "core:math"
import mt "../src/core/math_types"

import session "../src/core/session"
import postfx "../src/rendering/postfx"

@(test)
test_session_save_load :: proc(t: ^testing.T) {
	test_file := "test_session_1.json"
	defer os.remove(test_file)
	
	// Create test state with unique values
	state_to_save: session.Session_State
	state_to_save.window_pos = {123, 456}
	state_to_save.window_size = {1920, 1080}
	
	state_to_save.camera_pos = {1.0, 2.0, 3.0}
	state_to_save.camera_yaw = 45.0
	state_to_save.camera_pitch = 15.0
	state_to_save.camera_zoom = 2.0
	
	state_to_save.exposure = 1.5
	state_to_save.wireframe_enabled = true
	state_to_save.skybox_visible = false
	
	state_to_save.postfx_active = true
	// Minimal settings check
	state_to_save.postfx_settings.effects = 12345
	
	state_to_save.gui_visible = true
	state_to_save.ibl_debug_open = false
	
	state_to_save.is_fullscreen = true
	state_to_save.overlay_mode = 2
	state_to_save.camera_enabled = false
	
	// 1. Test save
	save_ok := session.save_session(&state_to_save, test_file)
	testing.expect_value(t, save_ok, true)
	
	// Ensure file exists
	testing.expect_value(t, os.exists(test_file), true)
	
	// 2. Test load
	loaded_state: session.Session_State
	load_ok := session.load_session(&loaded_state, test_file)
	testing.expect_value(t, load_ok, true)
	
	// 3. Validate values
	testing.expect_value(t, loaded_state.window_pos[0], 123)
	testing.expect_value(t, loaded_state.window_pos[1], 456)
	testing.expect_value(t, loaded_state.window_size[0], 1920)
	testing.expect_value(t, loaded_state.window_size[1], 1080)
	
	testing.expect_value(t, loaded_state.camera_pos.x, 1.0)
	testing.expect_value(t, loaded_state.camera_pos.y, 2.0)
	testing.expect_value(t, loaded_state.camera_pos.z, 3.0)
	testing.expect_value(t, loaded_state.camera_yaw, 45.0)
	
	testing.expect_value(t, loaded_state.exposure, 1.5)
	testing.expect_value(t, loaded_state.wireframe_enabled, true)
	testing.expect_value(t, loaded_state.skybox_visible, false)
	
	testing.expect_value(t, loaded_state.postfx_active, true)
	testing.expect_value(t, loaded_state.postfx_settings.effects, 12345)
	
	testing.expect_value(t, loaded_state.gui_visible, true)
	
	testing.expect_value(t, loaded_state.is_fullscreen, true)
	testing.expect_value(t, loaded_state.overlay_mode, 2)
	testing.expect_value(t, loaded_state.camera_enabled, false)
}

@(test)
test_session_missing_file :: proc(t: ^testing.T) {
	test_file := "test_session_missing.json"
	os.remove(test_file) // ensure it does not exist
	
	// Attempt to load from non-existent file
	loaded_state: session.Session_State
	load_ok := session.load_session(&loaded_state, test_file)
	
	// Should fail gracefully and return false
	testing.expect_value(t, load_ok, false)
}
