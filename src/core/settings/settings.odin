package settings

// Global application constants, configuration, and default values.
// ISO port of app_settings.h from suckless-ogl.

// --- Renderer Configuration ---

DEFAULT_SAMPLES        :: 1     // MSAA sample count (1 = no MSAA)
DEFAULT_STENCIL_MASK   :: 0xFF  // All bits enabled

USE_TRANSPARENT_BILLBOARDS :: true  // Enable transparent billboard rendering

// --- Geometry Generation ---

MIN_SUBDIV             :: 0     // Minimum icosphere subdivision level
MAX_SUBDIV             :: 6     // Maximum subdivision level (~40k vertices at 6)
CUBEMAP_SIZE           :: 1024  // Legacy cubemap size
INITIAL_SUBDIVISIONS   :: 3     // Starting subdivision level

// --- Camera Configuration ---

DEFAULT_CAMERA_DISTANCE :: 20.0   // Initial orbit radius
DEFAULT_CAMERA_YAW      :: -90.0  // Initial horizontal angle (looking -Z)
DEFAULT_CAMERA_PITCH    :: 0.0    // Initial vertical angle (Horizon)
DEFAULT_ENV_LOD         :: 0.0    // Initial skybox blur level (0=Sharp)

// Projection matrix
NEAR_PLANE              :: 0.1    // Z-Near clip
FAR_PLANE               :: 1000.0 // Z-Far clip
FOV_ANGLE               :: 60.0   // Vertical FOV in degrees

// Gameplay constraints
MIN_CAMERA_DISTANCE     :: 1.5    // Closest zoom
MAX_CAMERA_DISTANCE     :: 50.0   // Furthest zoom

// --- Window Defaults ---

WINDOW_WIDTH            :: 1280
WINDOW_HEIGHT           :: 720

// --- Material Defaults ---

DEFAULT_METALLIC        :: 0.0
DEFAULT_ROUGHNESS       :: 0.5
DEFAULT_AO              :: 1.0
DEFAULT_EXPOSURE        :: 1.0

// --- N-Body Simulation ---

NUM_SPHERES             :: 50
G_CONSTANT              :: 0.5   // Gravitational constant
REPULSION_STRENGTH      :: 2.0
MIN_DISTANCE            :: 1.0

// --- Instancing Grid Layout ---

DEFAULT_COLS            :: 10
DEFAULT_SPACING         :: 2.5
HALF_OFFSET_MULTIPLIER  :: 0.5

// --- SIMD Alignment ---

SIMD_ALIGNMENT          :: 64    // 64-byte cache-line alignment

// --- Compute Shader Tuning Profiles ---

import "core:encoding/json"
import "core:os"
import log "../log"

Compute_Shader_Profile :: enum {
	Legacy,     // Original heavy values (1024 samples, 0.025 step size)
	Optimized,  // Optimized values (256/512 samples, 0.05 step size)
}

Compute_Slicing_Config :: struct {
	specular_mip0_slices: i32 `json:"specular_mip0_slices"`,
	specular_mip1_slices: i32 `json:"specular_mip1_slices"`,
	specular_mip2_slices: i32 `json:"specular_mip2_slices"`,
	irdiff_slices:        i32 `json:"irdiff_slices"`,
	specular_mip_grouping_start_mip: i32 `json:"specular_mip_grouping_start_mip"`,
	seamless_downsample_progressive_mip_threshold: i32 `json:"seamless_downsample_progressive_mip_threshold"`,
}

Compute_Tuning_Params :: struct {
	spbrdf_sample_count: i32 `json:"spbrdf_sample_count"`,
	spmap_sample_count:  i32 `json:"spmap_sample_count"`,
	irmap_sample_delta:  f32 `json:"irmap_sample_delta"`,
	slicing:             Compute_Slicing_Config `json:"slicing"`,
}

Compute_Tuning_Config :: struct {
	profiles: map[string]Compute_Tuning_Params `json:"profiles"`,
}

DEFAULT_COMPUTE_TUNING :: Compute_Tuning_Params{
	spbrdf_sample_count = 1024,
	spmap_sample_count  = 1024,
	irmap_sample_delta  = 0.025,
	slicing = Compute_Slicing_Config{
		specular_mip0_slices = 24,
		specular_mip1_slices = 8,
		specular_mip2_slices = 4,
		irdiff_slices        = 12,
		specular_mip_grouping_start_mip = 3,
		seamless_downsample_progressive_mip_threshold = 2,
	},
}

