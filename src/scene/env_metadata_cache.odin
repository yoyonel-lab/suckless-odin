package scene

import "core:encoding/json"
import "core:os"
import "core:strings"

import log "../core/log"
import "../rendering"

ENV_METADATA_CACHE_PATH :: "assets/textures/hdr/env_metadata.json"

Env_Metadata_Entry :: struct {
	direction:      [3]f32 `json:"direction"`,
	azimuth:        f32    `json:"azimuth"`,
	elevation:      f32    `json:"elevation"`,
	color:          [3]f32 `json:"color"`,
	peak_intensity: f32    `json:"peak_intensity"`,
	confidence:     i32    `json:"confidence"`,
	sun_detected:   bool   `json:"sun_detected"`,
	is_aperture:    bool   `json:"is_aperture"`,
}

Env_Metadata_Table :: map[string]Env_Metadata_Entry

// Extracts bare filename from path (e.g. "assets/textures/hdr/cedar_bridge_2_4k.hdr" -> "cedar_bridge_2_4k.hdr")
env_metadata_key :: proc(path: string) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx >= 0 && idx + 1 < len(path) {
		return path[idx+1:]
	}
	return path
}

// Attempts to read precomputed sun detection metadata for a given HDR file.
env_metadata_cache_lookup :: proc(path: string) -> (det: rendering.Sun_Detection, ok: bool) {
	data, err := os.read_entire_file_from_path(ENV_METADATA_CACHE_PATH, context.temp_allocator)
	if err != nil {
		return det, false
	}

	table: Env_Metadata_Table
	json_err := json.unmarshal(data, &table, allocator = context.temp_allocator)
	if json_err != nil {
		return det, false
	}

	key := env_metadata_key(path)
	entry, found := table[key]
	if !found {
		return det, false
	}

	det.direction = {entry.direction[0], entry.direction[1], entry.direction[2]}
	det.azimuth = entry.azimuth
	det.elevation = entry.elevation
	det.color = {entry.color[0], entry.color[1], entry.color[2]}
	if det.color.x <= 0.001 && det.color.y <= 0.001 && det.color.z <= 0.001 {
		det.color = rendering.SUN_FALLBACK_COLOR
	}
	det.peak_intensity = entry.peak_intensity
	det.confidence = entry.confidence
	det.sun_detected = entry.sun_detected
	det.is_aperture = entry.is_aperture
	return det, true
}

// Stores updated sun detection metadata to cache file on disk.
env_metadata_cache_save :: proc(path: string, det: rendering.Sun_Detection) -> bool {
	table: Env_Metadata_Table

	data, err := os.read_entire_file_from_path(ENV_METADATA_CACHE_PATH, context.temp_allocator)
	if err == nil {
		_ = json.unmarshal(data, &table, allocator = context.temp_allocator)
	}

	key := env_metadata_key(path)
	entry := Env_Metadata_Entry{
		direction      = {det.direction.x, det.direction.y, det.direction.z},
		azimuth        = det.azimuth,
		elevation      = det.elevation,
		color          = {det.color.x, det.color.y, det.color.z},
		peak_intensity = det.peak_intensity,
		confidence     = det.confidence,
		sun_detected   = det.sun_detected,
		is_aperture    = det.is_aperture,
	}
	table[key] = entry

	out_bytes, marshal_err := json.marshal(table, allocator = context.temp_allocator, opt = json.Marshal_Options{pretty = true})
	if marshal_err != nil {
		log.log_error("scene.env", "Failed to marshal env metadata cache: %v", marshal_err)
		return false
	}

	write_err := os.write_entire_file(ENV_METADATA_CACHE_PATH, out_bytes)
	if write_err != nil {
		log.log_error("scene.env", "Failed to write env metadata cache to %s: %v", ENV_METADATA_CACHE_PATH, write_err)
		return false
	}

	log.log_info("scene.env", "Saved env metadata cache for '%s' to %s", key, ENV_METADATA_CACHE_PATH)
	return true
}
