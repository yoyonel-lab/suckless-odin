package tests

import "core:testing"
import "core:os"

import "../src/rendering"

// --- Material loading ---
// ISO port of test_material.c from suckless-ogl

@(test)
test_material_load_presets_nonexistent :: proc(t: ^testing.T) {
	lib, ok := rendering.material_load_presets("nonexistent.json")
	testing.expect(t, !ok, "loading nonexistent file should fail")
	testing.expect_value(t, lib.count, 0)
}

@(test)
test_material_load_presets_valid :: proc(t: ^testing.T) {
	path :: "assets/materials/pbr_materials.json"
	if !os.exists(path) {
		// Skip if fixture not present
		return
	}

	lib, ok := rendering.material_load_presets(path)
	testing.expect(t, ok, "loading valid material JSON should succeed")
	testing.expect(t, lib.count > 0, "should have at least one material")
	testing.expect(t, len(lib.materials) == lib.count, "materials slice length should match count")

	// Verify first material has non-empty name
	if lib.count > 0 {
		testing.expect(t, len(lib.materials[0].name) > 0,
			"first material should have a name")
	}

	rendering.material_lib_destroy(&lib)
}

@(test)
test_material_lib_destroy_empty :: proc(t: ^testing.T) {
	lib: rendering.Material_Lib
	// Destroying an empty lib should not crash
	rendering.material_lib_destroy(&lib)
	testing.expect_value(t, lib.count, 0)
}
