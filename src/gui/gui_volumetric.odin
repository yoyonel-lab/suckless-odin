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

	// 2. Shadow Cubemap Live Preview & Resolution Inspector
	if imgui.CollapsingHeader("Shadow Cubemap Inspector (3x2 Atlas & Controls)", imgui.TreeNodeFlags{}) {
		// Dynamic Resolution Control
		res_options := [4]i32{256, 512, 1024, 2048}
		current_res_idx: i32 = 1 // default 512
		for i in 0..<4 {
			if sc.resolution == res_options[i] {
				current_res_idx = i32(i)
				break
			}
		}
		if imgui.Combo("Cubemap Resolution", &current_res_idx, "256x256\x00512x512\x001024x1024\x002048x2048\x00\x00") {
			new_res := res_options[current_res_idx]
			if new_res != sc.resolution {
				rendering.shadow_cubemap_resize(sc, new_res)
			}
		}

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

	// 3. Phase 2: Depth Downsample & Edge Discontinuity Inspector
	if state.depth_downsample != nil && imgui.CollapsingHeader("Depth Downsample & Discontinuities (Phase 2)", imgui.TreeNodeFlags{}) {
		dd := state.depth_downsample
		imgui.Text("Full: %dx%d -> Half: %dx%d (Rank/Median 4-tap Filter)", dd.full_width, dd.full_height, dd.width, dd.height)

		imgui.SliderFloat("Edge Relative Threshold (ε)", &dd.edge_threshold, 0.001, 0.100, "%.3f (Scale-Invariant)")

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
				imgui.SetTooltip("Depth Discontinuity Mask:\nRed = Silhouette Edge (High Relative Step Δz/z > ε)\nDark Blue = Continuous Geometry / Sky")
			} else {
				imgui.SetTooltip("Downsampled Linear Camera Depth (Median 4-tap filtered)")
			}
		}
	}

	// 4. Phase 3: Volumetric Raymarching & Henyey-Greenstein Inspector
	if state.volumetric != nil && imgui.CollapsingHeader("Volumetric Raymarching & Henyey-Greenstein (Phase 3)", imgui.TreeNodeFlags{.DefaultOpen}) {
		vr := state.volumetric
		avail_w := imgui.GetContentRegionAvail().x

		imgui.Checkbox("Enable Volumetric Raymarching", &vr.params.enabled)
		imgui.SameLine()
		imgui.Checkbox("Direct In-Scene Viewport", &vr.params.composite_in_scene)
		imgui.SameLine()
		imgui.Checkbox("Isolate Volumetric (No IBL)", &vr.params.isolate_in_scene)

		if vr.params.enabled {
			imgui.SliderInt("Raymarch Steps (N)", &vr.params.step_count, 4, 64)
			imgui.SliderFloat("Scattering Coeff (sigma_s)", &vr.params.scattering_coeff, 0.01, 1.0, "%.3f")
			imgui.SliderFloat("Anisotropy (g)", &vr.params.anisotropy_g, -0.90, 0.90, "%.2f")
			imgui.SliderFloat("Intensity Multiplier", &vr.params.intensity_mult, 0.0, 10.0, "%.2f")
			imgui.Checkbox("Volumetric Shadows (God Rays)", &vr.params.shadows_enabled)
			imgui.SameLine()
			imgui.Checkbox("Spatial Ray Jittering (IGN)", &vr.params.jitter_enabled)

			// Atmosphere Scattering Presets (ISO legacy Volumetric_Dynamic_Lights)
			imgui.Spacing()
			imgui.TextColored({0.4, 0.8, 1.0, 1.0}, "Atmospheric & Cinematic Presets:")
			if imgui.Button("Isotropic (g=0.0)") { vr.params.anisotropy_g = 0.0 }
			imgui.SameLine()
			if imgui.Button("Dust / Sand (g=0.35)") { vr.params.anisotropy_g = 0.35 }
			imgui.SameLine()
			if imgui.Button("Morning Fog (g=0.55)") { vr.params.anisotropy_g = 0.55 }
			imgui.SameLine()
			if imgui.Button("God Rays (g=0.70)") { vr.params.anisotropy_g = 0.70 }

			if imgui.Button("Alan Wake Torch (g=0.80)") { vr.params.anisotropy_g = 0.80 }
			imgui.SameLine()
			if imgui.Button("Car Headlights (g=0.88)") { vr.params.anisotropy_g = 0.88 }
			imgui.SameLine()
			if imgui.Button("Backscatter (g=-0.35)") { vr.params.anisotropy_g = -0.35 }

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

			imgui.Text("Preview Mode:")
			if imgui.RadioButton("Final Output##vol", vr.params.preview_mode == 0) { vr.params.preview_mode = 0 }
			imgui.SameLine()
			if imgui.RadioButton("Raw Grain##vol", vr.params.preview_mode == 1) { vr.params.preview_mode = 1 }
			imgui.SameLine()
			if imgui.RadioButton("Heatmap##vol", vr.params.preview_mode == 2) { vr.params.preview_mode = 2 }
			imgui.SameLine()
			if imgui.RadioButton("TAA Acceptance##vol", vr.params.preview_mode == 3) { vr.params.preview_mode = 3 }
			imgui.SameLine()
			if imgui.RadioButton("Post-Blur HDR##vol", vr.params.preview_mode == 4) { vr.params.preview_mode = 4 }

			if imgui.RadioButton("Bilateral Diff (|Δ|x10)##vol", vr.params.preview_mode == 5) { vr.params.preview_mode = 5 }
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
					imgui.SetTooltip("Bilateral Weight Attenuation Map:\n🟩 Green/Yellow (1.0) = Full blur allowed (homogeneous depth)\n🟥 Red/Blue (<0.2) = Depth edge detected, blur clamped to prevent bleed!")
				case 3:
					imgui.SetTooltip("TAA Acceptance Map (GL_RGBA8, W/2 x H/2):\n🟩 Green: Valid reprojected history pixel\n🟥 Red: Geometric disocclusion (depth delta > threshold)\n🟦 Blue: Offscreen reprojection outside viewport.")
				case 1:
					imgui.SetTooltip("Raw Raymarching buffer before temporal/bilateral filtering.\nPreserves spatial Interleaved Gradient Noise (IGN) grain.")
				case:
					imgui.SetTooltip("Volumetric In-Scattering Buffer (GL_RGBA16F, W/2 x H/2)\nCalculated via analytical ray-sphere raymarching + shadow cubemap.")
				}
			}
		}
	}

	// 5. Phase 4: TAA Temporal Reprojection & History Blending Inspector
	if state.volumetric != nil && imgui.CollapsingHeader("TAA Reprojection & History Blending (Phase 4)", imgui.TreeNodeFlags{.DefaultOpen}) {
		vr := state.volumetric
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
				imgui.SameLine()
				imgui.Checkbox("Spatial Ray Jitter (IGN Grain)", &vr.params.jitter_enabled)
			} else {
				imgui.TextDisabled("Temporal accumulation disabled. Spatial ray jittering grain is active.")
				imgui.Checkbox("Spatial Ray Jitter (IGN Grain)##raw", &vr.params.jitter_enabled)
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

	// 6. Phase 5: Separable Joint Bilateral Blur & Edge Discontinuity Inspector
	if state.volumetric != nil && imgui.CollapsingHeader("Separable Joint Bilateral Blur & Edge Inspector (Phase 5)", imgui.TreeNodeFlags{.DefaultOpen}) {
		vr := state.volumetric
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
}

