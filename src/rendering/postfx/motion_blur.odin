package postfx

import gl "vendor:OpenGL"

import shader "../shader"
import log "../../core/log"
import dbg "../../core/gl_debug"

// Tile size for velocity reduction (16×16 pixels → 1 tile).
MOTION_BLUR_TILE_SIZE :: 16

// Motion blur compute passes: tile-max and neighbor-max velocity reduction.
Motion_Blur_FX :: struct {
	tile_max_program:     u32,
	neighbor_max_program: u32,
	tile_max_tex:         u32, // RG16F, (width/16) × (height/16)
	neighbor_max_tex:     u32, // RG16F, same tile dims
	tile_width:           i32,
	tile_height:          i32,
}

// Create motion blur compute resources.
motion_blur_create :: proc(fx: ^Motion_Blur_FX, width, height: i32) -> (ok: bool) {
	defer if !ok { motion_blur_destroy(fx) }

	fx.tile_max_program = shader.load_compute("shaders/postfx/tile_max_velocity.comp") or_return
	fx.neighbor_max_program = shader.load_compute("shaders/postfx/neighbor_max_velocity.comp") or_return

	motion_blur_create_textures(fx, width, height)

	log.log_info("suckless-odin.postfx.motion_blur", "Motion blur created (%dx%d tiles from %dx%d)",
		fx.tile_width, fx.tile_height, width, height)
	return true
}

// Destroy motion blur resources.
motion_blur_destroy :: proc(fx: ^Motion_Blur_FX) {
	delete_program(&fx.tile_max_program)
	delete_program(&fx.neighbor_max_program)
	delete_texture(&fx.tile_max_tex)
	delete_texture(&fx.neighbor_max_tex)
}

// Resize tile textures on framebuffer resize.
motion_blur_resize :: proc(fx: ^Motion_Blur_FX, width, height: i32) {
	delete_texture(&fx.tile_max_tex)
	delete_texture(&fx.neighbor_max_tex)
	motion_blur_create_textures(fx, width, height)
}

// Run tile-max and neighbor-max compute passes.
// velocity_tex: the RG16F velocity buffer from scene MRT.
motion_blur_render :: proc(fx: ^Motion_Blur_FX, velocity_tex: u32) {
	dbg.push_group("PostFX_MotionBlur_Compute")
	defer dbg.pop_group()

	// Pass 1: Tile-max — reduce full-res velocity to per-tile max
	// Each workgroup (16×16 threads) processes one 16×16 pixel tile.
	// Dispatch: one group per tile.
	gl.UseProgram(fx.tile_max_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, velocity_tex)
	gl.BindImageTexture(1, fx.tile_max_tex, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RG16F)

	gl.DispatchCompute(u32(fx.tile_width), u32(fx.tile_height), 1)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)

	// Pass 2: Neighbor-max — 3×3 dilation over tile-max
	// Each thread processes one tile. Dispatch ceil(tiles/16) groups.
	gl.UseProgram(fx.neighbor_max_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, fx.tile_max_tex)
	gl.BindImageTexture(1, fx.neighbor_max_tex, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RG16F)

	neighbor_groups_x := u32((fx.tile_width + 15) / 16)
	neighbor_groups_y := u32((fx.tile_height + 15) / 16)
	gl.DispatchCompute(neighbor_groups_x, neighbor_groups_y, 1)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)

	gl.UseProgram(0)
}

// Get the neighbor-max texture for binding in composite pass.
motion_blur_get_neighbor_tex :: proc(fx: ^Motion_Blur_FX) -> u32 {
	return fx.neighbor_max_tex
}

// Get the velocity texture unit constant.
motion_blur_get_velocity_unit :: proc() -> u32 {
	return TEX_UNIT_VELOCITY
}

@(private)
motion_blur_create_textures :: proc(fx: ^Motion_Blur_FX, width, height: i32) {
	fx.tile_width = (width + MOTION_BLUR_TILE_SIZE - 1) / MOTION_BLUR_TILE_SIZE
	fx.tile_height = (height + MOTION_BLUR_TILE_SIZE - 1) / MOTION_BLUR_TILE_SIZE

	fx.tile_max_tex = create_texture_2d(
		fx.tile_width, fx.tile_height,
		gl.RG16F, gl.RG,
		filter = .Nearest,
	)
	fx.neighbor_max_tex = create_texture_2d(
		fx.tile_width, fx.tile_height,
		gl.RG16F, gl.RG,
		filter = .Nearest,
	)

	dbg.object_label(gl.TEXTURE, fx.tile_max_tex, "PostFX_TileMaxVelocity")
	dbg.object_label(gl.TEXTURE, fx.neighbor_max_tex, "PostFX_NeighborMaxVelocity")
}
