package postfx

// Runtime validation of UBO layout against GPU-reported offsets.
// Uses Odin struct reflection as source of truth — zero magic constants.
//
// HOW IT WORKS:
//   Forward pass: each {glsl_name → odin_field} in UBO_MAPPINGS must resolve
//                 in the linked shader AND have the correct byte offset.
//   Reverse pass: each GPU uniform in the block whose offset maps to a
//                 "section start" struct field must appear in UBO_MAPPINGS.
//                 A "section start" = first field of its prefix group (e.g.
//                 fog_density is the first "fog_*" field).
//
// WHEN TO UPDATE THIS FILE:
//   1. You added a new SECTION to Post_FX_UBO (new effect group):
//      → Add {"glslUniformName", "odin_field_name"} to UBO_MAPPINGS.
//        The offset is derived automatically via reflect. That's it.
//   2. You renamed a field in the GLSL shader:
//      → Update the glsl_name (first column) in UBO_MAPPINGS.
//   3. You renamed a field in Post_FX_UBO:
//      → Update the field_name (second column) in UBO_MAPPINGS.
//   4. You reordered or added padding in Post_FX_UBO:
//      → Nothing to do here. Offsets are auto-derived.
//        If the layout is wrong, `just test` will catch it.
//
// WHAT TRIGGERS A TEST FAILURE:
//   - Typo in glsl_name     → ERROR "UNRESOLVED: 'X' not found in shader"
//   - Typo in field_name    → ERROR "BUG: field 'X' not in Post_FX_UBO struct"
//   - Offset mismatch       → ERROR "OFFSET MISMATCH: 'X' GPU=N, struct=M"
//   - Forgot to add mapping → ERROR "MISSING MAPPING: GPU has 'X' at offset N"

import "base:runtime"
import "core:strings"

import gl "vendor:OpenGL"

import log "../../core/log"

// Name mapping: GLSL uniform name → Odin struct field name.
// Offsets are derived automatically via struct reflection — no magic numbers.
@(private)
UBO_MAPPING :: struct {
	glsl_name:  cstring,
	field_name: string,
}

@(private)
UBO_MAPPINGS :: [?]UBO_MAPPING{
	{"activeEffects",      "active_effects"},
	{"time",               "time"},
	{"screenTexelSize",    "screen_texel_size"},
	{"v_intensity",        "vignette_intensity"},
	{"g_intensity",        "grain_intensity"},
	{"e_exposure",         "exposure_manual"},
	{"ca_strength",        "chrom_abbr_strength"},
	{"wb_temperature",     "wb_temperature"},
	{"cg_saturation",      "grading_saturation"},
	{"tm_slope",           "tonemap_slope"},
	{"b_intensity",        "bloom_intensity"},
	{"fxaaQualitySubpix",  "fxaa_subpix"},
	{"d_focalDistance",    "dof_focal_distance"},
	{"zNear",              "z_near"},
	{"mb_intensity",       "mb_intensity"},
	{"bandingMode",        "banding_mode"},
	{"fog_density",        "fog_density"},
	{"lut3d_intensity",    "lut3d_intensity"},
	{"debugSplitMask",     "debug_split_mask"},
}

// Lookup a struct field's offset by name using runtime type info.
@(private)
struct_field_offset :: proc(field_name: string) -> (offset: uintptr, found: bool) {
	ti := runtime.type_info_base(type_info_of(Post_FX_UBO))
	s := ti.variant.(runtime.Type_Info_Struct)
	for i in 0 ..< s.field_count {
		if s.names[i] == field_name {
			return s.offsets[i], true
		}
	}
	return 0, false
}

// A field is a "section start" if it's the FIRST field of its prefix group.
// Prefix = everything before the first '_' (e.g. "fog" for "fog_density").
// This identifies the first field of each logical section without manual bookkeeping.
@(private)
is_section_start :: proc(field_name: string) -> bool {
	ti := runtime.type_info_base(type_info_of(Post_FX_UBO))
	s := ti.variant.(runtime.Type_Info_Struct)

	// Find prefix of the target field
	target_prefix := field_prefix(field_name)
	if len(target_prefix) == 0 { return false }

	// Walk struct fields — is this the FIRST non-padding field with this prefix?
	for i in 0 ..< s.field_count {
		name := s.names[i]
		if len(name) == 0 || name[0] == '_' { continue }
		if field_prefix(name) == target_prefix {
			return name == field_name
		}
	}
	return false
}

// Extract prefix: "fog_density" → "fog", "z_near" → "z", "active_effects" → "active"
@(private)
field_prefix :: proc(name: string) -> string {
	for i in 0 ..< len(name) {
		if name[i] == '_' {
			return name[:i]
		}
	}
	return name
}

