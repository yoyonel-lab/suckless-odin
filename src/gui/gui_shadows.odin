package gui

import imgui "../../deps/odin-imgui"
import rendering "../rendering"
import mt "../core/math_types"

// Dedicated Dear ImGui panel for Point Light & Shadow Cubemap (Phase 1)
draw_tab_shadows :: proc(g: ^Gui, state: Scene_State) {
	if state.point_light == nil || state.shadow_cubemap == nil {
		imgui.TextDisabled("Point light / Shadow Cubemap resources not initialized.")
		return
	}

	light := state.point_light
	sc := state.shadow_cubemap

	imgui.TextColored({0.2, 0.8, 1.0, 1.0}, "Point Light & Omnidirectional Shadows (Phase 1)")
	imgui.Separator()

	// 1. Point Light Properties
	if imgui.CollapsingHeader("Point Light Controls", imgui.TreeNodeFlags{.DefaultOpen}) {
		imgui.Checkbox("Light Enabled", &light.enabled)
		imgui.SameLine()
		imgui.Checkbox("Orbit Animation", &light.is_animated)

		if light.is_animated {
			imgui.SliderFloat("Orbit Speed", &light.orbit_speed, 0.0, 2.0, "%.3f rad/s")
			imgui.SliderFloat("Orbit Radius", &light.orbit_radius, 0.0, 20.0)
			pos_arr := [3]f32{light.orbit_center.x, light.orbit_center.y, light.orbit_center.z}
			if imgui.DragFloat3("Orbit Center", &pos_arr, 0.1) {
				light.orbit_center = mt.Vec3{pos_arr[0], pos_arr[1], pos_arr[2]}
			}
		} else {
			pos_arr := [3]f32{light.position.x, light.position.y, light.position.z}
			if imgui.DragFloat3("Position", &pos_arr, 0.1) {
				light.position = mt.Vec3{pos_arr[0], pos_arr[1], pos_arr[2]}
				light.is_dirty = true
			}
		}

		imgui.SliderFloat("Radius / Influence", &light.radius, 1.0, 50.0)
		color_arr := [3]f32{light.color.x, light.color.y, light.color.z}
		if imgui.ColorEdit3("Light Color", &color_arr) {
			light.color = mt.Vec3{color_arr[0], color_arr[1], color_arr[2]}
		}
		imgui.SliderFloat("Intensity", &light.intensity, 0.0, 10.0)
		imgui.SliderFloat("Phase Anisotropy (g)", &light.phase_g, -0.9, 0.9)

		imgui.Separator()
		imgui.TextColored({1.0, 0.9, 0.3, 1.0}, "Surface Shadow Mapping Verification (Debug Mode)")
		imgui.Checkbox("Direct Surface Shadows", &light.direct_shadows_enabled)
		if light.direct_shadows_enabled {
			imgui.SliderFloat("Shadow Base Bias", &light.shadow_bias, 0.0001, 0.02, "%.4f")
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Base constant depth bias applied to all surface fragments.")
			}

			imgui.SliderFloat("Normal Offset Bias", &light.shadow_normal_bias, 0.0, 0.10, "%.3f m")
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Receiver Normal Offset Bias (Crytek / UE4 style):\nDisplaces the shadow sample position along the surface normal N.\nEliminates 99%% of shadow acne on sphere curvatures without Peter-Panning!")
			}

			imgui.SliderFloat("Slope-Scaled Bias", &light.shadow_slope_bias, 0.0, 0.01, "%.4f")
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Slope-Scaled Bias:\nDynamically scales depth tolerance proportional to tan(theta) at grazing angles.")
			}

			imgui.SliderFloat("Shadow Darkening", &light.shadow_darkening, 0.0, 1.0, "%.2f")
			imgui.Checkbox("Shadow Debug Mask (Green=Lit, Red=Occluded)", &light.shadow_debug_mask)
		}

		imgui.Spacing()
		imgui.Checkbox("Show Light Bulb Gizmo", &light.show_bulb)
		if light.show_bulb {
			imgui.SliderFloat("Bulb Gizmo Radius", &light.bulb_radius, 0.05, 2.0, "%.2f m")
		}
	}

	// 2. Shadow Cubemap Live Preview & Resolution Inspector
	if imgui.CollapsingHeader("Shadow Cubemap Inspector (3x2 Atlas & Controls)", imgui.TreeNodeFlags{.DefaultOpen}) {
		// Dynamic Resolution Control (ISO parity: 64, 128, 256, 512)
		if imgui.Combo("Cube Shadow Map Res", &sc.res_index, "64x64\x00128x128\x00256x256 (Default)\x00512x512 (Ultra HD)\x00\x00") {
			new_res := rendering.shadow_cubemap_res_for_index(sc.res_index)
			if new_res != sc.resolution {
				rendering.shadow_cubemap_resize(sc, new_res)
				light.is_dirty = true
			}
		}

		imgui.Checkbox("Shadow Map Dirty Caching", &sc.shadow_cache)
		imgui.Combo(
			"Shadow Time-Slicing",
			&sc.time_slice_mode,
			"All 6 faces (Realtime / Max Quality)\x003 faces / frame (2-frame cycle)\x002 faces / frame (3-frame cycle)\x001 face / frame (Max Performance)\x00\x00",
		)

		imgui.SliderFloat("Near Clip", &sc.near_plane, 0.001, 1.0, "%.3f m")
		imgui.SliderFloat("Far Clip", &sc.far_plane, 1.0, 50.0, "%.1f m")

		// 6 Face status indicators
		imgui.Text("Face Cache Status:")
		imgui.SameLine()
		face_names := [6]cstring{"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
		for i in 0..<6 {
			if sc.cached_faces[i] {
				imgui.TextColored({0.2, 1.0, 0.2, 1.0}, "[%s: Cached]", face_names[i])
			} else {
				imgui.TextColored({1.0, 0.3, 0.3, 1.0}, "[%s: Dirty]", face_names[i])
			}
			if i < 5 do imgui.SameLine()
		}

		// Update 2D preview atlas on-demand when inspector is visible
		rendering.shadow_cubemap_update_preview_atlas(sc)

		// Render 3x2 unfolded preview
		imgui.Spacing()
		avail_w := imgui.GetContentRegionAvail().x
		preview_w := max(256.0, min(avail_w, 600.0))
		preview_h := preview_w * (2.0 / 3.0)

		imgui.Image(
			gl_tex_ref(sc.preview_tex),
			imgui.Vec2{preview_w, preview_h},
			imgui.Vec2{0, 1}, // Flip Y for OpenGL
			imgui.Vec2{1, 0},
		)

		if imgui.IsItemHovered() {
			mouse_pos := imgui.GetMousePos()
			item_min := imgui.GetItemRectMin()
			item_size := imgui.GetItemRectSize()
			rel_x := clamp((mouse_pos.x - item_min.x) / item_size.x, 0.0, 1.0)
			rel_y := clamp((mouse_pos.y - item_min.y) / item_size.y, 0.0, 1.0)

			// Determine which of the 3x2 face is under cursor
			col := i32(rel_x * 3.0)
			row := i32(rel_y * 2.0)
			face_idx := row * 3 + col
			face_label := face_names[clamp(face_idx, 0, 5)]

			imgui.SetTooltip("Hovered Face: %s (Col %d, Row %d)\nUV: (%.2f, %.2f)\nTop: +X (Right), +Y (Top), +Z (Front)\nBottom: -X (Left), -Y (Bottom), -Z (Back)", face_label, col, row, rel_x, rel_y)
		}
	}
}

