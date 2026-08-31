// +build test
// Phase 2: Headless GL context tests — shader compilation & GPU validation.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
// Requires a display (or xvfb-run on CI).
package test_gl

import "core:testing"
import "core:fmt"

import "vendor:glfw"
import gl "vendor:OpenGL"

import shader "../../src/rendering/shader"
import gl_state "../../src/core/gl_state"

// --- Headless GL context (shared, single-threaded) ---

GL_MAJOR :: 4
GL_MINOR :: 4

@(private)
gl_window: glfw.WindowHandle = nil

@(private)
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
}

// Ensure GL context is initialized (idempotent/fresh for each test).
@(private)
ensure_gl_context :: proc(t: ^testing.T) -> bool {
	if gl_window != nil {
		glfw.DestroyWindow(gl_window)
		gl_window = nil
	}

	if !glfw.Init() {
		testing.expect(t, false, "GLFW init failed — no display available?")
		return false
	}

	glfw.WindowHint(glfw.VISIBLE, 0)  // invisible = headless
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	gl_window = glfw.CreateWindow(64, 64, "test-headless", nil, nil)
	if gl_window == nil {
		glfw.Terminate()
		testing.expect(t, false, "Headless window creation failed")
		return false
	}

	glfw.MakeContextCurrent(gl_window)
	gl.load_up_to(GL_MAJOR, GL_MINOR, gl_set_proc_address)
	gl_state.reset()
	return true
}

// --- Shader compilation tests ---

@(test)
test_background_vert_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/background.vert")
	testing.expect(t, ok, "failed to read background.vert")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.VERTEX_SHADER)
	testing.expect(t, compile_ok, "background.vert compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_background_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/background.frag")
	testing.expect(t, ok, "failed to read background.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "background.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_pbr_billboard_vert_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/pbr_billboard.vert")
	testing.expect(t, ok, "failed to read pbr_billboard.vert")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.VERTEX_SHADER)
	testing.expect(t, compile_ok, "pbr_billboard.vert compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_pbr_billboard_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/pbr_billboard.frag")
	testing.expect(t, ok, "failed to read pbr_billboard.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "pbr_billboard.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_simple_billboard_vert_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/test/simple_billboard.vert")
	testing.expect(t, ok, "failed to read simple_billboard.vert")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.VERTEX_SHADER)
	testing.expect(t, compile_ok, "simple_billboard.vert compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_simple_billboard_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/test/simple_billboard.frag")
	testing.expect(t, ok, "failed to read simple_billboard.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "simple_billboard.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_ibl_irmap_compute_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/IBL/irmap.glsl")
	testing.expect(t, ok, "failed to read IBL/irmap.glsl")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.COMPUTE_SHADER)
	testing.expect(t, compile_ok, "IBL/irmap.glsl compute compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_ibl_spbrdf_compute_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/IBL/spbrdf.glsl")
	testing.expect(t, ok, "failed to read IBL/spbrdf.glsl")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.COMPUTE_SHADER)
	testing.expect(t, compile_ok, "IBL/spbrdf.glsl compute compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_ibl_spmap_compute_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/IBL/spmap.glsl")
	testing.expect(t, ok, "failed to read IBL/spmap.glsl")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.COMPUTE_SHADER)
	testing.expect(t, compile_ok, "IBL/spmap.glsl compute compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

// --- Program linking tests ---

@(test)
test_background_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/background.vert", "shaders/background.frag")
	testing.expect(t, ok, "background program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_pbr_billboard_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/pbr_billboard.vert", "shaders/pbr_billboard.frag")
	testing.expect(t, ok, "pbr_billboard program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_simple_billboard_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/test/simple_billboard.vert", "shaders/test/simple_billboard.frag")
	testing.expect(t, ok, "simple_billboard program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_shadow_cube_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/shadow_cube.vert", "shaders/shadow_cube.frag")
	testing.expect(t, ok, "shadow_cube program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_light_bulb_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/light_bulb.vert", "shaders/light_bulb.frag")
	testing.expect(t, ok, "light_bulb program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_depth_downsample_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/depth_downsample.frag")
	testing.expect(t, ok, "depth_downsample program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_debug_depth_preview_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/debug_depth_preview.frag")
	testing.expect(t, ok, "debug_depth_preview program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_volumetric_raymarch_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_raymarch.frag")
	testing.expect(t, ok, "volumetric_raymarch program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_volumetric_preview_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_preview.frag")
	testing.expect(t, ok, "volumetric_preview program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_volumetric_composite_simple_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_composite_simple.frag")
	testing.expect(t, ok, "volumetric_composite_simple program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_volumetric_taa_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/volumetric_taa.frag")
	testing.expect(t, ok, "volumetric_taa program linking failed")
	if ok { gl.DeleteProgram(program) }
}

// --- GL context validation ---

@(test)
test_gl_context_version :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	major, minor: i32
	gl.GetIntegerv(gl.MAJOR_VERSION, &major)
	gl.GetIntegerv(gl.MINOR_VERSION, &minor)

	testing.expect(t, major >= 4, fmt.tprintf("GL major version %d < 4", major))
	testing.expect(t, minor >= 3, fmt.tprintf("GL minor version %d < 3 (compute shader support)", minor))
}

@(test)
test_gl_compute_shader_supported :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// GL 4.3+ guarantees compute shaders
	max_work_group_count_x: i32
	gl.GetIntegeri_v(gl.MAX_COMPUTE_WORK_GROUP_COUNT, 0, &max_work_group_count_x)
	testing.expect(t, max_work_group_count_x > 0,
		fmt.tprintf("GL_MAX_COMPUTE_WORK_GROUP_COUNT[0] = %d, expected > 0", max_work_group_count_x))
}

@(test)
test_gl_max_texture_size :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	max_tex_size: i32
	gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &max_tex_size)
	// IBL cubemaps need at least 512, HDR textures need 2048+
	testing.expect(t, max_tex_size >= 2048,
		fmt.tprintf("GL_MAX_TEXTURE_SIZE = %d, need >= 2048 for HDR", max_tex_size))
}
