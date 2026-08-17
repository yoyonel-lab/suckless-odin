package gui

import "core:fmt"
import "core:slice"
import "core:strings"

import imgui "../../deps/odin-imgui"
import settings "../core/settings"

// Helper to check if a profile is a protected built-in profile
is_protected_profile :: proc(name: string) -> bool {
	return name == "legacy" || name == "optimized"
}

// Dedicated tab for Compute Shader and Progressive Slicing Tuning
draw_tab_compute_tuning :: proc(g: ^Gui, state: Scene_State) {
	// --- Lazy initialization on first display ---
	if !g.compute_tuning_loaded {
		config, ok := settings.load_compute_tuning_config()
		if ok {
			g.compute_tuning_config = config
			g.compute_tuning_loaded = true
			
			// Try to find "legacy" profile as default selection
			g.compute_tuning_selected_idx = 0
			keys := make([dynamic]string, context.temp_allocator)
			for k, _ in g.compute_tuning_config.profiles {
				append(&keys, k)
			}
			slice.sort(keys[:])
			
			for key, idx in keys {
				if key == "legacy" {
					g.compute_tuning_selected_idx = i32(idx)
					break
				}
			}
			
			if len(keys) > 0 {
				selected_key := keys[g.compute_tuning_selected_idx]
				g.compute_tuning_draft = g.compute_tuning_config.profiles[selected_key]
			}
		} else {
			// Fallback: initialize with built-in legacy defaults
			g.compute_tuning_config.profiles = make(map[string]settings.Compute_Tuning_Params)
			g.compute_tuning_config.profiles["legacy"] = settings.DEFAULT_COMPUTE_TUNING
			g.compute_tuning_config.profiles["optimized"] = settings.DEFAULT_OPTIMIZED_COMPUTE_TUNING
			g.compute_tuning_loaded = true
			g.compute_tuning_selected_idx = 0
			g.compute_tuning_draft = settings.DEFAULT_COMPUTE_TUNING
		}
	}

	// Retrieve sorted list of profile names to keep list stable in UI
	keys := make([dynamic]string, context.temp_allocator)
	for k, _ in g.compute_tuning_config.profiles {
		append(&keys, k)
	}
	slice.sort(keys[:])

	imgui.TextColored(imgui.Vec4{1.0, 0.8, 0.3, 1.0}, "Compute & Slicing Tuning")
	imgui.TextWrapped("Staged parameter tweaking. Edits are held in local draft memory until explicitly validated and applied.")
	imgui.Separator()

	imgui.Spacing()

	// --- 1. Profile / Preset Select Combo ---
	current_profile_name := "Select..."
	if len(keys) > 0 && g.compute_tuning_selected_idx >= 0 && g.compute_tuning_selected_idx < i32(len(keys)) {
		current_profile_name = keys[g.compute_tuning_selected_idx]
	}

	imgui.Text("Active Profile:")
	imgui.SetNextItemWidth(200)
	if imgui.BeginCombo("##profile_combo", fmt.ctprintf("%s", current_profile_name)) {
		for key, idx in keys {
			is_selected := i32(idx) == g.compute_tuning_selected_idx
			if imgui.Selectable(fmt.ctprintf("%s", key), is_selected) {
				g.compute_tuning_selected_idx = i32(idx)
				g.compute_tuning_draft = g.compute_tuning_config.profiles[key]
				g.compute_tuning_status_msg = "Profile loaded!"
				g.compute_tuning_status_timer = 2.0
			}
		}
		imgui.EndCombo()
	}

	imgui.Spacing()
	imgui.Separator()

	// --- 2. Edit Parameter Fields (Draft State) ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Compute Shader Parameters")

	// Sample Counts
	val_spbrdf := g.compute_tuning_draft.spbrdf_sample_count
	if imgui.SliderInt("SPBRDF Sample Count", &val_spbrdf, 32, 2048) {
		g.compute_tuning_draft.spbrdf_sample_count = val_spbrdf
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Precomputed BRDF integration sample count\n1024 = full visual reference\n256 = fast build, minimal loss")
	}
	draw_reset_button("spbrdf", &g.compute_tuning_draft.spbrdf_sample_count, settings.DEFAULT_COMPUTE_TUNING.spbrdf_sample_count)

	val_spmap := g.compute_tuning_draft.spmap_sample_count
	if imgui.SliderInt("SPMap Sample Count", &val_spmap, 32, 2048) {
		g.compute_tuning_draft.spmap_sample_count = val_spmap
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Specular reflection environment map mip convolution samples\n1024 = pristine, 512 = optimized balance")
	}
	draw_reset_button("spmap", &g.compute_tuning_draft.spmap_sample_count, settings.DEFAULT_COMPUTE_TUNING.spmap_sample_count)

	// Sample Delta
	val_ir_delta := g.compute_tuning_draft.irmap_sample_delta
	if imgui.SliderFloat("IRMap Delta", &val_ir_delta, 0.005, 0.200, "%.3f") {
		g.compute_tuning_draft.irmap_sample_delta = val_ir_delta
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Irradiance sphere map integral sample step delta (radians)\nSmaller = higher quality but more samples\n0.025 = reference, 0.05 = optimized")
	}
	draw_reset_button("irmap_delta", &g.compute_tuning_draft.irmap_sample_delta, settings.DEFAULT_COMPUTE_TUNING.irmap_sample_delta)

	imgui.Spacing()

	// Slicing and Amortization parameters
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Sliced Amortization (Frames)")

	val_mip0 := g.compute_tuning_draft.slicing.specular_mip0_slices
	if imgui.DragInt("Mip 0 Slices", &val_mip0, 1.0, 1, 100) {
		g.compute_tuning_draft.slicing.specular_mip0_slices = val_mip0
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Number of slices/frames used to convolve base specular level (Mip 0)\n1 = all in one frame, >1 = amortize over multiple frames")
	}
	draw_reset_button("mip0_slices", &g.compute_tuning_draft.slicing.specular_mip0_slices, settings.DEFAULT_COMPUTE_TUNING.slicing.specular_mip0_slices)

	val_mip1 := g.compute_tuning_draft.slicing.specular_mip1_slices
	if imgui.DragInt("Mip 1 Slices", &val_mip1, 1.0, 1, 100) {
		g.compute_tuning_draft.slicing.specular_mip1_slices = val_mip1
	}
	draw_reset_button("mip1_slices", &g.compute_tuning_draft.slicing.specular_mip1_slices, settings.DEFAULT_COMPUTE_TUNING.slicing.specular_mip1_slices)

	val_mip2 := g.compute_tuning_draft.slicing.specular_mip2_slices
	if imgui.DragInt("Mip 2 Slices", &val_mip2, 1.0, 1, 100) {
		g.compute_tuning_draft.slicing.specular_mip2_slices = val_mip2
	}
	draw_reset_button("mip2_slices", &g.compute_tuning_draft.slicing.specular_mip2_slices, settings.DEFAULT_COMPUTE_TUNING.slicing.specular_mip2_slices)

	val_irdiff := g.compute_tuning_draft.slicing.irdiff_slices
	if imgui.DragInt("Irradiance Slices", &val_irdiff, 1.0, 1, 100) {
		g.compute_tuning_draft.slicing.irdiff_slices = val_irdiff
	}
	draw_reset_button("irdiff_slices", &g.compute_tuning_draft.slicing.irdiff_slices, settings.DEFAULT_COMPUTE_TUNING.slicing.irdiff_slices)

	// Mip Progressive Thresholds
	val_grouping_start := g.compute_tuning_draft.slicing.specular_mip_grouping_start_mip
	if imgui.SliderInt("Mip Grouping Start Mip", &val_grouping_start, 0, 10) {
		g.compute_tuning_draft.slicing.specular_mip_grouping_start_mip = val_grouping_start
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Starting mip level where convolving maps are processed in a single group slice.")
	}
	draw_reset_button("grouping_start", &g.compute_tuning_draft.slicing.specular_mip_grouping_start_mip, settings.DEFAULT_COMPUTE_TUNING.slicing.specular_mip_grouping_start_mip)

	val_downsample := g.compute_tuning_draft.slicing.seamless_downsample_progressive_mip_threshold
	if imgui.SliderInt("Seamless Progressive Mip Threshold", &val_downsample, 0, 10) {
		g.compute_tuning_draft.slicing.seamless_downsample_progressive_mip_threshold = val_downsample
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Threshold mip level below which downsampling uses progressive sliced routines.")
	}
	draw_reset_button("downsample", &g.compute_tuning_draft.slicing.seamless_downsample_progressive_mip_threshold, settings.DEFAULT_COMPUTE_TUNING.slicing.seamless_downsample_progressive_mip_threshold)


	imgui.Spacing()
	imgui.Separator()

	// --- 3. Staged Bulk Application Action ---
	imgui.TextColored(imgui.Vec4{1.0, 0.6, 0.2, 1.0}, "Apply changes to application:")
	
	if imgui.Button("Apply & Recalculate Active Environment", imgui.Vec2{350, 32}) {
		if !settings.validate_compute_tuning_params(g.compute_tuning_draft) {
			g.compute_tuning_error_msg = "Rejected: values outside valid semantic limits!"
			g.compute_tuning_error_timer = 4.0
		} else {
			if state.apply_compute_tuning != nil {
				if state.apply_compute_tuning(state.scene_ptr, g.compute_tuning_draft) {
					g.compute_tuning_status_msg = "Successfully applied and triggered recalculation!"
					g.compute_tuning_status_timer = 3.0
				} else {
					g.compute_tuning_error_msg = "Shader compilation failed!"
					g.compute_tuning_error_timer = 4.0
				}
			} else {
				g.compute_tuning_error_msg = "Apply callback not registered!"
				g.compute_tuning_error_timer = 4.0
			}
		}
	}

	// Status Feedback
	if g.compute_tuning_status_msg != nil && g.compute_tuning_status_timer > 0 {
		imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "%s", g.compute_tuning_status_msg)
		g.compute_tuning_status_timer -= imgui.GetIO().DeltaTime
		if g.compute_tuning_status_timer <= 0 {
			g.compute_tuning_status_msg = nil
		}
	}

	if g.compute_tuning_error_msg != nil && g.compute_tuning_error_timer > 0 {
		imgui.TextColored(imgui.Vec4{1.0, 0.3, 0.3, 1.0}, "%s", g.compute_tuning_error_msg)
		g.compute_tuning_error_timer -= imgui.GetIO().DeltaTime
		if g.compute_tuning_error_timer <= 0 {
			g.compute_tuning_error_msg = nil
		}
	}

	imgui.Spacing()
	imgui.Separator()

	// --- 4. Profile CRUD Operations ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Profile Manager (CRUD)")

	// Save Settings to Active Profile
	if len(keys) > 0 {
		active_key := keys[g.compute_tuning_selected_idx]
		button_label := fmt.ctprintf("Save Draft to '%s'", active_key)
		if imgui.Button(button_label) {
			if !settings.validate_compute_tuning_params(g.compute_tuning_draft) {
				g.compute_tuning_error_msg = "Cannot save: draft has invalid parameters!"
				g.compute_tuning_error_timer = 4.0
			} else {
				g.compute_tuning_config.profiles[active_key] = g.compute_tuning_draft
				if settings.save_compute_tuning_config(g.compute_tuning_config) {
					g.compute_tuning_status_msg = "Profile saved successfully to JSON!"
					g.compute_tuning_status_timer = 2.0
				} else {
					g.compute_tuning_error_msg = "Failed to save profile config!"
					g.compute_tuning_error_timer = 4.0
				}
			}
		}

		imgui.SameLine()
		
		// Delete Profile button (disabled for built-in protected profiles)
		is_protected := is_protected_profile(active_key)
		if is_protected {
			imgui.BeginDisabled()
		}
		if imgui.Button("Delete Profile") {
			imgui.OpenPopup("Confirm Delete Profile")
		}
		if is_protected {
			imgui.EndDisabled()
		}
	}

	// Delete confirmation modal
	if imgui.BeginPopupModal("Confirm Delete Profile", nil, {.AlwaysAutoResize}) {
		imgui.Text("Delete profile?")
		if len(keys) > 0 {
			active_key := keys[g.compute_tuning_selected_idx]
			imgui.TextColored(imgui.Vec4{1.0, 0.8, 0.3, 1.0}, "%s", fmt.ctprintf("%s", active_key))
		}
		imgui.Spacing()
		if imgui.Button("Yes, delete") {
			active_key := keys[g.compute_tuning_selected_idx]
			
			// Remove from configuration map
			delete_key(&g.compute_tuning_config.profiles, active_key)
			delete(active_key) // free key string
			
			// Default back to legacy index
			g.compute_tuning_selected_idx = 0
			
			// Save updated config
			if settings.save_compute_tuning_config(g.compute_tuning_config) {
				g.compute_tuning_status_msg = "Profile deleted successfully!"
				g.compute_tuning_status_timer = 2.0
			} else {
				g.compute_tuning_error_msg = "Failed to save config after deletion!"
				g.compute_tuning_error_timer = 4.0
			}
			
			// Refresh stable keys and load selection draft
			keys = make([dynamic]string, context.temp_allocator)
			for k, _ in g.compute_tuning_config.profiles {
				append(&keys, k)
			}
			slice.sort(keys[:])
			
			if len(keys) > 0 {
				selected_key := keys[g.compute_tuning_selected_idx]
				g.compute_tuning_draft = g.compute_tuning_config.profiles[selected_key]
			}
			
			imgui.CloseCurrentPopup()
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {
			imgui.CloseCurrentPopup()
		}
		imgui.EndPopup()
	}

	imgui.Spacing()

	// Create New Profile Section
	imgui.Text("Create new profile:")
	imgui.SetNextItemWidth(180)
	imgui.InputText("##new_profile_name", cast(cstring)&g.compute_tuning_save_name[0], len(g.compute_tuning_save_name))
	imgui.SameLine()
	
	new_name_cstr := cstring(&g.compute_tuning_save_name[0])
	new_name_str := string(new_name_cstr)
	create_disabled := len(new_name_str) == 0 || new_name_str in g.compute_tuning_config.profiles
	
	if create_disabled {
		imgui.BeginDisabled()
	}
	if imgui.Button("Create") {
		if !settings.validate_compute_tuning_params(g.compute_tuning_draft) {
			g.compute_tuning_error_msg = "Cannot create: draft has invalid parameters!"
			g.compute_tuning_error_timer = 4.0
		} else {
			// Save a copy of draft under new name (cloned string key)
			key_clone := strings.clone(new_name_str, context.allocator)
			g.compute_tuning_config.profiles[key_clone] = g.compute_tuning_draft
			
			if settings.save_compute_tuning_config(g.compute_tuning_config) {
				g.compute_tuning_status_msg = "Profile created successfully!"
				g.compute_tuning_status_timer = 2.0
				
				// Clear name input buffer
				g.compute_tuning_save_name = {}
				
				// Update selection index to the new profile
				new_keys := make([dynamic]string, context.temp_allocator)
				for k, _ in g.compute_tuning_config.profiles {
					append(&new_keys, k)
				}
				slice.sort(new_keys[:])
				for key, idx in new_keys {
					if key == new_name_str {
						g.compute_tuning_selected_idx = i32(idx)
						break
					}
				}
			} else {
				g.compute_tuning_error_msg = "Failed to save new profile config!"
				g.compute_tuning_error_timer = 4.0
			}
		}
	}
	if create_disabled {
		imgui.EndDisabled()
	}
}

