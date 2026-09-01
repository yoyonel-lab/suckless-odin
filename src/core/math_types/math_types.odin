package math_types

import "core:math/linalg/glsl"
import "core:math/linalg"
import "core:math"

// Type aliases mapping cglm types to Odin's GLSL-compatible linalg.
// These provide an ISO-equivalent API to the C version's cglm usage.

Vec2 :: glsl.vec2
Vec3 :: glsl.vec3
Vec4 :: glsl.vec4
Mat3 :: glsl.mat3x3
Mat4 :: glsl.mat4x4
Quat :: quaternion128

// Constants
VEC3_ZERO   :: Vec3{0, 0, 0}
VEC3_ONE    :: Vec3{1, 1, 1}
VEC3_UP     :: Vec3{0, 1, 0}
VEC3_RIGHT  :: Vec3{1, 0, 0}
VEC3_FRONT  :: Vec3{0, 0, -1}
MAT4_IDENTITY :: Mat4{
	1, 0, 0, 0,
	0, 1, 0, 0,
	0, 0, 1, 0,
	0, 0, 0, 1,
}

// Utility functions mapping to cglm equivalents

radians :: proc(degrees: f32) -> f32 {
	return degrees * math.RAD_PER_DEG
}

degrees :: proc(rad: f32) -> f32 {
	return rad * math.DEG_PER_RAD
}

vec3_normalize :: proc(v: Vec3) -> Vec3 {
	return glsl.normalize(v)
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return glsl.cross(a, b)
}

vec3_dot :: proc(a, b: Vec3) -> f32 {
	return glsl.dot(a, b)
}

vec3_length :: proc(v: Vec3) -> f32 {
	return glsl.length(v)
}

vec3_lerp :: proc(a, b: Vec3, t: f32) -> Vec3 {
	return glsl.mix(a, b, Vec3{t, t, t})
}

vec3_scale :: proc(v: Vec3, s: f32) -> Vec3 {
	return v * s
}

// View matrix (equivalent to cglm's glm_lookat)
look_at :: proc(eye, center, up: Vec3) -> Mat4 {
	f := vec3_normalize(center - eye)
	s := vec3_normalize(vec3_cross(f, up))
	u := vec3_cross(s, f)

	result := MAT4_IDENTITY
	result[0][0] = s.x
	result[1][0] = s.y
	result[2][0] = s.z
	result[0][1] = u.x
	result[1][1] = u.y
	result[2][1] = u.z
	result[0][2] = -f.x
	result[1][2] = -f.y
	result[2][2] = -f.z
	result[3][0] = -vec3_dot(s, eye)
	result[3][1] = -vec3_dot(u, eye)
	result[3][2] = vec3_dot(f, eye)
	return result
}

// Perspective projection (equivalent to cglm's glm_perspective)
perspective :: proc(fov_y, aspect, near, far: f32) -> Mat4 {
	tan_half_fov := math.tan(fov_y / 2.0)
	result := Mat4{}
	result[0][0] = 1.0 / (aspect * tan_half_fov)
	result[1][1] = 1.0 / tan_half_fov
	result[2][2] = -(far + near) / (far - near)
	result[2][3] = -1.0
	result[3][2] = -(2.0 * far * near) / (far - near)
	return result
}

// Matrix multiply
mat4_mul :: proc(a, b: Mat4) -> Mat4 {
	return a * b
}

// Matrix inverse
mat4_inverse :: proc(m: Mat4) -> Mat4 {
	return linalg.inverse(m)
}

// Translation matrix
mat4_translate :: proc(v: Vec3) -> Mat4 {
	result := MAT4_IDENTITY
	result[3][0] = v.x
	result[3][1] = v.y
	result[3][2] = v.z
	return result
}
