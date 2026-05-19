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
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##exposure", {}) {
			if imgui.SliderFloat("Exposure##value", &p.exposure.exposure, 0.1, 10.0) {
				p.ubo_dirty = true
			}
			imgui.TreePop()
		}
	}

	// --- Tonemapping ---
	tonemap_on := postfx.Post_Effect.Tonemap in p.active_effects
	if imgui.Checkbox("Tonemapping", &tonemap_on) {
		postfx.pipeline_toggle(p, .Tonemap)
	}
	if tonemap_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##tonemap", {}) {
			if imgui.SliderFloat("Slope", &p.tonemapper.slope, 0.1, 3.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Toe", &p.tonemapper.toe, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Shoulder", &p.tonemapper.shoulder, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Black Clip", &p.tonemapper.black_clip, 0.0, 0.5) { p.ubo_dirty = true }
			if imgui.SliderFloat("White Clip", &p.tonemapper.white_clip, 0.0, 0.5) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Vignette ---
	vignette_on := postfx.Post_Effect.Vignette in p.active_effects
	if imgui.Checkbox("Vignette", &vignette_on) {
		postfx.pipeline_toggle(p, .Vignette)
	}
	if vignette_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##vignette", {}) {
			if imgui.SliderFloat("Intensity##vig", &p.vignette.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Smoothness##vig", &p.vignette.smoothness, 0.01, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Roundness##vig", &p.vignette.roundness, 0.0, 1.0) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Film Grain ---
	grain_on := postfx.Post_Effect.Grain in p.active_effects
	if imgui.Checkbox("Film Grain", &grain_on) {
		postfx.pipeline_toggle(p, .Grain)
	}
	if grain_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##grain", {}) {
			if imgui.SliderFloat("Intensity##grain", &p.grain.intensity, 0.0, 0.2) { p.ubo_dirty = true }
			if imgui.SliderFloat("Texel Size##grain", &p.grain.texel_size, 0.5, 4.0) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Chromatic Aberration ---
	ca_on := postfx.Post_Effect.Chrom_Abbr in p.active_effects
	if imgui.Checkbox("Chromatic Aberration", &ca_on) {
		postfx.pipeline_toggle(p, .Chrom_Abbr)
	}
	if ca_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##ca", {}) {
			if imgui.SliderFloat("Strength##ca", &p.chrom_abbr.strength, 0.0, 0.05) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Color Grading ---
	cg_on := postfx.Post_Effect.Color_Grading in p.active_effects
	if imgui.Checkbox("Color Grading", &cg_on) {
		postfx.pipeline_toggle(p, .Color_Grading)
	}
	if cg_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##cg", {}) {
			if imgui.SliderFloat("Saturation", &p.color_grading.saturation, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Contrast", &p.color_grading.contrast, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Gamma##cg", &p.color_grading.gamma, 0.1, 3.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Gain", &p.color_grading.gain, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Offset", &p.color_grading.offset, -0.5, 0.5) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Bloom (not yet multi-pass, toggle only) ---
	bloom_on := postfx.Post_Effect.Bloom in p.active_effects
	if imgui.Checkbox("Bloom", &bloom_on) {
		postfx.pipeline_toggle(p, .Bloom)
	}
	if bloom_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##bloom", {}) {
			if imgui.SliderFloat("Intensity##bloom", &p.bloom.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Threshold##bloom", &p.bloom.threshold, 0.0, 5.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Soft Knee##bloom", &p.bloom.soft_threshold, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Radius##bloom", &p.bloom.radius, 0.1, 4.0) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- FXAA ---
	fxaa_on := postfx.Post_Effect.FXAA in p.active_effects
	if imgui.Checkbox("FXAA", &fxaa_on) {
		postfx.pipeline_toggle(p, .FXAA)
	}
	if fxaa_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##fxaa", {}) {
			if imgui.SliderFloat("Subpixel Quality", &p.fxaa.subpix, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Edge Threshold", &p.fxaa.edge_threshold, 0.01, 0.5) { p.ubo_dirty = true }
			if imgui.SliderFloat("Edge Threshold Min", &p.fxaa.edge_threshold_min, 0.01, 0.2) { p.ubo_dirty = true }
			imgui.TreePop()
		}
	}

	// --- Auto-Exposure ---
	ae_on := postfx.Post_Effect.Auto_Exposure in p.active_effects
	if imgui.Checkbox("Auto-Exposure", &ae_on) {
		postfx.pipeline_toggle(p, .Auto_Exposure)
	}
	if ae_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##ae", {}) {
			imgui.SliderFloat("Min Luminance", &p.auto_exposure_fx.params.min_luminance, 0.001, 1.0)
			imgui.SliderFloat("Max Luminance", &p.auto_exposure_fx.params.max_luminance, 100.0, 50000.0)
			imgui.SliderFloat("Speed Up", &p.auto_exposure_fx.params.speed_up, 0.1, 10.0)
			imgui.SliderFloat("Speed Down", &p.auto_exposure_fx.params.speed_down, 0.1, 10.0)
			imgui.SliderFloat("Key Value", &p.auto_exposure_fx.params.key_value, 0.01, 1.0)
			imgui.Spacing()
			imgui.Text("Current: %.3f", p.auto_exposure_fx.current_exposure)
			imgui.Text("Scene Lum: %.4f", p.auto_exposure_fx.current_scene_lum)
			imgui.Text("Target: %.3f", p.auto_exposure_fx.current_target)
			imgui.TreePop()
		}
	}

	// --- Depth of Field ---
	dof_on := postfx.Post_Effect.Dof in p.active_effects
	if imgui.Checkbox("Depth of Field", &dof_on) {
		postfx.pipeline_toggle(p, .Dof)
	}
	if dof_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##dof", {}) {
			if imgui.SliderFloat("Focal Distance##dof", &p.dof.focal_distance, 1.0, 100.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Focal Range##dof", &p.dof.focal_range, 0.5, 50.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Bokeh Scale##dof", &p.dof.bokeh_scale, 1.0, 50.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Anamorphic##dof", &p.dof.anamorphic_ratio, 0.5, 2.0) { p.ubo_dirty = true }

			dof_debug := postfx.Post_Effect.Dof_Debug in p.active_effects
			if imgui.Checkbox("Debug Zones##dof", &dof_debug) {
				postfx.pipeline_toggle(p, .Dof_Debug)
			}
			imgui.TreePop()
		}
	}

	// --- Not yet implemented effects ---
	imgui.BeginDisabled()
	mb_placeholder := false
	imgui.Checkbox("Motion Blur", &mb_placeholder)
	imgui.EndDisabled()

	imgui.Spacing()
}

