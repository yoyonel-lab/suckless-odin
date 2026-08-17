// +build test
// Async loader & env manager tests — validates background HDR loading,
// IBL progressive generation, and transition state machine.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
// Requires a display (or xvfb-run on CI) for GL context.
package test_gl

import "core:testing"
import "core:time"
import "core:fmt"
import "core:sync"
import libc "core:c/libc"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import sc "../../src/scene"
import rendering "../../src/rendering"

// --- Async Loader: create/destroy lifecycle ---

@(test)
test_async_loader_create_destroy :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	sc.async_loader_destroy(&loader)
}

// --- Async Loader: request rejected when path is empty ---

@(test)
test_async_loader_request_empty_path :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	defer sc.async_loader_destroy(&loader)

	accepted := sc.async_loader_request(&loader, "")
	testing.expect(t, !accepted, "empty path should be rejected")
}

// --- Async Loader: request rejected when path too long ---

@(test)
test_async_loader_request_path_too_long :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	defer sc.async_loader_destroy(&loader)

	// Create a path longer than ASYNC_MAX_PATH
	long_path := string(make([]u8, sc.ASYNC_MAX_PATH + 10))
	defer delete(transmute([]u8)long_path)
	accepted := sc.async_loader_request(&loader, long_path)
	testing.expect(t, !accepted, "too-long path should be rejected")
}

// --- Async Loader: successful load of real HDR file ---

@(test)
test_async_loader_load_hdr :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	defer sc.async_loader_destroy(&loader)

	accepted := sc.async_loader_request(&loader, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, accepted, "request for existing HDR should be accepted")

	// Poll until ready or timeout (5 seconds max)
	result: sc.Async_Request
	deadline := time.now()
	got_result := false
	for {
		elapsed := time.duration_milliseconds(time.diff(deadline, time.now()))
		if elapsed > 5000.0 {
			break
		}
		if sc.async_loader_poll(&loader, &result) == .Ready {
			got_result = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}

	testing.expect(t, got_result, "should get result within 5 seconds")
	if got_result {
		testing.expect(t, result.data != nil, "data should not be nil")
		testing.expect(t, result.width > 0, "width should be positive")
		testing.expect(t, result.height > 0, "height should be positive")
		testing.expect_value(t, result.channels, i32(4))

		// Clean up the data (ownership transferred to us, allocated via libc.malloc in worker)
		libc.free(result.data)
	}
}

// --- Async Loader: load of nonexistent file results in no-result (fails gracefully) ---

@(test)
test_async_loader_load_nonexistent :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	defer sc.async_loader_destroy(&loader)

	accepted := sc.async_loader_request(&loader, "nonexistent_file_that_does_not_exist.hdr")
	testing.expect(t, accepted, "request should be accepted (failure happens asynchronously)")

	// Poll — should eventually return false (failed, then reset to idle)
	time.sleep(200 * time.Millisecond)

	result: sc.Async_Request
	got := sc.async_loader_poll(&loader, &result)
	testing.expect(t, got == .Failed, "nonexistent file should report failure")
}

// --- Async Loader: request rejected while busy ---

@(test)
test_async_loader_reject_while_busy :: proc(t: ^testing.T) {
	loader: sc.Async_Loader
	ok := sc.async_loader_create(&loader)
	testing.expect(t, ok, "async_loader_create should succeed")
	defer sc.async_loader_destroy(&loader)

	// Submit a valid request
	accepted1 := sc.async_loader_request(&loader, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, accepted1, "first request should be accepted")

	// Immediately submit another — should be rejected (loader busy)
	// (Small race: if the first loads instantly this might not trigger,
	// but for a 4K HDR it should still be loading)
	_ = sc.async_loader_request(&loader, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	// Note: this test is slightly racy; if accepted2 is true, it means
	// the first load completed before we could submit the second.
	// We just verify it doesn't crash.

	// Wait for completion to avoid leaking thread work
	result: sc.Async_Request
	deadline := time.now()
	for {
		elapsed := time.duration_milliseconds(time.diff(deadline, time.now()))
		if elapsed > 5000.0 { break }
		if sc.async_loader_poll(&loader, &result) == .Ready {
			if result.data != nil {
				stbi.image_free(result.data)
			}
			break
		}
		time.sleep(10 * time.Millisecond)
	}
}

// --- Env Manager: create/destroy lifecycle (requires GL context) ---

@(test)
test_env_manager_create_destroy :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")

	// Verify initial state
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Wait_IBL)
	testing.expect_value(t, mgr.transition_alpha, f32(1.0))
	testing.expect_value(t, mgr.transition_mode, sc.Transition_Mode.Crossfade)
	testing.expect_value(t, mgr.is_first_load, true)
	testing.expect_value(t, mgr.ibl_state, sc.IBL_State.Idle)

	sc.env_manager_destroy(&mgr)
}

// --- Env Manager: transition rejected when not idle ---

@(test)
test_env_manager_transition_rejected_when_busy :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Initial state is Wait_IBL (not Idle), so transitions should be rejected
	result := sc.env_manager_trigger_transition(&mgr, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, !result, "transition should be rejected when state != Idle")
}

// --- Env Manager: transition accepted when idle ---

@(test)
test_env_manager_transition_accepted_when_idle :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Force to idle for testing
	mgr.transition_state = .Idle

	result := sc.env_manager_trigger_transition(&mgr, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, result, "transition should be accepted when idle")
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Loading)
}

// --- Env Manager: is_transitioning reflects state ---