// Search filter widget rendering for Shadow & Point Light parameters.
@(private)
draw_filtered_shadows :: proc(g: ^Gui, state: Scene_State, filter: cstring) -> int {
	if state.point_light == nil { return 0 }
	light := state.point_light
	sc := state.shadow_cubemap
	match_count := 0

	if fuzzy_match(filter, "Light Enabled", "point light toggle omnidirectional source") {
		imgui.Checkbox("Light Enabled##filt", &light.enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "Orbit Animation", "light animation movement rotation speed radius") {
		imgui.Checkbox("Orbit Animation##filt", &light.is_animated)
		if light.is_animated {
			imgui.SliderFloat("Orbit Speed##filt", &light.orbit_speed, 0.0, 2.0, "%.3f rad/s")
			imgui.SliderFloat("Orbit Radius##filt", &light.orbit_radius, 0.0, 20.0)
		}
		match_count += 1
	}
	if fuzzy_match(filter, "Direct Surface Shadows", "shadows direct pbr surface shadow mapping") {
		imgui.Checkbox("Direct Surface Shadows##filt", &light.direct_shadows_enabled)
		match_count += 1
	}
	if fuzzy_match(filter, "Shadow Base Bias", "shadow bias base constant depth acne") {
		imgui.SliderFloat("Shadow Base Bias##filt", &light.shadow_bias, 0.0001, 0.02, "%.4f")
		match_count += 1
	}
	if fuzzy_match(filter, "Normal Offset Bias", "shadow normal offset bias rnob receiver acne curvature") {
		imgui.SliderFloat("Normal Offset Bias##filt", &light.shadow_normal_bias, 0.0, 0.10, "%.3f m")
		match_count += 1
	}
	if fuzzy_match(filter, "Slope-Scaled Bias", "shadow slope bias ssdb grazing angle acne") {
		imgui.SliderFloat("Slope-Scaled Bias##filt", &light.shadow_slope_bias, 0.0, 0.01, "%.4f")
		match_count += 1
	}
	if fuzzy_match(filter, "Shadow Darkening", "shadow darkening occlusion attenuation intensity") {
		imgui.SliderFloat("Shadow Darkening##filt", &light.shadow_darkening, 0.0, 1.0, "%.2f")
		match_count += 1
	}
	if fuzzy_match(filter, "Shadow Debug Mask", "shadow debug mask green lit red occluded verification") {
		imgui.Checkbox("Shadow Debug Mask##filt", &light.shadow_debug_mask)
		match_count += 1
	}
	if fuzzy_match(filter, "Light Bulb Gizmo", "bulb gizmo sphere radius visual light") {
		imgui.Checkbox("Show Light Bulb Gizmo##filt", &light.show_bulb)
		if light.show_bulb {
			imgui.SliderFloat("Bulb Gizmo Radius##filt", &light.bulb_radius, 0.05, 2.0, "%.2f m")
		}
		match_count += 1
	}
	if sc != nil && fuzzy_match(filter, "Cube Shadow Map Res", "shadow resolution cubemap atlas 64 128 256 512") {
		if imgui.Combo("Cube Shadow Map Res##filt", &sc.res_index, "64x64\x00128x128\x00256x256 (Default)\x00512x512 (Ultra HD)\x00\x00") {
			new_res := rendering.shadow_cubemap_res_for_index(sc.res_index)
			if new_res != sc.resolution {
				rendering.shadow_cubemap_resize(sc, new_res)
				light.is_dirty = true
			}
		}
		match_count += 1
	}

	return match_count
}
