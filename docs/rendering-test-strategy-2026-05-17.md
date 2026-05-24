# Rendering Test Strategy

**Date:** 2026-05-17 (updated 2026-05-23)  
**Status:** Implemented  
**Scope:** GPU rendering validation, visual regression, headless testing

## Context

The legacy suckless-ogl (C11) project relies on:
- Unity test framework + CTest
- Visual regression with reference images (`tests/references/ref_*.png`)
- RenderDoc integration for GPU inspection
- `xvfb-run` for headless CI

Odin has **no dedicated GPU testing framework**. Testing rendering requires the same fundamental approach as any language: capture pixels, compare with references, validate GPU state.

## Architecture: 3-Phase Testing Pyramid

```
┌───────────────────────────────────────────────┐
│  Phase 3: Visual Regression (full pipeline)   │
│  Frame capture → RMSE compare → ref images    │
├───────────────────────────────────────────────┤
│  Phase 2: Headless GL (shader/GPU validation) │
│  GLFW invisible window → compile → query      │
├───────────────────────────────────────────────┤
│  Phase 1: Pure CPU (data + math)              │
│  No GPU context needed                        │
└───────────────────────────────────────────────┘
```

## Phase 1: Pure CPU Tests (no GL context)

Target functions that perform pure computation without touching OpenGL:

| Module | Function | What to test |
|--------|----------|--------------|
| `shader/shader.odin` | `directory_of` | Path extraction edge cases |
| `shader/shader.odin` | `process_includes` | `@header` include expansion, depth limit |
| `shader/shader.odin` | `read_file` | File loading + include resolution |
| `rendering/types.odin` | `aa_mode_to_string` | Enum → string mapping |
| `rendering/overlay.odin` | `ortho_matrix` | Orthographic projection correctness |
| `rendering/overlay.odin` | `overlay_cycle` | Mode cycling wraps correctly |
| `rendering/overlay.odin` | `overlay_update` | FPS accumulator logic |
| `rendering/instanced.odin` | `instanced_create` (grid layout) | Grid position math |
| `rendering/instanced.odin` | `instanced_update_prev_centers` | Motion blur data copy |

## Phase 2: Headless GL Context Tests

Requires GLFW with `GLFW_VISIBLE = false` (invisible window = headless rendering).

| Test Category | What to validate |
|---------------|-----------------|
| Shader compilation | All 9 shaders compile without errors |
| Shader linkage | Vertex + Fragment programs link correctly |
| Uniform query | Expected uniforms exist and have correct types |
| Compute dispatch | IBL compute shaders compile (GL 4.3+) |
| Texture creation | HDR texture loads into valid GL object |
| FBO rendering | Render to offscreen FBO, readPixels succeeds |

### Headless GL Setup Pattern

```odin
@(test)
test_shader_compiles :: proc(t: ^testing.T) {
    // 1. Init GLFW
    if glfw.Init() == 0 { testing.fatal(t, "GLFW init failed"); return }
    defer glfw.Terminate()

    // 2. Invisible window (headless)
    glfw.WindowHint(glfw.VISIBLE, 0)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

    window := glfw.CreateWindow(64, 64, "test", nil, nil)
    if window == nil { testing.fatal(t, "Window creation failed"); return }
    defer glfw.DestroyWindow(window)
    glfw.MakeContextCurrent(window)

    // 3. Load GL functions
    gl.load_up_to(4, 3, glfw.SetProcAddress)

    // 4. Test shader compilation
    source, ok := shader.read_file("shaders/background.vert")
    testing.expect(t, ok, "shader file read failed")
    // ... compile and check
}
```

## Phase 3: Visual Regression (future)

- Render full scene to FBO (256×256 minimum)
- `gl.ReadPixels()` → raw RGBA buffer
- Compare against `tests/references/ref_*.png` baselines
- RMSE threshold (e.g., < 0.02 per channel)
- CI: `xvfb-run just test-gl`

## Key Odin Advantages

1. **Built-in memory leak detection** — test runner catches `gl.Gen*` without matching `gl.Delete*`
2. **`#soa` validation** — SoA/AoS packing correctness testable at CPU level
3. **`context.temp_allocator`** — zero-leak staging buffers in tests
4. **`@(test)` + `// +build test`** — no separate test binary needed

## CI Integration

```bash
# Phase 1: always runs
just test-unit

# Phase 2+3: requires GPU (xvfb on CI)
xvfb-run just test-gl
```

## Progress Log

| Date | Phase | What | Status |
|------|-------|------|--------|
| 2026-05-17 | 1 | CPU tests: shader path, overlay math, instanced grid | ✅ Done |
| 2026-05-17 | 2 | Headless GL context test harness | ✅ Done |
| 2026-05-19 | 2 | GL shader/uniform/bloom/DoF tests | ✅ Done |
| 2026-05-22 | 3 | Visual regression (FXAA+MB sweep) | ✅ Done |