// GPU Timings tab — separate from Post-FX controls.
@(private)
draw_gpu_timings_section :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "GPU Profiling")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		return
	}

	imgui.Checkbox("Enable Profiling", &p.timers.enabled)
	if !p.timers.enabled { return }

	total_avg, total_min, total_max := postfx.gpu_timer_get_total_metrics(&p.timers)

	imgui.Spacing()
	imgui.Separator()

	// Per-pass metrics table
	table_flags := imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit
	if imgui.BeginTable("##gpu_timings", 5, table_flags) {
		imgui.TableSetupColumn("Pass", {.WidthFixed}, 90)
		imgui.TableSetupColumn("Avg", {.WidthFixed}, 70)
		imgui.TableSetupColumn("Min", {.WidthFixed}, 70)
		imgui.TableSetupColumn("Max", {.WidthFixed}, 70)
		imgui.TableSetupColumn("%", {.WidthFixed}, 45)
		imgui.TableHeadersRow()

		pass_names := postfx.TIMER_PASS_NAMES
		for pass in postfx.Timer_Pass {
			avg, min_v, max_v := postfx.gpu_timer_get_metrics(&p.timers, pass)
			pct := postfx.gpu_timer_get_pct(&p.timers, pass)

			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.Text("%s", pass_names[pass])
			imgui.TableNextColumn()
			imgui.Text("%.3f", avg)
			imgui.TableNextColumn()
			imgui.TextDisabled("%.3f", min_v)
			imgui.TableNextColumn()
			imgui.TextDisabled("%.3f", max_v)
			imgui.TableNextColumn()
			imgui.Text("%.0f%%", pct)
		}

		// Total row
		imgui.TableNextRow()
		imgui.TableNextColumn()
		imgui.TextColored(imgui.Vec4{0.8, 0.9, 1.0, 1.0}, "Total")
		imgui.TableNextColumn()
		imgui.TextColored(imgui.Vec4{0.8, 0.9, 1.0, 1.0}, "%.3f", total_avg)
		imgui.TableNextColumn()
		imgui.TextDisabled("%.3f", total_min)
		imgui.TableNextColumn()
		imgui.TextDisabled("%.3f", total_max)
		imgui.TableNextColumn()
		imgui.Text("")

		imgui.EndTable()
	}

	imgui.Spacing()
	// Frame budget: smoothed % of actual frame time consumed by PostFX
	frame_ms := state.frame_time_ms
	budget_pct: f32 = 0
	if frame_ms > 0 {
		budget_pct = (total_avg / frame_ms) * 100.0
	}
	budget_color: imgui.Vec4
	if budget_pct < 25 {
		budget_color = {0.3, 1.0, 0.3, 1.0} // green
	} else if budget_pct < 50 {
		budget_color = {1.0, 0.9, 0.3, 1.0} // yellow
	} else {
		budget_color = {1.0, 0.3, 0.3, 1.0} // red
	}
	imgui.TextColored(budget_color, "PostFX: %.1f%% of frame (%.2f ms)", budget_pct, frame_ms)
}

