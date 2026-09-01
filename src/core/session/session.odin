package session

import "core:os"
import "core:encoding/json"
import "core:fmt"
import mt "../math_types"
import postfx "../../rendering/postfx"

Specular_AA_Settings :: struct {
	enabled:        bool `json:"enabled"`,
	mode:           i32  `json:"mode"`,
	debug_mode:     i32  `json:"debug_mode"`,
	split_enabled:  bool `json:"split_enabled"`,
	split_position: f32  `json:"split_position"`,
}

Volumetric_Session_Settings :: struct {
	enabled:                bool `json:"enabled"`,
	composite_in_scene:     bool `json:"composite_in_scene"`,
	isolate_in_scene:       bool `json:"isolate_in_scene"`,
	shadows_enabled:        bool `json:"shadows_enabled"`,
	step_count:             i32  `json:"step_count"`,
	scattering_coeff:       f32  `json:"scattering_coeff"`,
	extinction_coeff:       f32  `json:"extinction_coeff"`,
	anisotropy_g:           f32  `json:"anisotropy_g"`,
	intensity_mult:         f32  `json:"intensity_mult"`,
	jitter_enabled:         bool `json:"jitter_enabled"`,
	taa_mode:               i32  `json:"taa_mode"`,
	taa_alpha:              f32  `json:"taa_alpha"`,
	taa_depth_threshold:    f32  `json:"taa_depth_threshold"`,
	taa_clamping_enabled:   bool `json:"taa_clamping_enabled"`,
	blur_mode:              i32  `json:"blur_mode"`,
	blur_sharpness:         f32  `json:"blur_sharpness"`,
	viewport_debug_mode:    i32  `json:"viewport_debug_mode"`,
	upsample_mode:          i32  `json:"upsample_mode"`,
	upsample_sharpness:     f32  `json:"upsample_sharpness"`,
	resolution_divider:     i32  `json:"resolution_divider"`,
	shadow_cache:           bool `json:"shadow_cache"`,
	time_slice_mode:        i32  `json:"time_slice_mode"`,
	shadow_res_index:       i32  `json:"shadow_res_index"`,
	preview_mode:           i32  `json:"preview_mode"`,
	preview_exposure_boost: f32  `json:"preview_exposure_boost"`,
}

Point_Light_Session_Settings :: struct {
	position:               mt.Vec3 `json:"position"`,
	radius:                 f32     `json:"radius"`,
	color:                  mt.Vec3 `json:"color"`,
	intensity:              f32     `json:"intensity"`,
	enabled:                bool    `json:"enabled"`,
	direct_shadows_enabled: bool    `json:"direct_shadows_enabled"`,
	shadow_bias:            f32     `json:"shadow_bias"`,
	shadow_normal_bias:     f32     `json:"shadow_normal_bias"`,
	shadow_slope_bias:      f32     `json:"shadow_slope_bias"`,
	shadow_darkening:       f32     `json:"shadow_darkening"`,
	shadow_debug_mask:      bool    `json:"shadow_debug_mask"`,
	phase_g:                f32     `json:"phase_g"`,
	is_animated:            bool    `json:"is_animated"`,
	orbit_speed:            f32     `json:"orbit_speed"`,
	orbit_radius:           f32     `json:"orbit_radius"`,
	orbit_center:           mt.Vec3 `json:"orbit_center"`,
	show_bulb:              bool    `json:"show_bulb"`,
	bulb_radius:            f32     `json:"bulb_radius"`,
}

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
	ibl_debug_exposure: f32 `json:"ibl_debug_exposure"`,
	
	is_fullscreen: bool `json:"is_fullscreen"`,
	overlay_mode: i32 `json:"overlay_mode"`,
	camera_enabled: bool `json:"camera_enabled"`,
	perf_mode_active: bool `json:"perf_mode_active"`,
	specular_aa: Specular_AA_Settings `json:"specular_aa"`,
	volumetric: Volumetric_Session_Settings `json:"volumetric"`,
	point_light: Point_Light_Session_Settings `json:"point_light"`,
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

// Free dynamically allocated memory in session state
session_free :: proc(state: ^Session_State) {
	delete(state.postfx_settings.name)
	delete(state.postfx_settings.lut3d_path)
}

