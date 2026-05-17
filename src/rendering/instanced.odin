package rendering

import gl "vendor:OpenGL"

import log "../core/log"
import mt  "../core/math_types"
import types "./types"
import settings "../core/settings"

// Multi-sphere instanced rendering via SSBO.
// Uses #soa (struct-of-arrays) for cache-friendly CPU-side iteration:
//   - All positions contiguous → fast frustum culling
//   - All roughness values contiguous → fast material animation
//   - All prev_centers contiguous → fast motion blur updates
// GPU SSBO still receives AoS (packed at upload time).
Instanced_Spheres :: struct {
	ssbo:       u32,
	instances:  #soa [dynamic]types.Sphere_Instance,  // SoA layout for CPU cache locality
	count:      i32,
}

SSBO_BINDING :: 2  // Must match billboard_instance_ssbo.glsl binding

HALF_OFFSET_MULTIPLIER :: 0.5

// Create spheres from material library in a grid layout (ISO port of scene_init_instancing)
instanced_create :: proc(inst: ^Instanced_Spheres, mat_lib: ^Material_Lib) {
	cols :: settings.DEFAULT_COLS
	max_count :: cols * cols  // 100
	total_count := min(mat_lib.count, max_count)
	rows := (total_count + cols - 1) / cols
	spacing := f32(settings.DEFAULT_SPACING)

	// Grid dimensions for centering (ISO: grid_w / grid_h)
	grid_w := f32(cols - 1) * spacing
	grid_h := f32(rows - 1) * spacing

	inst.instances = make(#soa [dynamic]types.Sphere_Instance, total_count)
	inst.count = i32(total_count)

	for i in 0..<total_count {
		grid_x := i % cols
		grid_y := i / cols

		pos_x := f32(grid_x) * spacing - grid_w * HALF_OFFSET_MULTIPLIER
		pos_y := -(f32(grid_y) * spacing - grid_h * HALF_OFFSET_MULTIPLIER)
		position := mt.Vec3{pos_x, pos_y, 0.0}

		// Build model matrix: identity + translate (no scale, radius=1.0)
		model := mt.MAT4_IDENTITY
		model[3][0] = position.x
		model[3][1] = position.y
		model[3][2] = position.z

		// Material from library
		mat := &mat_lib.materials[i]

		inst.instances[i] = types.Sphere_Instance{
			model       = model,
			albedo      = mat.albedo,
			metallic    = mat.metallic,
			roughness   = mat.roughness,
			ao          = 1.0,
			prev_center = position,
		}
	}

	// Pack SoA → AoS and upload to SSBO
	instanced_upload(inst)

	log.log_info("suckless-odin.instanced", "Created %d sphere instances (SSBO binding %d, %dx%d grid, spacing=%.1f, #soa)",
		total_count, SSBO_BINDING, cols, rows, spacing)
}

// Pack SoA → AoS staging buffer and upload to GPU SSBO.
// Called once at init, and again if CPU-side data changes (animation, physics).
instanced_upload :: proc(inst: ^Instanced_Spheres) {
	count := int(inst.count)
	if count == 0 { return }

	// Pack from SoA to AoS (GPU expects struct-per-instance layout)
	// Uses temp_allocator — freed automatically, no leak possible.
	gpu_data := make([]types.Sphere_Instance, count, context.temp_allocator)
	for i in 0..<count {
		gpu_data[i] = inst.instances[i]
	}

	if inst.ssbo == 0 {
		gl.GenBuffers(1, &inst.ssbo)
	}

	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, inst.ssbo)
	gl.BufferData(
		gl.SHADER_STORAGE_BUFFER,
		count * size_of(types.Sphere_Instance),
		raw_data(gpu_data),
		gl.DYNAMIC_DRAW,
	)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, SSBO_BINDING, inst.ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0)
}

// Update prev_center from current model positions (motion blur preparation).
// Benefits from SoA: iterates contiguous model[3] columns and prev_center arrays only,
// avoiding loading albedo/metallic/roughness/ao into cache lines.
instanced_update_prev_centers :: proc(inst: ^Instanced_Spheres) {
	count := int(inst.count)
	// Direct field-slice access — #soa gives us contiguous arrays per field
	models := inst.instances.model[:]
	prev_centers := inst.instances.prev_center[:]

	for i in 0..<count {
		prev_centers[i] = mt.Vec3{models[i][3][0], models[i][3][1], models[i][3][2]}
	}
}

// Bind SSBO before draw
instanced_bind :: proc(inst: ^Instanced_Spheres) {
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, SSBO_BINDING, inst.ssbo)
}

// Draw all instances (billboard quad * N instances)
instanced_draw :: proc(inst: ^Instanced_Spheres, bb: ^Billboard) {
	if bb.vao == 0 || inst.count == 0 { return }

	culling_enabled := gl.IsEnabled(gl.CULL_FACE)
	gl.Disable(gl.CULL_FACE)

	gl.BindVertexArray(bb.vao)
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, inst.count)

	if culling_enabled {
		gl.Enable(gl.CULL_FACE)
	}
}

instanced_destroy :: proc(inst: ^Instanced_Spheres) {
	if inst.ssbo != 0 {
		gl.DeleteBuffers(1, &inst.ssbo)
		inst.ssbo = 0
	}
	delete(inst.instances)
	inst.count = 0
}
