package tracy

// Frame Image Capture — async PBO-based screenshot pipeline for Tracy.
// Port of tracy_manager_update_screenshots() from suckless-ogl/src/tracy_manager.c
//
// Architecture:
// - Ring buffer of 4 PBOs for async GPU → CPU readback
// - Downscale backbuffer (blit) → 320×180 FBO
// - ReadPixels into PBO (non-blocking via PBO binding)
// - FenceSync guards readback completion
// - MapBuffer → tracy_gpu_screenshot → UnmapBuffer

import gl "vendor:OpenGL"

SCREENSHOT_WIDTH  :: 320
SCREENSHOT_HEIGHT :: 180
PBO_COUNT         :: 4

Frame_Image :: struct {
	screenshot_pbo:  [PBO_COUNT]u32,
	screenshot_sync: [PBO_COUNT]gl.sync_t,
	screenshot_fbo:  u32,
	screenshot_tex:  u32,
	pbo_idx:         int,
}

frame_image_init :: proc(fi: ^Frame_Image) {
	when !TRACY_ENABLE { return }

	// Create downscale texture
	gl.GenTextures(1, &fi.screenshot_tex)
	gl.BindTexture(gl.TEXTURE_2D, fi.screenshot_tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, SCREENSHOT_WIDTH, SCREENSHOT_HEIGHT)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// Create FBO
	gl.GenFramebuffers(1, &fi.screenshot_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fi.screenshot_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fi.screenshot_tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	// Create PBO ring buffer
	gl.GenBuffers(PBO_COUNT, &fi.screenshot_pbo[0])
	for i in 0 ..< PBO_COUNT {
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fi.screenshot_pbo[i])
		gl.BufferData(gl.PIXEL_PACK_BUFFER, SCREENSHOT_WIDTH * SCREENSHOT_HEIGHT * 4, nil, gl.STREAM_READ)
		fi.screenshot_sync[i] = nil
	}
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
	fi.pbo_idx = 0
}

frame_image_destroy :: proc(fi: ^Frame_Image) {
	when !TRACY_ENABLE { return }

	gl.DeleteTextures(1, &fi.screenshot_tex)
	gl.DeleteFramebuffers(1, &fi.screenshot_fbo)
	gl.DeleteBuffers(PBO_COUNT, &fi.screenshot_pbo[0])
	for i in 0 ..< PBO_COUNT {
		if fi.screenshot_sync[i] != nil {
			gl.DeleteSync(fi.screenshot_sync[i])
			fi.screenshot_sync[i] = nil
		}
	}
}

// Call once per frame AFTER rendering, BEFORE swap.
// Mirrors tracy_manager_update_screenshots() from legacy.
frame_image_update :: proc(fi: ^Frame_Image, viewport_w, viewport_h: i32) {
	when !TRACY_ENABLE { return }

	// 1. Send previous frame's screenshot (already in PBO, should be ready)
	read_idx := (fi.pbo_idx + 1) % PBO_COUNT

	if fi.screenshot_sync[read_idx] != nil {
		wait_res := gl.ClientWaitSync(fi.screenshot_sync[read_idx], gl.SYNC_FLUSH_COMMANDS_BIT, 0)
		if wait_res == gl.ALREADY_SIGNALED || wait_res == gl.CONDITION_SATISFIED {
			gl.DeleteSync(fi.screenshot_sync[read_idx])
			fi.screenshot_sync[read_idx] = nil

			gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fi.screenshot_pbo[read_idx])
			pbo_ptr := gl.MapBuffer(gl.PIXEL_PACK_BUFFER, gl.READ_ONLY)
			if pbo_ptr != nil {
				gpu_screenshot(pbo_ptr, SCREENSHOT_WIDTH, SCREENSHOT_HEIGHT)
				gl.UnmapBuffer(gl.PIXEL_PACK_BUFFER)
			}
			gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
		}
		// If TIMEOUT_EXPIRED or WAIT_FAILED, skip this frame (don't stall)
	}

	// 2. Downscale backbuffer → screenshot FBO
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.ReadBuffer(gl.BACK)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, fi.screenshot_fbo)
	gl.BlitFramebuffer(
		0, 0, viewport_w, viewport_h,
		0, 0, SCREENSHOT_WIDTH, SCREENSHOT_HEIGHT,
		gl.COLOR_BUFFER_BIT, gl.LINEAR,
	)

	// 3. ReadPixels into PBO (async — returns immediately with PBO bound)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, fi.screenshot_fbo)
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fi.screenshot_pbo[fi.pbo_idx])
	gl.ReadPixels(0, 0, SCREENSHOT_WIDTH, SCREENSHOT_HEIGHT, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	// 4. Fence this readback
	if fi.screenshot_sync[fi.pbo_idx] != nil {
		gl.DeleteSync(fi.screenshot_sync[fi.pbo_idx])
	}
	fi.screenshot_sync[fi.pbo_idx] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)

	// 5. Advance ring buffer
	fi.pbo_idx = (fi.pbo_idx + 1) % PBO_COUNT
}
