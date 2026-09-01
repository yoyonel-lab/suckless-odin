package tests

import "core:testing"
import "core:os"
import "core:math"
import "core:c/libc"
import "core:strings"
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
	state_to_save.perf_mode_active = true
	state_to_save.specular_aa.enabled = true
	state_to_save.specular_aa.mode = 1
	state_to_save.specular_aa.debug_mode = 2
	state_to_save.specular_aa.split_enabled = true
	state_to_save.specular_aa.split_position = 0.75
	
	state_to_save.skybox_mode = 1
	state_to_save.mipmap_mode = 2
	state_to_save.ibl_debug_exposure = 0.5
	state_to_save.diff_gain = 2.5
	state_to_save.edge_aa_enabled = true
	state_to_save.show_blur_diff = true
	state_to_save.sort_mode = 1
	state_to_save.blur_source = 0
	state_to_save.skybox_blur_lod = 1.2
	state_to_save.edge_aa_debug = false
	state_to_save.gui_active_tab = 3
	state_to_save.volumetric = session.Volumetric_Session_Settings{
		enabled                = true,
		composite_in_scene     = true,
		isolate_in_scene       = false,
		shadows_enabled        = true,
		step_count             = 32,
		scattering_coeff       = 0.035,
		extinction_coeff       = 0.050,
		anisotropy_g           = 0.75,
		intensity_mult         = 2.0,
		jitter_enabled         = true,
		taa_mode               = 2,
		taa_alpha              = 0.25,
		taa_depth_threshold    = 0.80,
		taa_clamping_enabled   = true,
		blur_mode              = 2,
		blur_sharpness         = 600.0,
		viewport_debug_mode    = 1,
		upsample_mode          = 2,
		upsample_sharpness     = 300.0,
		resolution_divider     = 2,
		shadow_cache           = true,
		time_slice_mode        = 1,
		shadow_res_index       = 2,
		preview_mode           = 4,
		preview_exposure_boost = 1.5,
	}
	state_to_save.point_light = session.Point_Light_Session_Settings{
		position               = {10.0, 5.0, -2.0},
		radius                 = 15.0,
		color                  = {1.0, 0.8, 0.6},
		intensity              = 2.5,
		enabled                = true,
		direct_shadows_enabled = true,
		shadow_bias            = 0.002,
		shadow_normal_bias     = 0.025,
		shadow_slope_bias      = 0.0010,
		shadow_darkening       = 0.75,
		shadow_debug_mask      = false,
		shadow_debug_mode      = 4,
		shadow_split_position  = 0.65,
		shadow_pcf_samples     = 16,
		shadow_filter_radius   = 0.020,
		shadow_pcf_jitter      = true,
		phase_g                = 0.75,
		is_animated            = true,
		orbit_speed            = 1.2,
		orbit_radius           = 8.0,
		orbit_center           = {0.0, 2.0, 0.0},
		show_bulb              = true,
		bulb_radius            = 0.3,
	}
	
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
	testing.expect_value(t, loaded_state.perf_mode_active, true)
	testing.expect_value(t, loaded_state.specular_aa.enabled, true)
	testing.expect_value(t, loaded_state.specular_aa.mode, 1)
	testing.expect_value(t, loaded_state.specular_aa.debug_mode, 2)
	testing.expect_value(t, loaded_state.specular_aa.split_enabled, true)
	testing.expect_value(t, loaded_state.specular_aa.split_position, 0.75)
	
	testing.expect_value(t, loaded_state.skybox_mode, 1)
	testing.expect_value(t, loaded_state.mipmap_mode, 2)
	testing.expect_value(t, loaded_state.ibl_debug_exposure, 0.5)
	testing.expect_value(t, loaded_state.diff_gain, 2.5)
	testing.expect_value(t, loaded_state.edge_aa_enabled, true)
	testing.expect_value(t, loaded_state.show_blur_diff, true)
	testing.expect_value(t, loaded_state.sort_mode, 1)
	testing.expect_value(t, loaded_state.blur_source, 0)
	testing.expect_value(t, loaded_state.skybox_blur_lod, 1.2)
	testing.expect_value(t, loaded_state.edge_aa_debug, false)
	testing.expect_value(t, loaded_state.gui_active_tab, 3)

	// Volumetric validation
	testing.expect_value(t, loaded_state.volumetric.enabled, true)
	testing.expect_value(t, loaded_state.volumetric.step_count, 32)
	testing.expect_value(t, loaded_state.volumetric.anisotropy_g, 0.75)
	testing.expect_value(t, loaded_state.volumetric.scattering_coeff, 0.035)
	testing.expect_value(t, loaded_state.volumetric.upsample_mode, 2)
	testing.expect_value(t, loaded_state.volumetric.upsample_sharpness, 300.0)
	testing.expect_value(t, loaded_state.volumetric.resolution_divider, 2)
	testing.expect_value(t, loaded_state.volumetric.shadow_cache, true)
	testing.expect_value(t, loaded_state.volumetric.time_slice_mode, 1)
	testing.expect_value(t, loaded_state.volumetric.shadow_res_index, 2)

	// Point Light validation
	testing.expect_value(t, loaded_state.point_light.enabled, true)
	testing.expect_value(t, loaded_state.point_light.intensity, 2.5)
	testing.expect_value(t, loaded_state.point_light.radius, 15.0)
	testing.expect_value(t, loaded_state.point_light.shadow_bias, 0.002)
	testing.expect_value(t, loaded_state.point_light.shadow_normal_bias, 0.025)
	testing.expect_value(t, loaded_state.point_light.shadow_slope_bias, 0.0010)
	testing.expect_value(t, loaded_state.point_light.shadow_debug_mode, 4)
	testing.expect_value(t, loaded_state.point_light.shadow_split_position, 0.65)
	testing.expect_value(t, loaded_state.point_light.shadow_pcf_samples, 16)
	testing.expect_value(t, loaded_state.point_light.shadow_filter_radius, 0.020)
	testing.expect_value(t, loaded_state.point_light.shadow_pcf_jitter, true)
	testing.expect_value(t, loaded_state.point_light.phase_g, 0.75)
	testing.expect_value(t, loaded_state.point_light.is_animated, true)
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

@(test)
test_persistence_coverage :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		exit_code := libc.system("python3 scripts/check_persistence.py")
		if exit_code != 0 {
			exit_code = libc.system("python scripts/check_persistence.py")
		}
		// Under Wine/Windows CI where host Python is not registered in Wine PATH
		if exit_code == 9009 {
			return
		}
		testing.expect_value(t, exit_code, 0)
	} else {
		cmd := "python3 scripts/check_persistence.py"
		cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
		exit_code := libc.system(cstr)
		testing.expect_value(t, exit_code, 0)
	}
}

