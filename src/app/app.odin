package app

import "vendor:glfw"
import gl "vendor:OpenGL"
import "base:runtime"
import session "../core/session"

import log "../core/log"
import settings "../core/settings"
import cam "../camera"
import scene "../scene"
import gui "../gui"
import postfx "../rendering/postfx"
import rendering "../rendering"
import dbg "../core/gl_debug"

// Application state — top-level struct owning all subsystems.
// ISO port of App struct from suckless-ogl/include/app.h.
App :: struct {
	window:          glfw.WindowHandle,
	width:           i32,
	height:          i32,
	title:           cstring,

	// Timing
	last_frame_time: f64,
	delta_time:      f32,

	// State
	running:         bool,
	is_fullscreen:   bool,
	camera_enabled:  bool,  // C key toggles mouse-driven camera
	saved_x:         i32,
	saved_y:         i32,
	saved_width:     i32,
	saved_height:    i32,

	// Scene
	scene:           scene.Scene,

	// GUI (Dear ImGui)
	imgui:           gui.Gui,
}

// Creates the application (allocates + creates window).
create :: proc(width, height: i32, title: cstring) -> ^App {
	application := new(App)
	application.width  = width
	application.height = height
	application.title  = title
	application.running = false
	return application
}

// Initializes the application: window, OpenGL context, callbacks.
init :: proc(application: ^App) -> bool {
	if application == nil { return false }

	// Try to load previous session
	session_state := session.Session_State{}
	has_session := session.load_session(&session_state)
	
	if has_session && session_state.window_size[0] > 0 && session_state.window_size[1] > 0 {
		application.width = session_state.window_size[0]
		application.height = session_state.window_size[1]
	}

	application.window = window_create(
		application.width,
		application.height,
		application.title,
	)
	if application.window == nil {
		return false
	}
	
	if has_session {
		glfw.SetWindowPos(application.window, session_state.window_pos[0], session_state.window_pos[1])
		application.saved_x = session_state.window_pos[0]
		application.saved_y = session_state.window_pos[1]
		application.saved_width = session_state.window_size[0]
		application.saved_height = session_state.window_size[1]
	}

	// Register Escape key callback
	glfw.SetKeyCallback(application.window, key_callback)

	// Store app pointer for use in callbacks
	glfw.SetWindowUserPointer(application.window, application)

	// Basic OpenGL setup
	gl.Enable(gl.DEPTH_TEST)
	gl.ClearColor(0.1, 0.1, 0.1, 1.0)

	// Framebuffer resize callback
	glfw.SetFramebufferSizeCallback(application.window, framebuffer_size_callback)

	// Mouse input for camera
	glfw.SetCursorPosCallback(application.window, mouse_callback)
	glfw.SetScrollCallback(application.window, scroll_callback)
	glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	application.camera_enabled = true

	// Initialize scene
	if !scene.scene_create(&application.scene, application.width, application.height) {
		log.log_error("suckless-odin.app", "Failed to create scene")
		return false
	}

	// Initialize GUI (Dear ImGui)
	if !gui.init(&application.imgui, application.window) {
		log.log_error("suckless-odin.app", "Failed to initialize ImGui")
		return false
	}

	if has_session {
		restore_session_state(application, session_state)
	}

	application.last_frame_time = glfw.GetTime()
	application.running = true

	log.log_info("suckless-odin.app", "Application initialized (%dx%d)", application.width, application.height)
	return true
}

