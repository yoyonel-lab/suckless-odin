package rendering

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import dbg "../core/gl_debug"
import log "../core/log"
import mt "../core/math_types"

DEFAULT_AO_MAP_WIDTH  :: 256
DEFAULT_AO_MAP_HEIGHT :: 128
DEFAULT_AO_SAMPLES    :: 256

// Ground Truth AO Baker (Offline CPU Multi-Threaded & GPU Compute + PNG Exporter)
AO_Baker :: struct {
	width:                 i32,
	height:                i32,
	target_sphere:         i32,
	range_start:           i32,
	range_end:             i32,
	bake_cpu_enabled:      bool,
	bake_gpu_enabled:      bool,
	num_samples:           i32,
	is_baked:              bool,
	spheres_baked_count:   i32,

	// CPU Data & Texture
	cpu_pixels:            [dynamic]u8, // RGBA8
	cpu_texture_id:        u32,
	cpu_time_ms:           f32,
	cpu_mrays_per_sec:     f32,
	cpu_threads_used:      i32,
	cpu_png_path:          [128]u8,

	// GPU Data & Texture
	gpu_pixels:                [dynamic]u8, // RGBA8
	gpu_texture_id:            u32,
	gpu_compute_program:       u32,
	gpu_array_compute_program: u32,
	gpu_time_ms:               f32,
	gpu_mrays_per_sec:         f32,
	gpu_png_path:              [128]u8,

	// Uniform locations (Single 2D Bake)
	loc_target_sphere_idx:     i32,
	loc_total_spheres:         i32,
	loc_num_samples:           i32,
	loc_width:                 i32,
	loc_height:                i32,

	// Uniform locations (Direct In-VRAM Array Batch Bake)
	loc_arr_start_sphere_idx:  i32,
	loc_arr_total_spheres:     i32,
	loc_arr_num_samples:       i32,
	loc_arr_width:             i32,
	loc_arr_height:            i32,

	// 2D Texture Array (100 Slices of 256x128 R8 for Billboard PBR Sampling)
	ao_array_texture_id:       u32,
	loaded_maps_count:         i32,

	// Comparison Metrics
	max_delta:             f32,
	mae:                   f32,
	rmse:                  f32,
	psnr_db:               f32,
	exact_match_pct:       f32,
	le_1lsb_pct:           f32,
	is_iso_match:          bool,
}

// Low-discrepancy radical inverse for 2D Hammersley sequence
@(private)
radical_inverse_vdc :: #force_inline proc(bits: u32) -> f32 {
	b := (bits << 16) | (bits >> 16)
	b = ((b & 0x55555555) << 1) | ((b & 0xAAAAAAAA) >> 1)
	b = ((b & 0x33333333) << 2) | ((b & 0xCCCCCCCC) >> 2)
	b = ((b & 0x0F0F0F0F) << 4) | ((b & 0xF0F0F0F0) >> 4)
	b = ((b & 0x00FF00FF) << 8) | ((b & 0xFF00FF00) >> 8)
	return f32(b) * 2.3283064365386963e-10
}

// Fast Ray-Sphere Intersection test
@(private)
ray_sphere_intersect :: #force_inline proc(ro, rd, center: mt.Vec3, radius: f32 = 1.0) -> bool {
	oc := ro - center
	b := mt.vec3_dot(oc, rd)
	if b >= 0.0 do return false // Sphere center is behind the ray origin facing away
	c := mt.vec3_dot(oc, oc) - radius * radius
	disc := b * b - c
	if disc < 0.0 do return false
	sqrt_disc := math.sqrt(disc)
	t := -b - sqrt_disc
	if t > 0.001 do return true
	t = -b + sqrt_disc
	return t > 0.001
}

@(private)
AO_Worker_Task :: struct {
	baker:         ^AO_Baker,
	target_center: mt.Vec3,
	other_centers: []mt.Vec3,
	y_start:       i32,
	y_end:         i32,
	num_samples:   i32,
}

