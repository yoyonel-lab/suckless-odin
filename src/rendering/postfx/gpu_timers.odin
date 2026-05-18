package postfx

import gl "vendor:OpenGL"

// GPU timer queries for per-pass profiling.
// Uses GL_TIME_ELAPSED queries with double-buffering to avoid stalls.

NUM_TIMER_PASSES :: 3 // bloom, composite, total

Timer_Pass :: enum {
	Bloom,
	Composite,
	Total,
}

TIMER_PASS_NAMES :: [Timer_Pass]string{
	.Bloom     = "Bloom",
	.Composite = "Composite",
	.Total     = "Total",
}

// Double-buffered query objects (read frame N-1 while writing frame N).
Gpu_Timers :: struct {
	queries:      [2][NUM_TIMER_PASSES]u32, // [front/back][pass]
	results_ns:   [NUM_TIMER_PASSES]u64,    // last completed results (nanoseconds)
	results_ms:   [NUM_TIMER_PASSES]f32,    // last completed results (milliseconds)
	current_buf:  i32,                      // 0 or 1 (ping-pong)
	frame_count:  u32,                      // skip first frame (no results yet)
	enabled:      bool,
}

// Create timer query objects.
gpu_timers_create :: proc(t: ^Gpu_Timers) {
	for buf in 0 ..< 2 {
		gl.GenQueries(NUM_TIMER_PASSES, raw_data(&t.queries[buf]))
	}
	t.enabled = true
	t.frame_count = 0
	t.current_buf = 0

	// Issue dummy queries on both buffers to initialize them
	for buf in 0 ..< 2 {
		for pass in 0 ..< NUM_TIMER_PASSES {
			gl.BeginQuery(gl.TIME_ELAPSED, t.queries[buf][pass])
			gl.EndQuery(gl.TIME_ELAPSED)
		}
	}
}

// Destroy timer query objects.
gpu_timers_destroy :: proc(t: ^Gpu_Timers) {
	for buf in 0 ..< 2 {
		gl.DeleteQueries(NUM_TIMER_PASSES, raw_data(&t.queries[buf]))
	}
}

// Begin timing a pass (call before the pass).
gpu_timer_begin :: proc(t: ^Gpu_Timers, pass: Timer_Pass) {
	if !t.enabled { return }
	gl.BeginQuery(gl.TIME_ELAPSED, t.queries[t.current_buf][pass])
}

// End timing a pass (call after the pass).
gpu_timer_end :: proc(t: ^Gpu_Timers, pass: Timer_Pass) {
	if !t.enabled { return }
	gl.EndQuery(gl.TIME_ELAPSED)
}

// Collect results from the PREVIOUS frame (non-blocking read).
// Call once per frame BEFORE beginning new queries.
gpu_timers_collect :: proc(t: ^Gpu_Timers) {
	if !t.enabled { return }

	// Skip first frame (no previous results)
	if t.frame_count < 2 {
		t.frame_count += 1
		t.current_buf = 1 - t.current_buf
		return
	}

	// Read from the OTHER buffer (completed last frame)
	read_buf := 1 - t.current_buf
	for pass in 0 ..< NUM_TIMER_PASSES {
		available: u32
		gl.GetQueryObjectuiv(t.queries[read_buf][pass], gl.QUERY_RESULT_AVAILABLE, &available)
		if available != 0 {
			gl.GetQueryObjectui64v(t.queries[read_buf][pass], gl.QUERY_RESULT, &t.results_ns[pass])
			t.results_ms[pass] = f32(t.results_ns[pass]) / 1_000_000.0
		}
	}

	// Swap buffer
	t.current_buf = 1 - t.current_buf
}

// Get the last measured time for a pass (in milliseconds).
gpu_timer_get_ms :: proc(t: ^Gpu_Timers, pass: Timer_Pass) -> f32 {
	return t.results_ms[pass]
}