// Main loop — polls events, clears screen, swaps buffers.
// ISO port of app_run() from suckless-ogl/src/app.c.
run :: proc(application: ^App) {
	if application == nil { return }

	log.log_info("suckless-odin.app", "Entering main loop (Escape to quit)")

	for application.running && !glfw.WindowShouldClose(application.window) {
		// Timing
		current_time := glfw.GetTime()
		application.delta_time = f32(current_time - application.last_frame_time)
		application.last_frame_time = current_time

		// Input
		glfw.PollEvents()
		if !gui.wants_keyboard(&application.imgui) {
			process_keyboard(application)
		}

		// Update scene (camera physics, etc.)
		scene.scene_update(&application.scene, application.delta_time)

		// Render
		dbg.push_group("Render_Frame")

		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		w, h := glfw.GetFramebufferSize(application.window)
		scene.scene_render(&application.scene, w, h)

		// GUI (Dear ImGui) — render on top of scene
		dbg.push_group("GUI_ImGui")
		gui.new_frame(&application.imgui)
		gui.update(&application.imgui, gui.Scene_State{
			camera              = &application.scene.camera,
			skybox_visible      = &application.scene.skybox_visible,
			wireframe_enabled   = &application.scene.wireframe_enabled,
			exposure            = &application.scene.exposure,
			skybox_blur_lod     = &application.scene.skybox.blur_lod,
			sort_mode           = &application.scene.sort_mode,
			ibl_irradiance_map  = application.scene.ibl.irradiance_map,
			ibl_prefilter_map   = application.scene.ibl.prefilter_map,
			ibl_brdf_lut        = application.scene.ibl.brdf_lut,
			env_texture_id      = application.scene.env_texture.id,
			env_texture_width   = application.scene.env_texture.width,
			env_texture_height  = application.scene.env_texture.height,
			postfx              = &application.scene.postfx_pipeline,
			frame_time_ms       = application.scene.overlay.frame_time_display,
		})
		gui.render(&application.imgui)
		dbg.pop_group()

		dbg.pop_group()

		// Swap
		glfw.SwapBuffers(application.window)
	}

	log.log_info("suckless-odin.app", "Main loop exited")
}

// Cleans up all resources.
destroy :: proc(application: ^App) {
	if application == nil { return }

	// Save session state
	state := extract_session_state(application)
	session.save_session(&state)

	gui.destroy(&application.imgui)
	scene.scene_destroy(&application.scene)
	window_destroy(application.window)
	free(application)

	log.log_info("suckless-odin.app", "Application destroyed")
}

// Apply CLI postfx options (preset, enable/disable).
apply_postfx_options :: proc(application: ^App, enabled: bool, preset: Maybe(postfx.Preset_Id)) {
	application.scene.postfx_pipeline.enabled = enabled
	if id, ok := preset.?; ok {
		postfx.pipeline_apply_preset(&application.scene.postfx_pipeline, id)
	}
}

// GLFW key callback — handles press-only actions.
// Movement keys (WASD/Q/E) are handled via polling in process_keyboard().
@(private)
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if action != glfw.PRESS { return }

	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }

	// Ctrl+F focuses search when GUI is visible (must be before the ImGui guard)
	if key == glfw.KEY_F && mods == glfw.MOD_CONTROL && app.imgui.visible {
		app.imgui.focus_search = true
		return
	}

	// When ImGui has keyboard focus, only block printable character keys
	// (so F2, Escape, F-keys etc. still work for toggling the GUI)
	if gui.wants_keyboard(&app.imgui) && key >= glfw.KEY_SPACE && key <= glfw.KEY_GRAVE_ACCENT {
		return
	}

	switch key {
	case glfw.KEY_ESCAPE:
		glfw.SetWindowShouldClose(window, true)
	case glfw.KEY_F:
		toggle_fullscreen(app)
	case glfw.KEY_F1:
		scene.scene_toggle_overlay(&app.scene)
	case glfw.KEY_F2:
		gui.toggle(&app.imgui)
		// GUI open → release cursor for UI interaction; GUI closed → capture cursor for camera
		if app.imgui.visible {
			app.camera_enabled = false
			glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
		} else {
			app.camera_enabled = true
			glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
			app.scene.camera.first_mouse = true
		}
	case glfw.KEY_C:
		toggle_camera(app)
	case glfw.KEY_SPACE:
		camera_reset(app)
	}
}

