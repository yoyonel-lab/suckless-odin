package rendering

import "core:os"
import "core:encoding/json"

import log "../core/log"
import mt  "../core/math_types"

// PBR Material (ISO port of PBRMaterial from material.h)
PBR_Material :: struct {
	name:      string,
	albedo:    mt.Vec3,
	metallic:  f32,
	roughness: f32,
}

// Material library (ISO port of MaterialLib)
Material_Lib :: struct {
	materials: [dynamic]PBR_Material,
	count:     int,
}

// JSON structure for deserialization
@(private)
Material_JSON :: struct {
	name:      string    `json:"name"`,
	albedo:    [3]f64    `json:"albedo"`,
	metallic:  f64       `json:"metallic"`,
	roughness: f64       `json:"roughness"`,
}

// Load PBR material presets from JSON file (ISO port of material_load_presets)
material_load_presets :: proc(path: string) -> (lib: Material_Lib, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.material", "Failed to read material file: %s", path)
		return lib, false
	}

	json_materials: [dynamic]Material_JSON
	json_err := json.unmarshal(data, &json_materials, allocator = context.allocator)
	if json_err != nil {
		log.log_error("suckless-odin.material", "Failed to parse material JSON: %s", path)
		return lib, false
	}

	lib.materials = make([dynamic]PBR_Material, len(json_materials))
	lib.count = len(json_materials)

	for i in 0..<len(json_materials) {
		jm := &json_materials[i]
		lib.materials[i] = PBR_Material{
			name      = jm.name,
			albedo    = mt.Vec3{f32(jm.albedo[0]), f32(jm.albedo[1]), f32(jm.albedo[2])},
			metallic  = f32(jm.metallic),
			roughness = f32(jm.roughness),
		}
	}

	log.log_info("suckless-odin.material", "Loaded %d material presets from %s", lib.count, path)
	return lib, true
}

material_lib_destroy :: proc(lib: ^Material_Lib) {
	delete(lib.materials)
	lib.count = 0
}
