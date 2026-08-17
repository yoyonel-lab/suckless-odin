package postfx

// FXAA Pre-pass — separate render pass for FXAA when combined with Motion Blur.
//
// Architecture:
//   When both FXAA and Motion Blur are active, FXAA must execute BEFORE MB.
//   The uber-shader pipeline is: scene → [effects] → output. Normally FXAA runs
//   inline after MB in the uber-shader, but this causes FXAA to interpret MB's
//   smooth color gradients as geometric edges, producing stair-step artifacts.
//
//   Solution: render FXAA into an intermediate texture (fxaa_tex) BEFORE the
//   composite pass. The composite then reads fxaa_tex as its scene source,
//   so MB samples from the already-anti-aliased image.
//
//   When only FXAA is active (no MB), the uber-shader's inline FXAA is used
//   (zero overhead — no extra pass, no extra texture copy).
//
// GPU cost: one additional fullscreen pass at scene resolution (RGBA16F).
// Measured ~0.2ms on mid-range GPUs at 1080p.

import gl "vendor:OpenGL"

import log "../../core/log"
import dbg "../../core/gl_debug"
import shader "../shader"

// Create FXAA pre-pass resources (FBO, texture, shader program).
@(private)
fxaa_prepass_create :: proc(p: ^Pipeline) -> (ok: bool) {
	// FBO
	gl.GenFramebuffers(1, &p.fxaa_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.fxaa_fbo)

	// RGBA16F texture — matches scene_color_tex format for seamless substitution
	p.fxaa_tex = create_texture_2d(p.width, p.height, gl.RGBA16F, gl.RGBA)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, p.fxaa_tex, 0)

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.postfx", "FXAA pre-pass FBO incomplete: 0x%X", status)
		return false
	}

	dbg.object_label(gl.FRAMEBUFFER, p.fxaa_fbo, "PostFX_FXAA_Prepass_FBO")
	dbg.object_label(gl.TEXTURE, p.fxaa_tex, "PostFX_FXAA_Prepass_Tex")

	// Shader (reuses the same vertex shader as composite)
	p.fxaa_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/fxaa_prepass.frag",
	) or_return

	// Set sampler uniform: screenTexture = unit 0
	gl.UseProgram(p.fxaa_program)
	set_uniform_i32(p.fxaa_program, "screenTexture", TEX_UNIT_SCENE)
	gl.UseProgram(0)

	log.log_info("suckless-odin.postfx", "FXAA pre-pass created (%dx%d)", p.width, p.height)
	return true
}

// Destroy FXAA pre-pass resources.
@(private)
fxaa_prepass_destroy :: proc(p: ^Pipeline) {
	delete_program(&p.fxaa_program)
	delete_texture(&p.fxaa_tex)
	delete_fbo(&p.fxaa_fbo)
}

// Resize FXAA pre-pass texture (called on window resize).
@(private)
fxaa_prepass_resize :: proc(p: ^Pipeline) {
	if p.fxaa_tex != 0 {
		delete_texture(&p.fxaa_tex)
		delete_fbo(&p.fxaa_fbo)

		gl.GenFramebuffers(1, &p.fxaa_fbo)
		gl.BindFramebuffer(gl.FRAMEBUFFER, p.fxaa_fbo)
		p.fxaa_tex = create_texture_2d(p.width, p.height, gl.RGBA16F, gl.RGBA)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, p.fxaa_tex, 0)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		dbg.object_label(gl.FRAMEBUFFER, p.fxaa_fbo, "PostFX_FXAA_Prepass_FBO")
		dbg.object_label(gl.TEXTURE, p.fxaa_tex, "PostFX_FXAA_Prepass_Tex")
	}
}
