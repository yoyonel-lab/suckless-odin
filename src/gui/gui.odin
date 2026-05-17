package gui

import "vendor:glfw"
import "core:strings"

import imgui "../../deps/odin-imgui"
import "../../deps/odin-imgui/imgui_impl_glfw"
import "../../deps/odin-imgui/imgui_impl_opengl3"

import cam "../camera"

// Forward-declare scene data needed by GUI panels.
// Avoids circular import by accepting raw pointers from app.
Scene_State :: struct {
	camera:            ^cam.Camera,
	skybox_visible:    ^bool,
	wireframe_enabled: ^bool,
	exposure:          ^f32,
	skybox_blur_lod:   ^f32,
}

SEARCH_BUF_SIZE :: 128

// GUI state — manages Dear ImGui lifecycle.
Gui :: struct {
	ctx:             ^imgui.Context,
	visible:         bool,
	docking_enabled: bool,
	search_buf:      [SEARCH_BUF_SIZE]u8,
	search_focused:  bool,
}

GLSL_VERSION :: "#version 440 core"

init :: proc(g: ^Gui, window: glfw.WindowHandle) -> bool {
	imgui.CHECKVERSION()

	g.ctx = imgui.CreateContext()
	if g.ctx == nil {
		return false
	}

	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}

	g.docking_enabled = true
	g.visible = true

	imgui.StyleColorsDark()

	if !imgui_impl_glfw.InitForOpenGL(window, true) {
		imgui.DestroyContext(g.ctx)
		g.ctx = nil
		return false
	}

	if !imgui_impl_opengl3.Init(GLSL_VERSION) {
		imgui_impl_glfw.Shutdown()
		imgui.DestroyContext(g.ctx)
		g.ctx = nil
		return false
	}

	return true
}

new_frame :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui_impl_opengl3.NewFrame()
	imgui_impl_glfw.NewFrame()
	imgui.NewFrame()
}

// Single window with search + tab bar for all engine controls.
update :: proc(g: ^Gui, state: Scene_State) {
	if g.ctx == nil { return }
	if !g.visible { return }

	imgui.SetNextWindowSize(imgui.Vec2{400, 560}, .FirstUseEver)

	if imgui.Begin("Engine Controls", &g.visible) {
		// Search bar at the top
		imgui.SetNextItemWidth(-1)
		imgui.InputTextWithHint("##search", "Search parameters...",
			cast(cstring)&g.search_buf[0], SEARCH_BUF_SIZE)

		filter := cstring(&g.search_buf[0])
		has_filter := len(filter) > 0

		imgui.Separator()

		if has_filter {
			// Filtered flat view
			draw_filtered_view(state, filter)
		} else {
			// Normal tab bar
			if imgui.BeginTabBar("##tabs") {
				if imgui.BeginTabItem("Camera") {
					draw_tab_camera(state.camera)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Scene") {
					draw_tab_scene(state)
					imgui.EndTabItem()
				}
				if imgui.BeginTabItem("Rendering") {
					draw_tab_rendering()
					imgui.EndTabItem()
				}
				imgui.EndTabBar()
			}
		}
	}
	imgui.End()
}

render :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui.Render()
	imgui_impl_opengl3.RenderDrawData(imgui.GetDrawData())
}

toggle :: proc(g: ^Gui) {
	g.visible = !g.visible
}

destroy :: proc(g: ^Gui) {
	if g.ctx == nil { return }
	imgui_impl_opengl3.Shutdown()
	imgui_impl_glfw.Shutdown()
	imgui.DestroyContext(g.ctx)
	g.ctx = nil
}

wants_keyboard :: proc(g: ^Gui) -> bool {
	if g.ctx == nil { return false }
	if !g.visible { return false }
	io := imgui.GetIO()
	return io.WantCaptureKeyboard
}

wants_mouse :: proc(g: ^Gui) -> bool {
	if g.ctx == nil { return false }
	if !g.visible { return false }
	io := imgui.GetIO()
	return io.WantCaptureMouse
}

// ─── Tab: Camera ───────────────────────────────────────────────────────────────

