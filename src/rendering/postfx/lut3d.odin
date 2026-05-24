package postfx

// .cube LUT loader and GL_TEXTURE_3D manager.
// Parses Adobe .cube v1.0 format: DOMAIN_MIN/MAX, LUT_3D_SIZE, then N³ float triplets.
// ISO port of the lut3d subsystem from suckless-ogl.

import "core:os"
import "core:strings"
import "core:strconv"
import gl "vendor:OpenGL"

import log "../../core/log"

// LUT3D_FX manages a single 3D LUT texture on the GPU.
LUT3D_FX :: struct {
	texture_id: u32,
	size:        i32,   // cube dimension (usually 33)
	loaded:      bool,
	path:        string, // retained for GUI display
}

// Parse an Adobe .cube file and upload to GL_TEXTURE_3D.
// Binds to TEX_UNIT_LUT3D (unit 8). Returns true on success.
// The caller is responsible for calling lut3d_destroy when done.
lut3d_load :: proc(lut: ^LUT3D_FX, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.postfx.lut3d", "Failed to read LUT file: %s (err=%v)", path, err)
		return false
	}
	defer delete(data)

	size: i32 = 0
	triplets: [dynamic]f32
	defer delete(triplets)

	lines := strings.split_lines(string(data), context.temp_allocator)
	for raw_line in lines {
		line := strings.trim_space(raw_line)

		// Skip comments and empty lines
		if len(line) == 0 || line[0] == '#' { continue }

		// Parse LUT_3D_SIZE directive
		if strings.has_prefix(line, "LUT_3D_SIZE") {
			parts := strings.fields(line, context.temp_allocator)
			if len(parts) >= 2 {
				n, parse_ok := strconv.parse_int(parts[1])
				if parse_ok { size = i32(n) }
			}
			continue
		}

		// Skip DOMAIN_MIN / DOMAIN_MAX / TITLE directives
		if strings.has_prefix(line, "DOMAIN_") || strings.has_prefix(line, "TITLE") { continue }

		// Parse float triplet (R G B per line)
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 3 { continue }
		r, ok_r := strconv.parse_f32(parts[0])
		g, ok_g := strconv.parse_f32(parts[1])
		b, ok_b := strconv.parse_f32(parts[2])
		if !ok_r || !ok_g || !ok_b { continue }
		append(&triplets, r, g, b)
	}

	expected := int(size * size * size)
	if size == 0 || len(triplets) != expected * 3 {
		log.log_error(
			"suckless-odin.postfx.lut3d",
			"Invalid .cube file '%s': size=%d, got %d triplets (expected %d)",
			path, size, len(triplets) / 3, expected,
		)
		return false
	}

	// Destroy existing texture if re-loading
	lut3d_destroy(lut)

	gl.GenTextures(1, &lut.texture_id)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_LUT3D)
	gl.BindTexture(gl.TEXTURE_3D, lut.texture_id)

	// Upload: .cube stores B-major order (B outermost loop, R innermost)
	gl.TexImage3D(
		gl.TEXTURE_3D, 0, gl.RGB16F,
		size, size, size, 0,
		gl.RGB, gl.FLOAT, raw_data(triplets[:]),
	)

	// Trilinear filtering without mipmap (mips distort LUT interpolation)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)

	gl.BindTexture(gl.TEXTURE_3D, 0)

	lut.size   = size
	lut.loaded = true
	lut.path   = strings.clone(path) // owned by LUT3D_FX, freed in lut3d_destroy

	log.log_info("suckless-odin.postfx.lut3d", "LUT loaded: %s (%d^3)", path, size)
	return true
}

// Bind the LUT texture to TEX_UNIT_LUT3D (8).
// If no LUT is loaded, binds texture 0 (identity fallback on GPU).
lut3d_bind :: proc(lut: ^LUT3D_FX) {
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_LUT3D)
	if lut.loaded {
		gl.BindTexture(gl.TEXTURE_3D, lut.texture_id)
	} else {
		gl.BindTexture(gl.TEXTURE_3D, 0)
	}
}

// Release the GPU texture and path string. Safe to call even if never loaded.
lut3d_destroy :: proc(lut: ^LUT3D_FX) {
	if lut.texture_id != 0 {
		gl.DeleteTextures(1, &lut.texture_id)
		lut.texture_id = 0
	}
	if lut.path != "" {
		delete(lut.path)
		lut.path = ""
	}
	lut.loaded = false
	lut.size   = 0
}
