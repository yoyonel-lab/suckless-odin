package postfx

import gl "vendor:OpenGL"

import log "../../core/log"
import shader "../shader"

// Post-processing pipeline state — owns FBO, textures, UBO, and shader.
Pipeline :: struct {
	// GPU resources
	scene_fbo:       u32,
	scene_color_tex: u32,
	depth_tex:       u32,
	settings_ubo:    u32,
	quad:            Fullscreen_Quad,

	// Multi-pass effects
	bloom_fx:         Bloom_FX,
	dof_fx:           Dof_FX,
	auto_exposure_fx: Auto_Exposure_FX,

	// GPU profiling
	timers: Gpu_Timers,

	// Shader variant cache (optional optimization)
	shader_cache: Shader_Cache,

	// Shader
	composite_program: u32,

	// Resolution
	width:  i32,
	height: i32,

	// Effect state
	active_effects: Effect_Flags,
	enabled:        bool,

	// Parameters
	vignette:      Vignette_Params,
	grain:         Grain_Params,
	exposure:      Exposure_Params,
	chrom_abbr:    Chrom_Aberration_Params,
	white_balance: White_Balance_Params,
	color_grading: Color_Grading_Params,
	tonemapper:    Tonemap_Params,
	bloom:         Bloom_Params,
	fxaa:          FXAA_Params,
	dof:           Dof_Params,

	// Per-frame data
	time:      f32,
	dt:        f32,
	ubo_dirty: bool,

	// Saved state for begin/end (restored framebuffer)
	prev_fbo:      i32,
	prev_viewport: [4]i32,
}

// Initialize the post-processing pipeline.
pipeline_create :: proc(p: ^Pipeline, width, height: i32) -> (ok: bool) {
	defer if !ok { pipeline_destroy(p) }

	p.width = width
	p.height = height
	p.enabled = true
	p.ubo_dirty = true

	// Set default parameters
	init_defaults(p)

	// Default active effects: exposure only (identity at 1.0)
	p.active_effects = {.Exposure}

	// Create fullscreen quad
	quad_create(&p.quad)

	// Create HDR framebuffer
	create_framebuffer(p) or_return

	// Create UBO
	gl.GenBuffers(1, &p.settings_ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, p.settings_ubo)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(Post_FX_UBO), nil, gl.DYNAMIC_DRAW)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, p.settings_ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	// Load composite shader
	p.composite_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
	) or_return

	// Set sampler uniforms (fixed texture unit bindings)
	gl.UseProgram(p.composite_program)
	set_sampler_uniforms(p.composite_program)
	gl.UseProgram(0)

	// Create sub-effects
	bloom_create(&p.bloom_fx, width, height) or_return
	dof_create(&p.dof_fx, width, height) or_return
	auto_exposure_create(&p.auto_exposure_fx) or_return

	// GPU timers for profiling
	gpu_timers_create(&p.timers)

	log.log_info("suckless-odin.postfx", "Pipeline created (%dx%d)", width, height)
	return true
}

// Destroy all pipeline resources.
pipeline_destroy :: proc(p: ^Pipeline) {
	shader_cache_destroy(&p.shader_cache)
	gpu_timers_destroy(&p.timers)
	auto_exposure_destroy(&p.auto_exposure_fx)
	dof_destroy(&p.dof_fx)
	bloom_destroy(&p.bloom_fx)
	delete_program(&p.composite_program)
	destroy_framebuffer(p)
	delete_buffer(&p.settings_ubo)
	quad_destroy(&p.quad)
	log.log_info("suckless-odin.postfx", "Pipeline destroyed")
}