@(private)
ao_worker_proc :: proc(t: ^thread.Thread) {
	task := (^AO_Worker_Task)(t.data)
	baker := task.baker
	W := baker.width
	H := baker.height
	samples := task.num_samples
	target_pos := task.target_center
	others := task.other_centers

	active_occluders: [100]mt.Vec3

	for y in task.y_start..<task.y_end {
		v := (f32(y) + 0.5) / f32(H)
		theta := (1.0 - v) * math.PI // GL UV v=1 (top) -> theta=0 -> +Y (Zenith/Sky)
		sin_theta := math.sin(theta)
		cos_theta := math.cos(theta)

		for x in 0..<W {
			u := (f32(x) + 0.5) / f32(W)
			phi := u * 2.0 * math.PI - math.PI // -PI to +PI

			// Normal on sphere surface
			N := mt.Vec3{
				sin_theta * math.cos(phi),
				cos_theta,
				sin_theta * math.sin(phi),
			}
			P := target_pos + N * 1.0 // point on surface
			ro := P + N * 0.002       // offset self

			// Compute tangent basis (T, B) once per texel
			up := mt.Vec3{0, 0, 1} if math.abs(N.z) < 0.999 else mt.Vec3{1, 0, 0}
			T := mt.vec3_normalize(mt.vec3_cross(up, N))
			B := mt.vec3_cross(N, T)

			// Cull occluders strictly behind the surface tangent plane
			active_count := 0
			for oc_center in others {
				if mt.vec3_dot(N, oc_center - P) > -0.99 {
					active_occluders[active_count] = oc_center
					active_count += 1
				}
			}
			active_others := active_occluders[:active_count]

			visible_count: f32 = 0.0

			for k in 0..<samples {
				u1 := (f32(k) + 0.5) / f32(samples)
				u2 := radical_inverse_vdc(u32(k))
				phi_sample := 2.0 * math.PI * u1
				sin_theta_sample := math.sqrt(u2)
				cos_theta_sample := math.sqrt(1.0 - u2)

				local_x := math.cos(phi_sample) * sin_theta_sample
				local_y := math.sin(phi_sample) * sin_theta_sample
				local_z := cos_theta_sample

				rd := mt.vec3_normalize(T * local_x + B * local_y + N * local_z)

				hit := false
				for oc_center in active_others {
					if ray_sphere_intersect(ro, rd, oc_center, 1.0) {
						hit = true
						break
					}
				}

				if !hit {
					visible_count += 1.0
				}
			}

			ao_val := visible_count / f32(samples)
			u8_val := u8(clamp(ao_val * 255.0 + 0.5, 0.0, 255.0))
			pixel_idx := (int(y) * int(W) + int(x)) * 4
			baker.cpu_pixels[pixel_idx + 0] = u8_val
			baker.cpu_pixels[pixel_idx + 1] = u8_val
			baker.cpu_pixels[pixel_idx + 2] = u8_val
			baker.cpu_pixels[pixel_idx + 3] = 255
		}
	}
}

@(private)
load_ao_compute_shader :: proc(filepath: string) -> (program: u32, ok: bool) {
	data, err := os.read_entire_file_from_path(filepath, context.temp_allocator)
	if err != nil {
		log.log_error("suckless-odin.ao_baker", "Failed to read AO compute shader: %s", filepath)
		return 0, false
	}

	c_source := strings.clone_to_cstring(string(data), context.temp_allocator)
	shader := gl.CreateShader(gl.COMPUTE_SHADER)
	gl.ShaderSource(shader, 1, &c_source, nil)
	gl.CompileShader(shader)

	status: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		log_buf: [1024]u8
		length: i32
		gl.GetShaderInfoLog(shader, 1024, &length, &log_buf[0])
		log.log_error("suckless-odin.ao_baker", "AO Compute shader compile error: %s", string(log_buf[:length]))
		gl.DeleteShader(shader)
		return 0, false
	}

	prog := gl.CreateProgram()
	gl.AttachShader(prog, shader)
	gl.LinkProgram(prog)
	gl.DeleteShader(shader)

	gl.GetProgramiv(prog, gl.LINK_STATUS, &status)
	if status == 0 {
		log_buf: [1024]u8
		length: i32
		gl.GetProgramInfoLog(prog, 1024, &length, &log_buf[0])
		log.log_error("suckless-odin.ao_baker", "AO Compute program link error: %s", string(log_buf[:length]))
		gl.DeleteProgram(prog)
		return 0, false
	}

	dbg.object_label(gl.PROGRAM, prog, "AO_Compute_Program")
	return prog, true
}

