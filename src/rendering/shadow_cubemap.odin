package rendering

import gl "vendor:OpenGL"
import "core:math"

import mt "../core/math_types"
import log "../core/log"
import dbg "../core/gl_debug"
import gl_state "../core/gl_state"
import tracy "../core/tracy"
import shader "./shader"

@(private)
srcloc_shadow_cubemap := tracy.Source_Location_Data{
	name     = "Shadow_Cubemap_Render",
	function = "shadow_cubemap_render_spheres",
	file     = #file,
	line     = #line,
	color    = 0xEBCB8B,
}

CUBEMAP_FACES :: 6

Shadow_Cubemap_Face :: enum int {
	Positive_X = 0,
	Negative_X = 1,
	Positive_Y = 2,
	Negative_Y = 3,
	Positive_Z = 4,
	Negative_Z = 5,
}

// Point light state for shadow map and volumetric raymarching
Point_Light :: struct {
	position:               mt.Vec3,
	radius:                 f32,
	color:                  mt.Vec3,
	intensity:              f32,
	enabled:                bool,
	direct_shadows_enabled: bool,
	shadow_bias:            f32,
	shadow_normal_bias:     f32,
	shadow_slope_bias:      f32,
	shadow_darkening:       f32,
	shadow_debug_mask:      bool,
	show_bulb:              bool,
	bulb_radius:            f32,
	is_dirty:               bool,
	is_animated:            bool,
	orbit_speed:            f32,
	orbit_radius:           f32,
	orbit_center:           mt.Vec3,
	phase_g:                f32, // Henyey-Greenstein anisotropy [-0.90..+0.90]
}

// Computes current light position (with orbit animation if enabled)
point_light_get_position :: proc(light: ^Point_Light, total_time: f32) -> mt.Vec3 {
	if !light.is_animated || light.orbit_radius <= 0.001 {
		return light.position
	}
	angle := total_time * light.orbit_speed
	return light.orbit_center + mt.Vec3{
		math.cos(angle) * light.orbit_radius,
		0.0,
		math.sin(angle) * light.orbit_radius,
	}
}

SHADOW_MAP_RESOLUTIONS :: [4]i32{64, 128, 256, 512}
DEFAULT_SHADOW_RES_INDEX :: 2 // 256x256
DEFAULT_SHADOW_RESOLUTION :: 256

shadow_cubemap_res_for_index :: proc(index: i32) -> i32 {
	resolutions := [4]i32{64, 128, 256, 512}
	idx := clamp(index, 0, 3)
	return resolutions[idx]
}

// Manages a 6-face Cubemap Framebuffer for Omnidirectional Point Light Shadows (Modern OpenGL 4.4 Core)
Shadow_Cubemap :: struct {
	fbo:                  u32,
	depth_cubemap:        u32, // GL_TEXTURE_CUBE_MAP, GL_DEPTH_COMPONENT32F
	linear_depth_cubemap: u32, // GL_TEXTURE_CUBE_MAP, GL_R32F (radial normalized distance [0..1])
	resolution:           i32,
	near_plane:           f32,
	far_plane:            f32,
	proj_matrix:          mt.Mat4,
	view_matrices:        [CUBEMAP_FACES]mt.Mat4,
	cached_faces:         [CUBEMAP_FACES]bool,

	// Dirty Caching & Time-Slicing Strategy
	shadow_cache:         bool, // Enable dirty caching (skip rendering if light static)
	time_slice_mode:      i32,  // 0: All 6 faces, 1: 3 faces/frame, 2: 2 faces/frame, 3: 1 face/frame
	face_offset:          int,  // Rolling face offset for time slicing
	res_index:            i32,  // Index in SHADOW_MAP_RESOLUTIONS (default 2 = 256x256)

	// Shaders for analytical sphere shadow casting
	program:              u32,
	loc_view:             i32,
	loc_projection:       i32,
	loc_light_pos:        i32,
	loc_light_radius:     i32,

	// Emissive light bulb gizmo shader
	bulb_program:             u32,
	bulb_loc_view:            i32,
	bulb_loc_proj:            i32,
	bulb_loc_light_pos:       i32,
	bulb_loc_light_color:     i32,
	bulb_loc_light_intensity: i32,
	bulb_loc_radius:          i32,

	// 2D Preview Atlas for ImGui Inspection (3x2 unfolded cubemap grid)
	preview_fbo:          u32,
	preview_tex:          u32, // GL_RGBA8, 768 x 512
	preview_w:            i32,
	preview_h:            i32,
	preview_program:      u32,
	preview_triangle:     Fullscreen_Triangle,
	preview_dirty:        bool,
}

