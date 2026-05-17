package shader

import gl "vendor:OpenGL"
import "core:fmt"
import "core:os"
import "core:strings"

import log "../../core/log"

// Shader warning throttle limit
SHADER_WARNING_THROTTLE_LIMIT :: 10
INFO_LOG_SIZE                 :: 512
MAX_SHADER_NAME_LEN           :: 256
MAX_INCLUDE_DEPTH             :: 16
MAX_SHADER_SOURCE_SIZE        :: 16 * 1024 * 1024 // 16MB limit

// Cached uniform metadata for fast lookup (ISO port of UniformEntry)
Uniform_Entry :: struct {
	name:     string,
	location: i32,
}

// Wrapper for an OpenGL program with uniform caching (ISO port of Shader struct)
Shader :: struct {
	program:         u32,
	name:            string,
	entries:         [dynamic]Uniform_Entry,
	silent_warnings: bool,
	warning_count:   int,
}

// Read a shader file from disk, processing @header includes
read_file :: proc(path: string) -> (source: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.shader", "Failed to read shader file: %s", path)
		return "", false
	}
	defer delete(data)
	raw_source := string(data)

	// Process includes
	result, proc_ok := process_includes(raw_source, path, 0)
	if !proc_ok {
		return "", false
	}

	return result, true
}

// Process @header includes recursively
@(private)
process_includes :: proc(source: string, file_path: string, depth: int) -> (result: string, ok: bool) {
	if depth > MAX_INCLUDE_DEPTH {
		log.log_error("suckless-odin.shader", "Maximum include depth exceeded (%d)", MAX_INCLUDE_DEPTH)
		return "", false
	}

	// Get directory of current file
	dir := directory_of(file_path)

	builder := strings.builder_make()
	lines := strings.split(source, "\n")
	defer delete(lines)

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "@header") {
			// Extract header path
			header_path_raw := strings.trim_space(trimmed[len("@header"):])
			if len(header_path_raw) == 0 {
				continue
			}

			// Resolve relative to current file
			full_path := strings.concatenate({dir, header_path_raw})
			defer delete(full_path)

			header_data, read_err := os.read_entire_file(full_path, context.allocator)
			if read_err != nil {
				log.log_error("suckless-odin.shader", "Failed to read included header: %s", full_path)
				return "", false
			}
			header_source := string(header_data)

			// Recurse
			included, include_ok := process_includes(header_source, full_path, depth + 1)
			delete(header_data)
			if !include_ok {
				return "", false
			}
			defer delete(included)

			strings.write_string(&builder, included)
			strings.write_byte(&builder, '\n')
		} else {
			strings.write_string(&builder, line)
			strings.write_byte(&builder, '\n')
		}
	}

	return strings.to_string(builder), true
}

// Compile a single shader stage from source
compile :: proc(source: string, shader_type: u32) -> (shader_id: u32, ok: bool) {
	shader_id = gl.CreateShader(shader_type)
	c_source := strings.clone_to_cstring(source)
	defer delete(c_source)

	gl.ShaderSource(shader_id, 1, &c_source, nil)
	gl.CompileShader(shader_id)

	success: i32
	gl.GetShaderiv(shader_id, gl.COMPILE_STATUS, &success)
	if success == 0 {
		info_log: [INFO_LOG_SIZE]u8
		gl.GetShaderInfoLog(shader_id, INFO_LOG_SIZE, nil, raw_data(&info_log))
		type_str := shader_type_string(shader_type)
		log.log_error("suckless-odin.shader", "%s compilation failed:\n%s", type_str, string(info_log[:]))
		gl.DeleteShader(shader_id)
		return 0, false
	}

	return shader_id, true
}

// Link vertex + fragment shaders into a program
load_program :: proc(vertex_path, fragment_path: string) -> (program: u32, ok: bool) {
	vs_source, vs_ok := read_file(vertex_path)
	if !vs_ok { return 0, false }
	defer delete(vs_source)

	fs_source, fs_ok := read_file(fragment_path)
	if !fs_ok { return 0, false }
	defer delete(fs_source)

	vs, vs_compile_ok := compile(vs_source, gl.VERTEX_SHADER)
	if !vs_compile_ok { return 0, false }
	defer gl.DeleteShader(vs)

	fs, fs_compile_ok := compile(fs_source, gl.FRAGMENT_SHADER)
	if !fs_compile_ok { return 0, false }
	defer gl.DeleteShader(fs)

	program = gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)
	gl.LinkProgram(program)

	success: i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &success)
	if success == 0 {
		info_log: [INFO_LOG_SIZE]u8
		gl.GetProgramInfoLog(program, INFO_LOG_SIZE, nil, raw_data(&info_log))
		log.log_error("suckless-odin.shader", "Program linking failed:\n%s", string(info_log[:]))
		gl.DeleteProgram(program)
		return 0, false
	}

	return program, true
}