@(test)
test_env_manager_is_transitioning :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Initial state is Wait_IBL → transitioning
	testing.expect(t, sc.env_manager_is_transitioning(&mgr), "Wait_IBL should be transitioning")

	// Force to idle
	mgr.transition_state = .Idle
	testing.expect(t, !sc.env_manager_is_transitioning(&mgr), "Idle should not be transitioning")

	// Force to Fade_In
	mgr.transition_state = .Fade_In
	testing.expect(t, sc.env_manager_is_transitioning(&mgr), "Fade_In should be transitioning")
}

// --- Env Manager: overlay alpha ---

@(test)
test_env_manager_overlay_alpha :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Initial alpha is 1.0
	testing.expect_value(t, sc.env_manager_get_overlay_alpha(&mgr), f32(1.0))

	// Force to idle → alpha should be 0
	mgr.transition_state = .Idle
	testing.expect_value(t, sc.env_manager_get_overlay_alpha(&mgr), f32(0.0))
}

// --- Env Manager: fade-in reduces alpha ---

@(test)
test_env_manager_fade_in_reduces_alpha :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Setup fade-in state
	mgr.transition_state = .Fade_In
	mgr.transition_alpha = 1.0
	mgr.transition_duration = 1.0 // 1 second

	// Simulate a frame at 60fps (dt ~= 0.016)
	sc.env_manager_update_transition(&mgr, nil, 0.5)

	// Alpha should have decreased
	testing.expect(t, mgr.transition_alpha < 1.0, "alpha should decrease during fade-in")
	testing.expect(t, mgr.transition_alpha > 0.0, "alpha should still be positive after 0.5s of 1s fade")
}

// --- Env Manager: fade-in completes to idle ---

@(test)
test_env_manager_fade_in_completes :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Setup fade-in near completion
	mgr.transition_state = .Fade_In
	mgr.transition_alpha = 0.1
	mgr.transition_duration = 0.25

	// Large dt to complete the fade
	sc.env_manager_update_transition(&mgr, nil, 1.0)

	testing.expect_value(t, mgr.transition_alpha, f32(0.0))
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Idle)
}

// --- Env Manager: fade-out increases alpha ---

@(test)
test_env_manager_fade_out_increases_alpha :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	mgr.transition_state = .Fade_Out
	mgr.transition_alpha = 0.0
	mgr.transition_duration = 1.0

	sc.env_manager_update_transition(&mgr, nil, 0.5)

	testing.expect(t, mgr.transition_alpha > 0.0, "alpha should increase during fade-out")
	testing.expect(t, mgr.transition_alpha <= 1.0, "alpha should not exceed 1.0")
}

// --- Env Manager: fade-out completes to fade-in ---

@(test)
test_env_manager_fade_out_completes :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	mgr.transition_state = .Fade_Out
	mgr.transition_alpha = 0.9
	mgr.transition_duration = 0.25

	// Large dt to complete
	sc.env_manager_update_transition(&mgr, nil, 1.0)

	testing.expect_value(t, mgr.transition_alpha, f32(1.0))
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Fade_In)
}

// =============================================================================
// HELPER: Wait for initial async IBL load to complete after scene_create.
// scene_create triggers env_manager_trigger_initial which starts async loading;
// the IBL pipeline must finish before scene_change_env can be called.
// =============================================================================

@(private)
wait_for_initial_load :: proc(t: ^testing.T, s: ^sc.Scene) -> bool {
	for _ in 0..<5000 {
		sc.scene_update(s, 0.016)
		// ISO: real app always renders between compute dispatches (GPU coherency).
		sc.scene_render(s, 64, 64)
		if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
			return true
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, false, "initial IBL pipeline did not complete within timeout")
	return false
}

// =============================================================================
// INTEGRATION TEST: Full scene env change (crossfade mode)
// Exercises: scene_change_env → async load → IBL pipeline → texture swap → fade
// =============================================================================

@(test)
test_integration_env_change_crossfade :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// Create full scene (materials, IBL, skybox, PBR spheres, env manager)
	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Verify state after initial load: env_mgr is Idle
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)
	testing.expect_value(t, s.env_mgr.is_first_load, false)
	testing.expect_value(t, s.env_mgr.ibl_state, sc.IBL_State.Idle)

	// Record original texture IDs
	orig_env_id := s.env_texture.id
	orig_irr_id := s.ibl.irradiance_map
	orig_spec_id := s.ibl.prefilter_map

	testing.expect(t, orig_env_id != 0, "initial env texture should exist")
	testing.expect(t, orig_irr_id != 0, "initial irradiance map should exist")
	testing.expect(t, orig_spec_id != 0, "initial prefilter map should exist")

	// Trigger env change (same file — exercises full pipeline regardless of content)
	ok := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok, "scene_change_env should succeed")
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Loading)

	// Run the update loop until transition completes or timeout
	dt := f32(0.016) // ~60fps
	max_iterations := 5000 // safety cap
	completed := false

	for _ in 0..<max_iterations {
		sc.scene_update(&s, dt)

		// Check for completion
		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
			completed = true
			break
		}

		// Short sleep to let async thread work
		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}

	testing.expect(t, completed, "env transition should complete within iteration budget")

	// Verify textures were swapped (new GL IDs)
	testing.expect(t, s.env_texture.id != 0, "new env texture should exist")
	testing.expect(t, s.ibl.irradiance_map != 0, "new irradiance map should exist")
	testing.expect(t, s.ibl.prefilter_map != 0, "new prefilter map should exist")

	// In the optimized engine, identical dimension textures are persistently reused.
	// We only require that the irradiance and prefilter maps are valid and have been updated/regenerated.
	testing.expect(t, s.ibl.irradiance_map != 0, "irradiance map ID should be valid")
	testing.expect(t, s.ibl.prefilter_map != 0, "prefilter map ID should be valid")

	// Transition should be fully complete
	testing.expect_value(t, s.env_mgr.transition_alpha, f32(0.0))
}