// Generates view matrix for a specific cubemap face in OpenGL convention
cubemap_face_view_matrix :: proc(face: Shadow_Cubemap_Face, eye: mt.Vec3) -> mt.Mat4 {
	switch face {
	case .Positive_X:
		return mt.look_at(eye, eye + mt.Vec3{ 1,  0,  0}, mt.Vec3{0, -1,  0})
	case .Negative_X:
		return mt.look_at(eye, eye + mt.Vec3{-1,  0,  0}, mt.Vec3{0, -1,  0})
	case .Positive_Y:
		return mt.look_at(eye, eye + mt.Vec3{ 0,  1,  0}, mt.Vec3{0,  0,  1})
	case .Negative_Y:
		return mt.look_at(eye, eye + mt.Vec3{ 0, -1,  0}, mt.Vec3{0,  0, -1})
	case .Positive_Z:
		return mt.look_at(eye, eye + mt.Vec3{ 0,  0,  1}, mt.Vec3{0, -1,  0})
	case .Negative_Z:
		return mt.look_at(eye, eye + mt.Vec3{ 0,  0, -1}, mt.Vec3{0, -1,  0})
	}
	return mt.MAT4_IDENTITY
}

@(private)
shadow_cubemap_create_fbo_textures :: proc(sc: ^Shadow_Cubemap, resolution: i32) -> bool {
	sc.resolution = resolution

	// 1. Create Depth Cubemap (GL_DEPTH_COMPONENT32F)
	gl.GenTextures(1, &sc.depth_cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, sc.depth_cubemap)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	for i in 0..<CUBEMAP_FACES {
		gl.TexImage2D(
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(i),
			0,
			gl.DEPTH_COMPONENT32F,
			resolution,
			resolution,
			0,
			gl.DEPTH_COMPONENT,
			gl.FLOAT,
			nil,
		)
	}

	// 2. Create Linear Depth Cubemap (GL_R32F for volumetric raymarching)
	gl.GenTextures(1, &sc.linear_depth_cubemap)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, sc.linear_depth_cubemap)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	for i in 0..<CUBEMAP_FACES {
		gl.TexImage2D(
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(i),
			0,
			gl.R32F,
			resolution,
			resolution,
			0,
			gl.RED,
			gl.FLOAT,
			nil,
		)
	}
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)

	// 3. Create FBO
	gl.GenFramebuffers(1, &sc.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, sc.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_CUBE_MAP_POSITIVE_X, sc.depth_cubemap, 0)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_CUBE_MAP_POSITIVE_X, sc.linear_depth_cubemap, 0)
	draw_bufs := [1]u32{gl.COLOR_ATTACHMENT0}
	gl.DrawBuffers(1, &draw_bufs[0])

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.shadow", "Shadow cubemap FBO incomplete: 0x%X", status)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return false
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	dbg.object_label(gl.FRAMEBUFFER, sc.fbo, "Shadow_Cubemap_FBO")
	dbg.object_label(gl.TEXTURE, sc.depth_cubemap, "Shadow_Depth_Cubemap")
	dbg.object_label(gl.TEXTURE, sc.linear_depth_cubemap, "Shadow_Linear_Cubemap")
	return true
}

@(private)
shadow_cubemap_destroy_fbo_textures :: proc(sc: ^Shadow_Cubemap) {
	if sc.fbo != 0 {
		gl.DeleteFramebuffers(1, &sc.fbo)
		sc.fbo = 0
	}
	if sc.depth_cubemap != 0 {
		gl.DeleteTextures(1, &sc.depth_cubemap)
		sc.depth_cubemap = 0
	}
	if sc.linear_depth_cubemap != 0 {
		gl.DeleteTextures(1, &sc.linear_depth_cubemap)
		sc.linear_depth_cubemap = 0
	}
}

// Resizes the shadow cubemap resolution dynamically (256, 512, 1024, 2048)
shadow_cubemap_resize :: proc(sc: ^Shadow_Cubemap, new_resolution: i32) -> bool {
	if sc.resolution == new_resolution && sc.fbo != 0 do return true
	shadow_cubemap_destroy_fbo_textures(sc)
	if !shadow_cubemap_create_fbo_textures(sc, new_resolution) {
		return false
	}
	for i in 0..<CUBEMAP_FACES {
		sc.cached_faces[i] = false
	}
	sc.preview_dirty = true
	log.log_info("suckless-odin.shadow", "Shadow cubemap resized to %dx%d", new_resolution, new_resolution)
	return true
}

