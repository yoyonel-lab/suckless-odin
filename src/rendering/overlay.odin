package rendering

import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"
import "core:fmt"
import "core:c"
import "core:os"

import log "../core/log"
import mt  "../core/math_types"

// Text overlay for FPS/position display (F1 toggle).
// ISO port of the text overlay from suckless-ogl/src/ui.c.
// Uses stb_truetype with FiraCode-Regular.ttf baked into a font atlas.

Overlay_Mode :: enum {
	Off = 0,
	FPS_Position,
	FPS_Position_Env,
}

FONT_ATLAS_SIZE   :: 512
FONT_FIRST_CHAR   :: 32
FONT_CHAR_COUNT   :: 96
FONT_SIZE         :: f32(32.0)
MAX_VERTICES      :: 4096  // max vertices (6 per glyph quad)
FLOATS_PER_VERTEX :: 8     // x, y, u, v, r, g, b, a

Text_Overlay :: struct {
	mode:    Overlay_Mode,
	program: u32,
	vao:     u32,
	vbo:     u32,
	texture: u32,  // font atlas texture

	// Font data
	chardata: [FONT_CHAR_COUNT]stbtt.bakedchar,

	// FPS tracking
	frame_count:  i32,
	fps_accum:    f32,
	fps_display:  f32,
}

overlay_create :: proc(overlay: ^Text_Overlay) -> bool {
	// Shader: position + texcoord + color, samples font atlas red channel
	vert_src :: `#version 440 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
uniform mat4 u_projection;
out vec2 v_uv;
out vec4 v_color;
void main() {
    gl_Position = u_projection * vec4(a_pos, 0.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
}
`
	frag_src :: `#version 440 core
in vec2 v_uv;
in vec4 v_color;
out vec4 FragColor;
uniform sampler2D u_atlas;
void main() {
    float alpha = texture(u_atlas, v_uv).r;
    FragColor = vec4(v_color.rgb, v_color.a * alpha);
}
`
	program, ok := gl.load_shaders_source(vert_src, frag_src)
	if !ok {
		log.log_error("suckless-odin.overlay", "Failed to compile overlay shader")
		return false
	}
	overlay.program = program

	// Load font file
	font_data, font_err := os.read_entire_file_from_path("assets/fonts/FiraCode-Regular.ttf", context.allocator)
	if font_err != nil {
		log.log_error("suckless-odin.overlay", "Failed to load font: assets/fonts/FiraCode-Regular.ttf")
		return false
	}
	defer delete(font_data)

	// Bake font atlas
	bitmap: [FONT_ATLAS_SIZE * FONT_ATLAS_SIZE]u8
	result := stbtt.BakeFontBitmap(
		raw_data(font_data), 0, FONT_SIZE,
		&bitmap[0], FONT_ATLAS_SIZE, FONT_ATLAS_SIZE,
		FONT_FIRST_CHAR, FONT_CHAR_COUNT,
		&overlay.chardata[0],
	)
	if result <= 0 {
		log.log_error("suckless-odin.overlay", "Failed to bake font bitmap (result=%d)", result)
		return false
	}

	// Upload font atlas as GL_RED texture
	gl.GenTextures(1, &overlay.texture)
	gl.BindTexture(gl.TEXTURE_2D, overlay.texture)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RED, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE,
	              0, gl.RED, gl.UNSIGNED_BYTE, &bitmap[0])
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// VAO/VBO for text quads (8 floats per vertex: x, y, u, v, r, g, b, a)
	gl.GenVertexArrays(1, &overlay.vao)
	gl.GenBuffers(1, &overlay.vbo)

	gl.BindVertexArray(overlay.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, overlay.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, MAX_VERTICES * FLOATS_PER_VERTEX * size_of(f32), nil, gl.DYNAMIC_DRAW)

	stride := i32(FLOATS_PER_VERTEX * size_of(f32))
	// Position (layout 0): vec2
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, 0)
	// UV (layout 1): vec2
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, 2 * size_of(f32))
	// Color (layout 2): vec4
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.FLOAT, false, stride, 4 * size_of(f32))

	gl.BindVertexArray(0)

	overlay.mode = .Off
	overlay.fps_display = 0.0
	log.log_info("suckless-odin.overlay", "Text overlay initialized (FiraCode %.0fpx, atlas %dx%d)", FONT_SIZE, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)
	return true
}

overlay_destroy :: proc(overlay: ^Text_Overlay) {
	if overlay.texture != 0 { gl.DeleteTextures(1, &overlay.texture); overlay.texture = 0 }
	if overlay.program != 0 { gl.DeleteProgram(overlay.program); overlay.program = 0 }
	if overlay.vao != 0 { gl.DeleteVertexArrays(1, &overlay.vao); overlay.vao = 0 }
	if overlay.vbo != 0 { gl.DeleteBuffers(1, &overlay.vbo); overlay.vbo = 0 }
}

overlay_cycle :: proc(overlay: ^Text_Overlay) {
	next := int(overlay.mode) + 1
	if next > int(Overlay_Mode.FPS_Position_Env) { next = 0 }
	overlay.mode = Overlay_Mode(next)
}

