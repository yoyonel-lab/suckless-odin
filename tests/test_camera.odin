package tests

import "core:testing"
import "core:math"

import cam "../src/camera"
import mt "../src/core/math_types"
import settings "../src/core/settings"

TOLERANCE_SMALL :: 0.01
TOLERANCE_TINY  :: 1e-6

@(private)
make_camera :: proc() -> cam.Camera {
	c: cam.Camera
	cam.init(&c,
		settings.DEFAULT_CAMERA_DISTANCE,
		settings.DEFAULT_CAMERA_YAW,
		settings.DEFAULT_CAMERA_PITCH)
	return c
}

// --- Initialization ---

@(test)
test_camera_initialization :: proc(t: ^testing.T) {
	c := make_camera()

	testing.expect_value(t, c.yaw, settings.DEFAULT_CAMERA_YAW)
	testing.expect_value(t, c.pitch, settings.DEFAULT_CAMERA_PITCH)
	testing.expect_value(t, c.velocity, cam.DEFAULT_CAMERA_SPEED)
	testing.expect_value(t, c.sensitivity, cam.DEFAULT_CAMERA_SENSITIVITY)
	testing.expect_value(t, c.zoom, cam.DEFAULT_CAMERA_ZOOM)
	testing.expect_value(t, c.physics_accumulator, f32(0))
	testing.expect_value(t, c.fixed_timestep, cam.DEFAULT_FIXED_TIMESTEP)

	// Position: (0, 0, distance)
	testing.expect_value(t, c.position.x, f32(0))
	testing.expect_value(t, c.position.y, f32(0))
	testing.expect_value(t, c.position.z, settings.DEFAULT_CAMERA_DISTANCE)
}

// --- Vector basis ---

@(test)
test_camera_update_vectors_normalized :: proc(t: ^testing.T) {
	c := make_camera()

	front_len := mt.vec3_length(c.front)
	testing.expectf(t, abs(front_len - 1.0) < TOLERANCE_SMALL,
		"front vector not normalized: len=%v", front_len)

	right_len := mt.vec3_length(c.right)
	testing.expectf(t, abs(right_len - 1.0) < TOLERANCE_SMALL,
		"right vector not normalized: len=%v", right_len)

	up_len := mt.vec3_length(c.up)
	testing.expectf(t, abs(up_len - 1.0) < TOLERANCE_SMALL,
		"up vector not normalized: len=%v", up_len)
}

@(test)
test_camera_update_vectors_orthogonal :: proc(t: ^testing.T) {
	c := make_camera()

	dot_front_right := mt.vec3_dot(c.front, c.right)
	testing.expectf(t, abs(dot_front_right) < TOLERANCE_SMALL,
		"front and right not orthogonal: dot=%v", dot_front_right)
}

// --- Fixed update no input ---

@(test)
test_camera_fixed_update_no_input :: proc(t: ^testing.T) {
	c := make_camera()
	initial_pos := c.position

	cam.build_keyboard_input(&c)
	cam.fixed_update(&c)

	testing.expect_value(t, c.position.x, initial_pos.x)
	testing.expect_value(t, c.position.y, initial_pos.y)
	testing.expect_value(t, c.position.z, initial_pos.z)
}

// --- Forward movement ---

@(test)
test_camera_fixed_update_forward :: proc(t: ^testing.T) {
	c := make_camera()
	initial_pos := c.position

	c.move_forward = true
	cam.build_keyboard_input(&c)
	cam.fixed_update(&c)

	dist := mt.vec3_length(c.position - initial_pos)
	testing.expectf(t, dist > 0, "camera did not move forward: dist=%v", dist)
}

// --- Accumulator stepping ---

@(test)
test_camera_fixed_update_accumulator :: proc(t: ^testing.T) {
	c := make_camera()
	c.physics_accumulator = cam.DEFAULT_FIXED_TIMESTEP * 3.0

	update_count := 0
	for c.physics_accumulator >= c.fixed_timestep {
		cam.build_keyboard_input(&c)
		cam.fixed_update(&c)
		c.physics_accumulator -= c.fixed_timestep
		update_count += 1
	}

	testing.expect_value(t, update_count, 3)
}

// --- Mouse orientation ---

@(test)
test_camera_process_mouse_changes_orientation :: proc(t: ^testing.T) {
	c := make_camera()
	initial_yaw := c.yaw_target
	initial_pitch := c.pitch_target

	cam.process_mouse(&c, 10.0, 5.0)

	testing.expectf(t, c.yaw_target != initial_yaw,
		"yaw_target unchanged after mouse input")
	testing.expectf(t, c.pitch_target != initial_pitch,
		"pitch_target unchanged after mouse input")
}

