package postfx

import "core:encoding/json"
import "core:os"
import "core:strings"

import log "../../core/log"

// Serializable PostFX settings (JSON-friendly mirror of Pipeline params).
// Effect_Flags is stored as u32 for portable JSON representation.
Settings_File :: struct {
	name:          string                  `json:"name"`,
	effects:       u32                     `json:"effects"`,
	vignette:      Vignette_Params         `json:"vignette"`,
	grain:         Grain_Params            `json:"grain"`,
	exposure:      Exposure_Params         `json:"exposure"`,
	chrom_abbr:    Chrom_Aberration_Params `json:"chrom_abbr"`,
	white_balance: White_Balance_Params    `json:"white_balance"`,
	color_grading: Color_Grading_Params    `json:"color_grading"`,
	tonemapper:    Tonemap_Params          `json:"tonemapper"`,
	bloom:         Bloom_Params            `json:"bloom"`,
	fxaa:          FXAA_Params             `json:"fxaa"`,
	dof:           Dof_Params              `json:"dof"`,
	banding:       Banding_Params          `json:"banding"`,
	fog:           Fog_Params              `json:"fog"`,
	motion_blur:   Motion_Blur_Params      `json:"motion_blur"`,
	lut3d:         LUT3D_Params            `json:"lut3d"`,
	lut3d_path:    string                  `json:"lut3d_path"`,
}

// Default directory for user PostFX presets.
POSTFX_PRESETS_DIR :: "assets/postfx"

// Export current pipeline settings to a JSON file.
settings_export :: proc(p: ^Pipeline, path: string, name: string) -> bool {
	settings := Settings_File{
		name          = name,
		effects       = transmute(u32)p.active_effects,
		vignette      = p.vignette,
		grain         = p.grain,
		exposure      = p.exposure,
		chrom_abbr    = p.chrom_abbr,
		white_balance = p.white_balance,
		color_grading = p.color_grading,
		tonemapper    = p.tonemapper,
		bloom         = p.bloom,
		fxaa          = p.fxaa,
		dof           = p.dof,
		banding       = p.banding,
		fog           = p.fog,
		motion_blur   = p.motion_blur,
		lut3d         = p.lut3d,
		lut3d_path    = p.lut3d_fx.path,
	}

	// Ensure output directory exists
	dir := os.dir(path)
	if !os.exists(dir) {
		os.make_directory_all(dir)
	}

	data, err := json.marshal(settings, allocator = context.temp_allocator)
	if err != nil {
		log.log_error("suckless-odin.postfx.io", "Failed to marshal settings: %v", err)
		return false
	}

	write_err := os.write_entire_file(path, data)
	if write_err != nil {
		log.log_error("suckless-odin.postfx.io", "Failed to write settings file: %s", path)
		return false
	}

	log.log_info("suckless-odin.postfx.io", "Exported settings '%s' to %s", name, path)
	return true
}

// Import settings from a JSON file and apply to pipeline.
settings_import :: proc(p: ^Pipeline, path: string) -> bool {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		log.log_error("suckless-odin.postfx.io", "Failed to read settings file: %s", path)
		return false
	}
	defer delete(data)

	settings: Settings_File
	json_err := json.unmarshal(data, &settings, allocator = context.allocator)
	if json_err != nil {
		log.log_error("suckless-odin.postfx.io", "Failed to parse settings JSON: %s", path)
		return false
	}
	defer delete(settings.name)

	// Apply to pipeline
	p.active_effects = transmute(Effect_Flags)settings.effects
	p.debug_split    = {}
	p.cached_debug   = {}
	p.cached_split   = {}
	p.vignette       = settings.vignette
	p.grain          = settings.grain
	p.exposure       = settings.exposure
	p.chrom_abbr     = settings.chrom_abbr
	p.white_balance  = settings.white_balance
	p.color_grading  = settings.color_grading
	p.tonemapper     = settings.tonemapper
	p.bloom          = settings.bloom
	p.fxaa           = settings.fxaa
	p.dof            = settings.dof
	p.banding        = settings.banding
	p.fog            = settings.fog
	p.motion_blur    = settings.motion_blur
	p.lut3d          = settings.lut3d
	if settings.lut3d_path != "" {
		pipeline_load_lut(p, settings.lut3d_path)
	}
	defer delete(settings.lut3d_path)
	p.ubo_dirty      = true

	log.log_info("suckless-odin.postfx.io", "Imported settings '%s' from %s", settings.name, path)
	return true
}

// List all .json preset files in the presets directory.
settings_list_files :: proc(dir: string, allocator := context.allocator) -> (files: [dynamic]string) {
	files = make([dynamic]string, allocator)

	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return files
	}

	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".json") {
			append(&files, strings.clone(entry.name, allocator))
		}
	}
	return files
}

// Delete a saved preset file.
settings_delete :: proc(path: string) -> bool {
	err := os.remove(path)
	if err != nil {
		log.log_error("suckless-odin.postfx.io", "Failed to delete settings file: %s", path)
		return false
	}
	log.log_info("suckless-odin.postfx.io", "Deleted settings file: %s", path)
	return true
}

// Build full path from directory + filename.
settings_build_path :: proc(dir, filename: string) -> string {
	if strings.has_suffix(filename, ".json") {
		return strings.concatenate({dir, "/", filename}, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", filename, ".json"}, context.temp_allocator)
}