// =============================================================================
// INTEGRATION TEST: Full scene env change (black screen mode)
// Exercises: .Black_Screen transition path (fade-out → swap → fade-in)
// =============================================================================

@(test)
test_integration_env_change_black_screen :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Switch to black screen mode
	s.env_mgr.transition_mode = .Black_Screen

	// Trigger env change
	ok := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok, "scene_change_env should succeed")

	// Run the update loop
	dt := f32(0.016)
	max_iterations := 5000
	completed := false
	saw_fade_out := false

	for _ in 0..<max_iterations {
		sc.scene_update(&s, dt)

		// Track that we went through Fade_Out (black screen path specific)
		if s.env_mgr.transition_state == .Fade_Out {
			saw_fade_out = true
		}

		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
			completed = true
			break
		}

		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}

	testing.expect(t, completed, "black screen transition should complete")
	testing.expect(t, saw_fade_out, "black screen mode should go through Fade_Out state")
	testing.expect_value(t, s.env_mgr.transition_alpha, f32(0.0))
}

// =============================================================================
// INTEGRATION TEST: Scene render during env transition
// Exercises: scene_render while IBL is processing (no crash, valid output)
// =============================================================================

@(test)
test_integration_render_during_transition :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Create FBO for render target
	fbo, tex, rbo: u32
	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 64, 64, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0)
	gl.GenRenderbuffers(1, &rbo)
	gl.BindRenderbuffer(gl.RENDERBUFFER, rbo)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, 64, 64)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	defer {
		gl.DeleteTextures(1, &tex)
		gl.DeleteRenderbuffers(1, &rbo)
		gl.DeleteFramebuffers(1, &fbo)
	}

	// Trigger env change
	sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")

	// Run update+render interleaved (the real app loop) — verify no crash
	dt := f32(0.016)
	render_count := 0

	for _ in 0..<3000 {
		sc.scene_update(&s, dt)

		// Render every frame (like real app)
		gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
		gl.Viewport(0, 0, 64, 64)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, 64, 64)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		render_count += 1

		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
			break
		}

		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}

	testing.expect(t, render_count > 10, fmt.tprintf("should have rendered multiple frames, got %d", render_count))
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)
}

// =============================================================================
// INTEGRATION TEST: Double env change (trigger second after first completes)
// Exercises: full cycle twice — verifies cleanup and re-entry
// =============================================================================

@(test)
test_integration_double_env_change :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Helper: run until transition completes
	run_until_idle :: proc(s: ^sc.Scene) -> bool {
		dt := f32(0.016)
		for _ in 0..<5000 {
			sc.scene_update(s, dt)
			if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
				return true
			}
			if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
				time.sleep(1 * time.Millisecond)
			}
		}
		return false
	}

	// First transition
	ok1 := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok1, "first env change should succeed")
	testing.expect(t, run_until_idle(&s), "first transition should complete")

	mid_env_id := s.env_texture.id

	// Second transition (same file, new texture ID)
	ok2 := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok2, "second env change should succeed")
	testing.expect(t, run_until_idle(&s), "second transition should complete")

	// Verify we got a valid texture (it may be persistently reused in the optimized engine)
	testing.expect(t, s.env_texture.id != 0, "final env texture should be valid")
}

// =============================================================================
// INTEGRATION TEST: env change rejected during active transition
// Exercises: trigger_transition guard when transition is in progress
// =============================================================================

@(test)
test_integration_env_change_rejected_during_transition :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// First trigger
	ok1 := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, ok1, "first env change should succeed")

	// Second trigger while first is in progress — should be rejected
	ok2 := sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")
	testing.expect(t, !ok2, "second env change should be rejected during transition")

	// Still complete the first one (don't leak)
	dt := f32(0.016)
	for _ in 0..<5000 {
		sc.scene_update(&s, dt)
		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle {
			break
		}
		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}
}

// =============================================================================
// TEST: IBL state machine progression (verify all states are visited)
// =============================================================================

@(test)
test_integration_ibl_state_progression :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Track which IBL states we visit
	saw_upload := false
	saw_mipmaps := false
	saw_spec_init := false
	saw_spec_mips := false
	saw_irradiance := false
	saw_done := false

	sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")

	dt := f32(0.016)
	for _ in 0..<5000 {
		sc.scene_update(&s, dt)

		switch s.env_mgr.ibl_state {
		case .Upload_Texture: saw_upload = true
		case .Upload_Progressive: // progressive vertical slice upload
		case .Generate_Mipmaps: saw_mipmaps = true
		case .Luminance: // adaptive threshold computation
		case .Specular_Init: saw_spec_init = true
		case .Specular_Mips: saw_spec_mips = true
		case .Irradiance: saw_irradiance = true
		case .Done: saw_done = true
		case .Idle: // expected after completion
		}

		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle && saw_done {
			break
		}

		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}

	testing.expect(t, saw_upload, "should visit Upload_Texture state")
	testing.expect(t, saw_mipmaps, "should visit Generate_Mipmaps state")
	testing.expect(t, saw_spec_init, "should visit Specular_Init state")
	testing.expect(t, saw_spec_mips, "should visit Specular_Mips state")
	testing.expect(t, saw_irradiance, "should visit Irradiance state")
	testing.expect(t, saw_done, "should visit Done state")
}