draw_reset_button :: proc(id: string, current_val: ^$T, default_val: T) {
	imgui.SameLine()
	if imgui.Button(fmt.ctprintf("Reset##%s", id)) {
		current_val^ = default_val
	}
	if imgui.IsItemHovered() {
		imgui.SetTooltip(fmt.ctprintf("Reset this parameter to default value: %v", default_val))
	}
}

// Compute tuning filtered search entries — called from draw_filtered_view.
@(private)
draw_filtered_compute :: proc(g: ^Gui, filter: cstring) -> int {
	match_count := 0

	if fuzzy_match(filter, "Active Compute Profile", "compute profile tuning preset legacy optimized active") {
		compute_goto_button(g)
		imgui.SameLine()
		imgui.Text("Compute Profile (Tuning Tab)")
		match_count += 1
	}

	if fuzzy_match(filter, "SPBRDF Sample Count", "compute spbrdf samples brdf lut integration quality") {
		val := g.compute_tuning_draft.spbrdf_sample_count
		if imgui.SliderInt("SPBRDF Sample Count##filt", &val, 32, 2048) {
			g.compute_tuning_draft.spbrdf_sample_count = val
		}
		match_count += 1
	}

	if fuzzy_match(filter, "SPMap Sample Count", "compute spmap samples specular prefilter convolution quality") {
		val := g.compute_tuning_draft.spmap_sample_count
		if imgui.SliderInt("SPMap Sample Count##filt", &val, 32, 2048) {
			g.compute_tuning_draft.spmap_sample_count = val
		}
		match_count += 1
	}

	if fuzzy_match(filter, "IRMap Delta", "compute irmap delta irradiance angle step samples quality") {
		val := g.compute_tuning_draft.irmap_sample_delta
		if imgui.SliderFloat("IRMap Delta##filt", &val, 0.005, 0.200, "%.3f") {
			g.compute_tuning_draft.irmap_sample_delta = val
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Specular Mip 0 Slices", "compute progressive slicing specular mip0 slices amortization frame spikes") {
		val := g.compute_tuning_draft.slicing.specular_mip0_slices
		if imgui.DragInt("Mip 0 Slices##filt", &val, 1.0, 1, 100) {
			g.compute_tuning_draft.slicing.specular_mip0_slices = val
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Irradiance Slices", "compute progressive slicing irradiance irdiff slices amortization") {
		val := g.compute_tuning_draft.slicing.irdiff_slices
		if imgui.DragInt("Irradiance Slices##filt", &val, 1.0, 1, 100) {
			g.compute_tuning_draft.slicing.irdiff_slices = val
		}
		match_count += 1
	}

	return match_count
}