// Initialize AO Baker resources (CPU & GPU)
ao_baker_init :: proc(baker: ^AO_Baker, width: i32 = DEFAULT_AO_MAP_WIDTH, height: i32 = DEFAULT_AO_MAP_HEIGHT) -> bool {
	baker.width = width
	baker.height = height
	baker.num_samples = DEFAULT_AO_SAMPLES
	baker.target_sphere = 45 // Center sphere of 10x10 grid
	baker.range_start = 45
	baker.range_end = 45
	baker.bake_cpu_enabled = true
	baker.bake_gpu_enabled = true
	baker.spheres_baked_count = 0
	baker.is_baked = false
	baker.cpu_threads_used = 12

	pixel_size := int(width) * int(height) * 4
	baker.cpu_pixels = make([dynamic]u8, pixel_size)
	baker.gpu_pixels = make([dynamic]u8, pixel_size)
	for i in 0..<pixel_size {
		baker.cpu_pixels[i] = 255
		baker.gpu_pixels[i] = 255
	}

	// 1. CPU Preview Texture
	gl.GenTextures(1, &baker.cpu_texture_id)
	gl.BindTexture(gl.TEXTURE_2D, baker.cpu_texture_id)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(baker.cpu_pixels))
	dbg.object_label(gl.TEXTURE, baker.cpu_texture_id, "AO_CPU_Texture")
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// 2. GPU Texture (GL_R8 format for compute write & preview)
	gl.GenTextures(1, &baker.gpu_texture_id)
	gl.BindTexture(gl.TEXTURE_2D, baker.gpu_texture_id)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	swizzle_mask := [4]i32{gl.RED, gl.RED, gl.RED, gl.ONE}
	gl.TexParameteriv(gl.TEXTURE_2D, gl.TEXTURE_SWIZZLE_RGBA, raw_data(swizzle_mask[:]))
	init_r8 := make([]u8, int(width) * int(height), context.temp_allocator)
	for i in 0..<len(init_r8) { init_r8[i] = 255 }
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(init_r8))
	dbg.object_label(gl.TEXTURE, baker.gpu_texture_id, "AO_GPU_Texture")
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// 3. Load Compute Shaders (Single 2D Diagnostic + Layered In-VRAM Array)
	program, ok := load_ao_compute_shader("shaders/compute/ao_baker.glsl")
	if !ok {
		log.log_warning("suckless-odin.ao_baker", "Failed to compile AO 2D compute shader (diagnostic GPU bake disabled)")
	}
	baker.gpu_compute_program = program

	if program != 0 {
		baker.loc_target_sphere_idx = gl.GetUniformLocation(program, "u_target_sphere_idx")
		baker.loc_total_spheres     = gl.GetUniformLocation(program, "u_total_spheres")
		baker.loc_num_samples       = gl.GetUniformLocation(program, "u_num_samples")
		baker.loc_width             = gl.GetUniformLocation(program, "u_width")
		baker.loc_height            = gl.GetUniformLocation(program, "u_height")
	}

	arr_program, arr_ok := load_ao_compute_shader("shaders/compute/ao_baker_array.glsl")
	if !arr_ok {
		log.log_warning("suckless-odin.ao_baker", "Failed to compile AO Array compute shader (direct In-VRAM GPU bake disabled)")
	}
	baker.gpu_array_compute_program = arr_program

	if arr_program != 0 {
		baker.loc_arr_start_sphere_idx = gl.GetUniformLocation(arr_program, "u_start_sphere_idx")
		baker.loc_arr_total_spheres     = gl.GetUniformLocation(arr_program, "u_total_spheres")
		baker.loc_arr_num_samples       = gl.GetUniformLocation(arr_program, "u_num_samples")
		baker.loc_arr_width             = gl.GetUniformLocation(arr_program, "u_width")
		baker.loc_arr_height            = gl.GetUniformLocation(arr_program, "u_height")
	}

	// 4. Initialize 2D Texture Array and load all 100 sphere maps from disk
	ao_baker_load_all_maps_from_disk(baker, "build")

	log.log_info("suckless-odin.ao_baker", "AO Baker initialized (%dx%d, cpu_tex=%d, gpu_tex=%d, array_tex=%d, compute_prog=%d, array_prog=%d)",
		width, height, baker.cpu_texture_id, baker.gpu_texture_id, baker.ao_array_texture_id, baker.gpu_compute_program, baker.gpu_array_compute_program)
	return true
}

