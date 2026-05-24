package scene

import gl "vendor:OpenGL"
import "core:math"
import "core:os"

import log "../core/log"
import mt "../core/math_types"
import settings "../core/settings"
import cam "../camera"
import "../rendering"
import postfx "../rendering/postfx"
import dbg "../core/gl_debug"

// Scene holds the camera, rendering resources, and all subsystems.
Scene :: struct {
	camera:    cam.Camera,

	// PBR billboard shader (instanced, SSBO-driven)
	pbr_program: u32,
	billboard:   rendering.Billboard,
	spheres:     rendering.Instanced_Spheres,
	mat_lib:     rendering.Material_Lib,

	// Skybox
	skybox:      rendering.Skybox,
	env_texture: rendering.Texture_HDR,

	// IBL resources (irradiance, prefilter, BRDF LUT)
	ibl:         rendering.IBL_Resources,

	// Post-processing pipeline
	postfx_pipeline: postfx.Pipeline,

	// Text overlay (F1)
	overlay:     rendering.Text_Overlay,

	// Cached uniform locations for PBR shader
	loc_view:           i32,
	loc_projection:     i32,
	loc_cam_pos:        i32,
	loc_prev_view_proj: i32,
	loc_screen_size:    i32,
	loc_edge_aa_mode:   i32,

	// Previous frame view-projection matrix (for motion blur velocity)
	prev_view_proj: mt.Mat4,
	prev_vp_initialized: bool,

	// Runtime toggles
	skybox_visible:    bool,
	wireframe_enabled: bool,
	exposure:          f32,
	sort_mode:         rendering.Sort_Mode,
	edge_aa_enabled:   bool,
	edge_aa_debug:     bool,
}

HDR_PATH      :: "../suckless-ogl/assets/textures/hdr/cedar_bridge_2_4k.hdr"
MATERIALS_PATH :: "assets/materials/pbr_materials.json"

scene_create :: proc(s: ^Scene, width, height: i32) -> (ok: bool) {
	defer if !ok { scene_destroy(s) }
	// Camera (ISO: same defaults as C — distance=20, yaw=-90, pitch=0)
	cam.init(
		&s.camera,
		settings.DEFAULT_CAMERA_DISTANCE,
		settings.DEFAULT_CAMERA_YAW,
		settings.DEFAULT_CAMERA_PITCH,
	)

	// Load material library (ISO: material_load_presets)
	s.mat_lib = rendering.material_load_presets(MATERIALS_PATH) or_return

	// Billboard geometry (shared quad)
	rendering.billboard_create(&s.billboard)

	// Multi-sphere instances from material library (ISO: scene_init_instancing)
	rendering.instanced_create(&s.spheres, &s.mat_lib)

	// Load HDR environment
	s.env_texture = rendering.texture_hdr_load(HDR_PATH) or_return

	// Compute IBL textures from HDR
	if !rendering.ibl_create(&s.ibl, s.env_texture.id) {
		log.log_error("suckless-odin.scene", "Failed to create IBL resources")
		return false
	}

	// Skybox
	if !rendering.skybox_create(&s.skybox, s.env_texture.id, s.ibl.prefilter_map, "shaders/background.vert", "shaders/background.frag") {
		log.log_error("suckless-odin.scene", "Failed to create skybox")
		return false
	}

	// PBR billboard shader
	s.pbr_program = load_shader("shaders/pbr_billboard.vert", "shaders/pbr_billboard.frag") or_return

	// Cache uniform locations
	s.loc_view       = gl.GetUniformLocation(s.pbr_program, "u_view")
	s.loc_projection = gl.GetUniformLocation(s.pbr_program, "u_projection")
	s.loc_cam_pos    = gl.GetUniformLocation(s.pbr_program, "u_cam_pos")
	s.loc_prev_view_proj = gl.GetUniformLocation(s.pbr_program, "u_previousViewProj")
	s.loc_screen_size = gl.GetUniformLocation(s.pbr_program, "u_screen_size")
	s.loc_edge_aa_mode = gl.GetUniformLocation(s.pbr_program, "u_edge_aa_mode")

	// Initialize previous view*proj to identity (avoids huge velocities on frame 1)
	s.prev_view_proj = mt.MAT4_IDENTITY

	// Runtime toggles (defaults)
	s.skybox_visible = true
	s.wireframe_enabled = false
	s.exposure = settings.DEFAULT_EXPOSURE
	s.edge_aa_enabled = true

	// Post-processing pipeline
	if !postfx.pipeline_create(&s.postfx_pipeline, width, height) {
		log.log_error("suckless-odin.scene", "Failed to create postfx pipeline")
		return false
	}

	// Text overlay
	if !rendering.overlay_create(&s.overlay) {
		log.log_warning("suckless-odin.scene", "Failed to create text overlay (non-fatal)")
	}

	log.log_info("suckless-odin.scene", "Scene created (%d spheres, PBR/IBL active)", s.spheres.count)
	return true
}

