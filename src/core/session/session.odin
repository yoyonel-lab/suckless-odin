package session

import "core:os"
import "core:encoding/json"
import "core:fmt"
import mt "../math_types"
import postfx "../../rendering/postfx"

// Session_State holds all runtime state to persist across runs.
Session_State :: struct {
	window_pos: [2]i32 `json:"window_pos"`,
	window_size: [2]i32 `json:"window_size"`,
	
	camera_pos: mt.Vec3 `json:"camera_pos"`,
	camera_yaw: f32 `json:"camera_yaw"`,
	camera_pitch: f32 `json:"camera_pitch"`,
	camera_zoom: f32 `json:"camera_zoom"`,
	
	exposure: f32 `json:"exposure"`,
	wireframe_enabled: bool `json:"wireframe_enabled"`,
	skybox_visible: bool `json:"skybox_visible"`,
	skybox_blur_lod: f32 `json:"skybox_blur_lod"`,
	skybox_mode: i32 `json:"skybox_mode"`,
	mipmap_mode: i32 `json:"mipmap_mode"`,
	blur_source: i32 `json:"blur_source"`,
	show_blur_diff: bool `json:"show_blur_diff"`,
	diff_gain: f32 `json:"diff_gain"`,
	sort_mode: i32 `json:"sort_mode"`,
	edge_aa_enabled: bool `json:"edge_aa_enabled"`,
	edge_aa_debug: bool `json:"edge_aa_debug"`,
	
	postfx_active: bool `json:"postfx_active"`,
	postfx_settings: postfx.Settings_File `json:"postfx_settings"`,
	
	gui_visible: bool `json:"gui_visible"`,
	gui_active_tab: i32 `json:"gui_active_tab"`,
	ibl_debug_open: bool `json:"ibl_debug_open"`,
	
	is_fullscreen: bool `json:"is_fullscreen"`,
	overlay_mode: i32 `json:"overlay_mode"`,
	camera_enabled: bool `json:"camera_enabled"`,
}

SESSION_FILE_PATH :: "session.json"

// Save session state to disk as JSON
save_session :: proc(state: ^Session_State, path: string = SESSION_FILE_PATH) -> bool {
	data, err := json.marshal(state^, allocator = context.temp_allocator, opt = json.Marshal_Options{pretty = true})
	if err != nil {
		fmt.eprintln("[session] Failed to marshal session state:", err)
		return false
	}
	
	write_err := os.write_entire_file(path, data)
	if write_err != nil {
		fmt.eprintln("[session] Failed to write session file:", write_err)
		return false
	}
	return true
}

// Load session state from disk
load_session :: proc(state: ^Session_State, path: string = SESSION_FILE_PATH) -> bool {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		// Normal on first run
		return false
	}
	
	unmarshal_err := json.unmarshal(data, state, allocator = context.allocator)
	if unmarshal_err != nil {
		fmt.eprintln("[session] Failed to decode session JSON:", unmarshal_err)
		return false
	}
	return true
}