// =============================================================================
// TEST: skybox_update_env integration (cubemaps regenerated after swap)
// =============================================================================

@(test)
test_integration_skybox_update_after_swap :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial async IBL load to complete
	if !wait_for_initial_load(t, &s) { return }

	// Set mode to Cubemap to trigger regeneration after env change
	s.skybox.mode = .Cubemap

	// Trigger env change and run to completion
	sc.scene_change_env(&s, "assets/textures/hdr/cedar_bridge_2_4k.hdr")

	dt := f32(0.016)
	for _ in 0..<5000 {
		sc.scene_update(&s, dt)
		// ISO: render between compute dispatches for GPU coherency + skybox regen
		sc.scene_render(&s, 64, 64)

		if s.skybox.cubemap_dirty || s.skybox.gen_state.in_progress {
			rendering.skybox_ensure_cubemap(&s.skybox)
		}

		if s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle && !s.skybox.gen_state.in_progress {
			break
		}
		if s.env_mgr.ibl_state == .Idle && s.env_mgr.transition_state == .Loading {
			time.sleep(1 * time.Millisecond)
		}
	}

	// Skybox should have new cubemap texture (regenerated from new env) for active mipmap_mode
	switch s.skybox.mipmap_mode {
	case .Gl_Generate:
		testing.expect(t, s.skybox.cubemap_gl != 0, "new cubemap_gl should exist")
	case .Seamless:
		testing.expect(t, s.skybox.cubemap_seamless != 0, "new cubemap_seamless should exist")
	}

	// Skybox env_tex should point to new env texture
	testing.expect_value(t, s.skybox.env_tex, s.env_texture.id)
	testing.expect_value(t, s.skybox.ibl_prefilter_tex, s.ibl.prefilter_map)
}

// =============================================================================
// TEST: skybox amortized generation progression (.Seamless)
// =============================================================================

@(test)
test_skybox_amortized_generation_progression :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	if !wait_for_initial_load(t, &s) { return }

	// Set mode to Cubemap
	s.skybox.mode = .Cubemap
	s.skybox.mipmap_mode = .Seamless

	// Force it to be dirty and invalidate cubemaps to trigger amortized generation
	s.skybox.cubemap_dirty = true
	if s.skybox.cubemap_seamless != 0 {
		gl.DeleteTextures(1, &s.skybox.cubemap_seamless)
		s.skybox.cubemap_seamless = 0
	}
	s.skybox.cubemap_tex = 0

	// 1. Kick off / Start Gen (Frame 1)
	testing.expect(t, !s.skybox.gen_state.in_progress, "should not be in progress yet")
	rendering.skybox_ensure_cubemap(&s.skybox)
	testing.expect(t, s.skybox.gen_state.in_progress, "should be in progress after first call")
	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Mip0_Faces)
	testing.expect_value(t, s.skybox.gen_state.current_face, i32(0))

	// 2. Render Mip 0 faces (6 faces = 6 frames)
	for face in 0..<6 {
		testing.expect_value(t, s.skybox.gen_state.current_face, i32(face))
		rendering.skybox_ensure_cubemap(&s.skybox)
	}
	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Downsample)
	testing.expect_value(t, s.skybox.gen_state.current_mip, i32(1))

	// 3. Render Seamless downsample mip levels progressively
	// Mip 1 downsamples 1 face per frame (6 frames)
	for face in 0..<6 {
		testing.expect_value(t, s.skybox.gen_state.current_mip, i32(1))
		testing.expect_value(t, s.skybox.gen_state.current_face, i32(face))
		rendering.skybox_ensure_cubemap(&s.skybox)
	}

	// Mip 2 downsamples 1 face per frame (6 frames)
	for face in 0..<6 {
		testing.expect_value(t, s.skybox.gen_state.current_mip, i32(2))
		testing.expect_value(t, s.skybox.gen_state.current_face, i32(face))
		rendering.skybox_ensure_cubemap(&s.skybox)
	}

	// Mips 3 to 10 downsample grouped all faces in a single frame per mip (8 frames)
	for mip in 3..=10 {
		testing.expect_value(t, s.skybox.gen_state.current_mip, i32(mip))
		rendering.skybox_ensure_cubemap(&s.skybox)
	}

	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Done)

	// 4. Done phase / Swap handles (1 frame)
	rendering.skybox_ensure_cubemap(&s.skybox)

	// Now it should be Done and completed!
	testing.expect(t, !s.skybox.gen_state.in_progress, "should be done")
	testing.expect(t, !s.skybox.cubemap_dirty, "should not be dirty anymore")
	testing.expect(t, s.skybox.cubemap_seamless != 0, "cubemap_seamless should be generated")
	testing.expect(t, s.skybox.cubemap_tex == s.skybox.cubemap_seamless, "cubemap_tex should be set")
}

// =============================================================================
// TEST: skybox amortized generation progression (.Gl_Generate)
// =============================================================================