// Upload single R8 layer to the 2D texture array
ao_baker_upload_layer_r8 :: proc(baker: ^AO_Baker, layer: i32, data_r8: []u8) {
	if baker.ao_array_texture_id == 0 || len(data_r8) < int(baker.width * baker.height) do return
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, baker.ao_array_texture_id)
	gl.TexSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, layer, baker.width, baker.height, 1, gl.RED, gl.UNSIGNED_BYTE, raw_data(data_r8))
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0)
}

// Load all 100 sphere AO maps from disk (build/ folder or screenshots/) into the 2D Texture Array
ao_baker_load_all_maps_from_disk :: proc(baker: ^AO_Baker, folder: string = "build") -> (loaded_count: int, ok: bool) {
	if baker.ao_array_texture_id == 0 {
		gl.GenTextures(1, &baker.ao_array_texture_id)
		gl.BindTexture(gl.TEXTURE_2D_ARRAY, baker.ao_array_texture_id)
		gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT)
		gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		swizzle_mask := [4]i32{gl.RED, gl.RED, gl.RED, gl.ONE}
		gl.TexParameteriv(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_SWIZZLE_RGBA, raw_data(swizzle_mask[:]))

		// Allocate 100 slices of 256x128 R8
		gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.R8, baker.width, baker.height, 100, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
		dbg.object_label(gl.TEXTURE, baker.ao_array_texture_id, "AO_Array_Texture")
		gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0)
	}

	gl.BindTexture(gl.TEXTURE_2D_ARRAY, baker.ao_array_texture_id)

	default_white := make([]u8, int(baker.width * baker.height), context.temp_allocator)
	for i in 0..<len(default_white) { default_white[i] = 255 }

	count := 0
	for i in 0..<100 {
		// Try candidate file paths in order of preference
		paths := [5]string{
			fmt.tprintf("%s/ao_sphere_%02d_gpu.png", folder, i),
			fmt.tprintf("%s/ao_sphere_%02d_cpu.png", folder, i),
			fmt.tprintf("%s/ao_sphere_%02d.png", folder, i),
			fmt.tprintf("screenshots/ao_sphere_%02d_gpu.png", i),
			fmt.tprintf("screenshots/ao_sphere_%02d_cpu.png", i),
		}

		found := false
		for p in paths {
			if !os.exists(p) do continue

			c_path := strings.clone_to_cstring(p, context.temp_allocator)
			w, h, channels: c.int
			data := stbi.load(c_path, &w, &h, &channels, 1) // Force 1-channel (R8)
			if data != nil {
				defer stbi.image_free(data)
				if w == c.int(baker.width) && h == c.int(baker.height) {
					gl.TexSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, i32(i), baker.width, baker.height, 1, gl.RED, gl.UNSIGNED_BYTE, data)
					found = true
					count += 1
					break
				}
			}
		}

		if !found {
			// Initialize missing layer to 1.0 (white / unoccluded)
			gl.TexSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, i32(i), baker.width, baker.height, 1, gl.RED, gl.UNSIGNED_BYTE, raw_data(default_white))
		}
	}

	gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0)
	baker.loaded_maps_count = i32(count)

	log.log_info("suckless-odin.ao_baker", "Loaded %d/100 Baked AO Maps into Texture Array (ID %d)", count, baker.ao_array_texture_id)
	return count, count > 0
}

