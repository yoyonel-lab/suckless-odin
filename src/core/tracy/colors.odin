package tracy

// Standardized Semantic Color Palette for Tracy Profiler (ISO parity with suckless-vulkan & suckless-ogl)

// --- Main Frame Loop & Core CPU ---
COLOR_FRAME_TOTAL        :: 0x2E7D32 // Emerald / Dark Forest Green (Total Frame)
COLOR_CPU_ACQUIRE        :: 0xEF6C00 // Vivid Orange (Acquire / Event Poll)
COLOR_CPU_UPDATE         :: 0x1976D2 // Royal Cobalt Blue (Scene Update / Uniforms)
COLOR_CPU_UPDATE_CHILD   :: 0x42A5F5 // Light Sky Blue (Process Ready Textures)
COLOR_CPU_RENDER         :: 0x7B1FA2 // Royal Purple (Scene & Pass Recording)
COLOR_CPU_PRESENT        :: 0x00897B // Dark Teal / Sea Green (Swap Buffers / Present)
COLOR_CPU_GUI            :: 0x5C6BC0 // Indigo (ImGui UI rendering)

// --- Async I/O & Assets Thread ---
COLOR_IO_PROCESS         :: 0x4E342E // Espresso Brown (Container Request Loop)
COLOR_IO_DECODE          :: 0xE65100 // Burnt Orange (STBI / Disk Decode)
COLOR_IO_ALLOC           :: 0xFFA000 // Golden Amber (Texture & Buffer Allocation)
COLOR_IO_CONVERT         :: 0x00ACC1 // Cyan (FP32 -> FP16 / SIMD Conversion)
COLOR_IO_READY           :: 0x7CB342 // Apple Light Green (Resource Ready for Upload)
COLOR_IO_FAILED          :: 0xE53935 // Crimson Red (Error / Failure)
COLOR_IO_IDLE            :: 0x9E9E9E // Neutral Gray (Idle Worker Thread)
COLOR_IO_PENDING         :: 0xFDD835 // Vivid Yellow (Queued Request)
COLOR_IO_CLEANUP         :: 0x78909C // Blue Gray (Buffer & Resource Cleanup)

// --- Compute & IBL Pipeline ---
COLOR_GPU_COMPUTE        :: 0xF57F17 // Solar Gold (IBL Compute Shaders)
COLOR_IBL_LUMINANCE      :: 0xFFB300 // Gold / Amber (Luminance Reduction)
COLOR_IBL_BRDF           :: 0x039BE5 // Blue Compute (BRDF Split-Sum LUT)
COLOR_IBL_IRRADIANCE     :: 0xF57C00 // Warm Orange (Irradiance Convolution)
COLOR_IBL_SPECULAR       :: 0xD81B60 // Magenta Compute (Specular GGX Mips)

// --- GPU Raster & Passes ---
COLOR_GPU_PASS           :: 0xD32F2F // Ruby Red (Render Passes)
COLOR_GPU_GEOMETRY       :: 0xFB8C00 // Amber Orange (Instanced Spheres / Geometry)
COLOR_GPU_SKYBOX         :: 0x0288D1 // Sky Blue (Skybox Cubemap & Equirect)
COLOR_GPU_POSTFX         :: 0x8E24AA // Deep Purple (PostFX Pipeline)
COLOR_GPU_OVERLAY        :: 0x0097A7 // Dark Cyan (Overlay / Debug Grid)

// --- Volumetric Lighting & Shadows ---
COLOR_GPU_SHADOW         :: 0xF57F17 // Solar Amber (Shadow Cubemap Pass)
COLOR_GPU_GIZMO          :: 0xFFD600 // Radiant Yellow (Light Bulb Gizmo)
COLOR_GPU_DEPTH_DOWN     :: 0xFF7043 // Coral Orange (Depth Downsample Pass)
COLOR_GPU_VOLUMETRIC     :: 0x00897B // Dark Teal (Volumetric Pipeline)
COLOR_GPU_RAYMARCH       :: 0x00ACC1 // Vivid Cyan (Volumetric Raymarch Pass)
COLOR_GPU_TAA            :: 0x43A047 // Emerald Green (TAA History Blend)
COLOR_GPU_BLUR           :: 0x5C6BC0 // Indigo (Bilateral Blur Pass)
COLOR_GPU_UPSAMPLE       :: 0x7CB342 // Apple Green (JBU Composite Pass)

// --- Post-Processing Subpasses ---
COLOR_POSTFX_BLOOM       :: 0xD81B60 // Bright Magenta (Bloom Pass)
COLOR_POSTFX_DOF         :: 0x546E7A // Slate Blue Gray (Depth of Field)
COLOR_POSTFX_EXPOSURE    :: 0xFFA000 // Golden Amber (Auto Exposure)
COLOR_POSTFX_MB          :: 0x00E5FF // Electric Cyan (Motion Blur Compute)
COLOR_POSTFX_COMPOSITE   :: 0x9C27B0 // Purple (Uber Composite Pass)

// --- Sync & System ---
COLOR_SYNC_WAIT          :: 0x607D8B // Slate Gray (Fences / GPU Sync / Wait Idle)
COLOR_INIT_SHUTDOWN      :: 0x263238 // Midnight Blue (Init & Destroy)

// --- Log Level Colors for Tracy Messages ---
COLOR_LOG_DEBUG          :: 0x757575 // Medium Gray
COLOR_LOG_INFO           :: 0x2196F3 // Blue
COLOR_LOG_WARNING        :: 0xFF9800 // Orange
COLOR_LOG_ERROR          :: 0xF44336 // Red