// Validate that GPU UBO offsets match our packed struct layout.
// Call once after shader link. Asserts on failure in debug builds.
validate_ubo_layout :: proc(program: u32) -> bool {
	block_idx := gl.GetUniformBlockIndex(program, "PostProcessBlock")
	if block_idx == gl.INVALID_INDEX {
		log.log_warning("suckless-odin.postfx.validate", "UBO block 'PostProcessBlock' not found")
		return false
	}

	all_ok := true
	mappings := UBO_MAPPINGS
	resolved_count := 0

	// --- Forward pass: our mapping table → GPU ---
	for i in 0 ..< len(mappings) {
		// Get expected offset from struct reflection
		expected, field_found := struct_field_offset(mappings[i].field_name)
		if !field_found {
			log.log_error(
				"suckless-odin.postfx.validate",
				"BUG: field '%s' not in Post_FX_UBO struct",
				mappings[i].field_name,
			)
			all_ok = false
			continue
		}

		// Resolve GLSL name in the shader
		name := mappings[i].glsl_name
		idx: u32
		gl.GetUniformIndices(program, 1, &name, &idx)
		if idx == gl.INVALID_INDEX {
			log.log_error(
				"suckless-odin.postfx.validate",
				"UNRESOLVED: '%s' (field '%s') not found in shader",
				name, mappings[i].field_name,
			)
			all_ok = false
			continue
		}

		resolved_count += 1
		gpu_offset: i32
		gl.GetActiveUniformsiv(program, 1, &idx, gl.UNIFORM_OFFSET, &gpu_offset)

		if uintptr(gpu_offset) != expected {
			log.log_error(
				"suckless-odin.postfx.validate",
				"OFFSET MISMATCH: '%s' GPU=%d, struct=%d (delta=%d)",
				name, gpu_offset, i32(expected), gpu_offset - i32(expected),
			)
			all_ok = false
		}
	}

	// --- Reverse pass: GPU block → struct reflection ---
	// For each GPU uniform: find its struct field via offset.
	// If that field is a SECTION START (previous field is padding) and NOT in our
	// mapping table → someone forgot to add it. Intermediate fields are skipped.
	num_uniforms: i32
	gl.GetActiveUniformBlockiv(program, block_idx, gl.UNIFORM_BLOCK_ACTIVE_UNIFORMS, &num_uniforms)

	if num_uniforms > 0 {
		indices := make([]u32, num_uniforms, context.temp_allocator)
		gl.GetActiveUniformBlockiv(
			program, block_idx, gl.UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES,
			raw_data(transmute([]i32)indices),
		)

		for ui in 0 ..< num_uniforms {
			name_buf: [128]u8
			name_len: i32
			gl.GetActiveUniformName(program, indices[ui], 128, &name_len, raw_data(&name_buf))
			gpu_name := string(name_buf[:name_len])
			stripped := strings.trim_prefix(gpu_name, "PostProcessBlock.")

			// Already covered by our table? → skip
			covered := false
			for j in 0 ..< len(mappings) {
				if string(mappings[j].glsl_name) == stripped {
					covered = true
					break
				}
			}
			if covered { continue }

			// Find which struct field sits at this GPU offset
			gpu_offset: i32
			gl.GetActiveUniformsiv(program, 1, &indices[ui], gl.UNIFORM_OFFSET, &gpu_offset)

			ti := runtime.type_info_base(type_info_of(Post_FX_UBO))
			s := ti.variant.(runtime.Type_Info_Struct)
			field_name := ""
			for fi in 0 ..< s.field_count {
				if s.offsets[fi] == uintptr(gpu_offset) {
					field_name = s.names[fi]
					break
				}
			}
			if len(field_name) == 0 { continue }

			// Only error if this field is a section start AND not already mapped
			if !is_section_start(field_name) { continue }

			// It's a section start not in our table → missing mapping
			is_mapped := false
			for j in 0 ..< len(mappings) {
				if mappings[j].field_name == field_name {
					is_mapped = true
					break
				}
			}

			if !is_mapped {
				log.log_error(
					"suckless-odin.postfx.validate",
					"MISSING MAPPING: GPU has '%s' at offset %d → struct section '%s' not in UBO_MAPPINGS",
					gpu_name, gpu_offset, field_name,
				)
				all_ok = false
			}
		}
	}

	if all_ok {
		log.log_info(
			"suckless-odin.postfx.validate",
			"UBO layout validated (%d/%d mappings resolved, %d GPU uniforms in block)",
			resolved_count, len(mappings), num_uniforms,
		)
	}
	return all_ok
}
