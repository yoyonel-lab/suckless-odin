package gui

import "core:math"
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
	if imgui.CollapsingHeader("Shadow Cubemap Inspector (3x2 Atlas)", imgui.TreeNodeFlags{}) {
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

	// 3. Phase 2: Depth Downsample & Edge Discontinuity Inspector
	if state.depth_downsample != nil && imgui.CollapsingHeader("Depth Downsample & Discontinuities (Phase 2)", imgui.TreeNodeFlags{}) {
		dd := state.depth_downsample
		imgui.Text("Full: %dx%d -> Half: %dx%d (Rank/Median 4-tap Filter)", dd.full_width, dd.full_height, dd.width, dd.height)

		imgui.SliderFloat("Edge Step Threshold", &dd.edge_threshold, 0.01, 2.0, "%.2f m")

		// Preview display modes
		imgui.Text("Preview Mode:")
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
				imgui.SetTooltip("Depth Discontinuity Mask:\nRed = Silhouette Edge (High Depth Step)\nDark Blue = Continuous Geometry / Sky")
			} else {
				imgui.SetTooltip("Downsampled Linear Camera Depth (Median 4-tap filtered)")
			}
		}
	}

	// 4. Phase 3: Volumetric Raymarching & Henyey-Greenstein Inspector
	if state.volumetric != nil && imgui.CollapsingHeader("Volumetric Raymarching & Henyey-Greenstein (Phase 3)", imgui.TreeNodeFlags{.DefaultOpen}) {
		vr := state.volumetric
		avail_w := imgui.GetContentRegionAvail().x

		imgui.Checkbox("Enable Volumetric Raymarching", &vr.enabled)
		imgui.SameLine()
		imgui.Checkbox("Direct In-Scene Viewport", &vr.composite_in_scene)
		imgui.SameLine()
		imgui.Checkbox("Isolate Volumetric (No IBL)", &vr.isolate_in_scene)

		if vr.enabled {
			imgui.SliderInt("Raymarch Steps (N)", &vr.step_count, 4, 64)
			imgui.SliderFloat("Scattering Coeff (sigma_s)", &vr.scattering_coeff, 0.01, 2.0, "%.3f")
			imgui.SliderFloat("Extinction Coeff (sigma_t)", &vr.extinction_coeff, 0.00, 1.0, "%.3f")
			imgui.SliderFloat("Anisotropy (g)", &vr.anisotropy_g, -0.90, 0.90, "%.2f")
			imgui.SliderFloat("Intensity Multiplier", &vr.intensity_mult, 0.0, 10.0, "%.2f")
			imgui.Checkbox("Volumetric Shadows (God Rays)", &vr.shadows_enabled)
			imgui.SameLine()
			imgui.Checkbox("Spatial Ray Jittering (IGN)", &vr.jitter_enabled)

			// Henyey-Greenstein Phase Plot
			imgui.Spacing()
			imgui.TextColored({1.0, 0.8, 0.2, 1.0}, "Henyey-Greenstein Phase Function P(theta, g):")
			phase_samples: [64]f32
			max_p: f32 = 0.001
			for i in 0..<64 {
				theta := (f32(i) / 63.0) * math.PI
				cos_theta := math.cos(theta)
				p := rendering.volumetric_henyey_greenstein(cos_theta, vr.anisotropy_g)
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

			// 2D Raw In-Scattering Buffer Preview
			imgui.Spacing()
			imgui.Separator()
			imgui.Text("Raw In-Scattering HDR Buffer (%dx%d):", vr.width, vr.height)

			imgui.Text("Preview Mode:")
			imgui.SameLine()
			if imgui.RadioButton("RGB In-Scattering##vol", vr.preview_mode == 0) { vr.preview_mode = 0 }
			imgui.SameLine()
			if imgui.RadioButton("Transmittance##vol", vr.preview_mode == 1) { vr.preview_mode = 1 }
			imgui.SameLine()
			if imgui.RadioButton("Heatmap##vol", vr.preview_mode == 2) { vr.preview_mode = 2 }

			imgui.SliderFloat("Exposure Boost##vol", &vr.preview_exposure_boost, 1.0, 10.0, "%.1fx")

			rendering.volumetric_update_preview(vr)

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
				imgui.SetTooltip("Raw Volumetric In-Scattering Buffer (GL_RGBA16F, W/2 x H/2)\nCalculated via analytical ray-sphere raymarching + shadow cubemap.")
			}
		}
	}
}
