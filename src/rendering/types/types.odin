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
	_padding:    f32,      // Alignment padding
	prev_center: mt.Vec3,  // Previous frame center (motion blur)
}

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
