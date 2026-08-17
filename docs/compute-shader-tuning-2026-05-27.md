# Compute Shader Tuning & Dynamic Quality Profiles

**Date:** 2026-05-27  
**Status:** Implemented & Verified  

---

## 1. Architectural Context & Motivation

To achieve smooth frame transition times during dynamic environment map swaps and highly responsive startup flows, we previously optimized several compute shaders by tuning their Monte Carlo integration sample counts. However, to maintain absolute pixel-perfect visual regression compatibility with existing reference frames and allow manual performance validation on constrained targets, we established a **Compute Shader Tuning Configuration System**.

In **V0**, this system has been upgraded to read from an **external JSON configuration file** (`assets/configs/compute_tuning.json`). This file groups settings under named profiles (`"legacy"` and `"optimized"`), eliminating compile-time hardcoding.

In **V1**, this has been further extended to **progressive amortization slicing parameters**, allowing the number of frames across which specular mips and diffuse irradiance are split to be fully customized at runtime without rebuilding the engine.

---

## 2. Profile Quality, Performance & Slicing Matrix

The dynamic parameters configured within each profile are structured as follows:

| Parameters & Shaders | Legacy Profile (Default) | Optimized Profile | Optimization Effect | Visual Quality / UX Impact |
| :--- | :---: | :---: | :---: | :--- |
| **BRDF LUT Sample Count** (`spbrdf.glsl`) | `1024u` | `256u` | **4x complexity speedup** | Zero measurable runtime difference (precomputed once on startup). |
| **Prefilter Specular Sample Count** (`spmap.glsl`) | `1024u` | `512u` | **2x complexity speedup** | Indistinguishable roughness prefiltering; avoids high-frequency shading noise. |
| **Diffuse Irradiance Step Size** (`irmap.glsl`) | `0.025` | `0.05` | **4x iteration reduction** | Absolutely zero visual regression. Diffuse maps represent extremely low-frequency ambient light. |
| **Specular Mip 0 Slices** | `24` | `24` | Amortized across 24 frames | Keeps Frame 2 spike under control (~236 ms on Mesa). |
| **Specular Mip 1 Slices** | `8` | `8` | Amortized across 8 frames | Balances quality swap speeds and stable frame rate. |
| **Specular Mip 2 Slices** | `4` | `4` | Amortized across 4 frames | Prevents frame drop spikes for mid-resolution mips. |
| **Diffuse Irradiance Slices** | `12` | `12` | Amortized across 12 frames | Distributes heavy irradiance convolutions evenly. |
| **Specular Mip Grouping Start Mip** | `3` | `3` | Stop slicing at this mip level | Small textures (mips 3+) are grouped in a single frame. |
| **Seamless Mip Downsample Threshold** | `2` | `2` | Face-by-face threshold mip level | Large seamless cubemap mips are processed progressively (1 face/frame). |

---

## 3. External JSON Configuration Schema (`assets/configs/compute_tuning.json`)

The application loads these settings from `assets/configs/compute_tuning.json` at startup. If the file is missing or contains invalid syntax, the engine automatically logs a warning and falls back to safe, high-fidelity hardcoded legacy defaults.

```json
{
  "profiles": {
    "legacy": {
      "spbrdf_sample_count": 1024,
      "spmap_sample_count": 1024,
      "irmap_sample_delta": 0.025,
      "slicing": {
        "specular_mip0_slices": 24,
        "specular_mip1_slices": 8,
        "specular_mip2_slices": 4,
        "irdiff_slices": 12,
        "specular_mip_grouping_start_mip": 3,
        "seamless_downsample_progressive_mip_threshold": 2
      }
    },
    "optimized": {
      "spbrdf_sample_count": 256,
      "spmap_sample_count": 512,
      "irmap_sample_delta": 0.05,
      "slicing": {
        "specular_mip0_slices": 24,
        "specular_mip1_slices": 8,
        "specular_mip2_slices": 4,
        "irdiff_slices": 12,
        "specular_mip_grouping_start_mip": 3,
        "seamless_downsample_progressive_mip_threshold": 2
      }
    }
  }
}
```

---

## 4. Preprocessor Injection & Slicing Pipeline

### Dynamic Preprocessor Override Injection

Rather than maintaining separate duplicate shader files on disk, we dynamically inject `#define` preprocessor directives directly in VRAM memory right after the shader's `#version` line during GLSL program compilation:

