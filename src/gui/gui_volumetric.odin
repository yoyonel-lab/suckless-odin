package gui

import "core:fmt"
import "core:math"
import imgui "../../deps/odin-imgui"
import rendering "../rendering"
import mt "../core/math_types"

// Dedicated Dear ImGui panel for Volumetric Lighting (Phases 2 to 7)
draw_tab_volumetric :: proc(g: ^Gui, state: Scene_State) {
	if state.volumetric == nil {
		imgui.TextDisabled("Volumetric Lighting resources not initialized.")
		return
	}

	vr := state.volumetric
	light := state.point_light

	imgui.TextColored({0.2, 0.8, 1.0, 1.0}, "Volumetric Lighting & Atmosphere (Phases 2-7)")
	imgui.Separator()

	// 1. Phase 2: Depth Downsample & Edge Discontinuity Inspector
	if state.depth_downsample != nil && imgui.CollapsingHeader("Depth Downsample & Discontinuities (Phase 2)", imgui.TreeNodeFlags{}) {
		dd := state.depth_downsample
		imgui.Text("Full: %dx%d -> Half: %dx%d (Rank/Median 4-tap Filter)", dd.full_width, dd.full_height, dd.width, dd.height)

		imgui.SliderFloat("Edge Relative Threshold (eps)", &dd.edge_threshold, 0.001, 0.100, "%.3f (Scale-Invariant)")

		// Preview display modes
		imgui.Text("Depth Preview Mode:")
		imgui.SameLine()
		if imgui.RadioButton("Turbo Heatmap", dd.preview_mode == 0) { dd.preview_mode = 0 }
		imgui.SameLine()
		if imgui.RadioButton("Linear Grayscale", dd.preview_mode == 1) { dd.preview_mode = 1 }
		imgui.SameLine()
		if imgui.RadioButton("Discontinuity Mask", dd.preview_mode == 2) { dd.preview_mode = 2 }

		if dd.preview_mode != 2 {
			imgui.SliderFloat("Min Depth Range", &dd.preview_min_depth, 0.1, 10.0, "%.1f m")
			imgui.SliderFloat("Max Depth Range", &dd.preview_max_depth, 5.0, 100.0, "%.1f m")
		}

		// Update preview texture on-demand
		rendering.depth_downsample_update_preview(dd)

		imgui.Spacing()
		avail_w := imgui.GetContentRegionAvail().x
		preview_w := max(256.0, min(avail_w, 600.0))
		aspect := f32(dd.height) / f32(max(1, dd.width))
		preview_h := preview_w * aspect

		imgui.Image(
			gl_tex_ref(dd.preview_tex),
			imgui.Vec2{preview_w, preview_h},
			imgui.Vec2{0, 1}, // Flip Y for OpenGL
			imgui.Vec2{1, 0},
		)

		if imgui.IsItemHovered() {
			if dd.preview_mode == 2 {
				imgui.SetTooltip("Depth Discontinuity Mask:\nRed = Silhouette Edge (High Relative Step dz/z > eps)\nDark Blue = Continuous Geometry / Sky")
			} else {
				imgui.SetTooltip("Downsampled Linear Camera Depth (Median 4-tap filtered)")
			}
		}
	}

	// 2. Phase 3: Volumetric Raymarching & Henyey-Greenstein Inspector
	if state.volumetric != nil && imgui.CollapsingHeader("Volumetric Raymarching & Henyey-Greenstein (Phase 3)", imgui.TreeNodeFlags{.DefaultOpen}) {
		avail_w := imgui.GetContentRegionAvail().x

		imgui.Checkbox("Enable Volumetric Raymarching", &vr.params.enabled)
		imgui.SameLine()
		imgui.Checkbox("Direct In-Scene Viewport", &vr.params.composite_in_scene)
		imgui.SameLine()
		imgui.Checkbox("Isolate Volumetric (No IBL)", &vr.params.isolate_in_scene)

		if vr.params.enabled {
			imgui.Text("Volumetric Buffer Resolution:")
			if imgui.RadioButton("1/1 (Full)", vr.params.resolution_divider == 1) {
				vr.params.resolution_divider = 1
			}
			imgui.SameLine()
			if imgui.RadioButton("1/2 (Half)", vr.params.resolution_divider == 2) {
				vr.params.resolution_divider = 2
			}
			imgui.SameLine()
			if imgui.RadioButton("1/4 (Quarter - Max FPS)", vr.params.resolution_divider == 4) {
				vr.params.resolution_divider = 4
			}

			imgui.SliderInt("Raymarch Steps (N)", &vr.params.step_count, 4, 64)
			imgui.SliderFloat("Scattering Coeff (sigma_s)", &vr.params.scattering_coeff, 0.01, 1.0, "%.3f")
			g_val := vr.params.anisotropy_g
			if imgui.SliderFloat("Anisotropy (g)", &g_val, -0.90, 0.90, "%.2f") {
				rendering.volumetric_set_anisotropy(vr, light, g_val)
			}
			imgui.SliderFloat("Intensity Multiplier", &vr.params.intensity_mult, 0.0, 10.0, "%.2f")
			imgui.Checkbox("Volumetric Shadows (God Rays)", &vr.params.shadows_enabled)
			imgui.SameLine()
			imgui.Checkbox("Spatial Ray Jittering (IGN)", &vr.params.jitter_enabled)

			// Atmosphere Scattering Presets (ISO legacy Volumetric_Dynamic_Lights)
			imgui.Spacing()
			imgui.TextColored({0.4, 0.8, 1.0, 1.0}, "Henyey-Greenstein Anisotropy (g) Presets:")
			if imgui.Button("Isotropic (g=0.0)") { rendering.volumetric_set_anisotropy(vr, light, 0.0) }
			imgui.SameLine()
			if imgui.Button("Dust / Sand (g=0.35)") { rendering.volumetric_set_anisotropy(vr, light, 0.35) }
			imgui.SameLine()
			if imgui.Button("Morning Fog (g=0.55)") { rendering.volumetric_set_anisotropy(vr, light, 0.55) }
			imgui.SameLine()
			if imgui.Button("God Rays (g=0.70)") { rendering.volumetric_set_anisotropy(vr, light, 0.70) }

			if imgui.Button("Alan Wake Torch (g=0.80)") { rendering.volumetric_set_anisotropy(vr, light, 0.80) }
			imgui.SameLine()
			if imgui.Button("Car Headlights (g=0.88)") { rendering.volumetric_set_anisotropy(vr, light, 0.88) }
			imgui.SameLine()
			if imgui.Button("Backscatter (g=-0.35)") { rendering.volumetric_set_anisotropy(vr, light, -0.35) }

			// Henyey-Greenstein Phase Plot
			imgui.Spacing()
			imgui.TextColored({1.0, 0.8, 0.2, 1.0}, "Henyey-Greenstein Phase Function P(theta, g):")
			phase_samples: [64]f32
			max_p: f32 = 0.001
			for i in 0..<64 {
				theta := (f32(i) / 63.0) * math.PI
				cos_theta := math.cos(theta)
				p := rendering.volumetric_henyey_greenstein(cos_theta, vr.params.anisotropy_g)
				phase_samples[i] = p
				if p > max_p do max_p = p
			}
			imgui.PlotLines(
				"##HG_Plot",
				&phase_samples[0],
				64,
				0,
				"Forward (0 deg) -> Backward (180 deg)",
				0.0,
				max_p * 1.05,
				imgui.Vec2{min(avail_w, 400.0), 60.0},
			)

			// 2D Volumetric Buffer Preview
			imgui.Spacing()
			imgui.Separator()
			imgui.Text("Volumetric In-Scattering Buffer (%dx%d):", vr.width, vr.height)

			imgui.Text("Buffer Preview Mode:")
			if imgui.RadioButton("Final Output##vol", vr.params.preview_mode == 0) { vr.params.preview_mode = 0 }
			imgui.SameLine()
			if imgui.RadioButton("Raw Grain##vol", vr.params.preview_mode == 1) { vr.params.preview_mode = 1 }
			imgui.SameLine()
			if imgui.RadioButton("Heatmap##vol", vr.params.preview_mode == 2) { vr.params.preview_mode = 2 }
			imgui.SameLine()
			if imgui.RadioButton("TAA Acceptance##vol", vr.params.preview_mode == 3) { vr.params.preview_mode = 3 }
			imgui.SameLine()
			if imgui.RadioButton("Post-Blur HDR##vol", vr.params.preview_mode == 4) { vr.params.preview_mode = 4 }

			if imgui.RadioButton("Bilateral Diff (|Delta|x10)##vol", vr.params.preview_mode == 5) { vr.params.preview_mode = 5 }
			imgui.SameLine()
			if imgui.RadioButton("Edge Overlay (Magenta)##vol", vr.params.preview_mode == 6) { vr.params.preview_mode = 6 }
			imgui.SameLine()
			if imgui.RadioButton("Silhouette Only##vol", vr.params.preview_mode == 7) { vr.params.preview_mode = 7 }
			imgui.SameLine()
			if imgui.RadioButton("Weight Attenuation##vol", vr.params.preview_mode == 8) { vr.params.preview_mode = 8 }
			imgui.SameLine()
			if imgui.RadioButton("Transmittance##vol", vr.params.preview_mode == 9) { vr.params.preview_mode = 9 }

			imgui.SliderFloat("Exposure Boost##vol", &vr.params.preview_exposure_boost, 1.0, 10.0, "%.1fx")

			// Magnifier Loupe Tool
			imgui.Spacing()
			imgui.TextColored({1.0, 0.7, 0.2, 1.0}, "Inspector Magnifier Loupe (Zoom on Sphere Edges):")
			imgui.SliderFloat("Magnifier Zoom", &vr.params.zoom_scale, 1.0, 16.0, "%.1fx")
			if vr.params.zoom_scale > 1.0 {
				pan := [2]f32{vr.params.zoom_center.x, vr.params.zoom_center.y}
				if imgui.SliderFloat2("Loupe Pan (UV)", &pan, 0.0, 1.0, "%.2f") {
					vr.params.zoom_center = mt.Vec2{pan[0], pan[1]}
				}
				imgui.SameLine()
				if imgui.Button("Reset Loupe") {
					vr.params.zoom_scale = 1.0
					vr.params.zoom_center = {0.5, 0.5}
				}
			}

			cur_depth := rendering.depth_downsample_get_current_depth(state.depth_downsample)
			disc_tex := state.depth_downsample.discontinuity_tex if state.depth_downsample != nil else 0
			rendering.volumetric_update_preview(vr, cur_depth, disc_tex)

			preview_w := max(256.0, min(avail_w, 600.0))
			aspect := f32(vr.height) / f32(max(1, vr.width))
			preview_h := preview_w * aspect

			imgui.Image(
				gl_tex_ref(vr.preview_tex),
				imgui.Vec2{preview_w, preview_h},
				imgui.Vec2{0, 1}, // Flip Y for OpenGL
				imgui.Vec2{1, 0},
			)

			if imgui.IsItemHovered() {
				switch vr.params.preview_mode {
				case 5:
					imgui.SetTooltip("Bilateral Difference Map (|Blurred - Unblurred| * Boost * 10):\nShows where spatial filtering modified pixels.\nLow-delta around sphere edges proves edge-preservation!")
				case 6:
					imgui.SetTooltip("Silhouette Edge Overlay:\nHighlights geometric sphere edges in Neon Magenta over the volumetric fog.")
				case 7:
					imgui.SetTooltip("Silhouette Edges Only:\nIsolates in-scattering exclusively on sphere silhouette pixels.")
				case 8:
					imgui.SetTooltip("Bilateral Weight Attenuation Map:\n[Green] Green/Yellow (1.0) = Full blur allowed (homogeneous depth)\n[Red] Red/Blue (<0.2) = Depth edge detected, blur clamped to prevent bleed!")
				case 3:
					imgui.SetTooltip("TAA Acceptance Map (GL_RGBA8, W/2 x H/2):\n[Green] Green: Valid reprojected history pixel\n[Red] Red: Geometric disocclusion (depth delta > threshold)\n[Blue] Blue: Offscreen reprojection outside viewport.")
				case 1:
					imgui.SetTooltip("Raw Raymarching buffer before temporal/bilateral filtering.\nPreserves spatial Interleaved Gradient Noise (IGN) grain.")
				case:
					imgui.SetTooltip("Volumetric In-Scattering Buffer (GL_RGBA16F, W/2 x H/2)\nCalculated via analytical ray-sphere raymarching + shadow cubemap.")
				}
			}
		}
	}

	// 3. Phase 4: TAA Temporal Reprojection & History Blending Inspector
	if imgui.CollapsingHeader("TAA Reprojection & History Blending (Phase 4)", imgui.TreeNodeFlags{.DefaultOpen}) {
		if vr.params.enabled {
			imgui.TextColored({0.2, 0.9, 0.4, 1.0}, "Temporal Filtering Mode:")
			if imgui.RadioButton("Off (Raw Jitter Grain)##taa", vr.params.taa_mode == 0) {
				vr.params.taa_mode = 0
			}
			imgui.SameLine()
			if imgui.RadioButton("Simple Blend (Static EMA)##taa", vr.params.taa_mode == 1) {
				vr.params.taa_mode = 1
			}
			imgui.SameLine()
			if imgui.RadioButton("TAA Reprojection (Motion-Aware)##taa", vr.params.taa_mode == 2) {
				vr.params.taa_mode = 2
			}

			if vr.params.taa_mode > 0 {
				imgui.SliderFloat("Current Frame Weight (Alpha)", &vr.params.taa_alpha, 0.02, 1.0, "%.2f (Lower = Smoother)")
				if vr.params.taa_mode == 2 {
					imgui.SliderFloat("Disocclusion Depth Threshold", &vr.params.taa_depth_threshold, 0.05, 3.0, "%.2f m")
				}
				imgui.Checkbox("3x3 Color Neighborhood Clamping", &vr.params.taa_clamping_enabled)
			} else {
				imgui.TextDisabled("Temporal accumulation disabled. Spatial ray jittering grain is active.")
			}

			imgui.Spacing()
			imgui.Text("TAA Diagnostics & Action:")
			imgui.BulletText("History Valid: %s", "TRUE (Accumulating)" if vr.history_valid else "FALSE (Resetting/Starting)")
			imgui.SameLine()
			if imgui.Button("Force History Reset") {
				vr.history_valid = false
			}

			imgui.BulletText("Ping-Pong Buffer Index: %d", vr.history_idx)
			imgui.BulletText("Acceptance Map Color Coding:")
			imgui.TextColored({0.1, 1.0, 0.2, 1.0}, "  [GREEN] Reprojected pixel accepted (EMA blend)")
			imgui.TextColored({1.0, 0.2, 0.2, 1.0}, "  [RED]   Geometric disocclusion (|depth delta| > threshold)")
			imgui.TextColored({0.2, 0.5, 1.0, 1.0}, "  [BLUE]  Offscreen / Outside viewport UV")
		} else {
			imgui.TextDisabled("Volumetric Lighting is disabled.")
		}
	}

	// 4. Phase 5: Separable Joint Bilateral Blur & Edge Discontinuity Inspector
	if imgui.CollapsingHeader("Separable Joint Bilateral Blur & Edge Inspector (Phase 5)", imgui.TreeNodeFlags{.DefaultOpen}) {
		if vr.params.enabled {
			imgui.TextColored({0.9, 0.6, 0.2, 1.0}, "Bilateral Edge-Aware Blur:")
			if imgui.RadioButton("None / Pass-through##blur", vr.params.blur_mode == 0) {
				vr.params.blur_mode = 0
			}
			imgui.SameLine()
			if imgui.RadioButton("5-tap Bilateral (Fast)##blur", vr.params.blur_mode == 1) {
				vr.params.blur_mode = 1
			}
			imgui.SameLine()
			if imgui.RadioButton("9-tap Bilateral (Smooth ISO)##blur", vr.params.blur_mode == 2) {
				vr.params.blur_mode = 2
			}

			if vr.params.blur_mode > 0 {
				imgui.SliderFloat("Depth Falloff Sharpness", &vr.params.blur_sharpness, 0.0, 2000.0, "%.0f (0=Gaussian Bleed, >500=Strict Edge)")

				imgui.Text("Sharpness Presets:")
				imgui.SameLine()
				if imgui.Button("Gaussian (0 - Bleeds Across Edges)") { vr.params.blur_sharpness = 0.0 }
				imgui.SameLine()
				if imgui.Button("Soft (100)") { vr.params.blur_sharpness = 100.0 }
				imgui.SameLine()
				if imgui.Button("Standard (500)") { vr.params.blur_sharpness = 500.0 }
				imgui.SameLine()
				if imgui.Button("Strict (2000)") { vr.params.blur_sharpness = 2000.0 }

				imgui.Spacing()
				imgui.TextColored({0.3, 0.9, 0.8, 1.0}, "Direct Viewport 3D Scene Edge Overlay:")
				if imgui.RadioButton("Normal Scene##vp", vr.params.viewport_debug_mode == 0) { vr.params.viewport_debug_mode = 0 }
				imgui.SameLine()
				if imgui.RadioButton("Neon Silhouette Highlight##vp", vr.params.viewport_debug_mode == 1) { vr.params.viewport_debug_mode = 1 }
				imgui.SameLine()
				if imgui.RadioButton("Isolated Silhouettes##vp", vr.params.viewport_debug_mode == 2) { vr.params.viewport_debug_mode = 2 }

				if imgui.RadioButton("Difference Map (x10)##vp", vr.params.viewport_debug_mode == 3) { vr.params.viewport_debug_mode = 3 }
				imgui.SameLine()
				if imgui.RadioButton("Weight Attenuation Map##vp", vr.params.viewport_debug_mode == 4) { vr.params.viewport_debug_mode = 4 }

				imgui.Spacing()
				imgui.TextWrapped("Architectural Note: Bilateral Blur denoises low-res volumetric fog without bleeding across sphere edges. Full-res geometric edge aliasing is solved in Phase 6 (Joint Bilateral Upsampling).")
			}
		} else {
			imgui.TextDisabled("Volumetric Lighting is disabled.")
		}
	}

	// 5. Phase 6: Composite & Joint Bilateral Upsampling Inspector
	if imgui.CollapsingHeader("Composite & Joint Bilateral Upsampling (Phase 6)", imgui.TreeNodeFlags{.DefaultOpen}) {
		if vr.params.enabled {
			imgui.TextColored({0.2, 0.9, 0.7, 1.0}, "Full-Resolution Depth-Guided Upsampling Mode:")
			if imgui.RadioButton("Bilinear Standard (Naive Baseline)##upsample", vr.params.upsample_mode == 0) {
				vr.params.upsample_mode = 0
			}
			imgui.SameLine()
			if imgui.RadioButton("Nearest-Depth Fast JBU##upsample", vr.params.upsample_mode == 1) {
				vr.params.upsample_mode = 1
			}
			imgui.SameLine()
			if imgui.RadioButton("Joint Bilateral 2x2 (JBU)##upsample", vr.params.upsample_mode == 2) {
				vr.params.upsample_mode = 2
			}

			if vr.params.upsample_mode == 2 {
				imgui.SliderFloat("JBU Sharpness", &vr.params.upsample_sharpness, 10.0, 1000.0, "%.0f (Higher = Sharper Silhouettes)")

				imgui.Text("JBU Presets:")
				imgui.SameLine()
				if imgui.Button("Soft (50)##jbu") { vr.params.upsample_sharpness = 50.0 }
				imgui.SameLine()
				if imgui.Button("Standard (200)##jbu") { vr.params.upsample_sharpness = 200.0 }
				imgui.SameLine()
				if imgui.Button("Strict (500)##jbu") { vr.params.upsample_sharpness = 500.0 }
			}

			imgui.Spacing()
			switch vr.params.upsample_mode {
			case 0:
				imgui.TextColored({1.0, 0.4, 0.4, 1.0}, "[!] Bilinear: Bleeds low-res fog across sphere silhouettes (visible half-res jagged staircasing).")
			case 1:
				imgui.TextColored({0.4, 0.8, 1.0, 1.0}, "[+] Nearest-Depth: Snaps to the foreground/background depth tap. Zero bleed, low ALU cost.")
			case 2:
				imgui.TextColored({0.2, 1.0, 0.4, 1.0}, "[*] Joint Bilateral Upsampling: 2x2 depth-weighted bilateral filter. Eliminates edge fringing while preserving sub-pixel smoothness.")
			}
		} else {
			imgui.TextDisabled("Volumetric Lighting is disabled.")
		}
	}

	// 6. Phase 7: Atmosphere Presets & GPU Performance Hub
	if imgui.CollapsingHeader("Atmosphere Presets & GPU Profiler Hub (Phase 7)", imgui.TreeNodeFlags{.DefaultOpen}) {

		// Atmospheric Presets Selector
		imgui.TextColored({1.0, 0.8, 0.2, 1.0}, "Atmospheric & Cinematic Presets:")
		if imgui.Button("Default (Standard)") {
			rendering.volumetric_preset_apply(vr, light, .Default)
		}
		imgui.SameLine()
		if imgui.Button("Isotropic Gas") {
			rendering.volumetric_preset_apply(vr, light, .Isotropic)
		}
		imgui.SameLine()
		if imgui.Button("Morning Fog") {
			rendering.volumetric_preset_apply(vr, light, .Morning_Fog)
		}

		if imgui.Button("God Rays (Dramatic)") {
			rendering.volumetric_preset_apply(vr, light, .God_Rays)
		}
		imgui.SameLine()
		if imgui.Button("Torch / Searchlight") {
			rendering.volumetric_preset_apply(vr, light, .Alan_Wake_Torch)
		}
		imgui.SameLine()
		if imgui.Button("Car Headlights") {
			rendering.volumetric_preset_apply(vr, light, .Car_Headlights)
		}
		imgui.SameLine()
		if imgui.Button("Dense Dust / Sand") {
			rendering.volumetric_preset_apply(vr, light, .Dense_Dust)
		}

		// GPU Performance Metrics (double-buffered hardware queries)
		imgui.Spacing()
		imgui.Separator()
		total_avg, total_min, total_max := rendering.volumetric_timer_get_total_metrics(&vr.timers)
		total_us := total_avg * 1000.0

		imgui.TextColored({0.3, 0.9, 1.0, 1.0}, "Volumetric GPU Pipeline Metrics (GL_TIME_ELAPSED):")
		imgui.Text("Total Frame Budget: %.3f ms (%.1f us)  [min: %.2f ms, max: %.2f ms]", total_avg, total_us, total_min, total_max)

		imgui.Spacing()
		passes := [rendering.NUM_VOLUMETRIC_TIMER_PASSES]rendering.Volumetric_Timer_Pass{
			.Shadow_Pass,
			.Depth_Downsample,
			.Raymarching,
			.TAA_Blend,
			.Bilateral_Blur,
			.Composite_Upsample,
		}

		avail_w := imgui.GetContentRegionAvail().x
		bar_w := max(100.0, avail_w - 220.0)

		for pass in passes {
			avg, _, _ := rendering.volumetric_timer_get_metrics(&vr.timers, pass)
			pct := rendering.volumetric_timer_get_pct(&vr.timers, pass)
			name := rendering.volumetric_timer_pass_name(pass)
			us := avg * 1000.0

			imgui.Text("%-18s: %6.1f us (%4.1f%%)", name, us, pct)
			imgui.SameLine()
			fraction := clamp(pct / 100.0, 0.0, 1.0)
			imgui.ProgressBar(fraction, imgui.Vec2{bar_w, 14.0}, "")
		}
	}
}

