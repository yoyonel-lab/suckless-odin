package types

import mt "../../core/math_types"

// Per-instance data sent to the shader via SSBO (binding 2).
// ISO port of SphereInstance from sphere_types.h.
// 64-byte aligned for optimal GPU throughput and SIMD compatibility.
Sphere_Instance :: struct #align(64) {
	model:       mt.Mat4,  // 4x4 Transformation matrix
	albedo:      mt.Vec3,  // Base color (linear RGB)
	metallic:    f32,      // PBR metallic factor (0.0 - 1.0)
	roughness:   f32,      // PBR roughness factor (0.0 - 1.0)
	ao:          f32,      // Ambient occlusion factor
	_:           f32,      // std430 alignment
	prev_center: mt.Vec3,  // Previous frame center (motion blur)
}

// Compile-time layout verification — matches GLSL SphereInstance (std430, 128B stride).
// #packed fields + uniform alignment (all 4B) → size_of alone guarantees layout.
// Section boundary offsets catch accidental field reordering.
#assert(size_of(Sphere_Instance) == 128)
#assert(offset_of(Sphere_Instance, albedo)      == 64)  // after mat4
#assert(offset_of(Sphere_Instance, prev_center) == 92)  // after padding

// Anti-Aliasing modes
AA_Mode :: enum {
	None,
	FXAA,
	MSAA,
}

aa_mode_to_string :: proc(mode: AA_Mode) -> string {
	switch mode {
	case .None: return "None"
	case .FXAA: return "FXAA"
	case .MSAA: return "MSAA"
	}
	return "Unknown"
}

Specular_AA_Mode :: enum {
	Screen_Space = 0,
	Curvature    = 1,
}

Specular_AA_Debug_Mode :: enum {
	Off                = 0,
	Grayscale_Variance = 1,
	Color_Difference   = 2,
}

