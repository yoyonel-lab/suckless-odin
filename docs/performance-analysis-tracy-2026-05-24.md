# Performance Analysis (Tracy Profiler)
**Date:** 2026-05-24
**Context:** OpenGL Post-Processing Pipeline implementation in Odin.

## 1. Frame Analysis Overview
A trace capture using Tracy Profiler (v0.13.1) revealed critical insights regarding the CPU and GPU load distribution during the rendering of the OpenGL Post-Processing pipeline.

The analysis definitively disproves the initial hypothesis that the Odin language's dynamic nature, allocator overhead, or garbage collection inserts "micro-bubbles" into the execution pipeline.

## 2. CPU Thread (Odin) Execution
The main CPU thread executes the entirety of the frame submission (`Render_Frame`, `Scene_Render`, `Post_Processing`, etc.) in an extraordinarily short time window (**< 0.5 milliseconds**). 
- **No CPU Bubbles:** The frame submission is perfectly contiguous. The Odin language is extremely fast and robust, yielding zero CPU-side stalling during command generation.
- **Swap_Buffers Bottleneck:** After submitting all draw calls, the CPU enters `glfwSwapBuffers` (or equivalent) and is blocked for the remaining ~9 milliseconds of the frame. This indicates the CPU is sleeping, waiting for the GPU driver to clear the command queue or waiting for VSync.

## 3. GPU Pipeline & Driver Bubbles
The GPU execution track displays visible gaps (bubbles) between sequential rendering passes (e.g., between `Skybox_Pass`, `Instanced_PBR_Spheres`, and `Post_Processing`). 

Since the CPU has already submitted all commands, these gaps are entirely localized to the GPU / Driver side:
1. **Costly State Changes:** Rebinding Framebuffers (FBOs), switching complex shader programs, and reconfiguring pipeline states forces the GPU's Command Processor to stall.
2. **Instrumentation Overhead:** The use of `glQueryCounter` for Tracy's GPU profiling incurs a measurable driver-level context switch on proprietary NVIDIA drivers, artificially stretching the gaps on the profiler timeline.
3. **Memory Bandwidth (VRAM):** Consecutive Post-Processing passes (Bloom downsampling/upsampling, Final Composite) are notoriously memory-bound. Reading and writing full-screen textures repeatedly saturates the GPU memory bus.

## 4. Architectural Recommendations (Uber-shader)
To eliminate GPU-side state changes and alleviate memory bandwidth saturation, an **Uber-shader (Mega-shader)** strategy is recommended for the Post-Processing pipeline:

- **Collapse Pixel-Local Effects:** Effects such as Auto-Exposure, Tonemapping, Gamma Correction, Color Grading, and FXAA should be mathematically combined into a single, unified `Composite_UberShader`. This allows a pixel to be fetched from VRAM once, fully processed in high-speed registers, and written out once.
- **Isolate Spatial Effects:** Effects requiring wide sampling radii (Bloom, Depth of Field, Motion Blur, SSAO) cannot be collapsed efficiently into a single pass. These must remain as pre-passes.
- **Hybrid Pipeline:** The optimal pipeline executes the Spatial pre-passes (e.g., `PostFX_Bloom`) first, then feeds their resulting textures as inputs into the `Composite_UberShader` for the final combined full-screen pass.
