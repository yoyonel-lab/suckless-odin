# Distrobox Environment & Native GPU Offloading (Optimus)

This document describes the hybrid architecture used to compile the engine inside an isolated, immutable-friendly container (`distrobox`) while seamlessly offloading the graphical execution to the host's native proprietary drivers (NVIDIA Optimus).

## 1. Transparent Distrobox Compilation

On immutable operating systems like Bazzite, Fedora Silverblue, or uBlue, installing development packages natively (`clang`, `llvm`, etc.) is heavily discouraged. To solve this, `suckless-odin` utilizes a `distrobox` container named `clang-dev` to handle all compilation processes.

### How it works
The `Justfile` dynamically detects if it is running inside the container (via the `$CONTAINER_ID` environment variable).
- **If executed from the host:** The `Justfile` aliases core commands (`odin`, `python3`, `cmake`, `bash`) to prefix them with `distrobox enter clang-dev --`.
- **If executed inside the container:** The commands run natively without double-wrapping.

This ensures the developer can run `just build` directly from the host terminal, and the build will transparently occur within the container. 

> [!IMPORTANT]
> The engine's source code depends on `base` packages located in `/usr/lib/odin`. Because `distrobox enter` does not invoke an interactive login shell, `.bashrc` isn't invariably sourced. The `Justfile` explicitly sets `env ODIN_ROOT=/usr/lib/odin` before injecting the compiler call to prevent an `Internal Compiler Error`.

## 2. Native Execution & NVIDIA Optimus Offloading

While the application **compiles** inside the container, it must **run** directly on the host to properly leverage the proprietary NVIDIA kernel drivers (`libGLX_nvidia.so`) via PRIME Render Offloading.

All `run` targets (like `run-ultra` or `br-ultra`) in the `Justfile` strip the `distrobox` wrapper, executing the compiled binaries (located in `build/`) strictly on the host system.

### Local `.env` Configuration

To force the native executable to utilize the dedicated NVIDIA GPU (instead of defaulting to the Intel iGPU or Mesa software rendering) without passing verbose inline flags, `Just` is configured with `set dotenv-load`. 

You can create a `.env` file at the root of the project with the following configuration:

```env
# NVIDIA PRIME Render Offload Environment Variables
__NV_PRIME_RENDER_OFFLOAD=1
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_onl

# Disable VSync for performance uncapping
vblank_mode=0
__GL_SYNC_TO_VBLANK=0

# Explicitly link system-level proprietary drivers (required for OpenGL ImGui/Glad loading)
LD_LIBRARY_PATH=/usr/lib64

# Enable dynamic MangoHud profiling for the final executable
USE_MANGOHUD=1
```

> [!WARNING]  
> Without `LD_LIBRARY_PATH=/usr/lib64`, the native executable may fail to resolve the NVIDIA implementation of `libGL.so`, causing an immediate crash during application startup (`Failed to initialize OpenGL loader!` inside Dear ImGui).

## 3. Dynamic MangoHud Hooking

The `Justfile` intercepts the `USE_MANGOHUD` variable from your `.env` file. 

Instead of wrapping the entire `just` execution tree (e.g., `mangohud just br-ultra`), which erroneously initializes MangoHud hooks with the Intel GPU before the `.env` variables take effect, the `Justfile` explicitly targets the final binary:

```just
runner := if env_var_or_default("USE_MANGOHUD", "0") == "1" { "mangohud " } else { "" }

run:
    {{ runner }}./build/debug/suckless-odin
```

**Developer Workflow:**
With the `.env` file correctly configured, you can invoke the maximum-performance workflow natively via a single command:
```bash
just br-ultra
```
This single step compiles the optimized codebase inside the `clang-dev` container, offloads execution directly to the NVIDIA GPU, and displays MangoHud profiling metrics natively on the host.
