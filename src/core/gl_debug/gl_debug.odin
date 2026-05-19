package gl_debug

// GL Debug Groups & Object Labels for RenderDoc / GPU profiler integration.
// ISO port of suckless-ogl/src/gl_debug.c — push/pop debug groups appear as
// hierarchical markers in RenderDoc's event browser.
//
// Calls are always emitted (no compile-time guard). Cost is negligible:
// - Without a debug context, the GL driver short-circuits these calls.
// - With RenderDoc attached, they produce the hierarchical event browser.

import gl "vendor:OpenGL"

// Push a named debug group (visible in RenderDoc as a collapsible section).
push_group :: proc(name: cstring) {
	gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, name)
}

// Pop the current debug group.
pop_group :: proc() {
	gl.PopDebugGroup()
}

// Label a GL object (texture, buffer, program, VAO, etc.) for RenderDoc.
// identifier: GL_TEXTURE, GL_BUFFER, GL_PROGRAM, GL_VERTEX_ARRAY, etc.
object_label :: proc(identifier: u32, handle: u32, label: cstring) {
	gl.ObjectLabel(identifier, handle, -1, label)
}