@(private)
ao_bake_single_sphere :: proc(
	baker: ^AO_Baker,
	spheres: ^Instanced_Spheres,
	sphere_idx: i32,
	bake_cpu: bool,
	bake_gpu: bool,
	ssbo_binding: u32 = 2,
) -> (cpu_ms: f32, gpu_ms: f32, max_d: f32, mae: f32, rmse: f32, exact_pct: f32, le_1lsb: f32, ok: bool) {
	count := int(spheres.count)
	if count == 0 do return 0, 0, 0, 0, 0, 0, 0, false

	t_idx := clamp(sphere_idx, 0, i32(count - 1))
	W := baker.width
	H := baker.height
	samples := baker.num_samples
	num_texels := int(W * H)

	// ─── 1. CPU Multi-Threaded Bake ───────────────────────────────────────────
	if bake_cpu {
		models := spheres.instances.model[:]
		target_center := mt.Vec3{models[t_idx][3][0], models[t_idx][3][1], models[t_idx][3][2]}

		other_centers := make([dynamic]mt.Vec3, 0, count - 1, context.temp_allocator)
		for i in 0..<count {
			if i == int(t_idx) do continue
			pos := mt.Vec3{models[i][3][0], models[i][3][1], models[i][3][2]}
			append(&other_centers, pos)
		}

		num_threads := 12
		baker.cpu_threads_used = i32(num_threads)
		threads := make([]^thread.Thread, num_threads, context.temp_allocator)
		tasks   := make([]AO_Worker_Task, num_threads, context.temp_allocator)
		rows_per_thread := H / i32(num_threads)

		cpu_start := time.now()
		for i in 0..<num_threads {
			tasks[i] = AO_Worker_Task{
				baker         = baker,
				target_center = target_center,
				other_centers = other_centers[:],
				y_start       = i32(i) * rows_per_thread,
				y_end         = i32(i + 1) * rows_per_thread if i < num_threads - 1 else H,
				num_samples   = samples,
			}
			threads[i] = thread.create(ao_worker_proc)
			threads[i].data = &tasks[i]
			thread.start(threads[i])
		}

		for i in 0..<num_threads {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}

		cpu_ms = f32(time.duration_milliseconds(time.since(cpu_start)))

		// Update CPU Texture for preview
		if baker.cpu_texture_id != 0 {
			gl.BindTexture(gl.TEXTURE_2D, baker.cpu_texture_id)
			gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(baker.cpu_pixels))
			gl.BindTexture(gl.TEXTURE_2D, 0)
		}

		// Export CPU PNG
		cpu_path := fmt.bprintf(baker.cpu_png_path[:], "build/ao_sphere_%02d_cpu.png", t_idx)
		c_cpu_path := strings.clone_to_cstring(cpu_path, context.temp_allocator)
		stbi.write_png(c_cpu_path, c.int(W), c.int(H), 4, raw_data(baker.cpu_pixels), c.int(W * 4))
	}

	// ─── 2. GPU Compute Shader Bake ───────────────────────────────────────────
	if bake_gpu {
		gpu_path := fmt.bprintf(baker.gpu_png_path[:], "build/ao_sphere_%02d_gpu.png", t_idx)

		if baker.gpu_compute_program != 0 && baker.gpu_texture_id != 0 {
			gpu_raw_r8 := make([]u8, num_texels, context.temp_allocator)

			gl.UseProgram(baker.gpu_compute_program)
			gl.Uniform1i(baker.loc_target_sphere_idx, t_idx)
			gl.Uniform1i(baker.loc_total_spheres, i32(count))
			gl.Uniform1i(baker.loc_num_samples, samples)
			gl.Uniform1i(baker.loc_width, W)
			gl.Uniform1i(baker.loc_height, H)

			// Bind 2D image
			gl.BindImageTexture(0, baker.gpu_texture_id, 0, false, 0, gl.WRITE_ONLY, gl.R8)

			gx := u32((W + 15) / 16)
			gy := u32((H + 15) / 16)

			gl.Finish()
			gpu_start := time.now()

			gl.DispatchCompute(gx, gy, 1)
			gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
			gl.Finish()

			gpu_ms = f32(time.duration_milliseconds(time.since(gpu_start)))

			gl.UseProgram(0)

			// Download GPU texture back to CPU memory
			gl.BindTexture(gl.TEXTURE_2D, baker.gpu_texture_id)
			gl.GetTexImage(gl.TEXTURE_2D, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(gpu_raw_r8))
			gl.BindTexture(gl.TEXTURE_2D, 0)

			// Convert R8 to RGBA8 for GPU preview pixels & export
			for i in 0..<num_texels {
				val := gpu_raw_r8[i]
				baker.gpu_pixels[i * 4 + 0] = val
				baker.gpu_pixels[i * 4 + 1] = val
				baker.gpu_pixels[i * 4 + 2] = val
				baker.gpu_pixels[i * 4 + 3] = 255
			}

			// Export GPU PNG
			c_gpu_path := strings.clone_to_cstring(gpu_path, context.temp_allocator)
			stbi.write_png(c_gpu_path, c.int(W), c.int(H), 4, raw_data(baker.gpu_pixels), c.int(W * 4))
		}
	}

	// ─── 3. Upload to 2D Texture Array (Slice t_idx) ──────────────────────────
	if baker.ao_array_texture_id != 0 {
		if bake_gpu && baker.gpu_compute_program != 0 && baker.gpu_texture_id != 0 {
			// Extract R8 from GPU pixels
			gpu_r8 := make([]u8, num_texels, context.temp_allocator)
			for i in 0..<num_texels {
				gpu_r8[i] = baker.gpu_pixels[i * 4]
			}
			ao_baker_upload_layer_r8(baker, t_idx, gpu_r8)
		} else if bake_cpu {
			cpu_r8 := make([]u8, num_texels, context.temp_allocator)
			for i in 0..<num_texels {
				cpu_r8[i] = baker.cpu_pixels[i * 4]
			}
			ao_baker_upload_layer_r8(baker, t_idx, cpu_r8)
		}
	}

	// ─── 3. Compute Comparison Metrics (if both methods enabled) ──────────────
	if bake_cpu && bake_gpu {
		sum_abs_d: f64 = 0.0
		sum_sq_d:  f64 = 0.0
		exact_count := 0
		le_1lsb_count := 0

		for i in 0..<num_texels {
			c_val := f32(baker.cpu_pixels[i * 4]) / 255.0
			g_val := f32(baker.gpu_pixels[i * 4]) / 255.0
			diff := math.abs(c_val - g_val)

			max_d = max(max_d, diff)
			sum_abs_d += f64(diff)
			sum_sq_d += f64(diff * diff)

			if baker.cpu_pixels[i * 4] == baker.gpu_pixels[i * 4] {
				exact_count += 1
			}
			c_i := int(baker.cpu_pixels[i * 4])
			g_i := int(baker.gpu_pixels[i * 4])
			if math.abs(c_i - g_i) <= 1 {
				le_1lsb_count += 1
			}
		}

		mae = f32(sum_abs_d / f64(num_texels))
		rmse = f32(math.sqrt(sum_sq_d / f64(num_texels)))
		exact_pct = (f32(exact_count) / f32(num_texels)) * 100.0
		le_1lsb = (f32(le_1lsb_count) / f32(num_texels)) * 100.0
	}

	return cpu_ms, gpu_ms, max_d, mae, rmse, exact_pct, le_1lsb, true
}