```
[Shader Source on Disk]
       │
       ▼
[app.init] ──► Loads profile from assets/configs/compute_tuning.json
       │
       ▼
[scene_create] ──► Passes settings.Compute_Tuning_Params
       ├──► [ibl_init] ──► Dynamically injects SAMPLE_COUNT / SAMPLE_DELTA defines
       └──► [env_manager_create] ──► Binds dynamic slicing counts (specular/irradiance mips)
```

### Amortized Slicing Processing (`src/scene/env_manager.odin`)

The progressive slicing passes in `env_manager.odin` now dynamically access the slicing configuration from `mgr.compute_tuning.slicing` instead of compile-time constants:

```odin
// Per-slice processing for large specular mips
if mgr.ibl_current_slice == 0 {
    switch mgr.ibl_current_mip {
    case 0:
        mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip0_slices
    case 1:
        mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip1_slices
    case 2:
        mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip2_slices
    case:
        mgr.ibl_total_slices = 1
    }
}
```

---

## 5. Command-Line Options Documentation

To control this pipeline dynamically, we extended the engine's Command Line Interface.

### Option Specification

*   **Flag**: `--compute-profile=<profile_name>`
*   **Allowed Values**:
    *   `legacy` — Compiles shaders and progressive loops with legacy settings. Ensures **pixel-perfect bitwise visual parity** with regression testing reference images.
    *   `optimized` — Injects optimized macro values. Cuts compute shader rendering overheads up to **4x** to smooth out frames on slower devices.
*   **Default**: `legacy`

### Usage Examples

```bash
# Launch with standard high-fidelity rendering (Default)
./build/release/suckless-odin

# Explicitly request Legacy Profile
./build/release/suckless-odin --compute-profile=legacy

# Launch with maximum performance compute profiling active
./build/release/suckless-odin --compute-profile=optimized

# Run benchmark using the optimized compute shader pipeline
./build/release/suckless-odin --benchmark --compute-profile=optimized
```

---

## 6. Verification and Integration Tests

The configuration system has been fully integrated into the test runner framework:

*   **CLI Argument Unit Testing (`src/test_cli.odin`)**:
    Validates correct parsing of `--compute-profile=legacy` and `--compute-profile=optimized` flags, and verifies that invalid profiles trigger clean error exits.
*   **Visual Regression Stability**:
    Because the default profile is `legacy`, the automated headless tests (`task test-gl`) retain 100% pixel-perfect matching with saved reference assets, keeping the CI/CD pipeline green.

---

## 7. Interactive Compute Shader Tuning GUI & Profile CRUD

To provide developers and artists with direct control over visual fidelity versus performance at runtime, a dedicated, Nord-themed **Compute Tuning** interface has been integrated into the user interface.

### Core Features

1. **Staged Draft Workspace & Apply Action**:
   Changing sliders or numbers changes a staged "draft" state to avoid initiating expensive GPU reallocations on every mouse interaction. Changes are applied in bulk by clicking **Apply & Recalculate Active Environment**, which triggers a validation check and calls `apply_compute_tuning_callback` to execute a progressive IBL precomputation using the new settings.
2. **Profile CRUD (Create, Read, Update, Delete)**:
   * **Read**: Select from any existing profile (e.g. `legacy`, `optimized`, or custom ones) via the dynamic profile dropdown combo box.
   * **Create / Clone**: Type a profile name and click **Clone Active Profile** to immediately branch off the current settings into a new named profile.
   * **Update**: Staged edits are marshaled to `assets/configs/compute_tuning.json` upon creation/saving.
   * **Delete**: Delete any user-created custom profiles with a safe fallback that keeps core presets like `legacy` protected.
3. **Field-Level Reset Buttons**:
   Adjacent to every slider and input is a small **Reset** button. Clicking this button immediately restores that individual parameter to its built-in global application default (defined in `settings.DEFAULT_COMPUTE_TUNING`), allowing rapid fine-tuning without losing track of baseline settings.
4. **Type-Safe Sanitization & Validation**:
   The validation system (`settings.validate_compute_tuning_params`) guarantees that parameter entries remain within logical, non-zero positive bounds. In the event of an invalid entry, the GUI displays a temporary warning message and rejects the application.