// Load a compute shader program
load_compute :: proc(compute_path: string) -> (program: u32, ok: bool) {
	cs_source, cs_ok := read_file(compute_path)
	if !cs_ok { return 0, false }
	defer delete(cs_source)

	cs, cs_compile_ok := compile(cs_source, gl.COMPUTE_SHADER)
	if !cs_compile_ok { return 0, false }
	defer gl.DeleteShader(cs)

	program = gl.CreateProgram()
	gl.AttachShader(program, cs)
	gl.LinkProgram(program)

	success: i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &success)
	if success == 0 {
		info_log: [INFO_LOG_SIZE]u8
		gl.GetProgramInfoLog(program, INFO_LOG_SIZE, nil, raw_data(&info_log))
		log.log_error("suckless-odin.shader", "Compute program linking failed:\n%s", string(info_log[:]))
		gl.DeleteProgram(program)
		return 0, false
	}

	return program, true
}

// Create a Shader with uniform caching (ISO port of shader_load)
load :: proc(vertex_path, fragment_path: string) -> ^Shader {
	program, ok := load_program(vertex_path, fragment_path)
	if !ok { return nil }

	shader := new(Shader)
	shader.program = program
	shader.name = fmt.tprintf("%s + %s", vertex_path, fragment_path)
	shader.entries = make([dynamic]Uniform_Entry)
	shader.silent_warnings = false
	shader.warning_count = 0

	cache_uniforms(shader)
	return shader
}

// Create a compute Shader with uniform caching
load_compute_shader :: proc(compute_path: string) -> ^Shader {
	program, ok := load_compute(compute_path)
	if !ok { return nil }

	shader := new(Shader)
	shader.program = program
	shader.name = compute_path
	shader.entries = make([dynamic]Uniform_Entry)
	shader.silent_warnings = false
	shader.warning_count = 0

	cache_uniforms(shader)
	return shader
}

// Destroy a shader and free resources
destroy :: proc(shader: ^Shader) {
	if shader == nil { return }
	gl.DeleteProgram(shader.program)
	delete(shader.entries)
	free(shader)
}

// Look up a cached uniform location by name
get_uniform_location :: proc(shader: ^Shader, name: string) -> i32 {
	for &entry in shader.entries {
		if entry.name == name {
			return entry.location
		}
	}
	if !shader.silent_warnings && shader.warning_count < SHADER_WARNING_THROTTLE_LIMIT {
		log.log_warning("suckless-odin.shader", "Uniform '%s' not found in shader '%s'", name, shader.name)
		shader.warning_count += 1
	}
	return -1
}

// Use this shader program
use :: proc(shader: ^Shader) {
	gl.UseProgram(shader.program)
}

// Set uniform helpers
set_int :: proc(shader: ^Shader, name: string, value: i32) {
	loc := get_uniform_location(shader, name)
	if loc >= 0 { gl.Uniform1i(loc, value) }
}

set_float :: proc(shader: ^Shader, name: string, value: f32) {
	loc := get_uniform_location(shader, name)
	if loc >= 0 { gl.Uniform1f(loc, value) }
}

set_vec3 :: proc(shader: ^Shader, name: string, value: [3]f32) {
	loc := get_uniform_location(shader, name)
	v := value
	if loc >= 0 { gl.Uniform3fv(loc, 1, raw_data(&v)) }
}

set_mat4 :: proc(shader: ^Shader, name: string, value: [4][4]f32) {
	loc := get_uniform_location(shader, name)
	v := value
	if loc >= 0 { gl.UniformMatrix4fv(loc, 1, false, raw_data(&v[0])) }
}

// --- Private helpers ---

@(private)
cache_uniforms :: proc(shader: ^Shader) {
	count: i32
	gl.GetProgramiv(shader.program, gl.ACTIVE_UNIFORMS, &count)

	for i in 0..<count {
		name_buf: [256]u8
		name_len: i32
		size: i32
		type_val: u32
		gl.GetActiveUniform(shader.program, u32(i), 256, &name_len, &size, &type_val, raw_data(&name_buf))

		name := string(name_buf[:name_len])
		location := gl.GetUniformLocation(shader.program, strings.clone_to_cstring(name))

		if location >= 0 {
			append(&shader.entries, Uniform_Entry{
				name     = strings.clone(name),
				location = location,
			})
		}
	}
}

@(private)
directory_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i+1]
		}
	}
	return "./"
}

@(private)
shader_type_string :: proc(t: u32) -> string {
	switch t {
	case gl.VERTEX_SHADER:   return "Vertex"
	case gl.FRAGMENT_SHADER: return "Fragment"
	case gl.COMPUTE_SHADER:  return "Compute"
	}
	return "Unknown"
}
