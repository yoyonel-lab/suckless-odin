package rendering

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"
import "core:c"

import log "../core/log"

// HDR texture loaded as GL_RGBA16F equirectangular 2D
Texture_HDR :: struct {
	id:     u32,
	width:  i32,
	height: i32,
}

// Load an HDR equirectangular image from disk, upload to GPU as RGBA16F
texture_hdr_load :: proc(path: cstring) -> (tex: Texture_HDR, ok: bool) {
	stbi.set_flip_vertically_on_load(1)  // Flip for OpenGL: uv.y=0=ground, uv.y=1=sky

	w, h, channels: c.int
	data := stbi.loadf(path, &w, &h, &channels, 4)  // force RGBA
	if data == nil {
		log.log_error("suckless-odin.texture", "Failed to load HDR: %s", path)
		return tex, false
	}
	defer stbi.image_free(data)

	tex.width  = i32(w)
	tex.height = i32(h)

	gl.GenTextures(1, &tex.id)
	gl.BindTexture(gl.TEXTURE_2D, tex.id)
	gl.TexImage2D(
		gl.TEXTURE_2D, 0, gl.RGBA16F,
		tex.width, tex.height, 0,
		gl.RGBA, gl.FLOAT, data,
	)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.GenerateMipmap(gl.TEXTURE_2D)

	gl.BindTexture(gl.TEXTURE_2D, 0)

	log.log_info("suckless-odin.texture", "HDR loaded: %s (%dx%d)", path, tex.width, tex.height)
	return tex, true
}

texture_destroy :: proc(tex: ^Texture_HDR) {
	if tex.id != 0 {
		gl.DeleteTextures(1, &tex.id)
		tex.id = 0
	}
}