@(private)
draw_tab_camera :: proc(c: ^cam.Camera) {
	if c == nil { return }

	imgui.Text("Position: %.1f, %.1f, %.1f", c.position.x, c.position.y, c.position.z)
	imgui.Text("Yaw: %.1f  Pitch: %.1f", c.yaw, c.pitch)
	imgui.Separator()

	imgui.SliderFloat("Speed", &c.velocity, 1.0, 100.0)
	imgui.SliderFloat("Acceleration", &c.acceleration, 1.0, 50.0)
	imgui.SliderFloat("Friction", &c.friction, 0.5, 0.99)
	imgui.SliderFloat("Sensitivity", &c.sensitivity, 0.01, 1.0)
	imgui.SliderFloat("Rotation Smoothing", &c.rotation_smoothing, 0.0, 0.5)
	imgui.SliderFloat("Mouse Smoothing", &c.mouse_smoothing_factor, 0.0, 0.5)
	imgui.SliderFloat("FOV", &c.zoom, 10.0, 120.0)
	imgui.Separator()

	imgui.Checkbox("Head Bobbing", &c.bobbing_enabled)
	if c.bobbing_enabled {
		imgui.SliderFloat("Bobbing Freq", &c.bobbing_frequency, 0.5, 10.0)
		imgui.SliderFloat("Bobbing Amp", &c.bobbing_amplitude, 0.0, 0.01)
	}

	imgui.Separator()
	if imgui.Button("Reset Camera") {
		cam.init(c, 20.0, -90.0, 0.0)
	}
}

// ─── Tab: Scene ────────────────────────────────────────────────────────────────

@(private)
draw_tab_scene :: proc(state: Scene_State) {
	imgui.Checkbox("Skybox", state.skybox_visible)
	imgui.SliderFloat("Skybox Blur", state.skybox_blur_lod, 0.0, 8.0)
	imgui.Separator()

	imgui.BeginDisabled()
	imgui.SliderFloat("Exposure", state.exposure, 0.1, 10.0)
	imgui.EndDisabled()
	imgui.Separator()

	imgui.Checkbox("Wireframe", state.wireframe_enabled)
}

// ─── Tab: Rendering (all debug views & post-FX, greyed until implemented) ────