// Creates shadow cubemap textures, FBO and shaders
shadow_cubemap_create :: proc(sc: ^Shadow_Cubemap, resolution: i32 = DEFAULT_SHADOW_RESOLUTION) -> (ok: bool) {
	sc.near_plane = 0.01
	sc.far_plane  = 25.0
	sc.shadow_cache = true
	sc.time_slice_mode = 0 // 0: All 6 faces (Realtime / Max Quality)
	sc.face_offset = 0
	sc.res_index = DEFAULT_SHADOW_RES_INDEX // 2 = 256x256

	// 1. Create FBO & textures
	if !shadow_cubemap_create_fbo_textures(sc, resolution) do return false

	// 2. Load Shadow Shader
	sc.program = shader.load_program("shaders/shadow_cube.vert", "shaders/shadow_cube.frag") or_return
	sc.loc_view         = gl.GetUniformLocation(sc.program, "u_view")
	sc.loc_projection   = gl.GetUniformLocation(sc.program, "u_projection")
	sc.loc_light_pos    = gl.GetUniformLocation(sc.program, "u_light_pos")
	sc.loc_light_radius = gl.GetUniformLocation(sc.program, "u_light_radius")

	// 3. Create ImGui Preview Atlas Resources (768 x 512)
	sc.preview_w = 768
	sc.preview_h = 512
	gl.GenTextures(1, &sc.preview_tex)
	gl.BindTexture(gl.TEXTURE_2D, sc.preview_tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, sc.preview_w, sc.preview_h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenFramebuffers(1, &sc.preview_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, sc.preview_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, sc.preview_tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	sc.preview_program = shader.load_program("shaders/postfx/postfx.vert", "shaders/debug_shadow_cube_preview.frag") or_return
	gl.UseProgram(sc.preview_program)
	gl.Uniform1i(gl.GetUniformLocation(sc.preview_program, "u_shadow_cubemap"), 0)
	gl.UseProgram(0)

	fullscreen_triangle_create(&sc.preview_triangle)

	dbg.object_label(gl.TEXTURE, sc.preview_tex, "Shadow_Preview_Atlas_Tex")

	sc.preview_dirty = true

	// 4. Load Light Bulb Emissive Gizmo Shader
	sc.bulb_program = shader.load_program("shaders/light_bulb.vert", "shaders/light_bulb.frag") or_return
	sc.bulb_loc_view = gl.GetUniformLocation(sc.bulb_program, "u_view")
	sc.bulb_loc_proj = gl.GetUniformLocation(sc.bulb_program, "u_projection")
	sc.bulb_loc_light_pos = gl.GetUniformLocation(sc.bulb_program, "u_light_pos")
	sc.bulb_loc_light_color = gl.GetUniformLocation(sc.bulb_program, "u_light_color")
	sc.bulb_loc_light_intensity = gl.GetUniformLocation(sc.bulb_program, "u_light_intensity")
	sc.bulb_loc_radius = gl.GetUniformLocation(sc.bulb_program, "u_bulb_radius")

	log.log_info("suckless-odin.shadow", "Shadow cubemap & Light bulb renderer created successfully (%dx%d)", resolution, resolution)
	return true
}

// Renders an emissive glowing sphere representing the point light source
shadow_cubemap_render_light_bulb :: proc(
	sc: ^Shadow_Cubemap,
	light: ^Point_Light,
	billboard: ^Billboard,
	view: ^mt.Mat4,
	proj: ^mt.Mat4,
	total_time: f32 = 0.0,
) {
	if !light.enabled || !light.show_bulb || sc.bulb_program == 0 do return

	dbg.push_group("Light_Bulb_Gizmo_Pass")

	light_pos := point_light_get_position(light, total_time)

	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.BLEND)

	gl.UseProgram(sc.bulb_program)
	gl.UniformMatrix4fv(sc.bulb_loc_view, 1, false, &view[0][0])
	gl.UniformMatrix4fv(sc.bulb_loc_proj, 1, false, &proj[0][0])
	gl.Uniform3f(sc.bulb_loc_light_pos, light_pos.x, light_pos.y, light_pos.z)
	gl.Uniform3f(sc.bulb_loc_light_color, light.color.x, light.color.y, light.color.z)
	gl.Uniform1f(sc.bulb_loc_light_intensity, light.intensity)
	gl.Uniform1f(sc.bulb_loc_radius, light.bulb_radius)

	gl.BindVertexArray(billboard.vao)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)

	gl.BindVertexArray(0)
	gl.UseProgram(0)
	gl_state.reset()
	dbg.pop_group()
}

// Updates cubemap projection and face view matrices for a given light
shadow_cubemap_update_matrices :: proc(sc: ^Shadow_Cubemap, light_pos: mt.Vec3, radius: f32, near_plane: f32 = 0.01) {
	sc.near_plane = near_plane
	sc.far_plane  = max(0.1, radius)

	// Perspective: 90 deg FOV, 1.0 aspect ratio
	sc.proj_matrix = mt.perspective(mt.radians(90.0), 1.0, sc.near_plane, sc.far_plane)

	for i in 0..<CUBEMAP_FACES {
		face := Shadow_Cubemap_Face(i)
		sc.view_matrices[i] = cubemap_face_view_matrix(face, light_pos)
	}
}