scene_render :: proc(s: ^Scene, width, height: i32) {
	dbg.push_group("Scene_Render")
	defer dbg.pop_group()

	postfx.pipeline_begin(&s.postfx_pipeline)

	aspect := f32(width) / f32(max(height, 1))
	fov_rad := mt.radians(s.camera.zoom)

	view := mt.look_at(
		s.camera.position,
		s.camera.position + s.camera.front,
		s.camera.up,
	)
	proj := mt.perspective(fov_rad, aspect, settings.NEAR_PLANE, settings.FAR_PLANE)

	// 1. Skybox (drawn first, depth <= 1.0)
	if s.skybox_visible {
		dbg.push_group("Skybox_Pass")
		rendering.skybox_render(&s.skybox, view, proj)
		dbg.pop_group()
	}

	// 2. PBR spheres (instanced billboard)
	dbg.push_group("Instanced_PBR_Spheres")

	if s.wireframe_enabled {
		gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)
	}

	gl.UseProgram(s.pbr_program)

	gl.UniformMatrix4fv(s.loc_view, 1, false, &view[0][0])
	gl.UniformMatrix4fv(s.loc_projection, 1, false, &proj[0][0])
	gl.Uniform3fv(s.loc_cam_pos, 1, &s.camera.position[0])
	gl.UniformMatrix4fv(s.loc_prev_view_proj, 1, false, &s.prev_view_proj[0][0])
	gl.Uniform2f(s.loc_screen_size, f32(width), f32(height))

	// Edge AA mode: 0=off, 1=on, 2=debug visualization
	edge_mode: i32 = 0
	if s.edge_aa_enabled { edge_mode = 1 }
	if s.edge_aa_debug   { edge_mode = 2 }
	gl.Uniform1i(s.loc_edge_aa_mode, edge_mode)

	// Enable per-buffer alpha blending on attachment 0 (color) for edge AA.
	// Attachment 1 (velocity) explicitly disabled — ISO legacy scene_render.c:393-407.
	// Requires back-to-front sort order (already active).
	if edge_mode > 0 {
		gl.Enablei(gl.BLEND, 0)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Disablei(gl.BLEND, 1)
	}

	// Bind IBL textures (units 15, 16, 17)
	rendering.ibl_bind(&s.ibl)

	// Bind SSBO and draw all instances
	rendering.instanced_bind(&s.spheres)
	rendering.instanced_draw(&s.spheres, &s.billboard)

	if edge_mode > 0 {
		gl.Disablei(gl.BLEND, 0)
	}

	gl.UseProgram(0)

	if s.wireframe_enabled {
		gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	}

	dbg.pop_group()

	// 3. End post-processing (composite to screen)
	// Inject camera data for fog depth reconstruction (invViewProj + world cam pos)
	inv_vp := mt.mat4_inverse(proj * view)
	cam_pos_v4 := [4]f32{s.camera.position.x, s.camera.position.y, s.camera.position.z, 1.0}
	inv_vp_flat := [16]f32{
		inv_vp[0][0], inv_vp[0][1], inv_vp[0][2], inv_vp[0][3],
		inv_vp[1][0], inv_vp[1][1], inv_vp[1][2], inv_vp[1][3],
		inv_vp[2][0], inv_vp[2][1], inv_vp[2][2], inv_vp[2][3],
		inv_vp[3][0], inv_vp[3][1], inv_vp[3][2], inv_vp[3][3],
	}
	postfx.pipeline_set_camera(&s.postfx_pipeline, cam_pos_v4, inv_vp_flat)
	postfx.pipeline_end(&s.postfx_pipeline)

	// Store current view*proj as previous for next frame's motion blur
	vp := proj * view
	if !s.prev_vp_initialized {
		// First frame: init to current VP to avoid velocity flash
		s.prev_view_proj = vp
		s.prev_vp_initialized = true
	}

	// Synthetic velocity injection: offset prev_view_proj to simulate camera movement.
	// Produces uniform velocity across the screen without touching the camera.
	mb := &s.postfx_pipeline.motion_blur
	if mb.inject_enabled && mb.inject_magnitude > 0.0 {
		angle_rad := mt.radians(mb.inject_direction)
		// NDC offset: velocity = (currNDC - prevNDC) * 0.5
		// To get velocity = magnitude at direction, prevNDC must be offset by -2*magnitude
		dx := -2.0 * mb.inject_magnitude * math.cos(angle_rad)
		dy := -2.0 * mb.inject_magnitude * math.sin(angle_rad)
		// Pre-multiply VP with NDC translation matrix
		ndc_offset := mt.MAT4_IDENTITY
		ndc_offset[3][0] = dx
		ndc_offset[3][1] = dy
		s.prev_view_proj = ndc_offset * vp
	} else {
		s.prev_view_proj = vp
	}

	// 4. Text overlay (rendered AFTER post-fx, directly to screen)
	dbg.push_group("Text_Overlay")
	rendering.overlay_render(&s.overlay, width, height, s.camera.position, s.camera.yaw, s.camera.pitch)
	dbg.pop_group()
}