// Toggle between windowed and fullscreen mode.
// ISO port of app_toggle_fullscreen() from suckless-ogl/src/app_input.c.
@(private)
toggle_fullscreen :: proc(application: ^App) {
	gl.Finish()

	if !application.is_fullscreen {
		monitor := glfw.GetPrimaryMonitor()
		mode := glfw.GetVideoMode(monitor)
		application.saved_x, application.saved_y = glfw.GetWindowPos(application.window)
		application.saved_width, application.saved_height = glfw.GetWindowSize(application.window)
		glfw.SetWindowMonitor(application.window, monitor, 0, 0,
			mode.width, mode.height, mode.refresh_rate)
	} else {
		glfw.SetWindowMonitor(application.window, nil, application.saved_x, application.saved_y,
			application.saved_width, application.saved_height, 0)
	}

	application.is_fullscreen = !application.is_fullscreen
	glfw.FocusWindow(application.window)
}

// Process held keys for continuous camera movement.
// ISO: W/S/A/D = move, Q = up, E = down (matches legacy camera_input.c)
@(private)
process_keyboard :: proc(application: ^App) {
	w := application.window
	s := &application.scene
	s.camera.move_forward  = glfw.GetKey(w, glfw.KEY_W) == glfw.PRESS
	s.camera.move_backward = glfw.GetKey(w, glfw.KEY_S) == glfw.PRESS
	s.camera.move_left     = glfw.GetKey(w, glfw.KEY_A) == glfw.PRESS
	s.camera.move_right_   = glfw.GetKey(w, glfw.KEY_D) == glfw.PRESS
	s.camera.move_up_      = glfw.GetKey(w, glfw.KEY_Q) == glfw.PRESS
	s.camera.move_down     = glfw.GetKey(w, glfw.KEY_E) == glfw.PRESS
}

// Toggle mouse-driven camera orientation (C key).
// ISO port of handle_camera_toggle() from suckless-ogl/src/app_input.c.
@(private)
toggle_camera :: proc(application: ^App) {
	application.camera_enabled = !application.camera_enabled
	if application.camera_enabled {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		application.scene.camera.first_mouse = true
		// Camera mode → hide GUI to prevent invisible interactions
		application.imgui.visible = false
	} else {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
}

// Reset camera to default position and orientation (Space key).
// ISO port of GLFW_KEY_SPACE handler from suckless-ogl/src/app_input.c.
@(private)
camera_reset :: proc(application: ^App) {
	cam.init(&application.scene.camera,
		settings.DEFAULT_CAMERA_DISTANCE,
		settings.DEFAULT_CAMERA_YAW,
		settings.DEFAULT_CAMERA_PITCH)
}

// GLFW mouse callback — camera look (only when camera_enabled).
// ISO port of camera_process_mouse with smoothing.
@(private)
mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }
	if !app.camera_enabled { return }
	if gui.wants_mouse(&app.imgui) { return }

	c := &app.scene.camera
	if c.first_mouse {
		c.last_mouse_x = xpos
		c.last_mouse_y = ypos
		c.first_mouse = false
		return
	}

	xoffset := f32(xpos - c.last_mouse_x)
	yoffset := f32(c.last_mouse_y - ypos)  // reversed: y goes bottom-to-top
	c.last_mouse_x = xpos
	c.last_mouse_y = ypos

	cam.process_mouse(c, xoffset, yoffset)
}

// GLFW scroll callback — forward velocity impulse along camera front.
// ISO port of camera_process_scroll from suckless-ogl/src/camera.c.
@(private)
scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }
	if !app.camera_enabled { return }
	if gui.wants_mouse(&app.imgui) { return }

	cam.process_scroll(&app.scene.camera, f32(yoffset))
}

// GLFW framebuffer resize callback.
@(private)
framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()
	gl.Viewport(0, 0, width, height)
	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app != nil {
		app.width = width
		app.height = height
		scene.scene_resize(&app.scene, width, height)
	}
}