// --- Pitch clamping ---

@(test)
test_camera_process_mouse_clamps_pitch :: proc(t: ^testing.T) {
	c := make_camera()

	// Extreme positive
	cam.process_mouse(&c, 0, 1000.0)
	testing.expectf(t, c.pitch_target <= cam.DEFAULT_MAX_PITCH,
		"pitch_target exceeded max: %v", c.pitch_target)

	// Reset and extreme negative
	c2 := make_camera()
	cam.process_mouse(&c2, 0, -1000.0)
	testing.expectf(t, c2.pitch_target >= cam.DEFAULT_MIN_PITCH,
		"pitch_target below min: %v", c2.pitch_target)
}

// --- View matrix ---

@(test)
test_camera_get_view_matrix_not_zero :: proc(t: ^testing.T) {
	c := make_camera()
	view := cam.get_view_matrix(&c)

	has_nonzero := false
	for col in 0 ..< 4 {
		for row in 0 ..< 4 {
			if abs(view[col][row]) > 0.001 {
				has_nonzero = true
				break
			}
		}
	}
	testing.expect(t, has_nonzero, "view matrix is all zeros")
}

// --- Scroll impulse ---

@(test)
test_camera_scroll_impulse_moves_forward :: proc(t: ^testing.T) {
	c := make_camera()
	initial_pos := c.position

	cam.process_scroll(&c, 1.0)
	cam.build_keyboard_input(&c)
	cam.fixed_update(&c)

	dist := mt.vec3_length(c.position - initial_pos)
	testing.expectf(t, dist > 0, "scroll did not move camera: dist=%v", dist)

	// Direction should align with front
	dir := mt.vec3_normalize(c.position - initial_pos)
	dot := mt.vec3_dot(c.front, dir)
	testing.expectf(t, abs(dot - 1.0) < TOLERANCE_SMALL,
		"scroll movement not aligned with front: dot=%v", dot)
}

// --- Head bobbing ---

@(test)
test_camera_head_bobbing_enabled_by_default :: proc(t: ^testing.T) {
	c := make_camera()
	testing.expect(t, c.bobbing_enabled, "head bobbing should be enabled by default")
}

// --- Rotation smoothing ---

@(test)
test_camera_rotation_smoothing :: proc(t: ^testing.T) {
	c := make_camera()
	cam.process_mouse(&c, 10.0, 5.0)

	// yaw/pitch should differ from targets (not instantly snapped)
	testing.expectf(t, c.yaw_target != c.yaw,
		"yaw should not equal yaw_target before smoothing")
	testing.expectf(t, c.pitch_target != c.pitch,
		"pitch should not equal pitch_target before smoothing")

	// After smooth_rotation, values should approach targets
	old_yaw := c.yaw
	old_pitch := c.pitch
	cam.smooth_rotation(&c)

	yaw_diff_before := abs(c.yaw_target - old_yaw)
	yaw_diff_after := abs(c.yaw_target - c.yaw)
	testing.expectf(t, yaw_diff_after < yaw_diff_before,
		"yaw did not approach target after smoothing")

	pitch_diff_before := abs(c.pitch_target - old_pitch)
	pitch_diff_after := abs(c.pitch_target - c.pitch)
	testing.expectf(t, pitch_diff_after < pitch_diff_before,
		"pitch did not approach target after smoothing")
}

// --- Camera reset ---

@(test)
test_camera_reset_restores_defaults :: proc(t: ^testing.T) {
	c := make_camera()

	// Modify camera state
	c.position = mt.Vec3{99, 99, 99}
	c.yaw = 42
	c.pitch = -30
	c.velocity_current = mt.Vec3{5, 5, 5}

	// Reset
	cam.init(&c,
		settings.DEFAULT_CAMERA_DISTANCE,
		settings.DEFAULT_CAMERA_YAW,
		settings.DEFAULT_CAMERA_PITCH)

	testing.expect_value(t, c.position.z, settings.DEFAULT_CAMERA_DISTANCE)
	testing.expect_value(t, c.yaw, settings.DEFAULT_CAMERA_YAW)
	testing.expect_value(t, c.pitch, settings.DEFAULT_CAMERA_PITCH)
	testing.expect_value(t, c.velocity_current, mt.VEC3_ZERO)
}
