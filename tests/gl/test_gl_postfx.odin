// +build test
// Post-processing pipeline GL tests — shader compilation, linking, and variant validation.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
// Requires a display (or xvfb-run on CI).
package test_gl

import "core:testing"
import "core:fmt"

import gl "vendor:OpenGL"

import shader "../../src/rendering/shader"

// --- PostFX Shader Compilation Tests ---

@(test)
test_postfx_vert_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/postfx.vert")
	testing.expect(t, ok, "failed to read postfx.vert")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.VERTEX_SHADER)
	testing.expect(t, compile_ok, "postfx.vert compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_postfx_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/postfx.frag")
	testing.expect(t, ok, "failed to read postfx.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "postfx.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_bloom_prefilter_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/bloom_prefilter.frag")
	testing.expect(t, ok, "failed to read bloom_prefilter.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "bloom_prefilter.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_bloom_downsample_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/bloom_downsample.frag")
	testing.expect(t, ok, "failed to read bloom_downsample.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "bloom_downsample.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_bloom_upsample_frag_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/bloom_upsample.frag")
	testing.expect(t, ok, "failed to read bloom_upsample.frag")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.FRAGMENT_SHADER)
	testing.expect(t, compile_ok, "bloom_upsample.frag compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

// --- PostFX Program Linking Tests ---

@(test)
test_postfx_composite_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/postfx.frag")
	testing.expect(t, ok, "postfx composite program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_bloom_prefilter_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/bloom_prefilter.frag")
	testing.expect(t, ok, "bloom prefilter program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_bloom_downsample_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/bloom_downsample.frag")
	testing.expect(t, ok, "bloom downsample program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_bloom_upsample_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/bloom_upsample.frag")
	testing.expect(t, ok, "bloom upsample program linking failed")
	if ok { gl.DeleteProgram(program) }
}

// --- Shader Variant Compilation (with #define injection) ---

@(test)
test_postfx_variant_all_effects :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Compile with ALL static defines enabled
	defines := "#define STATIC_VIGNETTE 1\n#define STATIC_GRAIN 1\n#define STATIC_EXPOSURE 1\n#define STATIC_CHROM_ABBR 1\n#define STATIC_BLOOM 1\n#define STATIC_COLOR_GRADING 1\n#define STATIC_FXAA 1\n#define STATIC_TONEMAP 1\n"

	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		defines,
	)
	testing.expect(t, ok, "postfx variant (all effects) compilation failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_postfx_variant_minimal :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Compile with only exposure (minimal path)
	defines := "#define STATIC_EXPOSURE 1\n"

	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		defines,
	)
	testing.expect(t, ok, "postfx variant (minimal) compilation failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_postfx_variant_bloom_tonemap :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Common combination: bloom + tonemapping
	defines := "#define STATIC_BLOOM 1\n#define STATIC_TONEMAP 1\n#define STATIC_EXPOSURE 1\n"

	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		defines,
	)
	testing.expect(t, ok, "postfx variant (bloom+tonemap) compilation failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_postfx_variant_no_defines :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Empty defines: uber-shader with all runtime branches
	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		"",
	)
	testing.expect(t, ok, "postfx variant (no defines) compilation failed")
	if ok { gl.DeleteProgram(program) }
}

// --- Uniform Validation ---

@(test)
test_postfx_uniforms_exist :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/postfx.frag")
	if !ok {
		testing.expect(t, false, "cannot test uniforms: program failed to link")
		return
	}
	defer gl.DeleteProgram(program)

	gl.UseProgram(program)

	// Essential sampler uniforms
	screen_loc := gl.GetUniformLocation(program, "screenTexture")
	testing.expectf(t, screen_loc >= 0, "screenTexture uniform not found (loc=%d)", screen_loc)

	bloom_loc := gl.GetUniformLocation(program, "bloomTexture")
	testing.expectf(t, bloom_loc >= 0, "bloomTexture uniform not found (loc=%d)", bloom_loc)

	autoexp_loc := gl.GetUniformLocation(program, "autoExposureTexture")
	testing.expectf(t, autoexp_loc >= 0, "autoExposureTexture uniform not found (loc=%d)", autoexp_loc)

	gl.UseProgram(0)
}

// --- Auto-Exposure Compute Shader Tests ---

@(test)
test_lum_downsample_compute_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/lum_downsample.comp")
	testing.expect(t, ok, "failed to read lum_downsample.comp")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.COMPUTE_SHADER)
	testing.expect(t, compile_ok, "lum_downsample.comp compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_lum_adapt_compute_compiles :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	source, ok := shader.read_file("shaders/postfx/lum_adapt.comp")
	testing.expect(t, ok, "failed to read lum_adapt.comp")
	defer delete(source)

	shader_id, compile_ok := shader.compile(source, gl.COMPUTE_SHADER)
	testing.expect(t, compile_ok, "lum_adapt.comp compilation failed")
	if compile_ok { gl.DeleteShader(shader_id) }
}

@(test)
test_lum_downsample_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_compute("shaders/postfx/lum_downsample.comp")
	testing.expect(t, ok, "lum_downsample compute program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_lum_adapt_program_links :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_compute("shaders/postfx/lum_adapt.comp")
	testing.expect(t, ok, "lum_adapt compute program linking failed")
	if ok { gl.DeleteProgram(program) }
}

@(test)
test_lum_adapt_uniforms_exist :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_compute("shaders/postfx/lum_adapt.comp")
	if !ok {
		testing.expect(t, false, "cannot test uniforms: program failed to link")
		return
	}
	defer gl.DeleteProgram(program)

	gl.UseProgram(program)

	uniforms := [?]cstring{"deltaTime", "minLuminance", "maxLuminance", "speedUp", "speedDown", "keyValue"}
	for name in uniforms {
		loc := gl.GetUniformLocation(program, name)
		testing.expectf(t, loc >= 0, "uniform '%s' not found in lum_adapt (loc=%d)", name, loc)
	}

	gl.UseProgram(0)
}

// --- DoF Integration Tests ---

@(test)
test_postfx_dof_samplers_exist :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	program, ok := shader.load_program("shaders/postfx/postfx.vert", "shaders/postfx/postfx.frag")
	if !ok {
		testing.expect(t, false, "cannot test DoF samplers: program failed to link")
		return
	}
	defer gl.DeleteProgram(program)

	gl.UseProgram(program)

	depth_loc := gl.GetUniformLocation(program, "depthTexture")
	testing.expectf(t, depth_loc >= 0, "depthTexture uniform not found (loc=%d)", depth_loc)

	dof_loc := gl.GetUniformLocation(program, "dofBlurTexture")
	testing.expectf(t, dof_loc >= 0, "dofBlurTexture uniform not found (loc=%d)", dof_loc)

	gl.UseProgram(0)
}