// Search filter widget rendering for Volumetric parameters.
@(private)
draw_filtered_volumetric :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	vr := state.volumetric
	if vr == nil { return 0 }
	light := state.point_light
	dd := state.depth_downsample
	match_count := 0

	if fuzzy_match(filter, "Volumetric Presets", "volumetric presets atmosphere fog god rays isotropic torch headlights dust") {
		imgui.Text("Atmosphere Presets:")
		for p in rendering.Volumetric_Preset {
			name := rendering.volumetric_preset_name(p)
			if imgui.Button(fmt.ctprintf("%s##vol_preset_filt", name)) {
				rendering.volumetric_preset_apply(vr, light, p)
			}
			imgui.SameLine()
		}
		imgui.NewLine()
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Raymarching", "volumetric light raymarch scattering fog mist atmosphere enable") {
		imgui.Checkbox("Enable Volumetric Raymarching##filt", &vr.params.enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Composite in Scene", "volumetric composite scene add blend direct") {
		imgui.Checkbox("Composite into Viewport##filt", &vr.params.composite_in_scene)
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Intensity Multiplier", "volumetric intensity mult master brightness power") {
		imgui.SliderFloat("Master Intensity##filt", &vr.params.intensity_mult, 0.0, 10.0, "%.2fx")
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Shadow Shafts", "volumetric shadows shafts god rays cubemap occlusion") {
		imgui.Checkbox("Shadow Shafts (God Rays)##filt", &vr.params.shadows_enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "Raymarch Steps", "volumetric raymarching steps samples quality performance") {
		imgui.SliderInt("Raymarch Steps (N)##filt", &vr.params.step_count, 4, 64)
		match_count += 1
	}
	if fuzzy_match(filter, "Scattering Coeff", "volumetric scattering sigma_s density fog") {
		imgui.SliderFloat("Scattering Coeff (sigma_s)##filt", &vr.params.scattering_coeff, 0.001, 0.2, "%.3f")
		match_count += 1
	}
	if fuzzy_match(filter, "Extinction Coeff", "volumetric extinction sigma_t absorption fog beer lambert") {
		imgui.SliderFloat("Extinction Coeff (sigma_t)##filt", &vr.params.extinction_coeff, 0.001, 0.5, "%.3f")
		match_count += 1
	}
	if light != nil && fuzzy_match(filter, "Phase Anisotropy (g)", "volumetric henyey greenstein anisotropy forward backward scattering phase") {
		g_val := vr.params.anisotropy_g
		if imgui.SliderFloat("Phase Anisotropy (g)##filt", &g_val, -0.9, 0.9, "%.2f") {
			rendering.volumetric_set_anisotropy(vr, light, g_val)
		}
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Spatial Jitter", "volumetric spatial jitter interleaved gradient noise ign dither") {
		imgui.Checkbox("IGN Spatial Jitter##filt", &vr.params.jitter_enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "TAA Reprojection", "volumetric taa temporal reprojection history jitter") {
		imgui.Combo("TAA Mode##vol_filt", &vr.params.taa_mode, "0: Off\x001: Simple EMA Blend\x002: Motion-Aware TAA Reprojection\x00\x00")
		imgui.SliderFloat("TAA Alpha##vol_filt", &vr.params.taa_alpha, 0.02, 1.00, "%.2f")
		imgui.SliderFloat("Disocclusion Depth Tol.##vol_filt", &vr.params.taa_depth_threshold, 0.05, 5.0, "%.2f m")
		imgui.Checkbox("3x3 Color Box Clamping##vol_filt", &vr.params.taa_clamping_enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "Bilateral Blur", "volumetric bilateral blur edge preserving filter smoothing sharpness") {
		imgui.Combo("Blur Filter##vol_filt", &vr.params.blur_mode, "0: Off\x001: 5-Tap Bilateral (Fast)\x002: 9-Tap Bilateral (Smooth ISO)\x00\x00")
		imgui.SliderFloat("Blur Sharpness##vol_filt", &vr.params.blur_sharpness, 10.0, 2000.0, "%.0f")
		match_count += 1
	}
	if fuzzy_match(filter, "Upsample Mode", "volumetric upsample jbu nearest bilateral sharpness") {
		imgui.Combo("JBU Mode##filt", &vr.params.upsample_mode, "Bilinear Standard (Fast)\x00Nearest-Depth Fast JBU\x00Joint Bilateral Upsampling 2x2 (Ultra HD)\x00\x00")
		imgui.SliderFloat("JBU Sharpness##filt", &vr.params.upsample_sharpness, 10.0, 2000.0, "%.0f")
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Viewport Debug Mode", "volumetric viewport debug neon silhouette isolated difference weight") {
		imgui.Combo("Viewport Debug View##vol_filt", &vr.params.viewport_debug_mode, "Normal Scene\x00Neon Silhouette Highlight\x00Isolated Silhouettes\x00Difference Map (x10)\x00Weight Attenuation Map\x00\x00")
		match_count += 1
	}
	if fuzzy_match(filter, "Volumetric Magnifier Loupe", "volumetric loupe zoom magnifier center inspection") {
		imgui.SliderFloat("Loupe Zoom##vol_filt", &vr.params.zoom_scale, 1.0, 16.0, "%.1fx")
		zoom_arr := [2]f32{vr.params.zoom_center.x, vr.params.zoom_center.y}
		if imgui.SliderFloat2("Loupe Center##vol_filt", &zoom_arr, 0.0, 1.0, "%.2f") {
			vr.params.zoom_center = mt.Vec2{zoom_arr[0], zoom_arr[1]}
		}
		match_count += 1
	}
	if dd != nil && fuzzy_match(filter, "Depth Downsample Edge Threshold", "depth downsample edge threshold discontinuity median filter") {
		imgui.SliderFloat("Depth Edge Threshold (eps)##filt", &dd.edge_threshold, 0.001, 0.100, "%.3f")
		imgui.SliderFloat("Depth Min Range##filt", &dd.preview_min_depth, 0.1, 10.0, "%.1f m")
		imgui.SliderFloat("Depth Max Range##filt", &dd.preview_max_depth, 5.0, 100.0, "%.1f m")
		match_count += 1
	}

	return match_count
}



