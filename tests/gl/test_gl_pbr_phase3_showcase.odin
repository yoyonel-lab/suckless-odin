// +build test
// E2E Headless GPU PBR Phase 3 Showcase & Validation Generator
// Generates high-fidelity comparative visual screenshots for Specular Occlusion & Horizon Clipping.
package test_gl

import "core:testing"
import "core:fmt"
import "core:time"
import "core:math"
import "core:c/libc"
import "core:os"
import "core:strings"

import sc "../../src/scene"
import cam "../../src/camera"
import mt "../../src/core/math_types"
import rend_types "../../src/rendering/types"
import rendering "../../src/rendering"
import postfx "../../src/rendering/postfx"
import gl "vendor:OpenGL"

@(test)
test_pbr_phase3_showcase_screenshots :: proc(t: ^testing.T) {
	RECORD_PBR_PHASE3 :: #config(RECORD_PBR_PHASE3, false)
	when !RECORD_PBR_PHASE3 {
		return
	}

	if !ensure_gl_context(t) { return }

	width: i32 = 1280
	height: i32 = 720

	rt, rt_ok := render_target_create(width, height)
	if !rt_ok {
		testing.expect(t, false, "Failed to create offscreen render target FBO")
		return
	}
	defer render_target_destroy(&rt)

	s: sc.Scene
	if !sc.scene_create(&s, width, height) {
		testing.expect(t, false, "Failed to create scene")
		return
	}
	defer sc.scene_destroy(&s)

	// Set varied Ambient Occlusion across columns to simulate contact crevices vs open surfaces
	for i in 0..<len(s.spheres.instances) {
		col := i % 10
		// Left columns: Deep occluded cavities (AO=0.05..0.25)
		// Middle columns: Partial occlusion (AO=0.40..0.65)
		// Right columns: Open exposed surfaces (AO=0.80..1.00)
		s.spheres.instances[i].ao = clamp(f32(0.05) + f32(col) * 0.105, 0.05, 1.0)
	}
	rendering.instanced_upload(&s.spheres)

	// Clean framing showing multi-material spheres across the AO gradient
	s.camera.position = mt.Vec3{0.0, 0.0, 9.5}
	s.camera.yaw = -90.0
	s.camera.pitch = 0.0
	s.camera.yaw_target = -90.0
	s.camera.pitch_target = 0.0
	cam.update_vectors(&s.camera)

	s.postfx_pipeline.enabled = false
	s.volumetric.params.enabled = false

	// Wait for async IBL pipeline to stabilize
	for _ in 0..<5000 {
		sc.scene_update(&s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, rt.width, rt.height)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle { break }
		time.sleep(1 * time.Millisecond)
	}

	render_and_capture :: proc(s: ^sc.Scene, rt: ^Render_Target) -> []u8 {
		sc.scene_update(s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(s, rt.width, rt.height)
		gl.Finish()
		return capture_framebuffer(rt)
	}

	libc.system("mkdir -p docs/images/pbr")
	artifact_dir := "/home/latty/.gemini/antigravity-cli/brain/abbd220c-398a-4f3d-bd7e-a93cd9610b2e"

	save_image_pair :: proc(path_rel: string, artifact_dir: string, filename: string, pix: []u8, w, h: i32) {
		save_png(path_rel, pix, w, h)
		full_art_path := fmt.tprintf("%s/%s", artifact_dir, filename)
		save_png(full_art_path, pix, w, h)
	}

	// 1. With Specular Occlusion + Horizon Clipping (PHYSICALLY ACCURATE FINAL PBR)
	s.specular_occlusion_enabled = true
	s.specular_occlusion_strength = 1.0
	s.horizon_clipping_enabled = true
	s.specular_occlusion_debug_mode = .Off
	s.specular_occlusion_split_enabled = false
	s.pbr_debug_mode = .Final_PBR
	pix1 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_with_so.png", artifact_dir, "pbr_phase3_with_so.png", pix1, width, height)
	delete(pix1)

	// 2. Without Specular Occlusion (UNPHYSICAL SPECULAR LIGHT LEAKS IN CAVITIES)
	s.specular_occlusion_enabled = false
	s.horizon_clipping_enabled = false
	pix2 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_without_so.png", artifact_dir, "pbr_phase3_without_so.png", pix2, width, height)
	delete(pix2)

	// 3. Debug View: Grayscale Occlusion Mask (SO * Horizon)
	s.specular_occlusion_enabled = true
	s.horizon_clipping_enabled = true
	s.specular_occlusion_debug_mode = .Grayscale_Factor
	pix3 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_so_grayscale_mask.png", artifact_dir, "pbr_phase3_so_grayscale_mask.png", pix3, width, height)
	delete(pix3)

	// 4. Debug View: Occluded Specular Energy Delta Heatmap (Turbo False-Color)
	s.specular_occlusion_debug_mode = .Delta_Heatmap
	pix4 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_so_delta_heatmap.png", artifact_dir, "pbr_phase3_so_delta_heatmap.png", pix4, width, height)
	delete(pix4)

	// 5. Debug View: Horizon Clipping Factor Grayscale
	s.specular_occlusion_debug_mode = .Horizon_Clipping
	pix5 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_so_horizon_factor.png", artifact_dir, "pbr_phase3_so_horizon_factor.png", pix5, width, height)
	delete(pix5)

	// 6. A/B Split-Screen (Left: With SO, Right: Bypassed Raw Specular Leaks)
	s.specular_occlusion_debug_mode = .Off
	s.specular_occlusion_split_enabled = true
	s.specular_occlusion_split_position = 0.50
	pix6 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_ab_split.png", artifact_dir, "pbr_phase3_ab_split.png", pix6, width, height)
	delete(pix6)

	// 7. PBR Diagnostic: Normal Map buffer
	s.specular_occlusion_split_enabled = false
	s.pbr_debug_mode = .Normal
	pix7 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_diag_normal.png", artifact_dir, "pbr_phase3_diag_normal.png", pix7, width, height)
	delete(pix7)

	// 8. PBR Diagnostic: Roughness Map buffer
	s.pbr_debug_mode = .Roughness
	pix8 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_diag_roughness.png", artifact_dir, "pbr_phase3_diag_roughness.png", pix8, width, height)
	delete(pix8)

	// --- CLOSE-UP PASS ON GLOSSY METALLIC & DIELECTRIC SPHERES ---
	s.camera.position = mt.Vec3{-7.5, 9.0, 4.5}
	s.camera.yaw = -70.0
	s.camera.pitch = -12.0
	s.camera.yaw_target = -70.0
	s.camera.pitch_target = -12.0
	cam.update_vectors(&s.camera)

	// Close-up With SO
	s.specular_occlusion_enabled = true
	s.horizon_clipping_enabled = true
	s.specular_occlusion_debug_mode = .Off
	s.specular_occlusion_split_enabled = false
	s.pbr_debug_mode = .Final_PBR
	pix_c1 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_closeup_with_so.png", artifact_dir, "pbr_phase3_closeup_with_so.png", pix_c1, width, height)
	delete(pix_c1)

	// Close-up Without SO (Shows glaring specular leaks in cavity)
	s.specular_occlusion_enabled = false
	s.horizon_clipping_enabled = false
	pix_c2 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_closeup_without_so.png", artifact_dir, "pbr_phase3_closeup_without_so.png", pix_c2, width, height)
	delete(pix_c2)

	// Close-up A/B Split (Left = With SO, Right = Raw unoccluded leaks)
	s.specular_occlusion_enabled = true
	s.horizon_clipping_enabled = true
	s.specular_occlusion_split_enabled = true
	s.specular_occlusion_split_position = 0.50
	pix_c3 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_closeup_ab_split.png", artifact_dir, "pbr_phase3_closeup_ab_split.png", pix_c3, width, height)
	delete(pix_c3)

	// Close-up Delta Heatmap
	s.specular_occlusion_split_enabled = false
	s.specular_occlusion_debug_mode = .Delta_Heatmap
	pix_c4 := render_and_capture(&s, &rt)
	save_image_pair("docs/images/pbr/pbr_phase3_closeup_heatmap.png", artifact_dir, "pbr_phase3_closeup_heatmap.png", pix_c4, width, height)
	delete(pix_c4)

	fmt.println("✅ PBR Phase 3 showcase screenshots generated successfully!")
}