// Renders the scene's instanced spheres into the cubemap faces (with dirty caching and time-slicing)
shadow_cubemap_render_spheres :: proc(
	sc: ^Shadow_Cubemap,
	light: ^Point_Light,
	spheres: ^Instanced_Spheres,
	billboard: ^Billboard,
	total_time: f32 = 0.0,
	force_all_faces: bool = false,
) {
	if !light.enabled || sc.fbo == 0 do return

	update_shadow := true
	if sc.shadow_cache && !light.is_dirty && !light.is_animated && !force_all_faces {
		update_shadow = false
	}
	if !update_shadow do return

	zone := tracy.zone_begin(&srcloc_shadow_cubemap)
	defer tracy.zone_end(zone)

	light_pos := point_light_get_position(light, total_time)
	shadow_cubemap_update_matrices(sc, light_pos, light.radius, sc.near_plane)

	dbg.push_group("Shadow_Cubemap_Pass")

	// Save prior GL state
	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, sc.fbo)
	gl.Viewport(0, 0, sc.resolution, sc.resolution)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.BLEND)

	gl.UseProgram(sc.program)
	gl.Uniform3f(sc.loc_light_pos, light_pos.x, light_pos.y, light_pos.z)
	gl.Uniform1f(sc.loc_light_radius, light.radius)
	gl.UniformMatrix4fv(sc.loc_projection, 1, false, &sc.proj_matrix[0][0])

	instanced_bind(spheres)
	gl.BindVertexArray(billboard.vao)

	faces_to_render: [6]int
	num_faces := 6

	if light.is_dirty || !light.is_animated || sc.time_slice_mode == 0 || force_all_faces {
		num_faces = 6
		for i in 0..<6 {
			faces_to_render[i] = i
		}
		sc.face_offset = 0
	} else {
		switch sc.time_slice_mode {
		case 1: num_faces = 3 // 3 faces / frame (2-frame cycle)
		case 2: num_faces = 2 // 2 faces / frame (3-frame cycle)
		case 3: num_faces = 1 // 1 face / frame (6-frame cycle)
		case:   num_faces = 6
		}

		for i in 0..<num_faces {
			faces_to_render[i] = (sc.face_offset + i) % 6
		}
		sc.face_offset = (sc.face_offset + num_faces) % 6
	}

	for i in 0..<num_faces {
		f := faces_to_render[i]
		face_target := gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(f)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, face_target, sc.depth_cubemap, 0)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, face_target, sc.linear_depth_cubemap, 0)

		gl.ClearColor(1.0, 1.0, 1.0, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		gl.UniformMatrix4fv(sc.loc_view, 1, false, &sc.view_matrices[f][0][0])
		gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, spheres.count)

		sc.cached_faces[f] = true
	}

	gl.BindVertexArray(0)
	gl.UseProgram(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	sc.preview_dirty = true
	light.is_dirty = false
}

// Updates the 2D preview atlas texture (3x2 grid) for Dear ImGui display
shadow_cubemap_update_preview_atlas :: proc(sc: ^Shadow_Cubemap) {
	if sc.preview_fbo == 0 || sc.linear_depth_cubemap == 0 do return

	dbg.push_group("Shadow_Preview_Atlas_Pass")

	prev_fbo: i32
	prev_viewport: [4]i32
	gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, &prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, &prev_viewport[0])

	gl.BindFramebuffer(gl.FRAMEBUFFER, sc.preview_fbo)
	gl.Viewport(0, 0, sc.preview_w, sc.preview_h)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)

	gl.UseProgram(sc.preview_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, sc.linear_depth_cubemap)

	fullscreen_triangle_draw(&sc.preview_triangle)

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)
	gl.UseProgram(0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, u32(prev_fbo))
	gl.Viewport(prev_viewport[0], prev_viewport[1], prev_viewport[2], prev_viewport[3])
	gl_state.reset()
	dbg.pop_group()

	sc.preview_dirty = false
}

// Destroys all GPU resources
shadow_cubemap_destroy :: proc(sc: ^Shadow_Cubemap) {
	fullscreen_triangle_destroy(&sc.preview_triangle)

	if sc.preview_fbo != 0 {
		gl.DeleteFramebuffers(1, &sc.preview_fbo)
		sc.preview_fbo = 0
	}
	if sc.preview_tex != 0 {
		gl.DeleteTextures(1, &sc.preview_tex)
		sc.preview_tex = 0
	}
	if sc.preview_program != 0 {
		gl.DeleteProgram(sc.preview_program)
		sc.preview_program = 0
	}
	if sc.program != 0 {
		gl.DeleteProgram(sc.program)
		sc.program = 0
	}
	if sc.bulb_program != 0 {
		gl.DeleteProgram(sc.bulb_program)
		sc.bulb_program = 0
	}
	shadow_cubemap_destroy_fbo_textures(sc)
}
