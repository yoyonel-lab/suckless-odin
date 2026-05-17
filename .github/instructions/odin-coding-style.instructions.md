---
description: "Use when writing or reviewing Odin code. Covers Odin idioms, vet compliance, strict-style requirements, and patterns specific to this project."
applyTo: ["src/**/*.odin", "tests/**/*.odin"]
---
# Odin Coding Style

## Vet & Strict Style Compliance

All code must pass: `odin check src/ -vet -strict-style -warnings-as-errors`

This enforces:
- No unused variables or imports
- No variable shadowing
- 1TBS brace style (opening brace on same line)
- Trailing commas in multi-line struct literals and proc args
- No deprecated syntax

## Type Conventions

- Use `f32` for all floating-point values (matches GPU/GLSL)
- Use `i32` for dimensions, counts, indices
- Use `u32` for OpenGL handles (textures, programs, buffers, VAOs)
- Use `bool` for boolean values (never integers)
- Use `string` for text (not `cstring` unless interfacing with C/OpenGL)

## Naming Conventions

- `snake_case` for procedures, variables, fields
- `Pascal_Case` for types (structs, enums, unions)
- `UPPER_CASE` for constants
- Package-qualified access: `gl.GenTextures`, `glfw.CreateWindow`

## Odin Idioms to Prefer

- `defer` for cleanup (GL resources, allocations)
- `or_return` for error propagation
- Multiple return values instead of out-parameters
- `#soa` for data-oriented arrays (sphere instances)
- Tagged unions for variant types
- `context` system for allocators and logging
- Named return values when they clarify intent

## OpenGL Interop Patterns

```odin
// GL handle types — always u32
program: u32
texture: u32
vao, vbo: u32

// String conversion for GL calls
gl.ShaderSource(shader, 1, &raw_data(src), nil)

// Cleanup with defer
gl.GenTextures(1, &texture)
defer if texture != 0 { gl.DeleteTextures(1, &texture) }
```

## Struct Initialization

```odin
// Prefer named fields
camera := Camera{
    position = Vec3{0, 0, 25},
    yaw      = -90.0,
    pitch    = 0.0,
    fov      = 45.0,
}
```

## Error Handling

- Return `bool` for operations that can fail
- Log errors at the point of detection
- Use `or_return` for propagation chains
- Never panic in library code — only in main/tests

## Import Organization

1. Core library (`core:fmt`, `core:math`, `core:os`, etc.)
2. Vendor packages (`vendor:OpenGL`, `vendor:glfw`, `vendor:stb`)
3. Project packages (relative imports)
