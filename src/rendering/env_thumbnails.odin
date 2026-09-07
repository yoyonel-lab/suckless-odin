package rendering

import "core:c"
import "core:strings"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import log "../core/log"

Env_Thumbnail :: struct {
	path:         string,
	filename:     string,
	display_name: string,
	tex_id:       u32,
	width:        i32,
	height:       i32,
}

Env_Thumbnail_Manager :: struct {
	thumbnails: [dynamic]Env_Thumbnail,
}

// Convert "assets/textures/hdr/cedar_bridge_2_4k.hdr" to "Cedar Bridge 2 (4K)"
format_hdr_display_name :: proc(filename: string) -> string {
	name := filename
	if strings.has_suffix(name, ".hdr") {
		name = name[:len(name)-4]
	} else if strings.has_suffix(name, ".exr") {
		name = name[:len(name)-4]
	}

	parts := strings.split(name, "_", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		if i > 0 do strings.write_string(&b, " ")
		if p == "4k" || p == "2k" || p == "8k" || p == "1k" {
			strings.write_string(&b, "(")
			strings.write_string(&b, strings.to_upper(p, context.temp_allocator))
			strings.write_string(&b, ")")
		} else if len(p) > 0 {
			upper_first := strings.to_upper(p[:1], context.temp_allocator)
			strings.write_string(&b, upper_first)
			if len(p) > 1 {
				strings.write_string(&b, p[1:])
			}
		}
	}
	return strings.clone(strings.to_string(b))
}

env_thumbnail_load :: proc(path: string) -> Env_Thumbnail {
	thumb: Env_Thumbnail
	thumb.path = strings.clone(path)

	last_slash := strings.last_index_byte(path, '/')
	filename := path[last_slash+1:] if last_slash >= 0 else path
	thumb.filename = strings.clone(filename)
	thumb.display_name = format_hdr_display_name(filename)

	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	stbi.set_flip_vertically_on_load(1)

	w, h, channels: c.int
	data := stbi.loadf(path_c, &w, &h, &channels, 4)
	if data == nil {
		log.log_warning("suckless-odin.texture", "Failed to load thumbnail HDR: %s", path)
		return thumb
	}
	defer stbi.image_free(data)

	thumb.width = i32(w)
	thumb.height = i32(h)

	gl.GenTextures(1, &thumb.tex_id)
	gl.BindTexture(gl.TEXTURE_2D, thumb.tex_id)
	gl.TexImage2D(
		gl.TEXTURE_2D, 0, gl.RGBA16F,
		thumb.width, thumb.height, 0,
		gl.RGBA, gl.FLOAT, data,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	return thumb
}

env_thumbnails_init :: proc(mgr: ^Env_Thumbnail_Manager, hdr_paths: []string) {
	clear(&mgr.thumbnails)
	for path in hdr_paths {
		thumb := env_thumbnail_load(path)
		append(&mgr.thumbnails, thumb)
	}
	log.log_info("suckless-odin.texture", "Loaded %d environment map thumbnails", len(mgr.thumbnails))
}

env_thumbnails_destroy :: proc(mgr: ^Env_Thumbnail_Manager) {
	for &thumb in mgr.thumbnails {
		if thumb.tex_id != 0 {
			gl.DeleteTextures(1, &thumb.tex_id)
			thumb.tex_id = 0
		}
		delete(thumb.path)
		delete(thumb.filename)
		delete(thumb.display_name)
	}
	delete(mgr.thumbnails)
}
