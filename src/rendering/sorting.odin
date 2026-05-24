package rendering

import "core:slice"

import mt  "../core/math_types"
import types "./types"

// Sort mode for billboard instance ordering (back-to-front).
// ISO port of billboard_sorting.h from legacy C11 project.
Sort_Mode :: enum i32 {
	None  = 0,  // No sorting (SSBO order = creation order)
	CPU   = 1,  // qsort back-to-front by squared distance
	Radix = 2,  // Radix sort (O(n), 4 passes of 8-bit)
}

// Lightweight proxy for sorting without moving 128-byte structs.
Sort_Entry :: struct {
	original_index: i32,
	depth:          f32,  // Squared distance from camera
}

FLOAT_SIGN_MASK       :: u32(0x80000000)
FLOAT_COMPLEMENT_MASK :: u32(0xFFFFFFFF)
RADIX_BITS_PER_PASS   :: 8
RADIX_BUCKETS         :: 256
RADIX_SHIFT_LIMIT     :: 32
RADIX_MASK            :: u32(0xFF)

// Sort sphere instances back-to-front (descending depth) using qsort.
// Operates on the SoA dynamic array in-place, reorders all fields.
instanced_sort_cpu :: proc(inst: ^Instanced_Spheres, camera_pos: mt.Vec3) {
	count := int(inst.count)
	if count <= 1 { return }

	// Build proxy entries (index + depth²)
	entries := make([]Sort_Entry, count, context.temp_allocator)
	for i in 0 ..< count {
		model := inst.instances.model[i]
		pos := mt.Vec3{model[3][0], model[3][1], model[3][2]}
		diff := pos - camera_pos
		entries[i] = Sort_Entry{
			original_index = i32(i),
			depth          = mt.vec3_dot(diff, diff),
		}
	}

	// Sort descending (back-to-front: farthest first)
	slice.sort_by(entries, proc(a, b: Sort_Entry) -> bool {
		return a.depth > b.depth
	})

	// Reorder instances using sorted indices (into temp buffer)
	sorted := make([]types.Sphere_Instance, count, context.temp_allocator)
	for i in 0 ..< count {
		sorted[i] = inst.instances[int(entries[i].original_index)]
	}

	// Write back
	for i in 0 ..< count {
		inst.instances[i] = sorted[i]
	}
}

// Convert float to uint32 that preserves sort order (IEEE 754 trick).
// Positive floats: flip sign bit. Negative floats: flip all bits.
float_to_sortable_uint :: #force_inline proc(f: f32) -> u32 {
	bits := transmute(u32)f
	mask := (bits & FLOAT_SIGN_MASK) != 0 ? FLOAT_COMPLEMENT_MASK : FLOAT_SIGN_MASK
	return bits ~ mask
}

// Sort sphere instances back-to-front using radix sort (O(n), stable).
// 4 passes of 8-bit counting sort with ping-pong buffers.
instanced_sort_radix :: proc(inst: ^Instanced_Spheres, camera_pos: mt.Vec3) {
	count := int(inst.count)
	if count <= 1 { return }

	// Build entries with sortable uint keys
	entries := make([]Sort_Entry, count, context.temp_allocator)
	entries_aux := make([]Sort_Entry, count, context.temp_allocator)

	for i in 0 ..< count {
		model := inst.instances.model[i]
		pos := mt.Vec3{model[3][0], model[3][1], model[3][2]}
		diff := pos - camera_pos
		depth := mt.vec3_dot(diff, diff)

		// Store sortable key in the depth field via transmute
		sortable_key := float_to_sortable_uint(depth)
		entries[i] = Sort_Entry{
			original_index = i32(i),
			depth          = transmute(f32)sortable_key,
		}
	}

	// 4 passes of 8-bit radix sort
	current_in := entries
	current_out := entries_aux

	for shift in u32(0) ..< u32(RADIX_SHIFT_LIMIT) / u32(RADIX_BITS_PER_PASS) {
		bit_shift := shift * u32(RADIX_BITS_PER_PASS)

		// Counting
		counts: [RADIX_BUCKETS]i32
		for i in 0 ..< count {
			bits := transmute(u32)current_in[i].depth
			bucket := (bits >> bit_shift) & RADIX_MASK
			counts[bucket] += 1
		}

		// Prefix sum (descending order for back-to-front)
		offsets: [RADIX_BUCKETS]i32
		offsets[RADIX_BUCKETS - 1] = 0
		for i := i32(RADIX_BUCKETS - 2); i >= 0; i -= 1 {
			offsets[i] = offsets[i + 1] + counts[i + 1]
		}

		// Scatter
		for i in 0 ..< count {
			bits := transmute(u32)current_in[i].depth
			bucket := (bits >> bit_shift) & RADIX_MASK
			current_out[offsets[bucket]] = current_in[i]
			offsets[bucket] += 1
		}

		// Ping-pong
		current_in, current_out = current_out, current_in
	}

	// Result is in current_in (after last swap)
	// Reorder instances
	sorted := make([]types.Sphere_Instance, count, context.temp_allocator)
	for i in 0 ..< count {
		sorted[i] = inst.instances[int(current_in[i].original_index)]
	}

	// Write back
	for i in 0 ..< count {
		inst.instances[i] = sorted[i]
	}
}

// Sort instances using the specified mode.
instanced_sort :: proc(inst: ^Instanced_Spheres, camera_pos: mt.Vec3, mode: Sort_Mode) {
	switch mode {
	case .None:
		// No-op
	case .CPU:
		instanced_sort_cpu(inst, camera_pos)
	case .Radix:
		instanced_sort_radix(inst, camera_pos)
	}
}
