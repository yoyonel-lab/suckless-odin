package tests

import "core:testing"
import "core:math"

// Non-linear hardware depth [0..1] to linear view-space depth in meters
cpu_linearize_depth :: proc(depth, near, far: f32) -> f32 {
	z_ndc := depth * 2.0 - 1.0
	return (2.0 * near * far) / (far + near - z_ndc * (far - near))
}

// 4-tap Rank/Median depth calculation
cpu_median_4tap_depth :: proc(d0, d1, d2, d3: f32) -> (median: f32, delta: f32) {
	min_d := min(min(d0, d1), min(d2, d3))
	max_d := max(max(d0, d1), max(d2, d3))
	median = (d0 + d1 + d2 + d3 - min_d - max_d) * 0.5
	delta = max_d - min_d
	return
}

@(test)
test_depth_linearization_math :: proc(t: ^testing.T) {
	near: f32 = 0.1
	far: f32 = 100.0

	// At near plane (depth = 0.0), linear depth must equal near
	d_near := cpu_linearize_depth(0.0, near, far)
	testing.expect(t, math.abs(d_near - near) < 0.01, "Near plane linearization mismatch")

	// At far plane (depth = 1.0), linear depth must equal far
	d_far := cpu_linearize_depth(1.0, near, far)
	testing.expect(t, math.abs(d_far - far) < 0.05, "Far plane linearization mismatch")

	// Monotonicity test across range
	prev: f32 = 0.0
	for i in 0..=100 {
		depth := f32(i) / 100.0
		lin := cpu_linearize_depth(depth, near, far)
		testing.expect(t, lin >= prev, "Linearized depth must be strictly monotonic")
		prev = lin
	}
}

@(test)
test_median_4tap_step_preservation :: proc(t: ^testing.T) {
	// Case 1: 3 foreground taps (depth 5.0m) and 1 background tap (depth 50.0m)
	// Standard bilinear average gives: (5 + 5 + 5 + 50) / 4 = 16.25m (terrible bleeding artifact)
	// 4-tap median gives: (5 + 5) / 2 = 5.0m (perfect foreground preservation)
	m1, delta1 := cpu_median_4tap_depth(5.0, 5.0, 5.0, 50.0)
	testing.expect_value(t, m1, 5.0)
	testing.expect_value(t, delta1, 45.0)

	// Case 2: 1 foreground tap (depth 5.0m) and 3 background taps (depth 50.0m)
	// 4-tap median gives: (50 + 50) / 2 = 50.0m (perfect background preservation)
	m2, delta2 := cpu_median_4tap_depth(5.0, 50.0, 50.0, 50.0)
	testing.expect_value(t, m2, 50.0)
	testing.expect_value(t, delta2, 45.0)

	// Case 3: Smooth flat surface with small variation
	m3, delta3 := cpu_median_4tap_depth(10.0, 10.1, 10.2, 10.3)
	testing.expect(t, math.abs(m3 - 10.15) < 0.001, "Smooth flat median mismatch")
	testing.expect(t, math.abs(delta3 - 0.3) < 0.001, "Smooth flat delta mismatch")
}

@(test)
test_depth_discontinuity_detection :: proc(t: ^testing.T) {
	threshold: f32 = 0.25 // 25 cm step

	// Smooth surface (delta 0.05m < 0.25m) -> No edge
	_, d_smooth := cpu_median_4tap_depth(12.0, 12.02, 12.03, 12.05)
	is_edge_smooth := d_smooth > threshold
	testing.expect(t, !is_edge_smooth, "Smooth surface should not trigger edge discontinuity")

	// Sphere silhouette edge (foreground 8.0m vs background 30.0m) -> Edge detected
	_, d_edge := cpu_median_4tap_depth(8.0, 8.0, 30.0, 30.0)
	is_edge := d_edge > threshold
	testing.expect(t, is_edge, "Silhouette boundary must trigger edge discontinuity")
}
