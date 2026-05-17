package gui

import "vendor:glfw"

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

// GUI state — manages Dear ImGui lifecycle.
Gui :: struct {
	ctx:             ^imgui.Context,
	visible:         bool,
	docking_enabled: bool,
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

// Single window with tab bar for all engine controls.
update :: proc(g: ^Gui, state: Scene_State) {
	if g.ctx == nil { return }
	if !g.visible { return }

	imgui.SetNextWindowSize(imgui.Vec2{380, 500}, .FirstUseEver)

	if imgui.Begin("Engine Controls", &g.visible) {
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
