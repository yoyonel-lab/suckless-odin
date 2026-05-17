package scene

import gl "vendor:OpenGL"
import "core:os"

import log "../core/log"
import mt "../core/math_types"
import settings "../core/settings"
import cam "../camera"
import "../rendering"

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

	// Text overlay (F1)
	overlay:     rendering.Text_Overlay,

	// Cached uniform locations for PBR shader
	loc_view:       i32,
	loc_projection: i32,
	loc_cam_pos:    i32,
}

HDR_PATH      :: "../suckless-ogl/assets/textures/hdr/cedar_bridge_2_4k.hdr"
MATERIALS_PATH :: "assets/materials/pbr_materials.json"

scene_create :: proc(s: ^Scene, width, height: i32) -> bool {
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
	if !rendering.skybox_create(&s.skybox, s.env_texture.id, "shaders/background.vert", "shaders/background.frag") {
		log.log_error("suckless-odin.scene", "Failed to create skybox")
		return false
	}

	// PBR billboard shader
	s.pbr_program = load_shader("shaders/pbr_billboard.vert", "shaders/pbr_billboard.frag") or_return

	// Cache uniform locations
	s.loc_view       = gl.GetUniformLocation(s.pbr_program, "u_view")
	s.loc_projection = gl.GetUniformLocation(s.pbr_program, "u_projection")
	s.loc_cam_pos    = gl.GetUniformLocation(s.pbr_program, "u_cam_pos")

	// Text overlay
	if !rendering.overlay_create(&s.overlay) {
		log.log_warning("suckless-odin.scene", "Failed to create text overlay (non-fatal)")
	}

	log.log_info("suckless-odin.scene", "Scene created (%d spheres, PBR/IBL active)", s.spheres.count)
	return true
}

scene_render :: proc(s: ^Scene, width, height: i32) {
	aspect := f32(width) / f32(max(height, 1))
	fov_rad := mt.radians(s.camera.zoom)

	view := mt.look_at(
		s.camera.position,
		s.camera.position + s.camera.front,
		s.camera.up,
	)
	proj := mt.perspective(fov_rad, aspect, settings.NEAR_PLANE, settings.FAR_PLANE)

	// 1. Skybox (drawn first, depth <= 1.0)
	rendering.skybox_render(&s.skybox, view, proj)

	// 2. PBR spheres (instanced billboard)
	gl.UseProgram(s.pbr_program)

	gl.UniformMatrix4fv(s.loc_view, 1, false, &view[0][0])
	gl.UniformMatrix4fv(s.loc_projection, 1, false, &proj[0][0])
	gl.Uniform3fv(s.loc_cam_pos, 1, &s.camera.position[0])

	// Bind IBL textures (units 15, 16, 17)
	rendering.ibl_bind(&s.ibl)

	// Bind SSBO and draw all instances
	rendering.instanced_bind(&s.spheres)
	rendering.instanced_draw(&s.spheres, &s.billboard)

	gl.UseProgram(0)

	// 3. Text overlay (on top of everything)
	rendering.overlay_render(&s.overlay, width, height, s.camera.position, s.camera.yaw, s.camera.pitch)
}

scene_update :: proc(s: ^Scene, dt: f32) {
	rendering.overlay_update(&s.overlay, dt)
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

scene_destroy :: proc(s: ^Scene) {
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
	vert_src, vert_ok := read_shader_file(vert_path)
	if !vert_ok { return 0, false }

	frag_src, frag_ok := read_shader_file(frag_path)
	if !frag_ok { return 0, false }

	program, ok := gl.load_shaders_source(vert_src, frag_src)
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
read_shader_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.scene", "Failed to read shader: %s", path)
		return "", false
	}
	return string(data), true
}
