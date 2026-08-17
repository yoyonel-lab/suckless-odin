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

## Memory Ownership & `defer` Discipline

**Every allocation MUST have a corresponding deallocation.** Before writing or reviewing any code, actively verify the following checklist:

### Mandatory `defer delete` patterns

| Allocation source | Required cleanup |
|---|---|
| `os.read_entire_file` / `os.read_entire_file_from_path` | `defer delete(data)` immediately after error check |
| `strings.concatenate` | `defer delete(result)` if temporary |
| `strings.clone` / `strings.clone_to_cstring` | `defer delete(...)` if temporary, or freed in the owning struct's `destroy` |
| `strings.builder_make` | Either `defer strings.builder_destroy(&b)`, or ownership transferred via return |
| `make([]T, ...)` / `make([dynamic]T)` | `defer delete(slice)` or freed in `destroy` proc |
| `new(T)` | `defer free(ptr)` or freed in `destroy` proc |

### Rules

1. **Immediate `defer`**: If the allocation is used only within the current scope, place `defer delete(...)` on the very next line after the error check.
2. **Ownership transfer**: If the allocation is returned to the caller, the caller is responsible. Document this in a comment if non-obvious.
3. **Struct-owned allocations**: Any allocation stored in a struct field MUST be freed in that struct's `destroy`/cleanup proc. The `destroy` proc MUST iterate dynamic arrays and free each element's owned allocations before deleting the array itself.
4. **Review trigger**: When modifying or creating ANY proc that calls an allocating function, STOP and verify: "Where is this freed?" If the answer is not immediately obvious, add the `defer` or fix the `destroy`.
5. **No silent leaks**: LeakSanitizer (ASAN) is the final arbiter. Run `task build-sanitize` + clean shutdown to validate 0 leaks after any memory-related change.

## GUI Search Synchronization

**Every interactive GUI element MUST be discoverable via the parameter search system.**

When adding or modifying any ImGui control in `src/gui/gui.odin`:

1. **Add a matching entry in `draw_filtered_view`** — include a `fuzzy_match(filter, "Label", "keywords...")` block for each new control.
2. **Update the relevant `*_KEYWORDS` constant** — add keywords that a user might type to discover the new control.
3. **If the control lives in a sub-window/tab** — add a `Go To` button (via `ibl_goto_button` pattern or equivalent) that clears the search buffer, activates the target view, and scrolls to the relevant section.
4. **Keyword coverage** — keywords must include: the label text, the subsystem name, synonyms, and related technical terms (e.g., "roughness" for a mip level slider).

This rule ensures the search bar acts as a universal command palette — no GUI element should be "invisible" to the search system.
