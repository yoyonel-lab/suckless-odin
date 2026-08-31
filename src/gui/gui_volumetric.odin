package gui

import imgui "../../deps/odin-imgui"
import rendering "../rendering"
import mt "../core/math_types"

// Dedicated Dear ImGui panel for Point Light & Shadow Cubemap (Phase 1) and Volumetric Light
draw_tab_volumetric_shadows :: proc(g: ^Gui, state: Scene_State) {
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

		imgui.SliderFloat("Radius / Far Plane", &light.radius, 1.0, 50.0)
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
			imgui.SliderFloat("Shadow Bias", &light.shadow_bias, 0.0001, 0.05, "%.4f")
			imgui.SliderFloat("Shadow Darkening", &light.shadow_darkening, 0.0, 1.0, "%.2f")
			imgui.Checkbox("Shadow Debug Mask (Green=Lit, Red=Occluded)", &light.shadow_debug_mask)
		}

		imgui.Spacing()
		imgui.Checkbox("Show Light Bulb Gizmo", &light.show_bulb)
		if light.show_bulb {
			imgui.SliderFloat("Bulb Gizmo Radius", &light.bulb_radius, 0.05, 2.0, "%.2f m")
		}
	}

	// 2. Shadow Cubemap Live Preview
	if imgui.CollapsingHeader("Shadow Cubemap Inspector (3x2 Atlas)", imgui.TreeNodeFlags{.DefaultOpen}) {
		imgui.Text("Resolution: %dx%d per face | Near: %.2f | Far: %.2f", sc.resolution, sc.resolution, sc.near_plane, sc.far_plane)

		// 6 Face status indicators
		imgui.Text("Faces:")
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
			imgui.SetTooltip("Unfolded Cubemap 3x2 Grid:\nTop: +X (Right), +Y (Top), +Z (Front)\nBottom: -X (Left), -Y (Bottom), -Z (Back)\nColor: Radial Distance to Sphere Surface")
		}
	}
}
