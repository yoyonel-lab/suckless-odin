package rendering

import gl "vendor:OpenGL"

VOLUMETRIC_WINDOW_DURATION_S :: 0.5 // Averaging window duration (seconds)

Volumetric_Timer_Pass :: enum {
	Shadow_Pass,
	Depth_Downsample,
	Raymarching,
	TAA_Blend,
	Bilateral_Blur,
	Composite_Upsample,
}

NUM_VOLUMETRIC_TIMER_PASSES :: 6

volumetric_timer_pass_name :: proc(pass: Volumetric_Timer_Pass) -> string {
	switch pass {
	case .Shadow_Pass:        return "Shadow Cubemap"
	case .Depth_Downsample:   return "Depth Downsample"
	case .Raymarching:        return "Raymarching"
	case .TAA_Blend:          return "TAA Reprojection"
	case .Bilateral_Blur:     return "Bilateral Blur"
	case .Composite_Upsample: return "JBU Composite"
	}
	return "Unknown"
}

// Per-pass smoothed metrics (windowed arithmetic mean).
Volumetric_Metric_Window :: struct {
	sum:         f64, // accumulated sum within current window
	count:       u32, // samples in current window
	min_raw:     f32, // min within current window
	max_raw:     f32, // max within current window
	display_avg: f32, // stable average in ms
	display_min: f32, // stable min in ms
	display_max: f32, // stable max in ms
}

// Double-buffered query objects for volumetric sub-passes
Volumetric_Gpu_Timers :: struct {
	queries:        [2][Volumetric_Timer_Pass]u32, // [front/back][pass]
	results_ns:     [Volumetric_Timer_Pass]u64,    // last completed results (nanoseconds)
	results_ms:     [Volumetric_Timer_Pass]f32,    // raw per-frame results (milliseconds)
	metrics:        [Volumetric_Timer_Pass]Volumetric_Metric_Window,
	total_metric:   Volumetric_Metric_Window,
	window_elapsed: f32,
	current_buf:    i32,
	frame_count:    u32,
	enabled:        bool,
}

@(private)
volumetric_metric_window_reset :: proc(m: ^Volumetric_Metric_Window) {
	m.sum = 0
	m.count = 0
	m.min_raw = 1e9
	m.max_raw = 0
}

@(private)
volumetric_metric_window_add :: proc(m: ^Volumetric_Metric_Window, value: f32) {
	m.sum += f64(value)
	m.count += 1
	if value < m.min_raw { m.min_raw = value }
	if value > m.max_raw { m.max_raw = value }
}

@(private)
volumetric_metric_window_finalize :: proc(m: ^Volumetric_Metric_Window) {
	if m.count > 0 {
		m.display_avg = f32(m.sum / f64(m.count))
		m.display_min = m.min_raw
		m.display_max = m.max_raw
	}
	volumetric_metric_window_reset(m)
}

// Create volumetric timer query objects.
volumetric_timers_create :: proc(t: ^Volumetric_Gpu_Timers) {
	for &buf_queries in t.queries {
		gl.GenQueries(NUM_VOLUMETRIC_TIMER_PASSES, raw_data(&buf_queries))
	}
	t.enabled = true
	t.frame_count = 0
	t.current_buf = 0

	for &m in t.metrics {
		volumetric_metric_window_reset(&m)
	}
	volumetric_metric_window_reset(&t.total_metric)

	for &buf_queries in t.queries {
		for pass in Volumetric_Timer_Pass {
			gl.BeginQuery(gl.TIME_ELAPSED, buf_queries[pass])
			gl.EndQuery(gl.TIME_ELAPSED)
		}
	}
}

// Destroy volumetric timer query objects.
volumetric_timers_destroy :: proc(t: ^Volumetric_Gpu_Timers) {
	for &buf_queries in t.queries {
		gl.DeleteQueries(NUM_VOLUMETRIC_TIMER_PASSES, raw_data(&buf_queries))
	}
	t^ = {}
}

// Begin timing a volumetric sub-pass.
volumetric_timer_begin :: proc(t: ^Volumetric_Gpu_Timers, pass: Volumetric_Timer_Pass) {
	if t == nil || !t.enabled { return }
	gl.BeginQuery(gl.TIME_ELAPSED, t.queries[t.current_buf][pass])
}

// End timing a volumetric sub-pass.
volumetric_timer_end :: proc(t: ^Volumetric_Gpu_Timers, pass: Volumetric_Timer_Pass) {
	if t == nil || !t.enabled { return }
	gl.EndQuery(gl.TIME_ELAPSED)
}

// Collect results from the previous frame (non-blocking read).
volumetric_timers_collect :: proc(t: ^Volumetric_Gpu_Timers, dt: f32) {
	if t == nil || !t.enabled { return }

	if t.frame_count < 2 {
		t.frame_count += 1
		t.current_buf = 1 - t.current_buf
		return
	}

	read_buf := 1 - t.current_buf
	for pass in Volumetric_Timer_Pass {
		available: u32
		gl.GetQueryObjectuiv(t.queries[read_buf][pass], gl.QUERY_RESULT_AVAILABLE, &available)
		if available != 0 {
			gl.GetQueryObjectui64v(t.queries[read_buf][pass], gl.QUERY_RESULT, &t.results_ns[pass])
			t.results_ms[pass] = f32(t.results_ns[pass]) / 1_000_000.0
		}
	}

	total_ms: f32
	for pass in Volumetric_Timer_Pass {
		volumetric_metric_window_add(&t.metrics[pass], t.results_ms[pass])
		total_ms += t.results_ms[pass]
	}
	volumetric_metric_window_add(&t.total_metric, total_ms)

	t.window_elapsed += dt
	if t.window_elapsed >= VOLUMETRIC_WINDOW_DURATION_S {
		for &m in t.metrics {
			volumetric_metric_window_finalize(&m)
		}
		volumetric_metric_window_finalize(&t.total_metric)
		t.window_elapsed = 0
	}

	t.current_buf = 1 - t.current_buf
}

// Get smoothed metrics for a volumetric sub-pass.
volumetric_timer_get_metrics :: proc(t: ^Volumetric_Gpu_Timers, pass: Volumetric_Timer_Pass) -> (avg, min_v, max_v: f32) {
	if t == nil do return 0, 0, 0
	m := &t.metrics[pass]
	return m.display_avg, m.display_min, m.display_max
}

// Get smoothed total metrics across all volumetric sub-passes.
volumetric_timer_get_total_metrics :: proc(t: ^Volumetric_Gpu_Timers) -> (avg, min_v, max_v: f32) {
	if t == nil do return 0, 0, 0
	return t.total_metric.display_avg, t.total_metric.display_min, t.total_metric.display_max
}

// Get pass percentage of total volumetric GPU time.
volumetric_timer_get_pct :: proc(t: ^Volumetric_Gpu_Timers, pass: Volumetric_Timer_Pass) -> f32 {
	if t == nil do return 0
	total := t.total_metric.display_avg
	if total <= 0 { return 0 }
	return (t.metrics[pass].display_avg / total) * 100.0
}
