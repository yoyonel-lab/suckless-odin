package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import mt "../src/core/math_types"
import rendering "../src/rendering"
import simd "../src/core/simd_utils"
import gl_state "../src/core/gl_state"

save_png :: proc(path: string, pixels: []u8, w, h, channels: i32) -> bool {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	stride := w * channels
	result := stbi.write_png(c_path, c.int(w), c.int(h), c.int(channels), raw_data(pixels), c.int(stride))
	return result != 0
}

flip_vertical :: proc(pixels: []u8, w, h, channels: i32) -> []u8 {
	flipped := make([]u8, int(w * h * channels))
	stride := int(w * channels)
	for y in 0 ..< int(h) {
		src_y := int(h) - 1 - y
		copy(flipped[y * stride : (y + 1) * stride], pixels[src_y * stride : (src_y + 1) * stride])
	}
	return flipped
}

draw_disk :: proc(pixels: []u8, w, h: i32, cx, cy, radius: i32, color: [4]u8) {
	for dy := -radius; dy <= radius; dy += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			if dx * dx + dy * dy <= radius * radius {
				px := cx + dx
				py := cy + dy
				if px >= 0 && px < w && py >= 0 && py < h {
					idx := int((py * w + px) * 4)
					pixels[idx + 0] = color[0]
					pixels[idx + 1] = color[1]
					pixels[idx + 2] = color[2]
					pixels[idx + 3] = color[3]
				}
			}
		}
	}
}

draw_circle :: proc(pixels: []u8, w, h: i32, cx, cy, radius, thickness: i32, color: [4]u8) {
	r_in := radius - thickness
	r_out := radius + thickness
	for dy := -r_out; dy <= r_out; dy += 1 {
		for dx := -r_out; dx <= r_out; dx += 1 {
			d2 := dx * dx + dy * dy
			if d2 >= r_in * r_in && d2 <= r_out * r_out {
				px := cx + dx
				py := cy + dy
				if px >= 0 && px < w && py >= 0 && py < h {
					idx := int((py * w + px) * 4)
					pixels[idx + 0] = color[0]
					pixels[idx + 1] = color[1]
					pixels[idx + 2] = color[2]
					pixels[idx + 3] = color[3]
				}
			}
		}
	}
}

draw_line :: proc(pixels: []u8, w, h: i32, x0, y0, x1, y1: i32, color: [4]u8) {
	dx := math.abs(x1 - x0)
	dy := -math.abs(y1 - y0)
	sx: i32 = 1 if x0 < x1 else -1
	sy: i32 = 1 if y0 < y1 else -1
	err := dx + dy
	cx := x0
	cy := y0

	for {
		if cx >= 0 && cx < w && cy >= 0 && cy < h {
			idx := int((cy * w + cx) * 4)
			pixels[idx + 0] = color[0]
			pixels[idx + 1] = color[1]
			pixels[idx + 2] = color[2]
			pixels[idx + 3] = color[3]
		}
		if cx == x1 && cy == y1 do break
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			cx += sx
		}
		if e2 <= dx {
			err += dx
			cy += sy
		}
	}
}

gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = glfw.GetProcAddress(name)
}

