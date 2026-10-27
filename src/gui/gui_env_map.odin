package gui

import "core:fmt"
import "core:strings"
import imgui "../../deps/odin-imgui"
import rendering "../rendering"
import mt "../core/math_types"

// Dedicated Dear ImGui panel for Environment Maps & HDR Gallery
draw_tab_env_map :: proc(g: ^Gui, state: Scene_State) {
	imgui.TextColored({0.2, 0.8, 1.0, 1.0}, "Environment Maps & Skybox Gallery")
	imgui.Separator()

	// 1. Current Active Environment Status
	curr_idx := state.current_hdr_index^ if state.current_hdr_index != nil else 0
	curr_path := ""
	curr_name := "None"
	if len(state.hdr_files) > 0 && curr_idx >= 0 && curr_idx < i32(len(state.hdr_files)) {
		curr_path = state.hdr_files[curr_idx]
		last_slash := strings.last_index_byte(curr_path, '/')
		curr_name = curr_path[last_slash+1:] if last_slash >= 0 else curr_path
	}

	if imgui.CollapsingHeader("Active Environment Map", imgui.TreeNodeFlags{.DefaultOpen}) {
		imgui.TextColored({0.4, 0.9, 0.4, 1.0}, fmt.ctprintf("Active HDR: %s", curr_name))
		imgui.Text("Texture ID: %d  |  Resolution: %dx%d  |  Format: RGBA16F",
			state.env_texture_id, state.env_texture_width, state.env_texture_height)

		if state.env_transitioning {
			imgui.ProgressBar(state.env_transition_alpha, imgui.Vec2{-1, 0}, "Transitioning...")
		} else {
			imgui.TextColored({0.5, 0.8, 0.5, 1.0}, "Status: Active & Converged")
		}

		// Fast Cycle Buttons
		if imgui.Button("< Previous Env (Page Up)") {
			if len(state.hdr_files) > 0 && state.change_env != nil && state.current_hdr_index != nil {
				new_idx := (curr_idx - 1 + i32(len(state.hdr_files))) % i32(len(state.hdr_files))
				state.current_hdr_index^ = new_idx
				state.change_env(state.scene_ptr, state.hdr_files[new_idx])
			}
		}
		imgui.SameLine()
		if imgui.Button("Next Env (Page Down) >") {
			if len(state.hdr_files) > 0 && state.change_env != nil && state.current_hdr_index != nil {
				new_idx := (curr_idx + 1) % i32(len(state.hdr_files))
				state.current_hdr_index^ = new_idx
				state.change_env(state.scene_ptr, state.hdr_files[new_idx])
			}
		}

		// Active Equirectangular Preview with Inspector
		if state.env_texture_id != 0 {
			imgui.Spacing()
			content_w := imgui.GetContentRegionAvail().x
			preview_w := max(128.0, min(content_w, 360.0))
			preview_h := preview_w * 0.5
			draw_image_with_inspector(g, state.env_texture_id,
				imgui.Vec2{preview_w, preview_h},
				state.env_texture_width, state.env_texture_height)
		}

		// Sun Detection & Direction Controls
		if state.sun_shadow != nil {
			ss := state.sun_shadow
			det := &ss.detection
			imgui.Spacing()
			imgui.SeparatorText("Sun Lighting & Direction")

			status_str: string
			status_col: imgui.Vec4
			if det.is_aperture && det.sun_detected {
				status_str = "Aperture Detected (Window / Skylight)"
				status_col = imgui.Vec4{0.2, 0.85, 1.0, 1.0}
			} else if det.sun_detected {
				status_str = "Sun Detected (Direct Sunlight)"
				status_col = imgui.Vec4{0.2, 1.0, 0.3, 1.0}
			} else {
				status_str = "Fallback Direction (Indoor / Diffuse)"
				status_col = imgui.Vec4{0.9, 0.7, 0.3, 1.0}
			}
			imgui.TextColored(status_col, "Status: %s", status_str)
			imgui.Text("Azimuth: %.1f deg  |  Elevation: %.1f deg  |  Confidence: %d px  |  Peak: %.1f",
				det.azimuth, det.elevation, det.confidence, det.peak_intensity)

			// Color swatch & override controls
			eff_col := rendering.sun_shadow_get_effective_color(ss)
			imgui.ColorButton("Sun Color##env_swatch", imgui.Vec4{eff_col.x, eff_col.y, eff_col.z, 1.0})
			imgui.SameLine()
			imgui.Text("Color: RGB(%.2f, %.2f, %.2f) (%s)", eff_col.x, eff_col.y, eff_col.z,
				"Manual Override" if ss.color_override_enabled else ("Auto-detected (Aperture)" if det.is_aperture else ("Auto-detected" if det.sun_detected else "Fallback")))
			imgui.SameLine()
			imgui.Checkbox("Override Color##sun_env", &ss.color_override_enabled)

			if ss.color_override_enabled {
				color_arr := [3]f32{ss.manual_color.x, ss.manual_color.y, ss.manual_color.z}
				if imgui.ColorEdit3("Manual Sun Color##sun_env", &color_arr) {
					ss.manual_color = mt.Vec3{color_arr[0], color_arr[1], color_arr[2]}
					if state.volumetric != nil {
						state.volumetric.history_valid = false
					}
				}
				imgui.SameLine()
				if imgui.Button("Reset Color##sun_env") {
					ss.manual_color = det.color
					ss.color_override_enabled = false
					if state.volumetric != nil {
						state.volumetric.history_valid = false
					}
				}
			}

			// Recompute button
			if imgui.Button("Recompute Sun Analysis (CPU)") {
				if len(curr_path) > 0 && state.change_env != nil {
					state.change_env(state.scene_ptr, curr_path, true)
				}
			}
			imgui.SameLine()
			imgui.Checkbox("Manual Override", &ss.override_enabled)
			imgui.SameLine()
			imgui.Checkbox("Show 3D Gizmo", &ss.show_gizmo)

			if ss.override_enabled {
				dir_changed := false
				if imgui.SliderFloat("Azimuth##sun_env", &det.azimuth, -180.0, 180.0, "%.1f deg") {
					dir_changed = true
				}
				if imgui.SliderFloat("Elevation##sun_env", &det.elevation, 0.0, 90.0, "%.1f deg") {
					dir_changed = true
				}
				if dir_changed {
					det.direction = rendering.sun_angles_to_dir(det.azimuth, det.elevation)
					ss.is_dirty = true
					ss.preview_dirty = true
					if state.volumetric != nil {
						state.volumetric.history_valid = false
					}
				}
			}
		}
	}


	imgui.Spacing()

	// 2. Available HDR Gallery (Thumbnails)
	if imgui.CollapsingHeader("Available Environment Gallery", imgui.TreeNodeFlags{.DefaultOpen}) {
		if len(state.env_thumbnails) == 0 {
			imgui.TextDisabled("No HDR environment maps discovered in assets/textures/hdr/")
		} else {
			imgui.TextDisabled("Click any thumbnail or button to switch environment map:")
			imgui.Spacing()

			for &thumb, i in state.env_thumbnails {
				rendering.env_thumbnail_ensure_loaded(&thumb)
				imgui.PushIDInt(i32(i))
				is_active := (i32(i) == curr_idx)

				imgui.BeginGroup()
				
				// Display thumbnail (180x90 px)
				thumb_w: f32 = 180.0
				thumb_h: f32 = 90.0
				
				if thumb.tex_id != 0 {
					imgui.ImageWithBg(
						gl_tex_ref(thumb.tex_id),
						imgui.Vec2{thumb_w, thumb_h},
						{0, 1}, {1, 0},
						{0.1, 0.1, 0.1, 1.0},
						is_active ? {1.0, 1.0, 1.0, 1.0} : {0.7, 0.7, 0.7, 1.0},
					)
					if imgui.IsItemClicked(.Left) && !is_active && state.change_env != nil && state.current_hdr_index != nil {
						state.current_hdr_index^ = i32(i)
						state.change_env(state.scene_ptr, thumb.path)
					}
					if imgui.IsItemHovered() {
						imgui.SetTooltip("Click to load: %s", strings.clone_to_cstring(thumb.filename, context.temp_allocator))
					}
				}

				imgui.EndGroup()
				imgui.SameLine()

				imgui.BeginGroup()
				imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0} if is_active else imgui.Vec4{1.0, 1.0, 1.0, 1.0},
					"%s", fmt.ctprintf("%s", thumb.display_name))
				imgui.TextDisabled("%s", fmt.ctprintf("%s", thumb.filename))
				imgui.TextDisabled("%dx%d RGBA16F", thumb.width, thumb.height)

				if is_active {
					imgui.TextColored({0.2, 0.9, 0.2, 1.0}, "[ACTIVE] CURRENTLY LOADED")
				} else {
					if imgui.Button("Load Environment") {
						if state.change_env != nil && state.current_hdr_index != nil {
							state.current_hdr_index^ = i32(i)
							state.change_env(state.scene_ptr, thumb.path)
						}
					}
				}
				imgui.EndGroup()

				imgui.Separator()
				imgui.PopID()
			}
		}
	}

	imgui.Spacing()

	// 3. Quick Skybox Settings
	if imgui.CollapsingHeader("Skybox & Background Settings") {
		if state.skybox_visible != nil {
			imgui.Checkbox("Skybox Visible", state.skybox_visible)
		}
		if state.skybox_mode != nil {
			mode_val := i32(state.skybox_mode^)
			if imgui.Combo("Skybox Mode", &mode_val, "Equirectangular\x00Cubemap (Diffuse/Specular)\x00\x00") {
				state.skybox_mode^ = rendering.Skybox_Mode(mode_val)
				if state.cubemap_dirty != nil {
					state.cubemap_dirty^ = true
				}
			}
		}
		if state.skybox_blur_lod != nil {
			imgui.SliderFloat("Skybox Blur (LOD)", state.skybox_blur_lod, 0.0, 8.0, "%.2f")
		}
		if state.exposure != nil {
			imgui.SliderFloat("HDR Exposure", state.exposure, 0.1, 10.0, "%.2f")
		}
	}
}