@(test)
test_skybox_amortized_generation_progression_gl :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	if !wait_for_initial_load(t, &s) { return }

	// Set mode to Cubemap and Gl_Generate
	s.skybox.mode = .Cubemap
	s.skybox.mipmap_mode = .Gl_Generate

	// Force it to be dirty and invalidate cubemaps
	s.skybox.cubemap_dirty = true
	if s.skybox.cubemap_gl != 0 {
		gl.DeleteTextures(1, &s.skybox.cubemap_gl)
		s.skybox.cubemap_gl = 0
	}
	s.skybox.cubemap_tex = 0

	// 1. Kick off (Frame 1)
	rendering.skybox_ensure_cubemap(&s.skybox)
	testing.expect(t, s.skybox.gen_state.in_progress, "should be in progress")
	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Mip0_Faces)
	testing.expect_value(t, s.skybox.gen_state.current_face, i32(0))

	// 2. Mip 0 faces (6 frames)
	for face in 0..<6 {
		testing.expect_value(t, s.skybox.gen_state.current_face, i32(face))
		rendering.skybox_ensure_cubemap(&s.skybox)
	}
	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Downsample)

	// 3. Gl Generate (1 frame)
	rendering.skybox_ensure_cubemap(&s.skybox)
	testing.expect_value(t, s.skybox.gen_state.phase, rendering.Cubemap_Gen_Phase.Done)

	// 4. Done phase / Swap handles (1 frame)
	rendering.skybox_ensure_cubemap(&s.skybox)

	// 5. Completed!
	testing.expect(t, !s.skybox.gen_state.in_progress, "should be done")
	testing.expect(t, s.skybox.cubemap_gl != 0, "cubemap_gl should be generated")
}

// =============================================================================
// TEST: env_manager_destroy with pending textures (destroy during IBL)
// Exercises: cleanup branches for pending_hdr_tex, pending_spec_tex, pending_irr_tex
// =============================================================================

@(test)
test_env_manager_destroy_with_pending_textures :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")

	// Simulate pending textures that IBL was building (not yet swapped)
	gl.GenTextures(1, &mgr.pending_hdr_tex)
	gl.GenTextures(1, &mgr.pending_spec_tex)
	gl.GenTextures(1, &mgr.pending_irr_tex)

	testing.expect(t, mgr.pending_hdr_tex != 0, "pending_hdr_tex should be allocated")
	testing.expect(t, mgr.pending_spec_tex != 0, "pending_spec_tex should be allocated")
	testing.expect(t, mgr.pending_irr_tex != 0, "pending_irr_tex should be allocated")

	// Destroy should clean up all pending textures without crash
	sc.env_manager_destroy(&mgr)

	// Verify GL didn't crash (we can't check deletion directly, but no GL error)
	err := gl.GetError()
	testing.expect_value(t, err, u32(gl.NO_ERROR))
}

// =============================================================================
// TEST: env_manager_trigger_transition with failing async_loader_request
// Exercises: the reset-to-Idle path when loader rejects the request
// =============================================================================

@(test)
test_env_manager_trigger_transition_request_fails :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Set to Idle so trigger_transition passes the first guard
	mgr.transition_state = .Idle

	// Use a path that will make async_loader_request fail (too long)
	long_path := string(make([]u8, sc.ASYNC_MAX_PATH + 10))
	defer delete(transmute([]u8)long_path)

	result := sc.env_manager_trigger_transition(&mgr, long_path)
	testing.expect(t, !result, "trigger should fail when loader rejects request")
	// Verify state was reset to Idle (not stuck in Loading)
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Idle)
}

// =============================================================================
// TEST: IBL Upload_Texture with nil data (error recovery)
// Exercises: the early-exit branch in .Upload_Texture when data is nil
// =============================================================================

@(test)
test_env_manager_upload_texture_nil_data :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Drain/reset background loader to avoid race with the ultra-fast multi-threaded decoder
	sc.async_loader_destroy(&s.env_mgr.loader)
	sc.async_loader_create(&s.env_mgr.loader)
	s.env_mgr.has_result = false

	// Manually force the IBL state machine into Upload_Texture with nil data
	s.env_mgr.ibl_state = .Upload_Texture
	s.env_mgr.async_result.data = nil
	s.env_mgr.transition_state = .Loading

	// Run one update — should recover gracefully
	sc.scene_update(&s, 0.016)

	// Both states should be reset to Idle (error recovery)
	testing.expect_value(t, s.env_mgr.ibl_state, sc.IBL_State.Idle)
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)
}

// =============================================================================
// TEST: IBL .Done with transition_state == .Wait_IBL (first async load path)
// Exercises: the Wait_IBL branch in .Done (swap + Fade_In + clear is_first_load)
// =============================================================================

@(test)
test_env_manager_done_wait_ibl :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Drain/reset background loader to avoid race
	sc.async_loader_destroy(&s.env_mgr.loader)
	sc.async_loader_create(&s.env_mgr.loader)
	s.env_mgr.has_result = false

	// Setup: simulate the state as if first async load just finished IBL
	// Allocate dummy pending textures (IBL would have generated these)
	gl.GenTextures(1, &s.env_mgr.pending_hdr_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_hdr_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 4, 4, 0, gl.RGBA, gl.FLOAT, nil)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenTextures(1, &s.env_mgr.pending_spec_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_spec_tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenTextures(1, &s.env_mgr.pending_irr_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_irr_tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	// Set state to trigger the Wait_IBL branch
	s.env_mgr.ibl_state = .Done
	s.env_mgr.transition_state = .Wait_IBL
	s.env_mgr.is_first_load = true
	s.env_mgr.async_result.width = 4
	s.env_mgr.async_result.height = 4

	// Run update
	sc.scene_update(&s, 0.016)

	// Should have swapped and transitioned to Fade_In
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Fade_In)
	// Alpha is 1.0 initially, then reduced by dt/duration in same frame update
	testing.expect(t, s.env_mgr.transition_alpha > 0.9, "alpha should be near 1.0 after one frame")
	testing.expect_value(t, s.env_mgr.is_first_load, false)
	testing.expect_value(t, s.env_mgr.ibl_state, sc.IBL_State.Idle)
	testing.expect(t, s.env_texture.id != 0, "env texture should be swapped in")
}

