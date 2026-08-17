package tests

import "core:testing"
import "core:os"
import "core:strings"

import settings "../src/core/settings"

// --- Settings constants validation ---
// ISO port of implicit constant checks from various legacy test files.

@(test)
test_settings_camera_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.DEFAULT_CAMERA_DISTANCE, 20.0)
	testing.expect_value(t, settings.DEFAULT_CAMERA_YAW, -90.0)
	testing.expect_value(t, settings.DEFAULT_CAMERA_PITCH, 0.0)
	testing.expect_value(t, settings.DEFAULT_ENV_LOD, 0.0)
}

@(test)
test_settings_projection :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.NEAR_PLANE, 0.1)
	testing.expect_value(t, settings.FAR_PLANE, 1000.0)
	testing.expect_value(t, settings.FOV_ANGLE, 60.0)
}

@(test)
test_settings_window :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.WINDOW_WIDTH, 1280)
	testing.expect_value(t, settings.WINDOW_HEIGHT, 720)
}

@(test)
test_settings_material_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.DEFAULT_METALLIC, 0.0)
	testing.expect_value(t, settings.DEFAULT_ROUGHNESS, 0.5)
	testing.expect_value(t, settings.DEFAULT_AO, 1.0)
	testing.expect_value(t, settings.DEFAULT_EXPOSURE, 1.0)
}

@(test)
test_settings_geometry :: proc(t: ^testing.T) {
	testing.expect(t, settings.MIN_SUBDIV <= settings.MAX_SUBDIV,
		"MIN_SUBDIV must be <= MAX_SUBDIV")
	testing.expect(t, settings.INITIAL_SUBDIVISIONS >= settings.MIN_SUBDIV,
		"INITIAL_SUBDIVISIONS must be >= MIN_SUBDIV")
	testing.expect(t, settings.INITIAL_SUBDIVISIONS <= settings.MAX_SUBDIV,
		"INITIAL_SUBDIVISIONS must be <= MAX_SUBDIV")
}

@(test)
test_settings_nbody :: proc(t: ^testing.T) {
	testing.expect(t, settings.NUM_SPHERES > 0,
		"NUM_SPHERES must be positive")
}

@(test)
test_settings_load_legacy_profile :: proc(t: ^testing.T) {
	params := settings.load_compute_tuning_params(.Legacy)
	testing.expect_value(t, params.spbrdf_sample_count, 1024)
	testing.expect_value(t, params.spmap_sample_count, 1024)
	testing.expect_value(t, params.irmap_sample_delta, 0.025)
	testing.expect_value(t, params.slicing.specular_mip0_slices, 24)
	testing.expect_value(t, params.slicing.specular_mip1_slices, 8)
	testing.expect_value(t, params.slicing.specular_mip2_slices, 4)
	testing.expect_value(t, params.slicing.irdiff_slices, 12)
	testing.expect_value(t, params.slicing.specular_mip_grouping_start_mip, 3)
	testing.expect_value(t, params.slicing.seamless_downsample_progressive_mip_threshold, 2)
}

@(test)
test_settings_load_optimized_profile :: proc(t: ^testing.T) {
	params := settings.load_compute_tuning_params(.Optimized)
	testing.expect_value(t, params.spbrdf_sample_count, 256)
	testing.expect_value(t, params.spmap_sample_count, 512)
	testing.expect_value(t, params.irmap_sample_delta, 0.05)
	testing.expect_value(t, params.slicing.specular_mip0_slices, 12)
	testing.expect_value(t, params.slicing.specular_mip1_slices, 6)
	testing.expect_value(t, params.slicing.specular_mip2_slices, 4)
	testing.expect_value(t, params.slicing.irdiff_slices, 8)
	testing.expect_value(t, params.slicing.specular_mip_grouping_start_mip, 3)
	testing.expect_value(t, params.slicing.seamless_downsample_progressive_mip_threshold, 2)
}

@(test)
test_settings_load_missing_file :: proc(t: ^testing.T) {
	params := settings.load_compute_tuning_params(.Legacy, "assets/configs/nonexistent_file_xyz.json")
	// Verify it falls back to legacy default
	testing.expect_value(t, params.spbrdf_sample_count, 1024)
	testing.expect_value(t, params.spmap_sample_count, 1024)
	testing.expect_value(t, params.irmap_sample_delta, 0.025)
	testing.expect_value(t, params.slicing.specular_mip0_slices, 24)
}

@(test)
test_settings_load_corrupted_json :: proc(t: ^testing.T) {
	temp_path := "tests/scratch_corrupted_test.json"
	bad_json := "{ invalid json syntax... }"
	_ = os.write_entire_file(temp_path, transmute([]byte)bad_json)
	defer os.remove(temp_path)

	params := settings.load_compute_tuning_params(.Legacy, temp_path)
	// Verify it falls back to legacy default
	testing.expect_value(t, params.spbrdf_sample_count, 1024)
	testing.expect_value(t, params.spmap_sample_count, 1024)
	testing.expect_value(t, params.irmap_sample_delta, 0.025)
}

@(test)
test_settings_load_invalid_values :: proc(t: ^testing.T) {
	temp_path := "tests/scratch_invalid_test.json"
	invalid_json := `{
	  "profiles": {
	    "legacy": {
	      "spbrdf_sample_count": 0,
	      "spmap_sample_count": -10,
	      "irmap_sample_delta": 0.0,
	      "slicing": {
	        "specular_mip0_slices": 0,
	        "specular_mip1_slices": -5,
	        "specular_mip2_slices": 4,
	        "irdiff_slices": 12,
	        "specular_mip_grouping_start_mip": -1,
	        "seamless_downsample_progressive_mip_threshold": -2
	      }
	    }
	  }
	}`
	_ = os.write_entire_file(temp_path, transmute([]byte)invalid_json)
	defer os.remove(temp_path)

	params := settings.load_compute_tuning_params(.Legacy, temp_path)
	// Verify it falls back to legacy default because of semantic validation failures
	testing.expect_value(t, params.spbrdf_sample_count, 1024)
	testing.expect_value(t, params.spmap_sample_count, 1024)
	testing.expect_value(t, params.irmap_sample_delta, 0.025)
	testing.expect_value(t, params.slicing.specular_mip0_slices, 24)
}

@(test)
test_settings_config_load_save :: proc(t: ^testing.T) {
	temp_path := "tests/scratch_config_load_save_test.json"
	defer os.remove(temp_path)

	// 1. Create a dummy config
	config: settings.Compute_Tuning_Config
	config.profiles = make(map[string]settings.Compute_Tuning_Params)
	defer settings.destroy_compute_tuning_config(&config)

	params := settings.DEFAULT_COMPUTE_TUNING
	params.spbrdf_sample_count = 999
	params.slicing.specular_mip0_slices = 99
	config.profiles[strings.clone("test_profile")] = params

	// 2. Save it
	save_ok := settings.save_compute_tuning_config(config, temp_path)
	testing.expect(t, save_ok, "Failed to save compute tuning config")

	// 3. Load it back
	loaded_config, load_ok := settings.load_compute_tuning_config(temp_path)
	testing.expect(t, load_ok, "Failed to load compute tuning config")
	defer settings.destroy_compute_tuning_config(&loaded_config)

	// 4. Verify contents
	testing.expect(t, "test_profile" in loaded_config.profiles, "test_profile not found in loaded config")
	loaded_params := loaded_config.profiles["test_profile"]
	testing.expect_value(t, loaded_params.spbrdf_sample_count, 999)
	testing.expect_value(t, loaded_params.slicing.specular_mip0_slices, 99)
}


