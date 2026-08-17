// +build test
// Temporal chaos fuzzer and concurrent stress test suite.
// Validates thread-safety, race conditions, memory safety,
// and state machine recovery under intensive, randomized transition triggers.
//
// Enabled ONLY via: just test-chaos (passes -define:CHAOS_STRESS=true)
package test_gl

import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"
import "core:math/rand"
import gl "vendor:OpenGL"

import sc "../../src/scene"

Chaos_Data :: struct {
	mgr:         ^sc.Env_Manager,
	should_stop: bool,
	mutex:       sync.Mutex,
}

chaos_worker_proc :: proc(thread_handle: ^thread.Thread) {
	data := (^Chaos_Data)(thread_handle.data)

	// List of test maps: 5 valid HDR assets, 1 nonexistent path (failure recovery),
	// 1 empty path, and 1 extremely long path (bounds checking).
	paths := [8]string{
		"assets/textures/hdr/abandoned_garage_4k.hdr",
		"assets/textures/hdr/cedar_bridge_2_4k.hdr",
		"assets/textures/hdr/neon_photostudio_4k.hdr",
		"assets/textures/hdr/river_alcove_4k.hdr",
		"assets/textures/hdr/small_cathedral_02_4k.hdr",
		"assets/textures/hdr/nonexistent_file_xyz_123.hdr",
		"",
		"a_very_long_path_to_trigger_buffer_and_path_bounds_checking_assertions_and_graceful_failures_in_the_async_loader_pipeline_without_causing_deadlocks_or_segmentation_faults_or_leaking_any_unmanaged_heap_resources.hdr",
	}

	for {
		// Thread-safe check for termination signal
		sync.lock(&data.mutex)
		stop := data.should_stop
		sync.unlock(&data.mutex)
		if stop { break }

		// Select a random environment path from the fuzzer pool
		idx := rand.int_max(len(paths))
		path := paths[idx]

		// Random sleep between 1ms and 15ms to desynchronize thread execution cycles
		sleep_ms := rand.int_max(15) + 1
		time.sleep(time.Duration(sleep_ms) * time.Millisecond)

		// Fire concurrent transition request
		sc.env_manager_trigger_transition(data.mgr, path)
	}
}

@(test)
test_env_manager_chaos_stress :: proc(t: ^testing.T) {
	// Compiler-level guard to bypass this long concurrent stress-test
	// during normal test suite execution ('just test')
	CHAOS_STRESS :: #config(CHAOS_STRESS, false)
	when !CHAOS_STRESS {
		return
	}

	if !ensure_gl_context(t) { return }

	s: sc.Scene
	if !sc.scene_create(&s, 64, 64) {
		testing.expect(t, false, "scene_create failed to initialize context")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for initial scene IBL load to complete dynamically and cleanly
	deadline := time.now()
	for s.env_mgr.transition_state != .Idle {
		if time.duration_milliseconds(time.diff(deadline, time.now())) > 120000.0 {
			break
		}
		sc.scene_update(&s, 0.016)
		time.sleep(10 * time.Millisecond)
	}

	data := Chaos_Data{
		mgr         = &s.env_mgr,
		should_stop = false,
	}

	// Create and start fuzzer background thread
	worker := thread.create(chaos_worker_proc)
	if worker == nil {
		testing.expect(t, false, "Failed to instantiate concurrent fuzzer thread")
		return
	}
	worker.data = &data
	thread.start(worker)

	// Stress loop: tick the environment manager at high frequency for 5.0 seconds
	start_time := time.now()
	for {
		elapsed := time.since(start_time)
		if time.duration_seconds(elapsed) >= 5.0 {
			break
		}

		// Update transition and IBL pipeline (ticks standard frame logic)
		sc.env_manager_update(&s.env_mgr, &s, 0.016)

		// Check for active OpenGL pipeline errors
		err := gl.GetError()
		if err != gl.NO_ERROR {
			testing.expectf(t, false, "OpenGL driver reported pipeline error %d during fuzzer execution", err)
			break
		}

		// Control loop cycle rate to prevent CPU cores overloading
		time.sleep(1 * time.Millisecond)
	}

	// Signal fuzzer worker thread to terminate and join
	sync.lock(&data.mutex)
	data.should_stop = true
	sync.unlock(&data.mutex)

	thread.join(worker)
	thread.destroy(worker)

	// Post-chaos recovery phase: let the manager drain any remaining active transition
	// and assert that it correctly recovers back to the stable Idle baseline.
	settled := false
	drain_start := time.now()
	for time.duration_seconds(time.since(drain_start)) < 120.0 {
		sc.env_manager_update(&s.env_mgr, &s, 0.016)

		sync.lock(&s.env_mgr.loader.mutex)
		is_idle := s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle
		sync.unlock(&s.env_mgr.loader.mutex)

		if is_idle {
			settled = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}

	testing.expect(t, settled, "State machine failed to recover and settle to .Idle after fuzzer completion")
}
