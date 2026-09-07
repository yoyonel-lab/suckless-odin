// +build test
package tests

import "core:testing"
import "core:math"

import rendering "../src/rendering"
import types "../src/rendering/types"
import mt "../src/core/math_types"

@(test)
test_ao_baker_init_and_bake :: proc(t: ^testing.T) {
	// Create instanced spheres (3 spheres: left=-2.5, center=0.0, right=2.5)
	inst: rendering.Instanced_Spheres
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, 3)
	defer delete(inst.instances)
	inst.count = 3

	positions := [3]mt.Vec3{
		{-2.5, 0.0, 0.0},
		{ 0.0, 0.0, 0.0},
		{ 2.5, 0.0, 0.0},
	}
	for i in 0..<3 {
		model := mt.MAT4_IDENTITY
		model[3][0] = positions[i].x
		model[3][1] = positions[i].y
		model[3][2] = positions[i].z
		inst.instances[i] = types.Sphere_Instance{
			model = model,
			ao    = 1.0,
		}
	}

	// Initialize Baker (low resolution 32x16 for fast test execution)
	baker: rendering.AO_Baker
	baker.width = 32
	baker.height = 16
	baker.num_samples = 64
	pixel_size := int(baker.width) * int(baker.height) * 4
	baker.cpu_pixels = make([dynamic]u8, pixel_size)
	baker.gpu_pixels = make([dynamic]u8, pixel_size)
	defer delete(baker.cpu_pixels)
	defer delete(baker.gpu_pixels)

	// Bake center sphere (index 1) with 64 samples
	ok := rendering.ao_baker_bake_and_compare(&baker, &inst, 1, 64)

	testing.expect(t, ok, "Bake and compare should return true")
	testing.expect(t, baker.is_baked, "Baker should be marked as baked")
	testing.expect(t, baker.cpu_time_ms >= 0.0, "CPU Bake time should be non-negative")
	testing.expect(t, baker.cpu_threads_used >= 1, "Should use at least 1 CPU thread")
	testing.expect(t, baker.cpu_mrays_per_sec > 0.0, "Mrays/s throughput should be positive")
	testing.expect(t, len(rendering.ao_baker_get_cpu_png_path(&baker)) > 0, "CPU PNG path should be set")
	testing.expect(t, len(rendering.ao_baker_get_gpu_png_path(&baker)) > 0, "GPU PNG path should be set")
}

@(test)
test_ao_baker_bake_range :: proc(t: ^testing.T) {
	inst: rendering.Instanced_Spheres
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, 4)
	defer delete(inst.instances)
	inst.count = 4

	for i in 0..<4 {
		model := mt.MAT4_IDENTITY
		model[3][0] = (f32(i) - 1.5) * 2.5
		inst.instances[i] = types.Sphere_Instance{
			model = model,
			ao    = 1.0,
		}
	}

	baker: rendering.AO_Baker
	baker.width = 16
	baker.height = 8
	baker.num_samples = 32
	pixel_size := int(baker.width) * int(baker.height) * 4
	baker.cpu_pixels = make([dynamic]u8, pixel_size)
	baker.gpu_pixels = make([dynamic]u8, pixel_size)
	defer delete(baker.cpu_pixels)
	defer delete(baker.gpu_pixels)

	// Test Range 1..2 (2 spheres) with CPU only
	ok := rendering.ao_baker_bake_range(&baker, &inst, 1, 2, 32, bake_cpu = true, bake_gpu = false)
	testing.expect(t, ok, "Range bake CPU should succeed")
	testing.expect_value(t, baker.spheres_baked_count, 2)
	testing.expect(t, baker.cpu_time_ms > 0.0, "CPU time should be positive")
	testing.expect(t, baker.is_baked, "Baker should be marked as baked")
}

@(test)
test_ao_baker_bake_direct_vram :: proc(t: ^testing.T) {
	inst: rendering.Instanced_Spheres
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, 3)
	defer delete(inst.instances)
	inst.count = 3

	baker: rendering.AO_Baker
	baker.width = 16
	baker.height = 8
	baker.num_samples = 32

	// Fast path directly returns false when GPU program / texture array is not initialized (headless unit test)
	_, ok := rendering.ao_baker_bake_direct_vram(&baker, &inst, 0, 2, 32)
	testing.expect(t, !ok, "Direct VRAM bake without GL context should safely return false")
}