// Begin post-processing: bind scene FBO for rendering.
// Call this BEFORE rendering the scene.
pipeline_begin :: proc(p: ^Pipeline) {
	if !p.enabled {
		return
	}
	// Save current framebuffer and viewport (for correct restore in end)
	gl.GetIntegerv(gl.DRAW_FRAMEBUFFER_BINDING, &p.prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, raw_data(&p.prev_viewport))

	gl.BindFramebuffer(gl.FRAMEBUFFER, p.scene_fbo)
	gl.Viewport(0, 0, p.width, p.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
}

// End post-processing: run all effects and composite to the previously bound framebuffer.
// Call this AFTER rendering the scene.
pipeline_end :: proc(p: ^Pipeline) {
	if !p.enabled {
		return
	}

	// Collect previous frame's timer results (non-blocking)
	gpu_timers_collect(&p.timers)

	// Total timer wraps everything
	gpu_timer_begin(&p.timers, .Total)

	// Run bloom multi-pass if enabled
	gpu_timer_begin(&p.timers, .Bloom)
	if .Bloom in p.active_effects {
		bloom_render(&p.bloom_fx, &p.bloom, p.scene_color_tex, &p.quad)
	}
	gpu_timer_end(&p.timers, .Bloom)

	// Run DoF pre-blur if enabled (reuses bloom shaders)
	if .Dof in p.active_effects {
		dof_render(&p.dof_fx, &p.bloom_fx, &p.dof, p.scene_color_tex, &p.quad)
	}

	// Run auto-exposure compute passes if enabled
	if .Auto_Exposure in p.active_effects {
		auto_exposure_render(&p.auto_exposure_fx, p.scene_color_tex, p.dt)
	}

	// Restore the framebuffer that was active before begin
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(p.prev_fbo))
	gl.Viewport(p.prev_viewport[0], p.prev_viewport[1], p.prev_viewport[2], p.prev_viewport[3])
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Disable(gl.DEPTH_TEST)

	// Upload UBO
	upload_ubo(p)

	// Composite pass (uber-shader)
	gpu_timer_begin(&p.timers, .Composite)

	// Use cached optimized variant if available, otherwise fallback to dynamic
	active_program := shader_cache_find(&p.shader_cache, p.active_effects)
	if active_program == 0 {
		active_program = p.composite_program
	}

	// Bind composite shader
	gl.UseProgram(active_program)

	// Bind scene color texture
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_SCENE)
	gl.BindTexture(gl.TEXTURE_2D, p.scene_color_tex)

	// Bind bloom texture (result of multi-pass, or empty if disabled)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_BLOOM)
	gl.BindTexture(gl.TEXTURE_2D, bloom_get_texture(&p.bloom_fx))

	// Bind auto-exposure texture (1x1, read by uber-shader)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_EXPOSURE)
	gl.BindTexture(gl.TEXTURE_2D, auto_exposure_get_texture(&p.auto_exposure_fx))

	// Bind depth texture (for DoF CoC calculation)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_DEPTH)
	gl.BindTexture(gl.TEXTURE_2D, p.depth_tex)

	// Bind DoF blur texture (1/4 res pre-blurred scene)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_DOF)
	gl.BindTexture(gl.TEXTURE_2D, dof_get_texture(&p.dof_fx))

	// Draw fullscreen quad (final composite)
	quad_draw(&p.quad)

	gpu_timer_end(&p.timers, .Composite)
	gpu_timer_end(&p.timers, .Total)

	// Restore state
	gl.Enable(gl.DEPTH_TEST)
	gl.UseProgram(0)
}

// Resize pipeline resources (call on window resize).
pipeline_resize :: proc(p: ^Pipeline, width, height: i32) {
	if width == p.width && height == p.height {
		return
	}
	p.width = width
	p.height = height

	destroy_framebuffer(p)
	create_framebuffer(p)
	bloom_resize(&p.bloom_fx, width, height)
	dof_resize(&p.dof_fx, width, height)
	p.ubo_dirty = true

	log.log_info("suckless-odin.postfx", "Pipeline resized (%dx%d)", width, height)
}

// Update time accumulator (call each frame).
pipeline_update :: proc(p: ^Pipeline, dt: f32) {
	p.time += dt
	p.dt = dt
	p.ubo_dirty = true // time changes every frame
}

// Toggle an effect on/off.
pipeline_toggle :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects ~= {effect}
	p.ubo_dirty = true
}

// Enable an effect.
pipeline_enable :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects += {effect}
	p.ubo_dirty = true
}

// Disable an effect.
pipeline_disable :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects -= {effect}
	p.ubo_dirty = true
}

// Check if an effect is active.
pipeline_is_enabled :: proc(p: ^Pipeline, effect: Post_Effect) -> bool {
	return effect in p.active_effects
}

// Compile an optimized shader variant for the current active effects.
// Returns true if a new variant was compiled, false if cache full or disabled.
pipeline_compile_variant :: proc(p: ^Pipeline) -> bool {
	if !p.shader_cache.enabled { return false }
	existing := shader_cache_find(&p.shader_cache, p.active_effects)
	if existing != 0 { return false } // already cached
	return shader_cache_compile(&p.shader_cache, p.active_effects) != 0
}

// --- Private helpers ---

