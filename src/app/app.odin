package app

import "vendor:glfw"
import gl "vendor:OpenGL"
import "core:fmt"
import "base:runtime"

import log "../core/log"
import settings "../core/settings"
import scene "../scene"

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
	saved_x:         i32,
	saved_y:         i32,
	saved_width:     i32,
	saved_height:    i32,

	// Scene
	scene:           scene.Scene,
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

	application.window = window_create(
		application.width,
		application.height,
		application.title,
	)
	if application.window == nil {
		return false
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
	glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)

	// Initialize scene
	if !scene.scene_create(&application.scene, application.width, application.height) {
		log.log_error("suckless-odin.app", "Failed to create scene")
		return false
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
		process_keyboard(application)

		// Update scene (camera physics, etc.)
		scene.scene_update(&application.scene, application.delta_time)

		// Render
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		w, h := glfw.GetFramebufferSize(application.window)
		scene.scene_render(&application.scene, w, h)

		// Swap
		glfw.SwapBuffers(application.window)
	}

	log.log_info("suckless-odin.app", "Main loop exited")
}

// Cleans up all resources.
destroy :: proc(application: ^App) {
	if application == nil { return }

	scene.scene_destroy(&application.scene)
	window_destroy(application.window)
	free(application)

	log.log_info("suckless-odin.app", "Application destroyed")
}

// GLFW key callback — Escape closes the window, F toggles fullscreen.
@(private)
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if action != glfw.PRESS { return }

	context = runtime.default_context()

	switch key {
	case glfw.KEY_ESCAPE:
		glfw.SetWindowShouldClose(window, true)
	case glfw.KEY_F:
		app := cast(^App)glfw.GetWindowUserPointer(window)
		if app != nil { toggle_fullscreen(app) }
	case glfw.KEY_F1:
		app := cast(^App)glfw.GetWindowUserPointer(window)
		if app != nil { scene.scene_toggle_overlay(&app.scene) }
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

// Process held keys for continuous camera movement
@(private)
process_keyboard :: proc(application: ^App) {
	w := application.window
	s := &application.scene
	s.camera.move_forward  = glfw.GetKey(w, glfw.KEY_W) == glfw.PRESS
	s.camera.move_backward = glfw.GetKey(w, glfw.KEY_S) == glfw.PRESS
	s.camera.move_left     = glfw.GetKey(w, glfw.KEY_A) == glfw.PRESS
	s.camera.move_right_   = glfw.GetKey(w, glfw.KEY_D) == glfw.PRESS
	s.camera.move_up_      = glfw.GetKey(w, glfw.KEY_SPACE) == glfw.PRESS
	s.camera.move_down     = glfw.GetKey(w, glfw.KEY_LEFT_SHIFT) == glfw.PRESS
}

// GLFW mouse callback — camera look
@(private)
mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }

	cam := &app.scene.camera
	if cam.first_mouse {
		cam.last_mouse_x = xpos
		cam.last_mouse_y = ypos
		cam.first_mouse = false
		return
	}

	xoffset := f32(xpos - cam.last_mouse_x)
	yoffset := f32(cam.last_mouse_y - ypos)  // reversed: y goes bottom-to-top
	cam.last_mouse_x = xpos
	cam.last_mouse_y = ypos

	// Feed into camera's mouse processing (imported at file scope via scene)
	cam.yaw_target   += xoffset * cam.sensitivity
	cam.pitch_target += yoffset * cam.sensitivity
}

// GLFW framebuffer resize callback.
@(private)
framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0, 0, width, height)
}
