package postfx

import gl "vendor:OpenGL"
import "core:fmt"
import "core:strings"

import log "../../core/log"
import shader "../shader"

// Shader variant cache — compile optimized uber-shader variants
// with #define flags that eliminate dead branches at compile time.

MAX_CACHED_VARIANTS :: 8

Shader_Variant :: struct {
	program: u32,
	effects: Effect_Flags,
}

Shader_Cache :: struct {
	variants: [MAX_CACHED_VARIANTS]Shader_Variant,
	count:    i32,
	enabled:  bool,
}

// Try to find a cached variant for the given effect flags.
// Returns program ID or 0 if not cached.
shader_cache_find :: proc(cache: ^Shader_Cache, effects: Effect_Flags) -> u32 {
	if !cache.enabled { return 0 }
	for i in 0 ..< cache.count {
		if cache.variants[i].effects == effects {
			return cache.variants[i].program
		}
	}
	return 0
}

// Compile and cache a shader variant for the given effect flags.
// Returns the compiled program, or 0 on failure.
shader_cache_compile :: proc(cache: ^Shader_Cache, effects: Effect_Flags) -> u32 {
	if !cache.enabled { return 0 }
	if cache.count >= MAX_CACHED_VARIANTS {
		log.log_warning("suckless-odin.postfx.shader_cache", "Cache full (%d variants)", MAX_CACHED_VARIANTS)
		return 0
	}

	// Build #define preamble
	preamble := build_defines_preamble(effects)
	defer delete(preamble)

	// Load and prepend defines to fragment shader source
	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		preamble,
	)
	if !ok {
		log.log_warning("suckless-odin.postfx.shader_cache", "Failed to compile variant")
		return 0
	}

	// Set sampler uniforms
	gl.UseProgram(program)
	loc_screen := gl.GetUniformLocation(program, "screenTexture")
	if loc_screen >= 0 { gl.Uniform1i(loc_screen, TEX_UNIT_SCENE) }
	loc_bloom := gl.GetUniformLocation(program, "bloomTexture")
	if loc_bloom >= 0 { gl.Uniform1i(loc_bloom, TEX_UNIT_BLOOM) }
	gl.UseProgram(0)

	// Store in cache
	cache.variants[cache.count] = {program = program, effects = effects}
	cache.count += 1

	log.log_info("suckless-odin.postfx.shader_cache", "Compiled variant #%d (effects: 0x%08X)", cache.count, transmute(u32)effects)
	return program
}

// Destroy all cached shader variants.
shader_cache_destroy :: proc(cache: ^Shader_Cache) {
	for i in 0 ..< cache.count {
		if cache.variants[i].program != 0 {
			gl.DeleteProgram(cache.variants[i].program)
			cache.variants[i].program = 0
		}
	}
	cache.count = 0
}

// Build GLSL #define preamble for the given effects.
// Inserts after #version line when prepended.
@(private)
build_defines_preamble :: proc(effects: Effect_Flags) -> string {
	b := strings.builder_make()

	// Static defines that override runtime bitfield checks
	if .Vignette in effects      { fmt.sbprintf(&b, "#define STATIC_VIGNETTE 1\n") }
	if .Grain in effects         { fmt.sbprintf(&b, "#define STATIC_GRAIN 1\n") }
	if .Exposure in effects      { fmt.sbprintf(&b, "#define STATIC_EXPOSURE 1\n") }
	if .Chrom_Abbr in effects    { fmt.sbprintf(&b, "#define STATIC_CHROM_ABBR 1\n") }
	if .Bloom in effects         { fmt.sbprintf(&b, "#define STATIC_BLOOM 1\n") }
	if .Color_Grading in effects { fmt.sbprintf(&b, "#define STATIC_COLOR_GRADING 1\n") }
	if .FXAA in effects          { fmt.sbprintf(&b, "#define STATIC_FXAA 1\n") }
	if .Tonemap in effects       { fmt.sbprintf(&b, "#define STATIC_TONEMAP 1\n") }

	return strings.to_string(b)
}