scene_update :: proc(s: ^Scene, dt: f32) {
	postfx.pipeline_update(&s.postfx_pipeline, dt)
	rendering.overlay_update(&s.overlay, dt)

	// Update prev_centers for motion blur (before camera/positions change)
	rendering.instanced_update_prev_centers(&s.spheres)

	// Sort instances back-to-front for correct blending/MB (ISO legacy)
	rendering.instanced_sort(&s.spheres, s.camera.position, s.sort_mode)

	rendering.instanced_upload(&s.spheres)

	cam.build_keyboard_input(&s.camera)

	// Fixed-timestep physics for camera
	s.camera.physics_accumulator += dt
	for s.camera.physics_accumulator >= s.camera.fixed_timestep {
		cam.fixed_update(&s.camera)
		s.camera.physics_accumulator -= s.camera.fixed_timestep
	}

	// Smooth rotation
	t := 1.0 - s.camera.rotation_smoothing
	s.camera.yaw   = s.camera.yaw   + (s.camera.yaw_target   - s.camera.yaw)   * t
	s.camera.pitch = s.camera.pitch + (s.camera.pitch_target - s.camera.pitch) * t

	// Clamp pitch
	if s.camera.pitch > cam.DEFAULT_MAX_PITCH  { s.camera.pitch = cam.DEFAULT_MAX_PITCH }
	if s.camera.pitch < cam.DEFAULT_MIN_PITCH  { s.camera.pitch = cam.DEFAULT_MIN_PITCH }
	s.camera.pitch_target = clamp(s.camera.pitch_target, cam.DEFAULT_MIN_PITCH, cam.DEFAULT_MAX_PITCH)

	cam.update_vectors(&s.camera)
}

// Toggle text overlay mode (F1): Off → FPS+Position → FPS+Position+Env → Off
scene_toggle_overlay :: proc(s: ^Scene) {
	rendering.overlay_cycle(&s.overlay)
}

// Toggle skybox visibility (K key).
scene_toggle_skybox :: proc(s: ^Scene) {
	s.skybox_visible = !s.skybox_visible
}

// Toggle wireframe rendering mode (Z key).
scene_toggle_wireframe :: proc(s: ^Scene) {
	s.wireframe_enabled = !s.wireframe_enabled
}

// Adjust exposure by delta (KP+/KP- keys).
scene_adjust_exposure :: proc(s: ^Scene, delta: f32) {
	s.exposure = clamp(s.exposure + delta, 0.1, 10.0)
	s.postfx_pipeline.exposure.exposure = s.exposure
	s.postfx_pipeline.ubo_dirty = true
}

// Resize postfx pipeline (call from framebuffer callback).
scene_resize :: proc(s: ^Scene, width, height: i32) {
	postfx.pipeline_resize(&s.postfx_pipeline, width, height)
}

scene_destroy :: proc(s: ^Scene) {
	postfx.pipeline_destroy(&s.postfx_pipeline)
	rendering.overlay_destroy(&s.overlay)
	if s.pbr_program != 0 {
		gl.DeleteProgram(s.pbr_program)
		s.pbr_program = 0
	}
	rendering.instanced_destroy(&s.spheres)
	rendering.billboard_destroy(&s.billboard)
	rendering.skybox_destroy(&s.skybox)
	rendering.ibl_destroy(&s.ibl)
	rendering.texture_destroy(&s.env_texture)
	rendering.material_lib_destroy(&s.mat_lib)
	log.log_info("suckless-odin.scene", "Scene destroyed")
}

// Internal: load shader program with error handling
@(private)
load_shader :: proc(vert_path, frag_path: string) -> (u32, bool) {
	vert_data, vert_ok := read_shader_file(vert_path)
	if !vert_ok { return 0, false }
	defer delete(vert_data)

	frag_data, frag_ok := read_shader_file(frag_path)
	if !frag_ok { return 0, false }
	defer delete(frag_data)

	program, ok := gl.load_shaders_source(string(vert_data), string(frag_data))
	if !ok {
		log.log_error("suckless-odin.scene", "Shader compilation failed: %s + %s", vert_path, frag_path)
		return 0, false
	}

	// Query binary size (matches legacy "Binary size: N bytes")
	bin_size: i32
	gl.GetProgramiv(program, gl.PROGRAM_BINARY_LENGTH, &bin_size)
	log.log_info("Shader", "Linked shader program '%s + %s' (ID %d). Binary size: %d bytes",
		vert_path, frag_path, program, bin_size)

	return program, true
}

@(private)
read_shader_file :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.scene", "Failed to read shader: %s", path)
		return nil, false
	}
	return data, true
}
