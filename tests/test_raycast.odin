package tests

import "core:testing"
import "core:math"
import mt "../src/core/math_types"
import rendering "../src/rendering"
import types "../src/rendering/types"
import scene "../src/scene"

@(test)
test_ray_intersect_sphere_direct_hit :: proc(t: ^testing.T) {
	ray := mt.Ray{
		origin    = mt.Vec3{0, 0, 10},
		direction = mt.Vec3{0, 0, -1},
	}
	center := mt.Vec3{0, 0, 0}
	radius: f32 = 2.0

	hit, dist := mt.ray_intersect_sphere(ray, center, radius)
	testing.expect(t, hit, "Direct ray should hit sphere")
	testing.expect(t, math.abs(dist - 8.0) < 0.001, "Direct hit distance should be 8.0 (10 - 2)")
}

@(test)
test_ray_intersect_sphere_miss :: proc(t: ^testing.T) {
	ray := mt.Ray{
		origin    = mt.Vec3{0, 5, 10},
		direction = mt.Vec3{0, 0, -1},
	}
	center := mt.Vec3{0, 0, 0}
	radius: f32 = 2.0

	hit, dist := mt.ray_intersect_sphere(ray, center, radius)
	testing.expect(t, !hit, "Ray offset by 5.0 should miss sphere with radius 2.0")
	testing.expect_value(t, dist, 0.0)
}

@(test)
test_ray_intersect_sphere_behind_ray :: proc(t: ^testing.T) {
	ray := mt.Ray{
		origin    = mt.Vec3{0, 0, 10},
		direction = mt.Vec3{0, 0, 1}, // Pointing away from origin
	}
	center := mt.Vec3{0, 0, 0}
	radius: f32 = 2.0

	hit, _ := mt.ray_intersect_sphere(ray, center, radius)
	testing.expect(t, !hit, "Sphere behind ray origin should not register positive hit")
}

@(test)
test_ray_from_screen_center :: proc(t: ^testing.T) {
	view := mt.look_at(mt.Vec3{0, 0, 10}, mt.Vec3{0, 0, 0}, mt.VEC3_UP)
	proj := mt.perspective(mt.radians(60.0), 16.0 / 9.0, 0.1, 1000.0)

	screen_pos := mt.Vec2{640, 360}
	viewport_size := mt.Vec2{1280, 720}

	ray := mt.ray_from_screen(screen_pos, viewport_size, view, proj)

	// Screen center should shoot directly along camera forward vector (0, 0, -1)
	testing.expect(t, math.abs(ray.direction.x) < 0.01, "Center ray dir.x should be near 0")
	testing.expect(t, math.abs(ray.direction.y) < 0.01, "Center ray dir.y should be near 0")
	testing.expect(t, ray.direction.z < -0.99, "Center ray dir.z should be -1.0")

	// Test hit with sphere at origin
	hit, dist := mt.ray_intersect_sphere(ray, mt.Vec3{0, 0, 0}, 1.0)
	testing.expect(t, hit, "Center ray should hit sphere at origin")
	// Ray starts on near plane (z = 10.0 - 0.1 = 9.9), so distance to sphere surface (z = 1.0) is 8.9
	testing.expect(t, math.abs(dist - 8.9) < 0.05, "Hit distance from near plane at z=9.9 to sphere of radius 1 at z=0 should be 8.9")
}

// Regression test for index-hopping bug:
// Ensures sorting modifies array positions without corrupting instance identities,
// and instanced_find_index_by_id faithfully tracks displaced spheres.
@(test)
test_sphere_stable_id_preservation_across_sort :: proc(t: ^testing.T) {
	inst: rendering.Instanced_Spheres
	defer rendering.instanced_destroy(&inst)

	total := 10
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, total)
	inst.count = i32(total)

	for i in 0..<total {
		pos := mt.Vec3{f32(i) * 2.0, 0, 0}
		m := mt.MAT4_IDENTITY
		m[3][0] = pos.x
		m[3][1] = pos.y
		m[3][2] = pos.z
		inst.instances[i] = types.Sphere_Instance{
			model       = m,
			albedo      = mt.Vec3{1, 1, 1},
			id          = i32(i),
			prev_center = pos,
		}
	}

	// Move sphere ID 3 to z = -100 (very far away from camera)
	idx_3 := rendering.instanced_find_index_by_id(&inst, 3)
	testing.expect_value(t, idx_3, 3)
	inst.instances.model[idx_3][3][2] = -100.0

	// Move sphere ID 7 to z = 15 (very close to camera at z = 20)
	idx_7 := rendering.instanced_find_index_by_id(&inst, 7)
	testing.expect_value(t, idx_7, 7)
	inst.instances.model[idx_7][3][2] = 15.0

	// Sort back-to-front relative to camera at (0, 0, 20)
	camera_pos := mt.Vec3{0, 0, 20}
	rendering.instanced_sort_cpu(&inst, camera_pos)

	// In back-to-front sorting, farthest sphere (z = -100) must appear first (index 0)
	// Closest sphere (z = 15) must appear last (index 9)
	new_idx_3 := rendering.instanced_find_index_by_id(&inst, 3)
	new_idx_7 := rendering.instanced_find_index_by_id(&inst, 7)

	testing.expect_value(t, new_idx_3, 0)
	testing.expect_value(t, new_idx_7, 9)

	// Verify identity and model position preserved
	testing.expect_value(t, inst.instances[new_idx_3].id, 3)
	testing.expect_value(t, inst.instances[new_idx_3].model[3][2], -100.0)

	testing.expect_value(t, inst.instances[new_idx_7].id, 7)
	testing.expect_value(t, inst.instances[new_idx_7].model[3][2], 15.0)

	// Verify all 10 IDs are uniquely preserved
	found := [10]bool{}
	for i in 0..<total {
		id := inst.instances.id[i]
		testing.expect(t, id >= 0 && id < 10, "ID must be in range 0..9")
		testing.expect(t, !found[id], "Each ID must appear exactly once")
		found[id] = true
	}
}