// Shader Cache tab — separate from Post-FX controls.
@(private)
draw_shader_cache_section :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Shader Optimization")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		return
	}

	imgui.Checkbox("Enable Variants", &p.shader_cache.enabled)
	if !p.shader_cache.enabled {
		imgui.TextDisabled("Disabled — using dynamic uber-shader with runtime branching")
		return
	}

	imgui.Spacing()

	// --- Current state ---
	imgui.Text("Active Effects:")
	imgui.Indent()
	// Only show effects that have static shader defines
	SHADER_EFFECTS :: [?]postfx.Post_Effect{
		.Vignette, .Grain, .Exposure, .Chrom_Abbr,
		.Bloom, .Color_Grading, .FXAA, .Tonemap,
	}
	EFFECT_NAMES :: [postfx.Post_Effect]string{
		.Vignette      = "Vignette",
		.Grain         = "Film Grain",
		.Exposure      = "Exposure",
		.Chrom_Abbr    = "Chrom. Abbr",
		.Bloom         = "Bloom",
		.Color_Grading = "Color Grading",
		.FXAA          = "FXAA",
		.Tonemap       = "Tonemap",
		.Dof           = "DoF",
		.Dof_Debug     = "DoF Debug",
		.Auto_Exposure = "Auto-Exposure",
		.Exposure_Debug = "Exposure Debug",
		.Motion_Blur   = "Motion Blur",
		.Motion_Blur_Debug = "MB Debug",
		.Banding       = "Banding",
		.Fog           = "Fog",
		.LUT3D         = "LUT3D",
	}
	effect_names := EFFECT_NAMES
	active_count := 0
	for effect in SHADER_EFFECTS {
		if effect in p.active_effects {
			imgui.BulletText("%s", effect_names[effect])
			active_count += 1
		}
	}
	if active_count == 0 {
		imgui.TextDisabled("(none)")
	}
	imgui.Unindent()

	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	// --- Cache hit/miss status ---
	cached_program := postfx.shader_cache_find(&p.shader_cache, p.active_effects)
	if cached_program != 0 {
		imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "Status: CACHED (program %d)", cached_program)
	} else {
		imgui.TextColored(imgui.Vec4{1.0, 0.7, 0.3, 1.0}, "Status: MISS — using dynamic branching")
	}

	imgui.Spacing()

	// --- Actions ---
	can_compile := cached_program == 0 && p.shader_cache.count < i32(postfx.MAX_CACHED_VARIANTS)
	if !can_compile { imgui.BeginDisabled() }
	if imgui.Button("Compile Current") {
		postfx.pipeline_compile_variant(p)
	}
	if !can_compile { imgui.EndDisabled() }
	if cached_program != 0 {
		imgui.SameLine()
		imgui.TextDisabled("(already cached)")
	} else if p.shader_cache.count >= i32(postfx.MAX_CACHED_VARIANTS) {
		imgui.SameLine()
		imgui.TextDisabled("(cache full)")
	}

	imgui.SameLine()
	if imgui.Button("Clear All") {
		postfx.shader_cache_destroy(&p.shader_cache)
	}

	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	// --- Cached variants list ---
	imgui.Text("Cached Variants: %d / %d", p.shader_cache.count, postfx.MAX_CACHED_VARIANTS)
	if p.shader_cache.count > 0 {
		table_flags := imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit | imgui.TableFlags_RowBg
		if imgui.BeginTable("##shader_variants", 3, table_flags) {
			imgui.TableSetupColumn("#", {.WidthFixed}, 25)
			imgui.TableSetupColumn("Program", {.WidthFixed}, 60)
			imgui.TableSetupColumn("Effects", {.WidthStretch})
			imgui.TableHeadersRow()

			for i in 0 ..< p.shader_cache.count {
				variant := &p.shader_cache.variants[i]
				imgui.TableNextRow()
				imgui.TableNextColumn()
				imgui.Text("%d", i + 1)
				imgui.TableNextColumn()
				imgui.Text("%d", variant.program)
				imgui.TableNextColumn()

				// Build effect list string for this variant
				first := true
				for effect in SHADER_EFFECTS {
					if effect in variant.effects {
						if !first { imgui.SameLine(0, 0); imgui.Text(", ") ; imgui.SameLine(0, 0) }
						is_current := (variant.effects == p.active_effects)
						if is_current {
							imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "%s", effect_names[effect])
						} else {
							imgui.Text("%s", effect_names[effect])
						}
						first = false
					}
				}
				if first {
					imgui.TextDisabled("(no effects)")
				}
			}
			imgui.EndTable()
		}
	}
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