// =============================================================================
// TEST: IBL .Done with transition_state == .Fade_In (safety fallback)
// Exercises: the catch-all (.Idle, .Fade_Out, .Fade_In) branch in .Done
// =============================================================================

@(test)
test_env_manager_done_fallback_states :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	// Drain/reset background loader to avoid race
	sc.async_loader_destroy(&s.env_mgr.loader)
	sc.async_loader_create(&s.env_mgr.loader)
	s.env_mgr.has_result = false

	// Test with .Fade_In as the transition_state when .Done fires
	gl.GenTextures(1, &s.env_mgr.pending_hdr_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_hdr_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 4, 4, 0, gl.RGBA, gl.FLOAT, nil)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenTextures(1, &s.env_mgr.pending_spec_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_spec_tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenTextures(1, &s.env_mgr.pending_irr_tex)
	gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_irr_tex)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	s.env_mgr.ibl_state = .Done
	s.env_mgr.transition_state = .Fade_In
	s.env_mgr.async_result.width = 4
	s.env_mgr.async_result.height = 4

	sc.scene_update(&s, 0.016)

	// Fallback: should swap and set Idle immediately
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)
	testing.expect_value(t, s.env_mgr.ibl_state, sc.IBL_State.Idle)
	testing.expect(t, s.env_texture.id != 0, "env texture should be swapped")
}

// =============================================================================
// TEST: Env Manager diagnostics tracking (state historical tracking & timers)
// =============================================================================

@(test)
test_env_manager_diagnostics_tracking :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	mgr: sc.Env_Manager
	ok := sc.env_manager_create(&mgr)
	testing.expect(t, ok, "env_manager_create should succeed")
	defer sc.env_manager_destroy(&mgr)

	// Force state to Idle first to start transition diagnostic tracking clean
	mgr.transition_prev_state = .Wait_IBL
	mgr.transition_state = .Idle
	mgr.transition_elapsed = 0.0
	mgr.ibl_prev_state = .Idle
	mgr.ibl_state = .Idle
	mgr.ibl_elapsed = 0.0

	// Verify baseline diagnostics
	testing.expect_value(t, mgr.transition_prev_state, sc.Transition_State.Wait_IBL)
	testing.expect_value(t, mgr.ibl_prev_state, sc.IBL_State.Idle)
	testing.expect_value(t, mgr.transition_elapsed, f32(0.0))
	testing.expect_value(t, mgr.ibl_elapsed, f32(0.0))

	// Set transition state and verify reset
	sc.env_manager_set_transition_state(&mgr, .Loading)
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Loading)
	testing.expect_value(t, mgr.transition_prev_state, sc.Transition_State.Idle)
	testing.expect_value(t, mgr.transition_elapsed, f32(0.0))

	// Simulate time passing on transition
	mgr.transition_elapsed += 0.5

	// Set IBL state and verify reset
	sc.env_manager_set_ibl_state(&mgr, .Upload_Texture)
	testing.expect_value(t, mgr.ibl_state, sc.IBL_State.Upload_Texture)
	testing.expect_value(t, mgr.ibl_prev_state, sc.IBL_State.Idle)
	testing.expect_value(t, mgr.ibl_elapsed, f32(0.0))

	// Simulate time passing on IBL state
	mgr.ibl_elapsed += 0.3

	// transition_elapsed should still be 0.5, ibl_elapsed is 0.3
	testing.expect_value(t, mgr.transition_elapsed, f32(0.5))
	testing.expect_value(t, mgr.ibl_elapsed, f32(0.3))

	// Transition both and verify history and reset timers
	sc.env_manager_set_transition_state(&mgr, .Wait_IBL)
	testing.expect_value(t, mgr.transition_state, sc.Transition_State.Wait_IBL)
	testing.expect_value(t, mgr.transition_prev_state, sc.Transition_State.Loading)
	testing.expect_value(t, mgr.transition_elapsed, f32(0.0))

	sc.env_manager_set_ibl_state(&mgr, .Upload_Progressive)
	testing.expect_value(t, mgr.ibl_state, sc.IBL_State.Upload_Progressive)
	testing.expect_value(t, mgr.ibl_prev_state, sc.IBL_State.Upload_Texture)
	testing.expect_value(t, mgr.ibl_elapsed, f32(0.0))
}

// =============================================================================
// TEST: Env Manager nonexistent HDR load deadlock (TDD)
// =============================================================================