// Extract current app state into a Session_State struct
extract_session_state :: proc(application: ^App) -> session.Session_State {
	s := &application.scene
	p := &s.postfx_pipeline
	
	pfx_settings := postfx.Settings_File{
		name          = "session_autosave",
		effects       = transmute(u32)p.active_effects,
		vignette      = p.vignette,
		grain         = p.grain,
		exposure      = p.exposure,
		chrom_abbr    = p.chrom_abbr,
		white_balance = p.white_balance,
		color_grading = p.color_grading,
		tonemapper    = p.tonemapper,
		bloom         = p.bloom,
		fxaa          = p.fxaa,
		dof           = p.dof,
		banding       = p.banding,
		fog           = p.fog,
		motion_blur   = p.motion_blur,
		lut3d         = p.lut3d,
	}

	// Update window saved position if not fullscreen
	if !application.is_fullscreen {
		application.saved_x, application.saved_y = glfw.GetWindowPos(application.window)
		application.saved_width, application.saved_height = glfw.GetWindowSize(application.window)
	}

	return session.Session_State{
		window_pos        = {application.saved_x, application.saved_y},
		window_size       = {application.saved_width, application.saved_height},
		camera_pos        = s.camera.position,
		camera_yaw        = s.camera.yaw,
		camera_pitch      = s.camera.pitch,
		camera_zoom       = s.camera.zoom,
		exposure          = s.exposure,
		wireframe_enabled = s.wireframe_enabled,
		skybox_visible    = s.skybox_visible,
		postfx_active     = p.enabled,
		postfx_settings   = pfx_settings,
		gui_visible       = application.imgui.visible,
		ibl_debug_open    = application.imgui.ibl_debug_open,
		is_fullscreen     = application.is_fullscreen,
		overlay_mode      = i32(s.overlay.mode),
		camera_enabled    = application.camera_enabled,
	}
}

// Restore app state from a Session_State struct
restore_session_state :: proc(application: ^App, state: session.Session_State) {
	s := &application.scene
	
	s.camera.position = state.camera_pos
	s.camera.yaw      = state.camera_yaw
	s.camera.pitch    = state.camera_pitch
	s.camera.zoom     = state.camera_zoom
	cam.update_vectors(&s.camera)
	
	s.exposure          = state.exposure
	s.wireframe_enabled = state.wireframe_enabled
	s.skybox_visible    = state.skybox_visible
	
	p := &s.postfx_pipeline
	p.enabled = state.postfx_active
	
	pfx := state.postfx_settings
	p.active_effects = transmute(postfx.Effect_Flags)pfx.effects
	p.vignette       = pfx.vignette
	p.grain          = pfx.grain
	p.exposure       = pfx.exposure
	p.chrom_abbr     = pfx.chrom_abbr
	p.white_balance  = pfx.white_balance
	p.color_grading  = pfx.color_grading
	p.tonemapper     = pfx.tonemapper
	p.bloom          = pfx.bloom
	p.fxaa           = pfx.fxaa
	p.dof            = pfx.dof
	p.banding        = pfx.banding
	p.fog            = pfx.fog
	p.motion_blur    = pfx.motion_blur
	p.lut3d          = pfx.lut3d
	p.ubo_dirty      = true
	
	application.imgui.visible = state.gui_visible
	application.imgui.ibl_debug_open = state.ibl_debug_open
	
	s.overlay.mode = rendering.Overlay_Mode(state.overlay_mode)
	
	application.camera_enabled = state.camera_enabled
	if state.gui_visible {
		application.camera_enabled = false
	}
	
	if application.camera_enabled {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	} else {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
	
	if state.is_fullscreen {
		monitor := glfw.GetPrimaryMonitor()
		if monitor != nil {
			mode := glfw.GetVideoMode(monitor)
			glfw.SetWindowMonitor(application.window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
			application.is_fullscreen = true
		}
	}
}