// Bake a range of spheres [start_index, end_index] with CPU and/or GPU methods and export PNGs
ao_baker_bake_range :: proc(
	baker: ^AO_Baker,
	spheres: ^Instanced_Spheres,
	start_index, end_index: i32,
	num_samples: i32,
	bake_cpu: bool = true,
	bake_gpu: bool = true,
	ssbo_binding: u32 = 2,
) -> bool {
	count := int(spheres.count)
	if count == 0 do return false
	if !bake_cpu && !bake_gpu {
		log.log_warning("suckless-odin.ao_baker", "Cannot bake: neither CPU nor GPU method is enabled")
		return false
	}

	start_idx := clamp(min(start_index, end_index), 0, i32(count - 1))
	end_idx   := clamp(max(start_index, end_index), 0, i32(count - 1))

	baker.range_start      = start_idx
	baker.range_end        = end_idx
	baker.num_samples      = max(num_samples, 16)
	baker.bake_cpu_enabled = bake_cpu
	baker.bake_gpu_enabled = bake_gpu

	os.make_directory("screenshots")
	os.make_directory("build")

	total_spheres := int(end_idx - start_idx + 1)
	W := baker.width
	H := baker.height
	total_rays_per_sphere := i64(W) * i64(H) * i64(baker.num_samples)
	all_rays := total_rays_per_sphere * i64(total_spheres)

	total_cpu_time: f32 = 0.0
	total_gpu_time: f32 = 0.0
	global_max_d:   f32 = 0.0
	sum_mae:        f64 = 0.0
	sum_rmse:       f64 = 0.0
	sum_exact_pct:  f32 = 0.0
	sum_le_1lsb:    f32 = 0.0

	for s_idx in start_idx..=end_idx {
		c_ms, g_ms, m_d, mae, rmse, ex_pct, le_1lsb, ok := ao_bake_single_sphere(
			baker, spheres, s_idx, bake_cpu, bake_gpu, ssbo_binding,
		)
		if !ok do continue

		total_cpu_time += c_ms
		total_gpu_time += g_ms
		global_max_d = max(global_max_d, m_d)
		sum_mae += f64(mae)
		sum_rmse += f64(rmse)
		sum_exact_pct += ex_pct
		sum_le_1lsb += le_1lsb
	}

	baker.spheres_baked_count = i32(total_spheres)
	baker.target_sphere = start_idx
	baker.cpu_time_ms = total_cpu_time
	baker.gpu_time_ms = total_gpu_time

	if bake_cpu {
		c_secs := max(f64(total_cpu_time) / 1000.0, 0.0001)
		baker.cpu_mrays_per_sec = f32(f64(all_rays) / c_secs / 1_000_000.0)
	} else {
		baker.cpu_mrays_per_sec = 0.0
	}

	if bake_gpu {
		g_secs := max(f64(total_gpu_time) / 1000.0, 0.0001)
		baker.gpu_mrays_per_sec = f32(f64(all_rays) / g_secs / 1_000_000.0)
	} else {
		baker.gpu_mrays_per_sec = 0.0
	}

	if bake_cpu && bake_gpu {
		baker.max_delta = global_max_d
		baker.mae = f32(sum_mae / f64(total_spheres))
		baker.rmse = f32(sum_rmse / f64(total_spheres))
		baker.psnr_db = 20.0 * math.log10(1.0 / max(baker.rmse, 1e-7))
		baker.exact_match_pct = sum_exact_pct / f32(total_spheres)
		baker.le_1lsb_pct = sum_le_1lsb / f32(total_spheres)
		baker.is_iso_match = (global_max_d <= 0.01)
	}

	baker.is_baked = true

	// Also format path for target sphere
	fmt.bprintf(baker.cpu_png_path[:], "build/ao_sphere_%02d_cpu.png", start_idx)
	fmt.bprintf(baker.gpu_png_path[:], "build/ao_sphere_%02d_gpu.png", start_idx)

	log.log_info(
		"suckless-odin.ao_baker",
		"Offline AO Bake Complete: %d Spheres (#%d..#%d) | CPU=%.2f ms (%.1f Mrays/s), GPU=%.2f ms (%.1f Mrays/s), Max Delta=%.4f",
		total_spheres, start_idx, end_idx, baker.cpu_time_ms, baker.cpu_mrays_per_sec, baker.gpu_time_ms, baker.gpu_mrays_per_sec, baker.max_delta,
	)

	return true
}

