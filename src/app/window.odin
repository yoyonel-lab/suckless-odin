package app

import "vendor:glfw"
import gl "vendor:OpenGL"

import log "../core/log"

// OpenGL version — ISO port targets GL 4.4 Core (same as suckless-ogl)
GL_MAJOR :: 4
GL_MINOR :: 4

// Creates a GLFW window with an OpenGL 4.4 core profile context.
// ISO port of window_create() from suckless-ogl/src/window.c.
window_create :: proc(width, height: i32, title: cstring, samples: i32 = 1, vsync: bool = false) -> glfw.WindowHandle {
	if !glfw.Init() {
		log.log_error("suckless-odin.window", "Failed to initialize GLFW")
		return nil
	}

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	when ODIN_DEBUG {
		glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
	}
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
	}
	if samples > 1 {
		glfw.WindowHint(glfw.SAMPLES, samples)
	}
	glfw.WindowHint(glfw.AUTO_ICONIFY, 0)
	glfw.WindowHint(glfw.DOUBLEBUFFER, 1)
	glfw.WindowHint(glfw.DEPTH_BITS, 24)

	window := glfw.CreateWindow(width, height, title, nil, nil)
	if window == nil {
		log.log_error("suckless-odin.window", "Failed to create GLFW window")
		glfw.Terminate()
		return nil
	}

	glfw.MakeContextCurrent(window)

	// VSync: 1 = on (driver sleeps in SwapBuffers), 0 = off (uncapped FPS)
	glfw.SwapInterval(1 if vsync else 0)

	// Load OpenGL function pointers (bridge GLFW getter → vendor setter)
	gl.load_up_to(GL_MAJOR, GL_MINOR, gl_set_proc_address)

	// Log context info
	major := glfw.GetWindowAttrib(window, glfw.CONTEXT_VERSION_MAJOR)
	minor := glfw.GetWindowAttrib(window, glfw.CONTEXT_VERSION_MINOR)
	log.log_info("suckless-odin.window", "OpenGL Context: %d.%d", major, minor)

	renderer := gl.GetString(gl.RENDERER)
	version  := gl.GetString(gl.VERSION)
	if renderer != nil {
		log.log_info("suckless-odin.window", "Renderer: %s", renderer)
	}
	if version != nil {
		log.log_info("suckless-odin.window", "GL Version: %s", version)
	}

	return window
}

// Destroys the GLFW window and terminates GLFW.
// ISO port of window_destroy() from suckless-ogl/src/window.c.
window_destroy :: proc(window: glfw.WindowHandle) {
	if window != nil {
		glfw.DestroyWindow(window)
	}
	glfw.Terminate()
}

// Bridge: vendor:OpenGL expects a setter proc(rawptr, cstring),
// but GLFW provides a getter proc(cstring) -> rawptr.
@(private)
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
}

// Validates whether (x, y) intersects with at least one active monitor's visible viewport.
// If offscreen or invalid, returns centered coordinates on the primary monitor.
sanitize_window_position :: proc(x, y, width, height: i32) -> (safe_x, safe_y: i32) {
	monitors := glfw.GetMonitors()
	for mon in monitors {
		mx, my := glfw.GetMonitorPos(mon)
		mode := glfw.GetVideoMode(mon)
		if mode != nil {
			// Check if the top-left portion of the window intersects this monitor
			if x >= mx - (width - 100) && x < mx + mode.width - 100 &&
			   y >= my && y < my + mode.height - 50 {
				return x, y
			}
		}
	}

	// Fallback: Center on primary monitor
	primary := glfw.GetPrimaryMonitor()
	if primary != nil {
		mx, my := glfw.GetMonitorPos(primary)
		mode := glfw.GetVideoMode(primary)
		if mode != nil {
			cx := mx + max(i32(0), (mode.width - width) / 2)
			cy := my + max(i32(0), (mode.height - height) / 2)
			return cx, cy
		}
	}

	return 100, 100
}
