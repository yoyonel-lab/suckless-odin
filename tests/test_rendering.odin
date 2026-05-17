// +build test
package tests

import "core:testing"

import rendering "../src/rendering"
import types     "../src/rendering/types"
import mt       "../src/core/math_types"

// --- AA Mode tests ---

@(test)
test_aa_mode_to_string_none :: proc(t: ^testing.T) {
	testing.expect_value(t, types.aa_mode_to_string(.None), "None")
}

@(test)
test_aa_mode_to_string_fxaa :: proc(t: ^testing.T) {
	testing.expect_value(t, types.aa_mode_to_string(.FXAA), "FXAA")
}

@(test)
test_aa_mode_to_string_msaa :: proc(t: ^testing.T) {
	testing.expect_value(t, types.aa_mode_to_string(.MSAA), "MSAA")
}

// --- Overlay cycle tests ---

@(test)
test_overlay_cycle_off_to_fps :: proc(t: ^testing.T) {
	overlay: rendering.Text_Overlay
	overlay.mode = .Off
	rendering.overlay_cycle(&overlay)
	testing.expect_value(t, overlay.mode, rendering.Overlay_Mode.FPS_Position)
}

@(test)
test_overlay_cycle_fps_to_env :: proc(t: ^testing.T) {
	overlay: rendering.Text_Overlay
	overlay.mode = .FPS_Position
	rendering.overlay_cycle(&overlay)
	testing.expect_value(t, overlay.mode, rendering.Overlay_Mode.FPS_Position_Env)
}

@(test)
test_overlay_cycle_env_wraps_to_off :: proc(t: ^testing.T) {
	overlay: rendering.Text_Overlay
	overlay.mode = .FPS_Position_Env
	rendering.overlay_cycle(&overlay)
	testing.expect_value(t, overlay.mode, rendering.Overlay_Mode.Off)
}

// --- Overlay FPS update tests ---

@(test)
test_overlay_update_accumulates :: proc(t: ^testing.T) {
	overlay: rendering.Text_Overlay
	// Simulate 10 frames at 16ms each = 0.16s total (below 0.5s threshold)
	for _ in 0..<10 {
		rendering.overlay_update(&overlay, 0.016)
	}
	// Should not have updated fps_display yet (accum < 0.5)
	testing.expect_value(t, overlay.fps_display, f32(0.0))
	testing.expect_value(t, overlay.frame_count, i32(10))
}

@(test)
test_overlay_update_triggers_at_half_second :: proc(t: ^testing.T) {
	overlay: rendering.Text_Overlay
	// Simulate 30 frames at 16.67ms = ~0.5s
	for _ in 0..<30 {
		rendering.overlay_update(&overlay, 1.0 / 60.0)
	}
	// After 0.5s threshold, fps_display should be computed and frame_count reset
	testing.expect(t, overlay.fps_display > 0.0, "fps_display should be computed after 0.5s")
	testing.expect_value(t, overlay.frame_count, i32(0))
}

// --- Instanced update_prev_centers tests ---

@(test)
test_instanced_update_prev_centers :: proc(t: ^testing.T) {
	inst: rendering.Instanced_Spheres
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, 3)
	defer delete(inst.instances)
	inst.count = 3

	// Set up model matrices with known positions
	for i in 0..<3 {
		model := mt.MAT4_IDENTITY
		model[3][0] = f32(i) * 2.0
		model[3][1] = f32(i) * 3.0
		model[3][2] = f32(i) * 4.0
		inst.instances[i] = types.Sphere_Instance{
			model       = model,
			prev_center = mt.VEC3_ZERO,
		}
	}

	rendering.instanced_update_prev_centers(&inst)

	// prev_center should now match model translation
	testing.expect_value(t, inst.instances[0].prev_center, mt.Vec3{0, 0, 0})
	testing.expect_value(t, inst.instances[1].prev_center, mt.Vec3{2, 3, 4})
	testing.expect_value(t, inst.instances[2].prev_center, mt.Vec3{4, 6, 8})
}