@(private)
draw_tab_rendering :: proc() {
	// --- PBR Debug Modes ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "PBR Debug Modes")
	imgui.Separator()
	imgui.BeginDisabled()

	pbr_debug_mode: i32 = 0
	imgui.Combo("Debug Mode", &pbr_debug_mode,
		"Final PBR\x00Albedo\x00Normal\x00Metallic\x00Roughness\x00AO\x00Irradiance (Diff)\x00Prefilter (Spec)\x00BRDF LUT\x00GI Probes\x00")

	specular_aa := false
	imgui.Checkbox("Specular Anti-Aliasing", &specular_aa)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Post-Processing ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Post-Processing")
	imgui.Separator()
	imgui.BeginDisabled()

	placeholder := false
	placeholder_f: f32 = 0.5

	imgui.Checkbox("Bloom", &placeholder)
	imgui.SliderFloat("Bloom Intensity", &placeholder_f, 0.0, 2.0)
	imgui.Checkbox("Depth of Field", &placeholder)
	imgui.SliderFloat("DoF Focus Dist", &placeholder_f, 0.0, 100.0)
	imgui.Checkbox("Auto-Exposure", &placeholder)
	imgui.SliderFloat("Manual Exposure", &placeholder_f, 0.1, 10.0)
	imgui.Checkbox("Motion Blur", &placeholder)
	imgui.Checkbox("FXAA", &placeholder)
	imgui.Checkbox("Vignette", &placeholder)
	imgui.Checkbox("Film Grain", &placeholder)
	imgui.Checkbox("Chromatic Aberration", &placeholder)
	imgui.Checkbox("Color Grading (LUT)", &placeholder)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Debug Views ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Debug Views")
	imgui.Separator()
	imgui.BeginDisabled()

	imgui.Checkbox("Bloom Debug", &placeholder)
	imgui.Checkbox("DoF Debug", &placeholder)
	imgui.Checkbox("Exposure Histogram", &placeholder)
	imgui.Checkbox("Motion Blur Debug", &placeholder)
	imgui.Checkbox("FXAA Debug", &placeholder)
	imgui.Checkbox("Stencil Debug", &placeholder)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- GPU Profiling ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Profiling")
	imgui.Separator()
	imgui.BeginDisabled()

	imgui.Checkbox("GPU Timeline", &placeholder)
	imgui.Checkbox("GPU Metrics Log", &placeholder)
	imgui.Checkbox("Perf Mode", &placeholder)
	imgui.Checkbox("Effect Benchmark", &placeholder)

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Scene Debug ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Scene Debug")
	imgui.Separator()
	imgui.BeginDisabled()

	imgui.Checkbox("Light Probes Debug", &placeholder)
	imgui.Checkbox("N-Body Simulation", &placeholder)
	imgui.SliderFloat("Sim Speed", &placeholder_f, 0.0, 5.0)
	imgui.SliderFloat("Gravity", &placeholder_f, 0.0, 10.0)
	imgui.Checkbox("Time Reversal", &placeholder)

	gi_mode: i32 = 0
	imgui.Combo("GI Mode", &gi_mode, "OFF\x00Volume 3D Tex\x00SSBO\x00")

	sort_mode: i32 = 0
	imgui.Combo("Sort Mode", &sort_mode, "None\x00CPU\x00GPU\x00")

	imgui.EndDisabled()
	imgui.Spacing()

	// --- Environment ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Environment")
	imgui.Separator()
	imgui.BeginDisabled()

	env_idx: i32 = 0
	imgui.SliderInt("HDR Env Index", &env_idx, 0, 5)
	imgui.SliderFloat("Env LOD Blur", &placeholder_f, 0.0, 8.0)
	imgui.Checkbox("Screenshot", &placeholder)
	imgui.Checkbox("Hot-Reload Shaders", &placeholder)

	imgui.EndDisabled()
}

// ─── Fuzzy Search ──────────────────────────────────────────────────────────────

// Matches if ALL space-separated terms appear (case-insensitive) in the
// concatenation of label + keywords. Mimics VS Code settings search.
@(private)
fuzzy_match :: proc(filter: cstring, label: string, keywords: string) -> bool {
	filter_str := string(filter)
	if len(filter_str) == 0 { return true }

	// Build haystack: "label keywords" lowercased
	haystack_buf: [512]u8
	haystack_len := 0
	for ch in label {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = u8(to_lower_ascii(ch))
		haystack_len += 1
	}
	haystack_buf[haystack_len] = ' '
	haystack_len += 1
	for ch in keywords {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = u8(to_lower_ascii(ch))
		haystack_len += 1
	}
	haystack := string(haystack_buf[:haystack_len])

	// Split filter by spaces, each term must be found
	term_start := 0
	for i in 0..=len(filter_str) {
		is_end := i == len(filter_str)
		is_space := !is_end && filter_str[i] == ' '
		if is_end || is_space {
			if i > term_start {
				term := filter_str[term_start:i]
				// Lowercase the term for comparison
				term_buf: [128]u8
				term_len := 0
				for ch in term {
					if term_len >= len(term_buf) { break }
					term_buf[term_len] = u8(to_lower_ascii(ch))
					term_len += 1
				}
				term_lower := string(term_buf[:term_len])
				if !strings.contains(haystack, term_lower) {
					return false
				}
			}
			term_start = i + 1
		}
	}
	return true
}

@(private)
to_lower_ascii :: proc(ch: rune) -> rune {
	if ch >= 'A' && ch <= 'Z' {
		return ch + 32
	}
	return ch
}