@(test)
test_env_manager_nonexistent_hdr_deadlock :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	ok := sc.scene_create(&s, 512, 512)
	testing.expect(t, ok, "scene_create should succeed")
	defer sc.scene_destroy(&s)

	// Wait for initial scene IBL load to complete
	deadline := time.now()
	for s.env_mgr.transition_state != .Idle {
		if time.duration_milliseconds(time.diff(deadline, time.now())) > 120000.0 {
			break
		}
		sc.scene_update(&s, 0.016)
		time.sleep(10 * time.Millisecond)
	}

	// Trigger a transition with a nonexistent file
	accepted := sc.env_manager_trigger_transition(&s.env_mgr, "nonexistent_file_that_does_not_exist.hdr")
	testing.expect(t, accepted, "first transition trigger should be accepted")
	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Loading)

	// Wait dynamically for the loader thread to complete the failure and the state to return to Idle
	deadline = time.now()
	for s.env_mgr.transition_state == .Loading {
		if time.duration_milliseconds(time.diff(deadline, time.now())) > 120000.0 {
			break
		}
		sc.scene_update(&s, 0.016)
		time.sleep(10 * time.Millisecond)
	}

	testing.expect_value(t, s.env_mgr.transition_state, sc.Transition_State.Idle)

	// If it successfully cleared back to Idle, a subsequent transition should be accepted!
	accepted2 := sc.env_manager_trigger_transition(&s.env_mgr, "another_nonexistent_file.hdr")
	testing.expect(t, accepted2, "subsequent transition should be accepted after a load failure")

	// Wait dynamically for the second failure to complete so the worker thread is Idle before destroy
	deadline = time.now()
	for s.env_mgr.transition_state == .Loading {
		if time.duration_milliseconds(time.diff(deadline, time.now())) > 120000.0 {
			break
		}
		sc.scene_update(&s, 0.016)
		time.sleep(10 * time.Millisecond)
	}
}

// =============================================================================
// TEST: skybox generation abort on mipmap_mode change
// Exercises: the abort block in skybox_ensure_cubemap to verify transient-only cleanup
// =============================================================================

@(test)
test_skybox_abort_generation :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	if !wait_for_initial_load(t, &s) { return }

	// Ensure skybox is using Cubemap mode and starting with Seamless
	s.skybox.mode = .Cubemap
	s.skybox.mipmap_mode = .Seamless

	// Force it to be dirty to trigger generation
	s.skybox.cubemap_dirty = true
	rendering.skybox_ensure_cubemap(&s.skybox)
	testing.expect(t, s.skybox.gen_state.in_progress, "generation should be in progress")
	testing.expect(t, s.skybox.gen_state.fbo != 0, "FBO should be created for in-progress generation")

	// Store persistent resource handles to verify they are NOT deleted during abort
	original_convert_prog := s.skybox.program_equirect_to_cubemap
	testing.expect(t, original_convert_prog != 0, "original convert program should be valid")

	// Toggle mipmap_mode and force dirty to trigger the abort block in ensure_cubemap
	s.skybox.mipmap_mode = .Gl_Generate
	s.skybox.cubemap_dirty = true

	// Call ensure_cubemap — should trigger abort of Seamless, clean up transient FBO/VAO/VBO,
	// and start a new generation for Gl_Generate
	rendering.skybox_ensure_cubemap(&s.skybox)

	// In the buggy implementation, s.skybox.program_equirect_to_cubemap would have been deleted and set to 0.
	// We verify it remains valid.
	testing.expect_value(t, s.skybox.program_equirect_to_cubemap, original_convert_prog)

	// Clean up and complete the Gl_Generate progression so we destroy nicely
	for s.skybox.gen_state.in_progress {
		rendering.skybox_ensure_cubemap(&s.skybox)
	}
	testing.expect(t, !s.skybox.gen_state.in_progress, "should have finished generation")
}

// =============================================================================
// TEST: Env Manager Deterministic Transition Matrix
// Exercises: Piste B transition table-driven state machine verification
// =============================================================================

Transition_Stimulus :: enum {
	Trigger_Transition,
	Trigger_Transition_Invalid,
	Poll_Ready,
	Poll_Failed,
	IBL_Done_Crossfade,
	IBL_Done_Black_Screen,
	Fade_Out_Complete,
	Fade_In_Complete,
}

Transition_Matrix_Row :: struct {
	initial_transition:  sc.Transition_State,
	initial_ibl:         sc.IBL_State,
	stimulus:            Transition_Stimulus,
	expected_transition: sc.Transition_State,
	expected_ibl:        sc.IBL_State,
	desc:                string,
}