@(test)
test_instanced_reset_grid :: proc(t: ^testing.T) {
	inst: rendering.Instanced_Spheres
	defer rendering.instanced_destroy(&inst)

	total := 100
	inst.instances = make(#soa [dynamic]types.Sphere_Instance, total)
	inst.count = i32(total)

	for i in 0..<total {
		// Scramble positions
		m := mt.MAT4_IDENTITY
		m[3][0] = 999.0
		m[3][1] = -999.0
		m[3][2] = 50.0
		inst.instances[i] = types.Sphere_Instance{
			model = m,
			id    = i32(i),
		}
	}

	// Reset grid
	rendering.instanced_reset_grid(&inst)

	// Verify grid coordinates are restored
	p0 := inst.instances.model[0][3].xyz
	p99 := inst.instances.model[99][3].xyz

	testing.expect(t, p0.x < p99.x, "First sphere should be left of last sphere")
	testing.expect(t, p0.y > p99.y, "First sphere should be above last sphere")
	testing.expect_value(t, p0.z, 0.0)
	testing.expect_value(t, p99.z, 0.0)
}

// Functional test: 3D Scene Picking integration
@(test)
test_scene_pick_entity_functional :: proc(t: ^testing.T) {
	s: scene.Scene

	// Camera at (0, 0, 10) looking toward (0, 0, 0)
	s.camera.position = mt.Vec3{0, 0, 10}
	s.camera.front = mt.Vec3{0, 0, -1}
	s.camera.up = mt.Vec3{0, 1, 0}
	s.camera.zoom = 60.0

	// Light bulb at (0, 0, 0)
	s.point_light.enabled = true
	s.point_light.show_bulb = true
	s.point_light.position = mt.Vec3{0, 0, 0}
	s.point_light.bulb_radius = 1.0

	defer rendering.instanced_destroy(&s.spheres)

	s.spheres.instances = make(#soa [dynamic]types.Sphere_Instance, 1)
	s.spheres.count = 1
	m := mt.MAT4_IDENTITY
	m[3][0] = 5.0 // Offset to the right
	m[3][1] = 0.0
	m[3][2] = 0.0
	s.spheres.instances[0] = types.Sphere_Instance{
		model = m,
		id    = 42,
	}

	// 1. Center click (640, 360) should hit Light Bulb at origin
	hit_light := scene.scene_pick_entity(&s, 640, 360, 1280, 720)
	testing.expect(t, hit_light, "Center click should pick light bulb")
	testing.expect_value(t, s.selection.type, types.Selection_Type.Light)
	testing.expect(t, s.point_light.show_gizmo, "Gizmo should be enabled on light pick")

	// 2. Corner click (10, 10) on empty skybox should deselect
	hit_sky := scene.scene_pick_entity(&s, 10, 10, 1280, 720)
	testing.expect(t, !hit_sky, "Skybox click should deselect")
	testing.expect_value(t, s.selection.type, types.Selection_Type.None)
	testing.expect(t, !s.point_light.show_gizmo, "Gizmo should be hidden on deselect")

	// 3. Disable light bulb, then place sphere at origin and test sphere picking
	s.point_light.enabled = false
	s.spheres.instances.model[0][3][0] = 0.0 // Move sphere 42 to origin

	hit_sphere := scene.scene_pick_entity(&s, 640, 360, 1280, 720)
	testing.expect(t, hit_sphere, "Center click should pick sphere at origin")
	testing.expect_value(t, s.selection.type, types.Selection_Type.Sphere)
	testing.expect_value(t, s.selection.sphere_id, 42)
	testing.expect_value(t, s.selection.sphere_index, 0)
	testing.expect(t, s.point_light.show_gizmo, "Gizmo should be enabled on sphere pick")
}
