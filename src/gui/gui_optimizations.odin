package gui

import "core:strings"
import imgui "../../deps/odin-imgui"
import rendering "../rendering"

// Dedicated Dear ImGui panel for Performance & Optimization Presets
draw_tab_optimizations :: proc(g: ^Gui, state: Scene_State) {
	imgui.TextColored({0.2, 0.9, 0.5, 1.0}, "Performance & Optimization Presets Hub")
	imgui.Separator()

	vr := state.volumetric
	light := state.point_light
	sc := state.shadow_cubemap
	current_prof := state.optimization_profile^ if state.optimization_profile != nil else .Quality

	// 1. Presets Selector
	if imgui.CollapsingHeader("Optimization Presets", imgui.TreeNodeFlags{.DefaultOpen}) {
		imgui.TextDisabled("Select a performance profile calibrated for your hardware:")
		imgui.Spacing()

		// Buttons row
		is_quality := (current_prof == .Quality)
		is_balanced := (current_prof == .Balanced)
		is_ultra := (current_prof == .Ultra_Performance)
		is_custom := (current_prof == .Custom)

		if is_quality { imgui.PushStyleColorImVec4(.Button, imgui.Vec4{0.2, 0.6, 0.3, 1.0}) }
		if imgui.Button("1. Quality (Cinematic)") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Quality
				rendering.optimization_profile_apply(.Quality, vr, light, sc)
				rendering.optimization_profile_log(.Quality, vr, light, sc)
			}
		}
		if is_quality { imgui.PopStyleColor() }
		imgui.SameLine()

		if is_balanced { imgui.PushStyleColorImVec4(.Button, imgui.Vec4{0.2, 0.6, 0.3, 1.0}) }
		if imgui.Button("2. Balanced (Recommended)") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Balanced
				rendering.optimization_profile_apply(.Balanced, vr, light, sc)
				rendering.optimization_profile_log(.Balanced, vr, light, sc)
			}
		}
		if is_balanced { imgui.PopStyleColor() }
		imgui.SameLine()

		if is_ultra { imgui.PushStyleColorImVec4(.Button, imgui.Vec4{0.2, 0.6, 0.3, 1.0}) }
		if imgui.Button("3. Ultra-Performance") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Ultra_Performance
				rendering.optimization_profile_apply(.Ultra_Performance, vr, light, sc)
				rendering.optimization_profile_log(.Ultra_Performance, vr, light, sc)
			}
		}
		if is_ultra { imgui.PopStyleColor() }

		imgui.Spacing()
		prof_name := rendering.optimization_profile_name(current_prof)
		imgui.Text("Active Profile: ")
		imgui.SameLine()
		imgui.TextColored(is_custom ? imgui.Vec4{1.0, 0.7, 0.2, 1.0} : imgui.Vec4{0.3, 1.0, 0.4, 1.0},
			"%s", strings.clone_to_cstring(prof_name, context.temp_allocator))

		// Profile Description Card
		imgui.Spacing()
		switch current_prof {
		case .Quality:
			imgui.TextColored({0.4, 0.8, 1.0, 1.0}, "[Quality / Reference Profile]")
			imgui.BulletText("Volumetric: 32 raymarching steps, Beer-Lambert accumulation, JBU 2x2 upsampling")
			imgui.BulletText("Shadows: Vogel-Disk PCF 16-tap, Shadow TAA active, Full 6-face cubemap per frame")
			imgui.BulletText("Target: Discrete GPUs & high-end hardware (~9.5 ms / ~105 FPS on iGPU)")

		case .Balanced:
			imgui.TextColored({0.3, 1.0, 0.5, 1.0}, "[Balanced / Optimized iGPU - Recommended]")
			imgui.BulletText("Volumetric: 16 stochastic steps + Golden-Ratio temporal jitter + TAA blend")
			imgui.BulletText("Shadows: Vogel-Disk PCF 8-tap + Shadow TAA active, Time-Slicing 2 faces/frame")
			imgui.BulletText("Target: Mobile & Integrated GPUs (+40%% FPS gain, ~6.0 ms / ~150 FPS)")

		case .Ultra_Performance:
			imgui.TextColored({1.0, 0.6, 0.2, 1.0}, "[Ultra-Performance Profile]")
			imgui.BulletText("Volumetric: 8 fast steps, Quarter-resolution downsampling, Nearest-Depth upsampling")
			imgui.BulletText("Shadows: Fast 4-tap, 256x256 cubemap, Time-Slicing 1 face/frame")
			imgui.BulletText("Target: Low-power devices & competitive framerates (> 180 FPS)")

		case .Custom:
			imgui.TextColored({1.0, 0.8, 0.3, 1.0}, "[Custom Profile]")
			imgui.TextDisabled("Individual parameters have been manually modified.")
		}
	}

	imgui.Spacing()

	// 2. Profile Settings Quick Adjustments
	if imgui.CollapsingHeader("Live Profile Parameters", imgui.TreeNodeFlags{.DefaultOpen}) {
		if vr != nil {
			imgui.TextColored({0.4, 0.8, 1.0, 1.0}, "Volumetric Lighting Pipeline:")
			
			step_val := vr.params.step_count
			if imgui.SliderInt("Raymarch Steps##opt_steps", &step_val, 4, 64) {
				vr.params.step_count = step_val
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}

			upsample_val := vr.params.upsample_mode
			if imgui.Combo("Upsampling Filter##opt_upsample", &upsample_val, "Bilinear (Fast)\x00Nearest-Depth\x00Joint Bilateral (JBU 2x2)\x00\x00") {
				vr.params.upsample_mode = upsample_val
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}

			blur_val := vr.params.blur_mode
			if imgui.Combo("Spatial Blur##opt_blur", &blur_val, "Off\x00Gaussian 3x3\x00Bilateral 5x5\x00\x00") {
				vr.params.blur_mode = blur_val
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}
		}

		imgui.Spacing()
		if light != nil {
			imgui.TextColored({1.0, 0.8, 0.3, 1.0}, "Shadows & PCF Filtering:")

			pcf_samples := light.shadow_pcf_samples
			if imgui.Combo("PCF Samples##opt_pcf", &pcf_samples, "Hard (1-tap)\x00\x00\x00\x00Vogel-Disk (4-tap)\x00\x00\x00\x00Vogel-Disk (8-tap)\x00\x00\x00\x00\x00\x00\x00\x00Vogel-Disk (16-tap)\x00\x00") {
				light.shadow_pcf_samples = pcf_samples
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}

			if imgui.Checkbox("Shadow TAA Anti-Aliasing##opt_taa", &light.shadow_taa_enabled) {
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}
		}

		if sc != nil {
			time_slice := sc.time_slice_mode
			if imgui.Combo("Shadow Cubemap Slicing##opt_slice", &time_slice, "Off (All 6 faces/frame)\x002 faces / frame\x001 face / frame\x00\x00") {
				sc.time_slice_mode = time_slice
				if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
			}
		}
	}
}