// Filtered view: draws all parameters that match, grouped by category.
@(private)
draw_filtered_view :: proc(state: Scene_State, filter: cstring) {
	match_count := 0

	c := state.camera

	// ── Camera params ──
	if section_has_matches(filter, CAMERA_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Camera")
		imgui.Separator()

		if c != nil {
			if fuzzy_match(filter, "Speed", "camera movement velocity") {
				imgui.SliderFloat("Speed", &c.velocity, 1.0, 100.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Acceleration", "camera movement accel") {
				imgui.SliderFloat("Acceleration", &c.acceleration, 1.0, 50.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Friction", "camera movement decel damping") {
				imgui.SliderFloat("Friction", &c.friction, 0.5, 0.99)
				match_count += 1
			}
			if fuzzy_match(filter, "Sensitivity", "camera mouse rotation") {
				imgui.SliderFloat("Sensitivity", &c.sensitivity, 0.01, 1.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Rotation Smoothing", "camera interpolation lerp") {
				imgui.SliderFloat("Rotation Smoothing", &c.rotation_smoothing, 0.0, 0.5)
				match_count += 1
			}
			if fuzzy_match(filter, "Mouse Smoothing", "camera input filter") {
				imgui.SliderFloat("Mouse Smoothing", &c.mouse_smoothing_factor, 0.0, 0.5)
				match_count += 1
			}
			if fuzzy_match(filter, "FOV", "camera field of view zoom projection") {
				imgui.SliderFloat("FOV", &c.zoom, 10.0, 120.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Head Bobbing", "camera walk bob oscillation") {
				imgui.Checkbox("Head Bobbing", &c.bobbing_enabled)
				match_count += 1
			}
			if fuzzy_match(filter, "Bobbing Frequency", "camera walk bob speed") {
				imgui.SliderFloat("Bobbing Freq", &c.bobbing_frequency, 0.5, 10.0)
				match_count += 1
			}
			if fuzzy_match(filter, "Bobbing Amplitude", "camera walk bob height") {
				imgui.SliderFloat("Bobbing Amp", &c.bobbing_amplitude, 0.0, 0.01)
				match_count += 1
			}
		}
		imgui.Spacing()
	}

	// ── Scene params ──
	if section_has_matches(filter, SCENE_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Scene")
		imgui.Separator()

		if fuzzy_match(filter, "Skybox", "environment background visible toggle") {
			imgui.Checkbox("Skybox", state.skybox_visible)
			match_count += 1
		}
		if fuzzy_match(filter, "Skybox Blur", "environment lod mip") {
			imgui.SliderFloat("Skybox Blur", state.skybox_blur_lod, 0.0, 8.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Exposure", "tone mapping hdr brightness") {
			imgui.BeginDisabled()
			imgui.SliderFloat("Exposure", state.exposure, 0.1, 10.0)
			imgui.EndDisabled()
			match_count += 1
		}
		if fuzzy_match(filter, "Wireframe", "debug mesh polygon lines") {
			imgui.Checkbox("Wireframe", state.wireframe_enabled)
			match_count += 1
		}
		imgui.Spacing()
	}

	// ── Rendering / Post-FX params ──
	if section_has_matches(filter, RENDERING_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Rendering")
		imgui.Separator()
		imgui.BeginDisabled()

		placeholder := false
		placeholder_f: f32 = 0.5

		if fuzzy_match(filter, "PBR Debug Mode", "albedo normal metallic roughness ao irradiance prefilter brdf") {
			pbr_debug_mode: i32 = 0
			imgui.Combo("Debug Mode", &pbr_debug_mode,
				"Final PBR\x00Albedo\x00Normal\x00Metallic\x00Roughness\x00AO\x00Irradiance\x00Prefilter\x00BRDF LUT\x00GI Probes\x00")
			match_count += 1
		}
		if fuzzy_match(filter, "Specular Anti-Aliasing", "aa filtering") {
			imgui.Checkbox("Specular Anti-Aliasing", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Bloom", "glow post effect") {
			imgui.Checkbox("Bloom", &placeholder)
			imgui.SliderFloat("Bloom Intensity", &placeholder_f, 0.0, 2.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Depth of Field", "dof bokeh blur focus") {
			imgui.Checkbox("Depth of Field", &placeholder)
			imgui.SliderFloat("DoF Focus Dist", &placeholder_f, 0.0, 100.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Auto-Exposure", "adaptation luminance eye") {
			imgui.Checkbox("Auto-Exposure", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Motion Blur", "velocity tile") {
			imgui.Checkbox("Motion Blur", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "FXAA", "anti-aliasing antialiasing smooth") {
			imgui.Checkbox("FXAA", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Vignette", "border darken") {
			imgui.Checkbox("Vignette", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Film Grain", "noise cinematic") {
			imgui.Checkbox("Film Grain", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Chromatic Aberration", "color fringe lens") {
			imgui.Checkbox("Chromatic Aberration", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Color Grading", "lut tone color correction") {
			imgui.Checkbox("Color Grading (LUT)", &placeholder)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	// ── Debug Views ──
	if section_has_matches(filter, DEBUG_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Debug")
		imgui.Separator()
		imgui.BeginDisabled()

		placeholder := false

		if fuzzy_match(filter, "Bloom Debug", "glow visualization") {
			imgui.Checkbox("Bloom Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "DoF Debug", "depth focus visualization") {
			imgui.Checkbox("DoF Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Exposure Histogram", "luminance distribution") {
			imgui.Checkbox("Exposure Histogram", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Motion Blur Debug", "velocity visualization") {
			imgui.Checkbox("Motion Blur Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "FXAA Debug", "edge detection visualization") {
			imgui.Checkbox("FXAA Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Stencil Debug", "mask buffer") {
			imgui.Checkbox("Stencil Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "GPU Timeline", "profiling performance timing") {
			imgui.Checkbox("GPU Timeline", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "GPU Metrics Log", "profiling performance stats") {
			imgui.Checkbox("GPU Metrics Log", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Perf Mode", "profiling fps benchmark") {
			imgui.Checkbox("Perf Mode", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Light Probes Debug", "gi global illumination") {
			imgui.Checkbox("Light Probes Debug", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "N-Body Simulation", "physics particles gravity") {
			imgui.Checkbox("N-Body Simulation", &placeholder)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	// ── Environment ──
	if section_has_matches(filter, ENV_KEYWORDS) {
		imgui.TextColored(imgui.Vec4{0.4, 0.9, 0.4, 1.0}, "Environment")
		imgui.Separator()
		imgui.BeginDisabled()

		placeholder := false
		placeholder_f: f32 = 0.5
		env_idx: i32 = 0

		if fuzzy_match(filter, "HDR Env Index", "environment map cycling skybox") {
			imgui.SliderInt("HDR Env Index", &env_idx, 0, 5)
			match_count += 1
		}
		if fuzzy_match(filter, "Env LOD Blur", "environment mip background") {
			imgui.SliderFloat("Env LOD Blur", &placeholder_f, 0.0, 8.0)
			match_count += 1
		}
		if fuzzy_match(filter, "Screenshot", "capture image save") {
			imgui.Checkbox("Screenshot", &placeholder)
			match_count += 1
		}
		if fuzzy_match(filter, "Hot-Reload Shaders", "reload recompile glsl") {
			imgui.Checkbox("Hot-Reload Shaders", &placeholder)
			match_count += 1
		}

		imgui.EndDisabled()
		imgui.Spacing()
	}

	if match_count == 0 {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "No matching parameters")
	}
}

// Check if ANY param in a keyword group matches (used to show/hide section headers).
@(private)
section_has_matches :: proc(filter: cstring, section_keywords: string) -> bool {
	return fuzzy_match(filter, "", section_keywords)
}

// Keyword constants for section-level pre-filtering.
@(private)
CAMERA_KEYWORDS :: "camera speed acceleration friction sensitivity smoothing fov bobbing zoom projection mouse movement"

@(private)
SCENE_KEYWORDS :: "scene skybox blur exposure wireframe toggle environment background tone mapping hdr mesh polygon"

@(private)
RENDERING_KEYWORDS :: "rendering pbr debug mode albedo normal metallic roughness ao bloom dof depth field fxaa motion blur vignette grain aberration grading lut irradiance prefilter brdf specular anti-aliasing post effect glow focus"

@(private)
DEBUG_KEYWORDS :: "debug bloom dof exposure histogram fxaa stencil gpu timeline metrics perf profiling probes gi n-body simulation physics visualization"

@(private)
ENV_KEYWORDS :: "environment hdr env lod blur screenshot capture reload shaders glsl cycling skybox map"