overlay_update :: proc(overlay: ^Text_Overlay, dt: f32) {
	overlay.fps_accum += dt
	overlay.frame_count += 1
	if overlay.fps_accum >= 0.5 {
		overlay.fps_display = f32(overlay.frame_count) / overlay.fps_accum
		overlay.frame_count = 0
		overlay.fps_accum = 0.0
	}
}

// Render overlay text on screen
overlay_render :: proc(overlay: ^Text_Overlay, width, height: i32, cam_pos: mt.Vec3, cam_yaw, cam_pitch: f32) {
	if overlay.mode == .Off { return }
	if overlay.program == 0 || overlay.texture == 0 { return }

	// Build text lines
	line0 := fmt.tprintf("FPS: %.1f", overlay.fps_display)
	line1 := fmt.tprintf("Pos: (%.2f, %.2f, %.2f)", cam_pos.x, cam_pos.y, cam_pos.z)
	line2 := fmt.tprintf("Yaw: %.1f  Pitch: %.1f", cam_yaw, cam_pitch)

	// Generate vertices from text
	verts: [MAX_VERTICES * FLOATS_PER_VERTEX]f32
	vert_count := 0

	color := [4]f32{1.0, 1.0, 1.0, 1.0}  // white like legacy

	vert_count = append_text_vertices(overlay, &verts, vert_count, line0, 10, 32, color)
	vert_count = append_text_vertices(overlay, &verts, vert_count, line1, 10, 64, color)
	vert_count = append_text_vertices(overlay, &verts, vert_count, line2, 10, 96, color)

	if overlay.mode == .FPS_Position_Env {
		line3 := fmt.tprintf("Env: cedar_bridge_2_4k.hdr")
		vert_count = append_text_vertices(overlay, &verts, vert_count, line3, 10, 128, color)
	}

	if vert_count == 0 { return }

	// Upload vertex data
	gl.BindBuffer(gl.ARRAY_BUFFER, overlay.vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, vert_count * FLOATS_PER_VERTEX * size_of(f32), &verts[0])

	// Setup orthographic projection
	ortho := ortho_matrix(0, f32(width), f32(height), 0, -1, 1)

	// Render with blending, no depth test
	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	gl.UseProgram(overlay.program)
	loc_proj := gl.GetUniformLocation(overlay.program, "u_projection")
	gl.UniformMatrix4fv(loc_proj, 1, false, &ortho[0][0])

	// Bind font atlas
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, overlay.texture)
	loc_atlas := gl.GetUniformLocation(overlay.program, "u_atlas")
	gl.Uniform1i(loc_atlas, 0)

	gl.BindVertexArray(overlay.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(vert_count))
	gl.BindVertexArray(0)

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
}

// Append text glyph quads to vertex buffer using stb_truetype baked data
@(private)
append_text_vertices :: proc(overlay: ^Text_Overlay, verts: ^[MAX_VERTICES * FLOATS_PER_VERTEX]f32, start_count: int, text: string, x, y: f32, color: [4]f32) -> int {
	xpos := x
	ypos := y
	count := start_count

	for ch in text {
		if ch < FONT_FIRST_CHAR || ch >= FONT_FIRST_CHAR + FONT_CHAR_COUNT {
			continue
		}
		if count + 6 > MAX_VERTICES { break }  // out of space

		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(
			&overlay.chardata[0],
			FONT_ATLAS_SIZE, FONT_ATLAS_SIZE,
			c.int(ch) - FONT_FIRST_CHAR,
			&xpos, &ypos,
			&q,
			true,  // opengl_fillrule
		)

		// Two triangles per glyph quad (6 vertices)
		// Triangle 1: top-left, bottom-right, bottom-left
		// Triangle 2: top-left, top-right, bottom-right
		emit_vert(verts, count, q.x0, q.y0, q.s0, q.t0, color); count += 1
		emit_vert(verts, count, q.x1, q.y1, q.s1, q.t1, color); count += 1
		emit_vert(verts, count, q.x0, q.y1, q.s0, q.t1, color); count += 1

		emit_vert(verts, count, q.x0, q.y0, q.s0, q.t0, color); count += 1
		emit_vert(verts, count, q.x1, q.y0, q.s1, q.t0, color); count += 1
		emit_vert(verts, count, q.x1, q.y1, q.s1, q.t1, color); count += 1
	}

	return count
}

@(private)
emit_vert :: proc(verts: ^[MAX_VERTICES * FLOATS_PER_VERTEX]f32, idx: int, x, y, u, v: f32, color: [4]f32) {
	base := idx * FLOATS_PER_VERTEX
	verts[base + 0] = x
	verts[base + 1] = y
	verts[base + 2] = u
	verts[base + 3] = v
	verts[base + 4] = color[0]
	verts[base + 5] = color[1]
	verts[base + 6] = color[2]
	verts[base + 7] = color[3]
}

// Simple orthographic projection matrix
@(private)
ortho_matrix :: proc(left, right, bottom, top, near, far: f32) -> mt.Mat4 {
	m := mt.MAT4_IDENTITY
	m[0][0] = 2.0 / (right - left)
	m[1][1] = 2.0 / (top - bottom)
	m[2][2] = -2.0 / (far - near)
	m[3][0] = -(right + left) / (right - left)
	m[3][1] = -(top + bottom) / (top - bottom)
	m[3][2] = -(far + near) / (far - near)
	return m
}