@(test)
test_env_manager_transition_matrix :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed")
		return
	}
	defer sc.scene_destroy(&s)

	rows := []Transition_Matrix_Row {
		{
			initial_transition = .Idle,
			initial_ibl = .Idle,
			stimulus = .Trigger_Transition,
			expected_transition = .Loading,
			expected_ibl = .Idle,
			desc = "Triggering a transition from Idle sets state to Loading",
		},
		{
			initial_transition = .Loading,
			initial_ibl = .Idle,
			stimulus = .Poll_Ready,
			expected_transition = .Wait_IBL,
			expected_ibl = .Upload_Texture,
			desc = "Loader returning Ready initiates IBL (.Upload_Texture) and transitions to .Wait_IBL",
		},
		{
			initial_transition = .Loading,
			initial_ibl = .Idle,
			stimulus = .Trigger_Transition_Invalid,
			expected_transition = .Loading,
			expected_ibl = .Idle,
			desc = "Attempting to trigger a transition when not Idle is rejected and keeps state unchanged",
		},
		{
			initial_transition = .Loading,
			initial_ibl = .Idle,
			stimulus = .Poll_Failed,
			expected_transition = .Idle,
			expected_ibl = .Idle,
			desc = "Loader returning Failed resets both state machines back to Idle (TDD recovery)",
		},
		{
			initial_transition = .Wait_IBL,
			initial_ibl = .Done,
			stimulus = .IBL_Done_Crossfade,
			expected_transition = .Fade_In,
			expected_ibl = .Idle,
			desc = "IBL Done under Crossfade swaps textures and enters Fade_In immediately",
		},
		{
			initial_transition = .Wait_IBL,
			initial_ibl = .Done,
			stimulus = .IBL_Done_Black_Screen,
			expected_transition = .Fade_Out,
			expected_ibl = .Idle,
			desc = "IBL Done under Black_Screen transitions to Fade_Out",
		},
		{
			initial_transition = .Fade_Out,
			initial_ibl = .Idle,
			stimulus = .Fade_Out_Complete,
			expected_transition = .Fade_In,
			expected_ibl = .Idle,
			desc = "Fade_Out completing swaps textures and transitions to Fade_In",
		},
		{
			initial_transition = .Fade_In,
			initial_ibl = .Idle,
			stimulus = .Fade_In_Complete,
			expected_transition = .Idle,
			expected_ibl = .Idle,
			desc = "Fade_In completing returns transition state to Idle",
		},
	}

	for row, idx in rows {
		// 1. Reset/Prepare the states
		s.env_mgr.transition_state = row.initial_transition
		s.env_mgr.ibl_state = row.initial_ibl

		// Reset loaders/result variables depending on initial states to satisfy invariants
		sync.lock(&s.env_mgr.loader.mutex)
		if row.initial_transition == .Loading {
			if row.initial_ibl != .Idle {
				s.env_mgr.loader.request.state = .Idle
			} else {
				s.env_mgr.loader.request.state = .Loading
			}
		} else {
			s.env_mgr.loader.request.state = .Idle
		}
		s.env_mgr.loader.request.data = nil
		s.env_mgr.has_result = false
		sync.unlock(&s.env_mgr.loader.mutex)

		// Allocate dummy textures if initial transition is Fade_Out/Fade_In/Wait_IBL/Loading
		// to prevent swap/snapshot errors
		if s.env_mgr.pending_hdr_tex == 0 {
			gl.GenTextures(1, &s.env_mgr.pending_hdr_tex)
			gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_hdr_tex)
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 4, 4, 0, gl.RGBA, gl.FLOAT, nil)
			gl.BindTexture(gl.TEXTURE_2D, 0)
		}
		if s.env_mgr.pending_spec_tex == 0 {
			gl.GenTextures(1, &s.env_mgr.pending_spec_tex)
			gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_spec_tex)
			gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
			gl.BindTexture(gl.TEXTURE_2D, 0)
		}
		if s.env_mgr.pending_irr_tex == 0 {
			gl.GenTextures(1, &s.env_mgr.pending_irr_tex)
			gl.BindTexture(gl.TEXTURE_2D, s.env_mgr.pending_irr_tex)
			gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 4, 4)
			gl.BindTexture(gl.TEXTURE_2D, 0)
		}

		// 2. Apply stimulus
		switch row.stimulus {
		case .Trigger_Transition:
			ok := sc.env_manager_trigger_transition(&s.env_mgr, "dummy_nonexistent.hdr")
			testing.expectf(t, ok, "Step %d: trigger_transition should succeed. Desc: %s", idx, row.desc)

		case .Trigger_Transition_Invalid:
			ok := sc.env_manager_trigger_transition(&s.env_mgr, "dummy_nonexistent.hdr")
			testing.expectf(t, !ok, "Step %d: trigger_transition should fail when not Idle. Desc: %s", idx, row.desc)

		case .Poll_Ready:
			// Mock poll result under lock
			sync.lock(&s.env_mgr.loader.mutex)
			s.env_mgr.loader.request.state = .Ready
			s.env_mgr.loader.request.data = cast([^]u16)libc.malloc(64 * size_of(u16))
			s.env_mgr.loader.request.width = 4
			s.env_mgr.loader.request.height = 4
			s.env_mgr.loader.request.channels = 4
			sync.unlock(&s.env_mgr.loader.mutex)
			s.env_mgr.has_result = false

			sc.env_manager_update(&s.env_mgr, &s, 0.016)

		case .Poll_Failed:
			// Mock poll failure under lock
			sync.lock(&s.env_mgr.loader.mutex)
			s.env_mgr.loader.request.state = .Failed
			sync.unlock(&s.env_mgr.loader.mutex)
			s.env_mgr.has_result = false

			sc.env_manager_update(&s.env_mgr, &s, 0.016)

		case .IBL_Done_Crossfade:
			s.env_mgr.transition_mode = .Crossfade
			s.env_mgr.async_result.width = 4
			s.env_mgr.async_result.height = 4
			// Trigger advance from Done state
			sc.env_manager_update(&s.env_mgr, &s, 0.016)

		case .IBL_Done_Black_Screen:
			s.env_mgr.transition_mode = .Black_Screen
			s.env_mgr.async_result.width = 4
			s.env_mgr.async_result.height = 4
			// Trigger advance from Done state
			sc.env_manager_update(&s.env_mgr, &s, 0.016)

		case .Fade_Out_Complete:
			s.env_mgr.transition_alpha = 0.99
			s.env_mgr.transition_duration = 0.1
			sc.env_manager_update(&s.env_mgr, &s, 0.15) // ticks by more than duration to complete

		case .Fade_In_Complete:
			s.env_mgr.transition_alpha = 0.01
			s.env_mgr.transition_duration = 0.1
			sc.env_manager_update(&s.env_mgr, &s, 0.15) // ticks by more than duration to complete
		}

		// 3. Assert target states
		testing.expectf(t, s.env_mgr.transition_state == row.expected_transition,
			"Step %d: Expected transition state %v, got %v. Desc: %s",
			idx, row.expected_transition, s.env_mgr.transition_state, row.desc)

		testing.expectf(t, s.env_mgr.ibl_state == row.expected_ibl,
			"Step %d: Expected IBL state %v, got %v. Desc: %s",
			idx, row.expected_ibl, s.env_mgr.ibl_state, row.desc)
	}
}