// Fast Path: Bake a range of spheres [start_index, end_index] directly into 2D Texture Array (100% In-VRAM, 0 CPU readback, 0 Disk I/O)
ao_baker_bake_direct_vram :: proc(
	baker: ^AO_Baker,
	spheres: ^Instanced_Spheres,
	start_index, end_index: i32,
	num_samples: i32,
	ssbo_binding: u32 = 2,
) -> (gpu_ms: f32, ok: bool) {
	count := int(spheres.count)
	if count == 0 || baker.ao_array_texture_id == 0 || baker.gpu_array_compute_program == 0 {
		return 0, false
	}

	start_idx := clamp(min(start_index, end_index), 0, i32(count - 1))
	end_idx   := clamp(max(start_index, end_index), 0, i32(count - 1))
	num_spheres := end_idx - start_idx + 1

	samples := max(num_samples, 16)
	W := baker.width
	H := baker.height

	baker.range_start = start_idx
	baker.range_end = end_idx
	baker.num_samples = samples
	baker.spheres_baked_count = num_spheres
	baker.target_sphere = start_idx
	baker.bake_gpu_enabled = true
	baker.bake_cpu_enabled = false

	gl.UseProgram(baker.gpu_array_compute_program)
	gl.Uniform1i(baker.loc_arr_start_sphere_idx, start_idx)
	gl.Uniform1i(baker.loc_arr_total_spheres, i32(count))
	gl.Uniform1i(baker.loc_arr_num_samples, samples)
	gl.Uniform1i(baker.loc_arr_width, W)
	gl.Uniform1i(baker.loc_arr_height, H)

	// Bind entire 2D texture array as layered writeonly image on unit 0
	gl.BindImageTexture(0, baker.ao_array_texture_id, 0, true, 0, gl.WRITE_ONLY, gl.R8)

	gx := u32((W + 15) / 16)
	gy := u32((H + 15) / 16)
	gz := u32(num_spheres)

	gl.Finish()
	gpu_start := time.now()

	gl.DispatchCompute(gx, gy, gz)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
	gl.Finish()

	gpu_ms = f32(time.duration_milliseconds(time.since(gpu_start)))

	gl.UseProgram(0)

	// Copy target sphere slice to GPU preview texture for instant ImGui visualization (Zero-Copy VRAM)
	if baker.gpu_texture_id != 0 {
		gl.CopyImageSubData(
			baker.ao_array_texture_id, gl.TEXTURE_2D_ARRAY, 0, 0, 0, start_idx,
			baker.gpu_texture_id, gl.TEXTURE_2D, 0, 0, 0, 0,
			W, H, 1,
		)
	}

	all_rays := i64(W) * i64(H) * i64(samples) * i64(num_spheres)
	g_secs := max(f64(gpu_ms) / 1000.0, 0.0001)
	baker.gpu_time_ms = gpu_ms
	baker.gpu_mrays_per_sec = f32(f64(all_rays) / g_secs / 1_000_000.0)
	baker.cpu_time_ms = 0.0
	baker.cpu_mrays_per_sec = 0.0
	baker.loaded_maps_count = max(baker.loaded_maps_count, end_idx + 1)
	baker.is_baked = true

	log.log_info(
		"suckless-odin.ao_baker",
		"Direct In-VRAM GPU Fast Bake Complete: %d Spheres (#%d..#%d) in %.2f ms (%.1f Mrays/s) | 0 Disk I/O, 0 CPU Readback",
		num_spheres, start_idx, end_idx, gpu_ms, baker.gpu_mrays_per_sec,
	)

	return gpu_ms, true
}

