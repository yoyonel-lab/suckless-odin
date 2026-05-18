package postfx

import gl "vendor:OpenGL"

import shader "../shader"
import log "../../core/log"

// Number of bloom mip levels (half-res cascade).
BLOOM_MIP_LEVELS :: 5

// Single mip level in the bloom chain.
Bloom_Mip :: struct {
	texture: u32,
	width:   i32,
	height:  i32,
}

// Bloom multi-pass effect: prefilter → downsample chain → upsample chain.
Bloom_FX :: struct {
	prefilter_program:  u32,
	downsample_program: u32,
	upsample_program:   u32,
	fbo:                u32,
	mips:               [BLOOM_MIP_LEVELS]Bloom_Mip,
}

// Initialize bloom resources (shaders, FBO, mip textures).
bloom_create :: proc(b: ^Bloom_FX, width, height: i32) -> (ok: bool) {
	defer if !ok { bloom_destroy(b) }

	// Load shaders (all use the same vertex shader)
	b.prefilter_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/bloom_prefilter.frag",
	) or_return

	b.downsample_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/bloom_downsample.frag",
	) or_return

	b.upsample_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/bloom_upsample.frag",
	) or_return

	// Create FBO (single FBO, re-attach textures per pass)
	gl.GenFramebuffers(1, &b.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)

	// Create mip chain textures (each half the previous)
	mip_w := width
	mip_h := height
	for i in 0 ..< BLOOM_MIP_LEVELS {
		mip_w /= 2
		mip_h /= 2
		if mip_w < 1 { mip_w = 1 }
		if mip_h < 1 { mip_h = 1 }

		b.mips[i].width = mip_w
		b.mips[i].height = mip_h
		b.mips[i].texture = create_texture_2d(mip_w, mip_h, gl.R11F_G11F_B10F, gl.RGB)
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	log.log_info("suckless-odin.postfx.bloom", "Bloom created (%d mips from %dx%d)", BLOOM_MIP_LEVELS, width, height)
	return true
}

// Destroy all bloom GPU resources.
bloom_destroy :: proc(b: ^Bloom_FX) {
	delete_fbo(&b.fbo)
	for &mip in b.mips {
		delete_texture(&mip.texture)
	}
	delete_program(&b.prefilter_program)
	delete_program(&b.downsample_program)
	delete_program(&b.upsample_program)
}

// Render bloom passes: prefilter → downsample → upsample.
// src_texture: scene HDR color texture to bloom from.
// Result is in mips[0].texture, ready to be bound as bloom texture unit.
bloom_render :: proc(b: ^Bloom_FX, params: ^Bloom_Params, src_texture: u32, quad: ^Fullscreen_Quad) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)
	defer gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Disable(gl.DEPTH_TEST)

	// --- 1. Prefilter: extract bright pixels → mip[0] ---
	gl.UseProgram(b.prefilter_program)
	gl.Uniform1f(0, params.threshold)
	gl.Uniform1f(1, params.soft_threshold)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, src_texture)

	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, b.mips[0].texture, 0)
	gl.Viewport(0, 0, b.mips[0].width, b.mips[0].height)

	quad_draw(quad)

	// --- 2. Downsample chain: mip[i] → mip[i+1] ---
	gl.UseProgram(b.downsample_program)

	for i in 0 ..< BLOOM_MIP_LEVELS - 1 {
		mip_src := &b.mips[i]
		mip_dst := &b.mips[i + 1]

		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, mip_src.texture)

		gl.Uniform2f(0, f32(mip_src.width), f32(mip_src.height))

		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, mip_dst.texture, 0)
		gl.Viewport(0, 0, mip_dst.width, mip_dst.height)

		quad_draw(quad)
	}

	// --- 3. Upsample chain: mip[i+1] → mip[i] (additive blend) ---
	gl.UseProgram(b.upsample_program)
	gl.Uniform1f(0, params.radius)

	gl.Enable(gl.BLEND)
	defer gl.Disable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE)
	gl.BlendEquation(gl.FUNC_ADD)

	for i := i32(BLOOM_MIP_LEVELS - 2); i >= 0; i -= 1 {
		mip_src := &b.mips[i + 1]
		mip_dst := &b.mips[i]

		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, mip_src.texture)

		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, mip_dst.texture, 0)
		gl.Viewport(0, 0, mip_dst.width, mip_dst.height)

		quad_draw(quad)
	}
}

// Resize bloom mip chain (call on window resize).
bloom_resize :: proc(b: ^Bloom_FX, width, height: i32) {
	mip_w := width
	mip_h := height
	for i in 0 ..< BLOOM_MIP_LEVELS {
		mip_w /= 2
		mip_h /= 2
		if mip_w < 1 { mip_w = 1 }
		if mip_h < 1 { mip_h = 1 }

		b.mips[i].width = mip_w
		b.mips[i].height = mip_h

		gl.BindTexture(gl.TEXTURE_2D, b.mips[i].texture)
		gl.TexImage2D(
			gl.TEXTURE_2D, 0, gl.R11F_G11F_B10F,
			mip_w, mip_h, 0,
			gl.RGB, gl.FLOAT, nil,
		)
	}
}

// Get the final bloom texture (mip[0] after full render pass).
bloom_get_texture :: proc(b: ^Bloom_FX) -> u32 {
	return b.mips[0].texture
}
