// +build test
package shader

import "core:testing"
import "core:strings"
import gl "vendor:OpenGL"

// --- directory_of tests ---

@(test)
test_directory_of_simple_path :: proc(t: ^testing.T) {
	testing.expect_value(t, directory_of("shaders/background.vert"), "shaders/")
}

@(test)
test_directory_of_nested_path :: proc(t: ^testing.T) {
	testing.expect_value(t, directory_of("shaders/IBL/irmap.glsl"), "shaders/IBL/")
}

@(test)
test_directory_of_no_slash :: proc(t: ^testing.T) {
	testing.expect_value(t, directory_of("file.glsl"), "./")
}

@(test)
test_directory_of_trailing_slash :: proc(t: ^testing.T) {
	testing.expect_value(t, directory_of("some/dir/"), "some/dir/")
}

// --- shader_type_string tests ---

@(test)
test_shader_type_string_vertex :: proc(t: ^testing.T) {
	testing.expect_value(t, shader_type_string(gl.VERTEX_SHADER), "Vertex")
}

@(test)
test_shader_type_string_fragment :: proc(t: ^testing.T) {
	testing.expect_value(t, shader_type_string(gl.FRAGMENT_SHADER), "Fragment")
}

@(test)
test_shader_type_string_compute :: proc(t: ^testing.T) {
	testing.expect_value(t, shader_type_string(gl.COMPUTE_SHADER), "Compute")
}

@(test)
test_shader_type_string_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, shader_type_string(0xDEAD), "Unknown")
}

// --- process_includes tests ---

@(test)
test_read_file_existing_shader :: proc(t: ^testing.T) {
	// Test reading an actual shader file (relative to project root)
	source, ok := read_file("../../../shaders/background.vert")
	if !ok {
		// Shader file not found — running from unexpected cwd, skip gracefully
		return
	}
	defer delete(source)

	testing.expect(t, len(source) > 0, "shader source should not be empty")
	testing.expect(t, strings.contains(source, "#version"), "shader should contain #version directive")
}

@(test)
test_read_file_nonexistent :: proc(t: ^testing.T) {
	_, ok := read_file("/tmp/nonexistent_shader_12345.glsl")
	testing.expect(t, !ok, "reading nonexistent file should fail")
}

@(test)
test_process_includes_no_headers :: proc(t: ^testing.T) {
	source := `#version 440 core
void main() { gl_Position = vec4(0); }
`
	result, ok := process_includes(source, "dummy.vert", 0)
	testing.expect(t, ok, "process_includes should succeed with no headers")
	defer delete(result)
	testing.expect(t, strings.contains(result, "gl_Position"), "content should be preserved")
}

@(test)
test_process_includes_max_depth_exceeded :: proc(t: ^testing.T) {
	source := `#version 440 core
void main() {}
`
	_, ok := process_includes(source, "dummy.vert", MAX_INCLUDE_DEPTH + 1)
	testing.expect(t, !ok, "should fail when max include depth exceeded")
}