// Search palette coverage for Optimization Profile settings
draw_filtered_optimizations :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	match_count := 0
	vr := state.volumetric
	light := state.point_light
	sc := state.shadow_cubemap
	current_prof := state.optimization_profile^ if state.optimization_profile != nil else .Quality

	if fuzzy_match(filter, "Optimization Presets", "optimization profile presets performance quality balanced ultra fps speed") {
		imgui.Text("Active Profile: %s", strings.clone_to_cstring(rendering.optimization_profile_name(current_prof), context.temp_allocator))
		if imgui.SmallButton("Set Quality##filt_prof") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Quality
				rendering.optimization_profile_apply(.Quality, vr, light, sc)
			}
		}
		imgui.SameLine()
		if imgui.SmallButton("Set Balanced (Recommended)##filt_prof") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Balanced
				rendering.optimization_profile_apply(.Balanced, vr, light, sc)
			}
		}
		imgui.SameLine()
		if imgui.SmallButton("Set Ultra-Performance##filt_prof") {
			if state.optimization_profile != nil {
				state.optimization_profile^ = .Ultra_Performance
				rendering.optimization_profile_apply(.Ultra_Performance, vr, light, sc)
			}
		}
		match_count += 1
	}

	if vr != nil && fuzzy_match(filter, "Optimization Volumetric Steps", "volumetric raymarch steps stochastic 16 32 8") {
		step_val := vr.params.step_count
		if imgui.SliderInt("Volumetric Steps##opt_steps_filt", &step_val, 4, 64) {
			vr.params.step_count = step_val
			if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
		}
		match_count += 1
	}

	if light != nil && fuzzy_match(filter, "Optimization PCF Samples", "shadow pcf samples vogel 8 16 4") {
		pcf_samples := light.shadow_pcf_samples
		if imgui.SliderInt("PCF Samples##opt_pcf_filt", &pcf_samples, 1, 16) {
			light.shadow_pcf_samples = pcf_samples
			if state.optimization_profile != nil { state.optimization_profile^ = .Custom }
		}
		match_count += 1
	}

	return match_count
}
