package gui

import imgui "../../deps/odin-imgui"
import postfx "../rendering/postfx"

// ─── Post-FX Section (live controls) ───────────────────────────────────────────

@(private)
draw_postfx_section :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Post-Processing")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		imgui.Spacing()
		return
	}

	// Master toggle
	imgui.Checkbox("Enable Post-FX", &p.enabled)
	if !p.enabled {
		imgui.Spacing()
		return
	}

	imgui.Spacing()

	// --- Preset selector ---
	@(static) current_preset: i32 = 0
	if imgui.Combo(
		"Preset",
		&current_preset,
		"Default\x00Subtle\x00Cinematic\x00Vibrant\x00Clean\x00",
	) {
		postfx.pipeline_apply_preset(p, postfx.Preset_Id(current_preset))
	}
	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	// --- Exposure ---
	exposure_on := postfx.Post_Effect.Exposure in p.active_effects
	if imgui.Checkbox("Exposure", &exposure_on) {
		postfx.pipeline_toggle(p, .Exposure)
	}
	if exposure_on {
		imgui.Indent()
		if imgui.SliderFloat("Exposure##value", &p.exposure.exposure, 0.1, 10.0) {
			p.ubo_dirty = true
		}
		imgui.Unindent()
	}

	// --- Tonemapping ---
	tonemap_on := postfx.Post_Effect.Tonemap in p.active_effects
	if imgui.Checkbox("Tonemapping", &tonemap_on) {
		postfx.pipeline_toggle(p, .Tonemap)
	}
	if tonemap_on {
		imgui.Indent()
		if imgui.SliderFloat("Slope", &p.tonemapper.slope, 0.1, 3.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Toe", &p.tonemapper.toe, 0.0, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Shoulder", &p.tonemapper.shoulder, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Black Clip", &p.tonemapper.black_clip, 0.0, 0.5) { p.ubo_dirty = true }
		if imgui.SliderFloat("White Clip", &p.tonemapper.white_clip, 0.0, 0.5) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Vignette ---
	vignette_on := postfx.Post_Effect.Vignette in p.active_effects
	if imgui.Checkbox("Vignette", &vignette_on) {
		postfx.pipeline_toggle(p, .Vignette)
	}
	if vignette_on {
		imgui.Indent()
		if imgui.SliderFloat("Intensity##vig", &p.vignette.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Smoothness##vig", &p.vignette.smoothness, 0.01, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Roundness##vig", &p.vignette.roundness, 0.0, 1.0) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Film Grain ---
	grain_on := postfx.Post_Effect.Grain in p.active_effects
	if imgui.Checkbox("Film Grain", &grain_on) {
		postfx.pipeline_toggle(p, .Grain)
	}
	if grain_on {
		imgui.Indent()
		if imgui.SliderFloat("Intensity##grain", &p.grain.intensity, 0.0, 0.2) { p.ubo_dirty = true }
		if imgui.SliderFloat("Texel Size##grain", &p.grain.texel_size, 0.5, 4.0) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Chromatic Aberration ---
	ca_on := postfx.Post_Effect.Chrom_Abbr in p.active_effects
	if imgui.Checkbox("Chromatic Aberration", &ca_on) {
		postfx.pipeline_toggle(p, .Chrom_Abbr)
	}
	if ca_on {
		imgui.Indent()
		if imgui.SliderFloat("Strength##ca", &p.chrom_abbr.strength, 0.0, 0.05) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Color Grading ---
	cg_on := postfx.Post_Effect.Color_Grading in p.active_effects
	if imgui.Checkbox("Color Grading", &cg_on) {
		postfx.pipeline_toggle(p, .Color_Grading)
	}
	if cg_on {
		imgui.Indent()
		if imgui.SliderFloat("Saturation", &p.color_grading.saturation, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Contrast", &p.color_grading.contrast, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Gamma##cg", &p.color_grading.gamma, 0.1, 3.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Gain", &p.color_grading.gain, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Offset", &p.color_grading.offset, -0.5, 0.5) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Bloom (not yet multi-pass, toggle only) ---
	bloom_on := postfx.Post_Effect.Bloom in p.active_effects
	if imgui.Checkbox("Bloom", &bloom_on) {
		postfx.pipeline_toggle(p, .Bloom)
	}
	if bloom_on {
		imgui.Indent()
		if imgui.SliderFloat("Intensity##bloom", &p.bloom.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Threshold##bloom", &p.bloom.threshold, 0.0, 5.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Soft Knee##bloom", &p.bloom.soft_threshold, 0.0, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Radius##bloom", &p.bloom.radius, 0.1, 4.0) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- FXAA ---
	fxaa_on := postfx.Post_Effect.FXAA in p.active_effects
	if imgui.Checkbox("FXAA", &fxaa_on) {
		postfx.pipeline_toggle(p, .FXAA)
	}
	if fxaa_on {
		imgui.Indent()
		if imgui.SliderFloat("Subpixel Quality", &p.fxaa.subpix, 0.0, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Edge Threshold", &p.fxaa.edge_threshold, 0.01, 0.5) { p.ubo_dirty = true }
		if imgui.SliderFloat("Edge Threshold Min", &p.fxaa.edge_threshold_min, 0.01, 0.2) { p.ubo_dirty = true }
		imgui.Unindent()
	}

	// --- Auto-Exposure ---
	ae_on := postfx.Post_Effect.Auto_Exposure in p.active_effects
	if imgui.Checkbox("Auto-Exposure", &ae_on) {
		postfx.pipeline_toggle(p, .Auto_Exposure)
	}
	if ae_on {
		imgui.Indent()
		imgui.SliderFloat("Min Luminance", &p.auto_exposure_fx.params.min_luminance, 0.001, 1.0)
		imgui.SliderFloat("Max Luminance", &p.auto_exposure_fx.params.max_luminance, 100.0, 50000.0)
		imgui.SliderFloat("Speed Up", &p.auto_exposure_fx.params.speed_up, 0.1, 10.0)
		imgui.SliderFloat("Speed Down", &p.auto_exposure_fx.params.speed_down, 0.1, 10.0)
		imgui.SliderFloat("Key Value", &p.auto_exposure_fx.params.key_value, 0.01, 1.0)
		imgui.Spacing()
		imgui.Text("Current: %.3f", p.auto_exposure_fx.current_exposure)
		imgui.Text("Scene Lum: %.4f", p.auto_exposure_fx.current_scene_lum)
		imgui.Text("Target: %.3f", p.auto_exposure_fx.current_target)
		imgui.Unindent()
	}

	// --- Not yet implemented effects ---
	imgui.BeginDisabled()
	dof_placeholder := false
	mb_placeholder := false
	imgui.Checkbox("Depth of Field", &dof_placeholder)
	imgui.Checkbox("Motion Blur", &mb_placeholder)
	imgui.EndDisabled()

	imgui.Spacing()
	imgui.Separator()

	// --- GPU Profiling ---
	if imgui.CollapsingHeader("GPU Timings") {
		imgui.Checkbox("Enable Profiling", &p.timers.enabled)
		if p.timers.enabled {
			bloom_ms := postfx.gpu_timer_get_ms(&p.timers, .Bloom)
			composite_ms := postfx.gpu_timer_get_ms(&p.timers, .Composite)
			total_ms := postfx.gpu_timer_get_ms(&p.timers, .Total)
			imgui.Text("Bloom:     %.3f ms", bloom_ms)
			imgui.Text("Composite: %.3f ms", composite_ms)
			imgui.Text("Total:     %.3f ms", total_ms)
		}
	}

	// --- Shader Optimization ---
	if imgui.CollapsingHeader("Shader Cache") {
		imgui.Checkbox("Enable Variants", &p.shader_cache.enabled)
		if p.shader_cache.enabled {
			imgui.Text("Cached: %d / %d", p.shader_cache.count, postfx.MAX_CACHED_VARIANTS)
			if imgui.Button("Compile Current") {
				postfx.pipeline_compile_variant(p)
			}
			imgui.SameLine()
			if imgui.Button("Clear Cache") {
				postfx.shader_cache_destroy(&p.shader_cache)
			}
		}
	}

	imgui.Spacing()
}

// PostFX filtered search entries — called from draw_filtered_view.
@(private)
draw_postfx_filtered :: proc(state: Scene_State, filter: cstring) -> int {
	p := state.postfx
	if p == nil { return 0 }

	match_count := 0

	if fuzzy_match(filter, "Enable Post-FX", "postfx pipeline master toggle") {
		imgui.Checkbox("Enable Post-FX", &p.enabled)
		match_count += 1
	}

	if fuzzy_match(filter, "Exposure", "postfx tone mapping hdr brightness manual") {
		exposure_on := postfx.Post_Effect.Exposure in p.active_effects
		if imgui.Checkbox("Exposure##filt", &exposure_on) {
			postfx.pipeline_toggle(p, .Exposure)
		}
		if imgui.SliderFloat("Exposure##filt_val", &p.exposure.exposure, 0.1, 10.0) {
			p.ubo_dirty = true
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Tonemapping", "postfx tonemap aces filmic curve hdr ldr") {
		tonemap_on := postfx.Post_Effect.Tonemap in p.active_effects
		if imgui.Checkbox("Tonemapping##filt", &tonemap_on) {
			postfx.pipeline_toggle(p, .Tonemap)
		}
		if imgui.SliderFloat("Slope##filt", &p.tonemapper.slope, 0.1, 3.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Toe##filt", &p.tonemapper.toe, 0.0, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Shoulder##filt", &p.tonemapper.shoulder, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Vignette", "postfx border darken edge shadow") {
		vignette_on := postfx.Post_Effect.Vignette in p.active_effects
		if imgui.Checkbox("Vignette##filt", &vignette_on) {
			postfx.pipeline_toggle(p, .Vignette)
		}
		if imgui.SliderFloat("Intensity##vig_filt", &p.vignette.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Smoothness##vig_filt", &p.vignette.smoothness, 0.01, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Film Grain", "postfx noise cinematic film grain texture") {
		grain_on := postfx.Post_Effect.Grain in p.active_effects
		if imgui.Checkbox("Film Grain##filt", &grain_on) {
			postfx.pipeline_toggle(p, .Grain)
		}
		if imgui.SliderFloat("Intensity##grain_filt", &p.grain.intensity, 0.0, 0.2) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Chromatic Aberration", "postfx color fringe lens dispersion ca") {
		ca_on := postfx.Post_Effect.Chrom_Abbr in p.active_effects
		if imgui.Checkbox("Chromatic Aberration##filt", &ca_on) {
			postfx.pipeline_toggle(p, .Chrom_Abbr)
		}
		if imgui.SliderFloat("Strength##ca_filt", &p.chrom_abbr.strength, 0.0, 0.05) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Color Grading", "postfx saturation contrast gamma gain offset lift color correction") {
		cg_on := postfx.Post_Effect.Color_Grading in p.active_effects
		if imgui.Checkbox("Color Grading##filt", &cg_on) {
			postfx.pipeline_toggle(p, .Color_Grading)
		}
		if imgui.SliderFloat("Saturation##filt", &p.color_grading.saturation, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Contrast##filt", &p.color_grading.contrast, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Bloom", "postfx glow effect bright threshold hdr") {
		bloom_on := postfx.Post_Effect.Bloom in p.active_effects
		if imgui.Checkbox("Bloom##filt", &bloom_on) {
			postfx.pipeline_toggle(p, .Bloom)
		}
		if imgui.SliderFloat("Intensity##bloom_filt", &p.bloom.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "FXAA", "postfx anti-aliasing antialiasing edge smoothing") {
		fxaa_on := postfx.Post_Effect.FXAA in p.active_effects
		if imgui.Checkbox("FXAA##filt", &fxaa_on) {
			postfx.pipeline_toggle(p, .FXAA)
		}
		if imgui.SliderFloat("Subpixel##fxaa_filt", &p.fxaa.subpix, 0.0, 1.0) { p.ubo_dirty = true }
		match_count += 1
	}

	return match_count
}