main :: proc() {
	if !glfw.Init() {
		fmt.eprintln("Failed to init GLFW")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.VISIBLE, 0)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window := glfw.CreateWindow(64, 64, "Sun Shadow Validator", nil, nil)
	if window == nil {
		fmt.eprintln("Failed to create headless window")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, gl_set_proc_address)
	gl_state.reset()

	libc.system("mkdir -p docs/images/sun_shadow")

	// Create test scene resources
	billboard: rendering.Billboard
	rendering.billboard_create(&billboard)
	defer rendering.billboard_destroy(&billboard)

	mat_lib, mat_ok := rendering.material_load_presets("assets/materials/pbr_materials.json")
	if !mat_ok {
		fmt.eprintln("Failed to load material presets")
		os.exit(1)
	}
	defer rendering.material_lib_destroy(&mat_lib)

	spheres: rendering.Instanced_Spheres
	rendering.instanced_create(&spheres, &mat_lib)
	defer rendering.instanced_destroy(&spheres)

	sun_shadow: rendering.Sun_Shadow
	if !rendering.sun_shadow_create(&sun_shadow, 1024) {
		fmt.eprintln("Failed to create sun shadow")
		os.exit(1)
	}
	defer rendering.sun_shadow_destroy(&sun_shadow)

	env_paths := [?]string{
		"assets/textures/hdr/cedar_bridge_2_4k.hdr",
		"assets/textures/hdr/neon_photostudio_4k.hdr",
		"assets/textures/hdr/abandoned_garage_4k.hdr",
		"assets/textures/hdr/river_alcove_4k.hdr",
		"assets/textures/hdr/small_cathedral_02_4k.hdr",
	}

	env_names := [?]string{
		"cedar_bridge",
		"neon_photostudio",
		"abandoned_garage",
		"river_alcove",
		"small_cathedral",
	}

	fmt.println("=========================================================================================")
	fmt.println("☀️  SUN DIRECTIONAL SHADOW MAP VALIDATION & BENCHMARK")
	fmt.println("=========================================================================================")
	fmt.printf("%-18s | %-12s | %-10s | %-10s | %-8s | %-10s | %-10s\n",
		"Environment", "Status", "Azimuth", "Elevation", "Conf(px)", "Peak", "Cost (ms)")
	fmt.println("-----------------------------------------------------------------------------------------")

	for env_idx in 0 ..< len(env_paths) {
		path := env_paths[env_idx]
		name := env_names[env_idx]

		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.eprintf("Failed to read %s\n", path)
			continue
		}
		defer delete(data)

		w, h: i32
		simd.fast_hdr_get_dimensions(raw_data(data), uint(len(data)), &w, &h)
		pixel_count := uint(w) * uint(h) * 4
		bytes_fp16 := (pixel_count * size_of(u16) + 63) & ~uint(63)
		half_data := cast([^]u16)libc.aligned_alloc(64, bytes_fp16)
		defer libc.free(half_data)

		simd.fast_hdr_decode_fp16(raw_data(data), uint(len(data)), &w, &h, half_data, pixel_count, 1)

		det := rendering.sun_detect_from_fp16(half_data, w, h)
		sun_shadow.detection = det
		sun_shadow.is_dirty = true

		// Render sun shadow pass
		rendering.sun_shadow_render(&sun_shadow, &spheres, &billboard, true)

		// Benchmark cost of sun shadow pass
		bench_iterations :: 200
		start_tick := time.tick_now()
		for _ in 0 ..< bench_iterations {
			rendering.sun_shadow_render(&sun_shadow, &spheres, &billboard, true)
		}
		gl.Finish()
		elapsed := time.tick_since(start_tick)
		cost_ms := f32(time.duration_milliseconds(elapsed)) / f32(bench_iterations)

		status_str := "DETECTED" if det.sun_detected else "FALLBACK"
		fmt.printf("%-18s | %-12s | %8.2f°  | %8.2f°  | %8d | %10.1f | %6.3f ms\n",
			name, status_str, det.azimuth, det.elevation, det.confidence, det.peak_intensity, cost_ms)

		// 1. Capture Shadow Atlas 2D preview
		rendering.sun_shadow_update_preview_atlas(&sun_shadow)
		atlas_w := sun_shadow.preview_w
		atlas_h := sun_shadow.preview_h
		atlas_pixels := make([]u8, int(atlas_w * atlas_h * 4))
		defer delete(atlas_pixels)

		gl.BindFramebuffer(gl.FRAMEBUFFER, sun_shadow.preview_fbo)
		gl.ReadPixels(0, 0, atlas_w, atlas_h, gl.RGBA, gl.UNSIGNED_BYTE, &atlas_pixels[0])
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		flipped_atlas := flip_vertical(atlas_pixels, atlas_w, atlas_h, 4)
		defer delete(flipped_atlas)
		atlas_out_path := fmt.tprintf("docs/images/sun_shadow/atlas_%s.png", name)
		save_png(atlas_out_path, flipped_atlas, atlas_w, atlas_h, 4)

		// 2. Generate Envmap Preview with Sun Marker Overlay
		prev_w: i32 = 512
		prev_h: i32 = 256
		prev_pixels := make([]u8, int(prev_w * prev_h * 4))
		defer delete(prev_pixels)

		// Downsample & Reinhard tonemap equirect pixels to preview
		for py in 0 ..< prev_h {
			for px in 0 ..< prev_w {
				sx := clamp(int(f32(px) / f32(prev_w) * f32(w)), 0, int(w) - 1)
				sy := clamp(int(f32(py) / f32(prev_h) * f32(h)), 0, int(h) - 1)
				idx_src := (sy * int(w) + sx) * 4
				r := f32(transmute(f16)half_data[idx_src + 0])
				g := f32(transmute(f16)half_data[idx_src + 1])
				b := f32(transmute(f16)half_data[idx_src + 2])
				if math.is_nan(r) do r = 0; if math.is_inf(r) do r = 1000
				if math.is_nan(g) do g = 0; if math.is_inf(g) do g = 1000
				if math.is_nan(b) do b = 0; if math.is_inf(b) do b = 1000
				r = max(0.0, r); g = max(0.0, g); b = max(0.0, b)

				// Reinhard tonemap + sRGB gamma
				r = r / (r + 1.0)
				g = g / (g + 1.0)
				b = b / (b + 1.0)
				r = math.pow(r, 1.0 / 2.2)
				g = math.pow(g, 1.0 / 2.2)
				b = math.pow(b, 1.0 / 2.2)

				idx_dst := int((py * prev_w + px) * 4)
				prev_pixels[idx_dst + 0] = u8(clamp(r * 255.0, 0.0, 255.0))
				prev_pixels[idx_dst + 1] = u8(clamp(g * 255.0, 0.0, 255.0))
				prev_pixels[idx_dst + 2] = u8(clamp(b * 255.0, 0.0, 255.0))
				prev_pixels[idx_dst + 3] = 255
			}
		}

		// Draw Sun Marker overlay on top of equirect preview
		sun_uv := rendering.sun_dir_to_uv(det.direction)
		marker_x := clamp(i32(sun_uv[0] * f32(prev_w)), 0, prev_w - 1)
		marker_y := clamp(i32(sun_uv[1] * f32(prev_h)), 0, prev_h - 1)

		marker_col: [4]u8 = [4]u8{255, 215, 0, 255} if det.sun_detected else [4]u8{160, 160, 180, 255}
		inner_col:  [4]u8 = [4]u8{255, 60, 0, 255}  if det.sun_detected else [4]u8{80, 80, 100, 255}

		// Outer reticle circle
		draw_circle(prev_pixels, prev_w, prev_h, marker_x, marker_y, 14, 2, marker_col)
		// Inner pinpoint circle
		draw_disk(prev_pixels, prev_w, prev_h, marker_x, marker_y, 3, inner_col)
		// Crosshair lines
		draw_line(prev_pixels, prev_w, prev_h, marker_x - 22, marker_y, marker_x + 22, marker_y, marker_col)
		draw_line(prev_pixels, prev_w, prev_h, marker_x, marker_y - 22, marker_x, marker_y + 22, marker_col)

		// Flip for PNG export (y=0 top in PNG vs y=0 bottom in equirect GL convention)
		flipped_prev := flip_vertical(prev_pixels, prev_w, prev_h, 4)
		defer delete(flipped_prev)
		marker_out_path := fmt.tprintf("docs/images/sun_shadow/marker_%s.png", name)
		save_png(marker_out_path, flipped_prev, prev_w, prev_h, 4)
	}

	fmt.println("=========================================================================================")
	fmt.println("✅ All shadow atlas & sun marker validation images generated in docs/images/sun_shadow/")
	fmt.println("=========================================================================================")
}
