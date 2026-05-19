package postfx

import gl "vendor:OpenGL"

// GPU profiling with double-buffered GL_TIME_ELAPSED queries and
// windowed arithmetic-mean smoothing (0.5s window, matching legacy).

WINDOW_DURATION_S :: 0.5 // Averaging window duration (seconds)

Timer_Pass :: enum {
	Bloom,
	Dof,
	Auto_Exposure,
	Composite,
}

NUM_TIMER_PASSES :: 4

TIMER_PASS_NAMES :: [Timer_Pass]string{
	.Bloom         = "Bloom",
	.Dof           = "DoF",
	.Auto_Exposure = "Auto-Exp",
	.Composite     = "Composite",
}

// Per-pass smoothed metrics (windowed arithmetic mean).
Metric_Window :: struct {
	sum:         f64, // accumulated sum within current window
	count:       u32, // samples in current window
	min_raw:     f32, // min within current window
	max_raw:     f32, // max within current window
	display_avg: f32, // stable average (updated every WINDOW_DURATION_S)
	display_min: f32, // stable min (updated with window)
	display_max: f32, // stable max (updated with window)
}

// Double-buffered query objects (read frame N-1 while writing frame N).
Gpu_Timers :: struct {
	queries:        [2][Timer_Pass]u32, // [front/back][pass]
	results_ns:     [Timer_Pass]u64,    // last completed results (nanoseconds)
	results_ms:     [Timer_Pass]f32,    // raw per-frame results (milliseconds)
	metrics:        [Timer_Pass]Metric_Window, // smoothed per-pass metrics
	total_metric:   Metric_Window,      // smoothed total (sum of all passes)
	window_elapsed: f32,                // time accumulated in current window
	current_buf:    i32,                // 0 or 1 (ping-pong)
	frame_count:    u32,                // skip first frame (no results yet)
	enabled:        bool,
}

// Create timer query objects.
gpu_timers_create :: proc(t: ^Gpu_Timers) {
	for &buf_queries in t.queries {
		gl.GenQueries(NUM_TIMER_PASSES, raw_data(&buf_queries))
	}
	t.enabled = true
	t.frame_count = 0
	t.current_buf = 0

	// Initialize metric windows
	for &m in t.metrics {
		metric_window_reset(&m)
	}
	metric_window_reset(&t.total_metric)

	// Issue dummy queries on both buffers to initialize them
	for &buf_queries in t.queries {
		for pass in Timer_Pass {
			gl.BeginQuery(gl.TIME_ELAPSED, buf_queries[pass])
			gl.EndQuery(gl.TIME_ELAPSED)
		}
	}
}

// Destroy timer query objects.
gpu_timers_destroy :: proc(t: ^Gpu_Timers) {
	for &buf_queries in t.queries {
		gl.DeleteQueries(NUM_TIMER_PASSES, raw_data(&buf_queries))
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
// Call once per frame BEFORE beginning new queries. Pass dt for smoothing.
gpu_timers_collect :: proc(t: ^Gpu_Timers, dt: f32) {
	if !t.enabled { return }

	// Skip first frame (no previous results)
	if t.frame_count < 2 {
		t.frame_count += 1
		t.current_buf = 1 - t.current_buf
		return
	}

	// Read from the OTHER buffer (completed last frame)
	read_buf := 1 - t.current_buf
	for pass in Timer_Pass {
		available: u32
		gl.GetQueryObjectuiv(t.queries[read_buf][pass], gl.QUERY_RESULT_AVAILABLE, &available)
		if available != 0 {
			gl.GetQueryObjectui64v(t.queries[read_buf][pass], gl.QUERY_RESULT, &t.results_ns[pass])
			t.results_ms[pass] = f32(t.results_ns[pass]) / 1_000_000.0
		}
	}

	// Feed raw results into windowed metrics
	total_ms: f32
	for pass in Timer_Pass {
		metric_window_add(&t.metrics[pass], t.results_ms[pass])
		total_ms += t.results_ms[pass]
	}
	metric_window_add(&t.total_metric, total_ms)

	// Check window expiration
	t.window_elapsed += dt
	if t.window_elapsed >= WINDOW_DURATION_S {
		for &m in t.metrics {
			metric_window_finalize(&m)
		}
		metric_window_finalize(&t.total_metric)
		t.window_elapsed = 0
	}

	// Swap buffer
	t.current_buf = 1 - t.current_buf
}

// Get the smoothed average time for a pass (in milliseconds).
gpu_timer_get_ms :: proc(t: ^Gpu_Timers, pass: Timer_Pass) -> f32 {
	return t.metrics[pass].display_avg
}

// Get the smoothed total time (sum of all passes) in milliseconds.
gpu_timer_get_total_ms :: proc(t: ^Gpu_Timers) -> f32 {
	return t.total_metric.display_avg
}

// Get metrics for a pass (avg, min, max).
gpu_timer_get_metrics :: proc(t: ^Gpu_Timers, pass: Timer_Pass) -> (avg, min_v, max_v: f32) {
	m := &t.metrics[pass]
	return m.display_avg, m.display_min, m.display_max
}

// Get total metrics (avg, min, max).
gpu_timer_get_total_metrics :: proc(t: ^Gpu_Timers) -> (avg, min_v, max_v: f32) {
	return t.total_metric.display_avg, t.total_metric.display_min, t.total_metric.display_max
}

// Get relative percentage of a pass vs total.
gpu_timer_get_pct :: proc(t: ^Gpu_Timers, pass: Timer_Pass) -> f32 {
	total := t.total_metric.display_avg
	if total <= 0 { return 0 }
	return (t.metrics[pass].display_avg / total) * 100.0
}

// --- Metric window helpers ---

@(private)
metric_window_reset :: proc(m: ^Metric_Window) {
	m.sum = 0
	m.count = 0
	m.min_raw = max(f32)
	m.max_raw = 0
}

@(private)
metric_window_add :: proc(m: ^Metric_Window, value: f32) {
	m.sum += f64(value)
	m.count += 1
	if value < m.min_raw { m.min_raw = value }
	if value > m.max_raw { m.max_raw = value }
}

@(private)
metric_window_finalize :: proc(m: ^Metric_Window) {
	if m.count > 0 {
		m.display_avg = f32(m.sum / f64(m.count))
		m.display_min = m.min_raw
		m.display_max = m.max_raw
	}
	metric_window_reset(m)
}