// Single-sphere bake wrapper
ao_baker_bake_and_compare :: proc(
	baker: ^AO_Baker,
	spheres: ^Instanced_Spheres,
	target_index: i32,
	num_samples: i32,
	ssbo_binding: u32 = 2,
) -> bool {
	bake_cpu := baker.bake_cpu_enabled
	bake_gpu := baker.bake_gpu_enabled
	if !bake_cpu && !bake_gpu {
		bake_cpu = true
		bake_gpu = true
	}
	return ao_baker_bake_range(baker, spheres, target_index, target_index, num_samples, bake_cpu, bake_gpu, ssbo_binding)
}

ao_baker_get_cpu_png_path :: proc(baker: ^AO_Baker) -> string {
	return string(cstring(raw_data(baker.cpu_png_path[:])))
}

ao_baker_get_gpu_png_path :: proc(baker: ^AO_Baker) -> string {
	return string(cstring(raw_data(baker.gpu_png_path[:])))
}

// Destroy AO Baker OpenGL textures and buffers
ao_baker_destroy :: proc(baker: ^AO_Baker) {
	if baker.cpu_texture_id != 0 {
		gl.DeleteTextures(1, &baker.cpu_texture_id)
		baker.cpu_texture_id = 0
	}
	if baker.gpu_texture_id != 0 {
		gl.DeleteTextures(1, &baker.gpu_texture_id)
		baker.gpu_texture_id = 0
	}
	if baker.ao_array_texture_id != 0 {
		gl.DeleteTextures(1, &baker.ao_array_texture_id)
		baker.ao_array_texture_id = 0
	}
	if baker.gpu_compute_program != 0 {
		gl.DeleteProgram(baker.gpu_compute_program)
		baker.gpu_compute_program = 0
	}
	if baker.gpu_array_compute_program != 0 {
		gl.DeleteProgram(baker.gpu_array_compute_program)
		baker.gpu_array_compute_program = 0
	}
	delete(baker.cpu_pixels)
	delete(baker.gpu_pixels)
	baker.is_baked = false
}