DEFAULT_OPTIMIZED_COMPUTE_TUNING :: Compute_Tuning_Params{
	spbrdf_sample_count = 256,
	spmap_sample_count  = 512,
	irmap_sample_delta  = 0.05,
	slicing = Compute_Slicing_Config{
		specular_mip0_slices = 12,
		specular_mip1_slices = 6,
		specular_mip2_slices = 4,
		irdiff_slices        = 8,
		specular_mip_grouping_start_mip = 3,
		seamless_downsample_progressive_mip_threshold = 2,
	},
}


validate_compute_tuning_params :: proc(params: Compute_Tuning_Params) -> bool {
	if params.spbrdf_sample_count <= 0 { return false }
	if params.spmap_sample_count <= 0 { return false }
	if params.irmap_sample_delta <= 0.0 { return false }
	if params.slicing.specular_mip0_slices <= 0 { return false }
	if params.slicing.specular_mip1_slices <= 0 { return false }
	if params.slicing.specular_mip2_slices <= 0 { return false }
	if params.slicing.irdiff_slices <= 0 { return false }
	if params.slicing.specular_mip_grouping_start_mip < 0 { return false }
	if params.slicing.seamless_downsample_progressive_mip_threshold < 0 { return false }
	return true
}

load_compute_tuning_params :: proc(profile: Compute_Shader_Profile, path: string = "assets/configs/compute_tuning.json") -> Compute_Tuning_Params {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_warning("suckless-odin.settings", "Failed to read compute tuning JSON file '%s'. Falling back to built-in default.", path)
		return DEFAULT_COMPUTE_TUNING
	}
	defer delete(data)

	config: Compute_Tuning_Config
	json_err := json.unmarshal(data, &config, allocator = context.allocator)
	if json_err != nil {
		log.log_warning("suckless-odin.settings", "Failed to parse compute tuning JSON file '%s'. Falling back to built-in default.", path)
		return DEFAULT_COMPUTE_TUNING
	}
	defer {
		for k, _ in config.profiles {
			delete(k)
		}
		delete(config.profiles)
	}

	profile_key: string
	switch profile {
	case .Legacy:    profile_key = "legacy"
	case .Optimized: profile_key = "optimized"
	}

	params, exists := config.profiles[profile_key]
	if !exists {
		log.log_warning("suckless-odin.settings", "Profile '%s' not found in JSON configuration. Falling back to built-in default.", profile_key)
		return DEFAULT_COMPUTE_TUNING
	}

	if !validate_compute_tuning_params(params) {
		log.log_warning("suckless-odin.settings", "Profile '%s' in JSON configuration has semantically invalid values. Falling back to built-in default.", profile_key)
		return DEFAULT_COMPUTE_TUNING
	}

	return params
}

load_compute_tuning_config :: proc(path: string = "assets/configs/compute_tuning.json") -> (config: Compute_Tuning_Config, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.settings", "Failed to read compute tuning JSON file '%s'", path)
		return {}, false
	}
	defer delete(data)

	json_err := json.unmarshal(data, &config, allocator = context.allocator)
	if json_err != nil {
		log.log_error("suckless-odin.settings", "Failed to parse compute tuning JSON: %v", json_err)
		return {}, false
	}

	return config, true
}

save_compute_tuning_config :: proc(config: Compute_Tuning_Config, path: string = "assets/configs/compute_tuning.json") -> bool {
	dir := os.dir(path)
	if !os.exists(dir) {
		os.make_directory_all(dir)
	}

	data, err := json.marshal(config, {pretty = true}, allocator = context.temp_allocator)
	if err != nil {
		log.log_error("suckless-odin.settings", "Failed to marshal compute tuning config: %v", err)
		return false
	}

	write_err := os.write_entire_file(path, data)
	if write_err != nil {
		log.log_error("suckless-odin.settings", "Failed to write compute tuning settings to '%s'", path)
		return false
	}

	return true
}

destroy_compute_tuning_config :: proc(config: ^Compute_Tuning_Config) {
	for k, _ in config.profiles {
		delete(k)
	}
	delete(config.profiles)
	config^ = {}
}



