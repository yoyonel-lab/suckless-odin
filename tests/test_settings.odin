package tests

import "core:testing"

import settings "../src/core/settings"

// --- Settings constants validation ---
// ISO port of implicit constant checks from various legacy test files.

@(test)
test_settings_camera_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.DEFAULT_CAMERA_DISTANCE, 20.0)
	testing.expect_value(t, settings.DEFAULT_CAMERA_YAW, -90.0)
	testing.expect_value(t, settings.DEFAULT_CAMERA_PITCH, 0.0)
	testing.expect_value(t, settings.DEFAULT_ENV_LOD, 0.0)
}

@(test)
test_settings_projection :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.NEAR_PLANE, 0.1)
	testing.expect_value(t, settings.FAR_PLANE, 1000.0)
	testing.expect_value(t, settings.FOV_ANGLE, 60.0)
}

@(test)
test_settings_window :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.WINDOW_WIDTH, 1280)
	testing.expect_value(t, settings.WINDOW_HEIGHT, 720)
}

@(test)
test_settings_material_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.DEFAULT_METALLIC, 0.0)
	testing.expect_value(t, settings.DEFAULT_ROUGHNESS, 0.5)
	testing.expect_value(t, settings.DEFAULT_AO, 1.0)
	testing.expect_value(t, settings.DEFAULT_EXPOSURE, 1.0)
}

@(test)
test_settings_geometry :: proc(t: ^testing.T) {
	testing.expect(t, settings.MIN_SUBDIV <= settings.MAX_SUBDIV,
		"MIN_SUBDIV must be <= MAX_SUBDIV")
	testing.expect(t, settings.INITIAL_SUBDIVISIONS >= settings.MIN_SUBDIV,
		"INITIAL_SUBDIVISIONS must be >= MIN_SUBDIV")
	testing.expect(t, settings.INITIAL_SUBDIVISIONS <= settings.MAX_SUBDIV,
		"INITIAL_SUBDIVISIONS must be <= MAX_SUBDIV")
}

@(test)
test_settings_nbody :: proc(t: ^testing.T) {
	testing.expect(t, settings.NUM_SPHERES > 0,
		"NUM_SPHERES must be positive")
}