// Search palette coverage for Environment Map settings
draw_filtered_env_map :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	match_count := 0
	curr_idx := state.current_hdr_index^ if state.current_hdr_index != nil else 0

	if fuzzy_match(filter, "Active Environment Map", "hdr environment active map current cedar bridge garage neon cathedral") {
		imgui.Text("Active Texture ID: %d (%dx%d)", state.env_texture_id, state.env_texture_width, state.env_texture_height)
		if imgui.Button("Cycle Next Env##filt") {
			if len(state.hdr_files) > 0 && state.change_env != nil && state.current_hdr_index != nil {
				new_idx := (curr_idx + 1) % i32(len(state.hdr_files))
				state.current_hdr_index^ = new_idx
				state.change_env(state.scene_ptr, state.hdr_files[new_idx])
			}
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Environment Gallery", "hdr environment gallery thumbnails miniatures switch load") {
		for thumb, i in state.env_thumbnails {
			imgui.PushIDInt(i32(100 + i))
			is_active := (i32(i) == curr_idx)
			imgui.TextUnformatted(fmt.ctprintf("%s: %s", "[ACTIVE]" if is_active else "[AVAILABLE]", thumb.display_name))
			if !is_active {
				imgui.SameLine()
				if imgui.SmallButton("Load##filt_thumb") {
					if state.change_env != nil && state.current_hdr_index != nil {
						state.current_hdr_index^ = i32(i)
						state.change_env(state.scene_ptr, thumb.path)
					}
				}
			}
			imgui.PopID()
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Skybox Blur LOD", "skybox blur lod background roughness") {
		if state.skybox_blur_lod != nil {
			imgui.SliderFloat("Skybox Blur (LOD)##filt", state.skybox_blur_lod, 0.0, 8.0, "%.2f")
			match_count += 1
		}
	}

	if fuzzy_match(filter, "Skybox Mode", "skybox mode equirectangular cubemap") {
		if state.skybox_mode != nil {
			mode_val := i32(state.skybox_mode^)
			if imgui.Combo("Skybox Mode##filt", &mode_val, "Equirectangular\x00Cubemap\x00\x00") {
				state.skybox_mode^ = rendering.Skybox_Mode(mode_val)
				if state.cubemap_dirty != nil {
					state.cubemap_dirty^ = true
				}
			}
			match_count += 1
		}
	}

	if state.sun_shadow != nil && fuzzy_match(filter, "Sun Direction & Override", "sun direction azimuth elevation override gizmo recompute analysis lighting color tint chromaticity window skylight aperture opening portal") {
		ss := state.sun_shadow
		det := &ss.detection
		status_str: string
		status_col: imgui.Vec4
		if det.is_aperture && det.sun_detected {
			status_str = "Aperture Detected (Window / Skylight)"
			status_col = imgui.Vec4{0.2, 0.85, 1.0, 1.0}
		} else if det.sun_detected {
			status_str = "Sun Detected (Direct Sunlight)"
			status_col = imgui.Vec4{0.2, 1.0, 0.3, 1.0}
		} else {
			status_str = "Fallback Direction (Indoor / Diffuse)"
			status_col = imgui.Vec4{0.9, 0.7, 0.3, 1.0}
		}
		imgui.TextColored(status_col, "Status: %s", status_str)
		imgui.Text("Azimuth: %.1f deg | Elevation: %.1f deg | Confidence: %d px | Peak: %.1f",
			det.azimuth, det.elevation, det.confidence, det.peak_intensity)

		eff_col := rendering.sun_shadow_get_effective_color(ss)
		imgui.ColorButton("Sun Color##filt_swatch", imgui.Vec4{eff_col.x, eff_col.y, eff_col.z, 1.0})
		imgui.SameLine()
		imgui.Text("Color: RGB(%.2f, %.2f, %.2f)", eff_col.x, eff_col.y, eff_col.z)
		imgui.SameLine()
		imgui.Checkbox("Override Color##filt_env", &ss.color_override_enabled)
		if ss.color_override_enabled {
			color_arr := [3]f32{ss.manual_color.x, ss.manual_color.y, ss.manual_color.z}
			if imgui.ColorEdit3("Manual Sun Color##filt_env", &color_arr) {
				ss.manual_color = mt.Vec3{color_arr[0], color_arr[1], color_arr[2]}
				if state.volumetric != nil {
					state.volumetric.history_valid = false
				}
			}
		}

		curr_path := ""
		if state.current_hdr_index != nil && len(state.hdr_files) > 0 {
			curr_path = state.hdr_files[state.current_hdr_index^]
		}
		if imgui.Button("Recompute Sun Analysis (CPU)##filt") {
			if len(curr_path) > 0 && state.change_env != nil {
				state.change_env(state.scene_ptr, curr_path, true)
			}
		}
		imgui.SameLine()
		imgui.Checkbox("Sun Manual Override##filt", &ss.override_enabled)
		imgui.SameLine()
		imgui.Checkbox("Show Sun 3D Gizmo##filt", &ss.show_gizmo)

		if ss.override_enabled || !det.sun_detected {
			dir_changed := false
			if imgui.SliderFloat("Sun Azimuth##filt_sun", &det.azimuth, -180.0, 180.0, "%.1f deg") {
				dir_changed = true
			}
			if imgui.SliderFloat("Sun Elevation##filt_sun", &det.elevation, 0.0, 90.0, "%.1f deg") {
				dir_changed = true
			}
			if dir_changed {
				det.direction = rendering.sun_angles_to_dir(det.azimuth, det.elevation)
				ss.is_dirty = true
				ss.preview_dirty = true
				if state.volumetric != nil {
					state.volumetric.history_valid = false
				}
			}
		} else {
			imgui.TextDisabled("Enable 'Sun Manual Override' to adjust angles manually.")
		}
		match_count += 1
	}

	return match_count
}