@(private)
init_defaults :: proc(p: ^Pipeline) {
	p.vignette = {
		intensity  = DEFAULT_VIGNETTE_INTENSITY,
		smoothness = DEFAULT_VIGNETTE_SMOOTHNESS,
		roundness  = DEFAULT_VIGNETTE_ROUNDNESS,
	}
	p.grain = {
		intensity            = DEFAULT_GRAIN_INTENSITY,
		intensity_shadows    = 1.0,
		intensity_midtones   = 1.0,
		intensity_highlights = 1.0,
		shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
		highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
		texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
	}
	p.exposure = {exposure = DEFAULT_EXPOSURE}
	p.chrom_abbr = {strength = DEFAULT_CHROM_ABBR_STRENGTH}
	p.white_balance = {temperature = DEFAULT_WB_TEMP, tint = DEFAULT_WB_TINT}
	p.color_grading = {
		saturation = 1.0,
		contrast   = 1.0,
		gamma      = 1.0,
		gain       = 1.0,
		offset     = 0.0,
		lift       = 0.0,
	}
	p.tonemapper = {
		slope      = DEFAULT_TONEMAP_SLOPE,
		toe        = DEFAULT_TONEMAP_TOE,
		shoulder   = DEFAULT_TONEMAP_SHOULDER,
		black_clip = DEFAULT_TONEMAP_BLACK_CLIP,
		white_clip = DEFAULT_TONEMAP_WHITE_CLIP,
	}
	p.bloom = {
		intensity      = DEFAULT_BLOOM_INTENSITY,
		threshold      = DEFAULT_BLOOM_THRESHOLD,
		soft_threshold = DEFAULT_BLOOM_SOFT_THRESHOLD,
		radius         = DEFAULT_BLOOM_RADIUS,
	}
	p.fxaa = {
		subpix             = DEFAULT_FXAA_SUBPIX,
		edge_threshold     = DEFAULT_FXAA_EDGE_THRESHOLD,
		edge_threshold_min = DEFAULT_FXAA_EDGE_THRESHOLD_MIN,
	}
	p.dof = DEFAULT_DOF_PARAMS
}

@(private)
create_framebuffer :: proc(p: ^Pipeline) -> (ok: bool) {
	gl.GenFramebuffers(1, &p.scene_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.scene_fbo)

	// HDR color texture (RGBA16F)
	p.scene_color_tex = create_texture_2d(p.width, p.height, gl.RGBA16F)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, p.scene_color_tex, 0)

	// Depth texture (D32F for precision)
	p.depth_tex = create_texture_2d(
		p.width, p.height,
		gl.DEPTH_COMPONENT32F, gl.DEPTH_COMPONENT,
		filter = .Nearest,
	)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, p.depth_tex, 0)

	// Check completeness
	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.postfx", "Framebuffer incomplete: 0x%X", status)
		return false
	}

	return true
}

@(private)
destroy_framebuffer :: proc(p: ^Pipeline) {
	delete_texture(&p.scene_color_tex)
	delete_texture(&p.depth_tex)
	delete_fbo(&p.scene_fbo)
}

@(private)
upload_ubo :: proc(p: ^Pipeline) {
	ubo := Post_FX_UBO{
		active_effects     = transmute(u32)p.active_effects,
		time               = p.time,
		screen_texel_size  = {1.0 / f32(p.width), 1.0 / f32(p.height)},

		vignette_intensity  = p.vignette.intensity,
		vignette_smoothness = p.vignette.smoothness,
		vignette_roundness  = p.vignette.roundness,

		grain_intensity            = p.grain.intensity,
		grain_intensity_shadows    = p.grain.intensity_shadows,
		grain_intensity_midtones   = p.grain.intensity_midtones,
		grain_intensity_highlights = p.grain.intensity_highlights,
		grain_shadows_max          = p.grain.shadows_max,
		grain_highlights_min       = p.grain.highlights_min,
		grain_texel_size           = p.grain.texel_size,

		exposure_manual = p.exposure.exposure,

		chrom_abbr_strength = p.chrom_abbr.strength,

		wb_temperature = p.white_balance.temperature,
		wb_tint        = p.white_balance.tint,

		grading_saturation = p.color_grading.saturation,
		grading_contrast   = p.color_grading.contrast,
		grading_gamma      = p.color_grading.gamma,
		grading_gain       = p.color_grading.gain,
		grading_offset     = p.color_grading.offset,
		grading_lift       = p.color_grading.lift,

		tonemap_slope      = p.tonemapper.slope,
		tonemap_toe        = p.tonemapper.toe,
		tonemap_shoulder   = p.tonemapper.shoulder,
		tonemap_black_clip = p.tonemapper.black_clip,
		tonemap_white_clip = p.tonemapper.white_clip,

		bloom_intensity      = p.bloom.intensity,
		bloom_threshold      = p.bloom.threshold,
		bloom_soft_threshold = p.bloom.soft_threshold,
		bloom_radius         = p.bloom.radius,

		fxaa_subpix             = p.fxaa.subpix,
		fxaa_edge_threshold     = p.fxaa.edge_threshold,
		fxaa_edge_threshold_min = p.fxaa.edge_threshold_min,

		dof_focal_distance   = p.dof.focal_distance,
		dof_focal_range      = p.dof.focal_range,
		dof_bokeh_scale      = p.dof.bokeh_scale,
		dof_anamorphic_ratio = p.dof.anamorphic_ratio,
	}

	gl.BindBuffer(gl.UNIFORM_BUFFER, p.settings_ubo)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(Post_FX_UBO), &ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	p.ubo_dirty = false
}
