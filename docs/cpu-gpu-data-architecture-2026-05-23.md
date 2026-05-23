# CPU ↔ GPU Data Architecture

> **Date**: 2026-05-23
> **Branch**: feat/postfx-pipeline
> **OpenGL**: 4.6 Core (Mesa Intel Iris Xe)

Complete mapping of all CPU↔GPU resource flows in the suckless-odin renderer.

---

## Table of Contents

1. [Overview Diagram](#overview-diagram)
2. [Buffer Objects (UBO / SSBO)](#buffer-objects)
3. [Vertex Data (VAO / VBO)](#vertex-data)
4. [Textures](#textures)
5. [Framebuffers (FBO)](#framebuffers)
6. [Pixel Buffer Objects (PBO)](#pixel-buffer-objects)
7. [Compute Shader Resources](#compute-shader-resources)
8. [Shader Programs](#shader-programs)
9. [Binding Point Map](#binding-point-map)
10. [Data Flow Timing Diagram](#data-flow-timing-diagram)

---

## Overview Diagram

```mermaid
graph LR
    subgraph CPU ["CPU (Odin)"]
        A[Scene State]
        B[PostFX Params]
        C[Text Overlay]
        D[HDR Image Files]
        E[LUT .cube Files]
        F[Font Atlas Bitmap]
    end

    subgraph GPU ["GPU (OpenGL 4.6)"]
        subgraph Buffers
            UBO0["UBO binding=0
Post_FX_UBO 512B"]
            SSBO2["SSBO binding=2
Sphere_Instance x N"]
        end
        subgraph Geometry
            VAO1["Billboard VAO
4 verts, TRIANGLE_STRIP"]
            VAO2["Fullscreen Triangle VAO
3 verts"]
            VAO3["Skybox VAO
3 verts"]
            VAO4["Overlay VAO
Dynamic text quads"]
        end
        subgraph Textures
            T0[Scene HDR RGBA16F]
            T1[Velocity RG16F]
            T2[Depth D32F]
            T3[Bloom Mip Chain]
            T4[DoF Quarter-res]
            T5["Exposure 1x1 RGBA32F"]
            T6[Env Equirect RGBA16F]
            T7[Cubemap RGBA16F]
            T8[IBL Irradiance/Prefilter]
            T9[BRDF LUT RG16F]
            T10[LUT3D RGB16F]
            T11[Font Atlas R8]
            T12[Tile/Neighbor Max RG16F]
            T13[Tracy Screenshot RGBA8]
        end
    end

    A -->|per-frame| SSBO2
    B -->|per-frame| UBO0
    C -->|per-frame| VAO4
    D -->|once| T6
    E -->|on-change| T10
    F -->|once| T11
```

---

## Buffer Objects

### UBO — Post-Processing Settings (binding = 0)

```mermaid
graph TD
    subgraph CPU
        GUI[GUI Controls] --> Params["Pipeline Params
vignette, bloom, fxaa..."]
        Camera[Camera State] --> Fog[fog_cam_pos, fog_inv_view_proj]
        Params --> UBO_Build[upload_ubo builds Post_FX_UBO]
        Fog --> UBO_Build
    end

    subgraph GPU
        UBO_Build -->|glBufferSubData 512B| UBO["UBO binding=0
PostProcessBlock"]
        UBO --> PostFX_Frag[postfx.frag]
        UBO --> FXAA_Frag[fxaa_prepass.frag]
        UBO --> Fog_GLSL[fog_common.glsl]
    end
```

| Property | Value |
|----------|-------|
| **Source file** | `src/rendering/postfx/pipeline.odin` |
| **Struct** | `Post_FX_UBO` (`src/rendering/postfx/types.odin`) |
| **Size** | 512 bytes (#packed, std140-compatible) |
| **Binding** | `GL_UNIFORM_BUFFER` base 0 |
| **Direction** | CPU → GPU |
| **Frequency** | Per-frame (in `upload_ubo`, triggered by `pipeline_end`) |
| **Upload** | `glBufferSubData(GL_UNIFORM_BUFFER, 0, 512, &ubo)` |
| **GLSL** | `layout(std140, binding = 0) uniform PostProcessBlock { ... }` |

**Layout sections** (512 bytes total):

| Offset | Size | Section |
|--------|------|---------|
| 0 | 16B | Header (active_effects, time, texel_size) |
| 16 | 16B | Vignette |
| 32 | 32B | Film Grain |
| 64 | 16B | Exposure |
| 80 | 16B | Chromatic Aberration |
| 96 | 16B | White Balance |
| 112 | 32B | Color Grading |
| 144 | 32B | Tonemapping |
| 176 | 16B | Bloom |
| 192 | 16B | FXAA |
| 208 | 16B | Depth of Field |
| 224 | 16B | Camera planes |
| 240 | 16B | Motion Blur |
| 256 | 32B | Banding |
| 288 | 112B | Fog (density, color, cam_pos, inv_view_proj mat4) |
| 400 | 16B | LUT3D |
| 416 | 16B | Debug split mask |
| 432 | 80B | Split positions (20 floats) |

---

### SSBO — Sphere Instances (binding = 2)

```mermaid
graph TD
    subgraph CPU
        Materials["PBR Material Library
JSON, 100 spheres"] --> SoA["SoA Storage
Instanced_Spheres"]
        Sort["Distance Sort
back-to-front"] --> SoA
        SoA --> Pack["Pack SoA to AoS
temp_allocator"]
    end

    subgraph GPU
        Pack -->|"glBufferData/SubData
N x 128B"| SSBO["SSBO binding=2
BillboardInstanceSSBO"]
        SSBO --> PBR_Vert["pbr_billboard.vert
gl_InstanceID indexing"]
    end
```

| Property | Value |
|----------|-------|
| **Source file** | `src/rendering/instanced.odin` |
| **CPU struct** | `Sphere_Instance` (`src/rendering/types/types.odin`) |
| **Per-instance** | 128 bytes (#align(64)) |
| **Total** | N × 128B (100 spheres = 12,800B) |
| **Binding** | `GL_SHADER_STORAGE_BUFFER` base 2 |
| **Direction** | CPU → GPU |
| **Frequency** | Per-frame (after sort in `scene_update`) |
| **Upload** | First frame: `glBufferData(DYNAMIC_DRAW)` / subsequent: `glBufferSubData` |
| **Draw** | `glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, count)` |

**Struct layout (std430, 128 bytes)**:

| Offset | Size | Field | Type |
|--------|------|-------|------|
| 0 | 64B | `model` | mat4 |
| 64 | 12B | `albedo` | vec3 |
| 76 | 4B | `metallic` | float |
| 80 | 4B | `roughness` | float |
| 84 | 4B | `ao` | float |
| 88 | 4B | padding | — |
| 92 | 12B | `prev_center` | vec3 (motion blur) |
| 104 | 24B | padding to 128B | #align(64) |

**Compile-time assertions**:

```odin
#assert(size_of(Sphere_Instance) == 128)
#assert(offset_of(Sphere_Instance, albedo) == 64)
#assert(offset_of(Sphere_Instance, prev_center) == 92)
```

---

## Vertex Data

### Billboard Quad VAO

```mermaid
graph LR
    subgraph CPU
        Static["quad_vertices rodata
4 x vec3 = 48B"]
    end
    subgraph GPU
        Static -->|"glBufferData STATIC_DRAW"| VBO[Billboard_QuadVBO]
        VBO --> VAO["Billboard_VAO
attrib 0: vec3"]
        VAO -->|"DrawArraysInstanced
TRIANGLE_STRIP, 4, N"| Raster[Rasterizer]
    end
```

| Property | Value |
|----------|-------|
| **Source** | `src/rendering/billboard.odin` |
| **Vertices** | 4 (triangle strip = 2 triangles) |
| **Layout** | attrib 0: vec3 position |
| **Size** | 48 bytes (static) |
| **Upload** | Once at init |
| **Draw call** | `glDrawArraysInstanced(TRIANGLE_STRIP, 0, 4, instance_count)` |

---

### PostFX Fullscreen Triangle VAO

```mermaid
graph LR
    subgraph CPU
        Tri["fullscreen_triangle_verts rodata
3 x vec2 = 24B"]
    end
    subgraph GPU
        Tri -->|"STATIC_DRAW"| VBO2[PostFX_QuadVBO]
        VBO2 --> VAO2["PostFX_QuadVAO
attrib 0: vec2"]
        VAO2 -->|"DrawArrays(TRIANGLES, 0, 3)"| FS[Full-screen coverage]
    end
```

| Property | Value |
|----------|-------|
| **Source** | `src/rendering/postfx/quad.odin` |
| **Technique** | Single oversized triangle (no diagonal seam) |
| **Vertices** | 3 × vec2 = 24 bytes |
| **Used by** | All postfx passes (bloom, DoF, composite, FXAA) |
| **Upload** | Once at init |

---

### Skybox Fullscreen VAO

| Property | Value |
|----------|-------|
| **Source** | `src/rendering/skybox.odin` |
| **Vertices** | 3 × vec3 = 36 bytes (fullscreen triangle) |
| **Upload** | Once at init |
| **Used by** | Background cubemap render |

---

### Text Overlay Dynamic VAO

```mermaid
graph TD
    subgraph CPU_Frame ["CPU (per frame)"]
        Text["Format strings
FPS, position, env"] --> Gen["Generate vertex stream
x,y,u,v,r,g,b,a per vertex"]
    end

    subgraph GPU
        Gen -->|"glBufferSubData
dynamic portion"| VBO3["Overlay_VBO
MAX_VERTICES x 32B"]
        VBO3 --> VAO3[Overlay_VAO]
        VAO3 --> Draw["DrawArrays TRIANGLES, 0, Nx6"]
    end
```

| Property | Value |
|----------|-------|
| **Source** | `src/rendering/overlay.odin` |
| **Stride** | 8 floats/vertex (32 bytes): x, y, u, v, r, g, b, a |
| **Attribs** | 0: vec2 pos, 1: vec2 uv, 2: vec4 color |
| **Buffer** | Pre-allocated at MAX_VERTICES, orphan + SubData each frame |
| **Direction** | CPU → GPU per frame |
| **Sync strategy** | Buffer orphaning (`BufferData(nil)` before `SubData`) |

---

## Textures

### Environment & IBL Pipeline

```mermaid
graph TD
    subgraph CPU
        HDR_File["cedar_bridge_2_4k.hdr"]
    end

    subgraph GPU
        HDR_File -->|"stbi_loadf, glTexImage2D"| Equirect["Equirect RGBA16F
2D texture"]
        Equirect -->|"Raster shader"| Cubemap["Cubemap RGBA16F
1024x1024 x 6 faces, 11 mips"]
        Cubemap -->|"Compute: irmap.glsl"| Irradiance["Irradiance Map
RGBA16F 128x64"]
        Cubemap -->|"Compute: spmap.glsl"| Prefilter["Prefilter Map
RGBA16F 512x256, 7 mips"]
        GPU_Only["---"] -->|"Compute: spbrdf.glsl"| BRDF["BRDF LUT
RG16F 256x256"]
    end
```

| Texture | Format | Size | Source | Direction | Frequency |
|---------|--------|------|--------|-----------|-----------|
| Environment (equirect) | RGBA16F | W×H (4K typical) | HDR file on disk | CPU→GPU | Once at startup |
| Cubemap | RGBA16F | 1024²×6, 11 mips | equirect→cubemap shader | GPU→GPU | Once at startup |
| Irradiance map | RGBA16F | 128×64 | Compute (irmap.glsl) | GPU→GPU | Once at startup |
| Prefilter map | RGBA16F | 512×256, 7 mips | Compute (spmap.glsl) | GPU→GPU | Once at startup |
| BRDF LUT | RG16F | 256×256 | Compute (spbrdf.glsl) | GPU→GPU | Once at startup |

---

### PostFX Texture Chain

```mermaid
graph LR
    subgraph SceneFBO ["Scene FBO (MRT)"]
        Color["Scene Color
RGBA16F"]
        Vel["Velocity
RG16F"]
        Depth["Depth
D32F"]
    end

    subgraph PostFX ["PostFX Pipeline"]
        Color --> FXAA["FXAA Tex
RGBA16F"]
        Color --> Bloom["Bloom Mips
RGBA16F x5"]
        Color --> DoF_T["DoF Blur
R11G11B10F 1/4 res"]
        Color --> Exposure["Exposure 1x1
RGBA32F"]
        Vel --> TileMax["Tile Max
RG16F"]
        TileMax --> NeighborMax["Neighbor Max
RG16F"]
    end

    subgraph Composite ["Uber-Shader Composite"]
        FXAA --> Final[Final Output]
        Bloom --> Final
        DoF_T --> Final
        Exposure --> Final
        Depth --> Final
        NeighborMax --> Final
        Vel --> Final
    end
```

| Unit | Texture | Format | Resolution | Updated |
|------|---------|--------|------------|---------|
| 0 | Scene color | RGBA16F | Full | Per frame |
| 1 | Bloom result | RGBA16F | ½ chain (5 mips) | Per frame if enabled |
| 2 | Depth | D32F | Full | Per frame |
| 3 | Exposure | RGBA32F | 1×1 | Per frame (compute) |
| 4 | Velocity | RG16F | Full | Per frame (MRT) |
| 5 | DoF blur | R11F_G11F_B10F | ¼ res | Per frame if enabled |
| 6 | Neighbor max velocity | RG16F | Tile res | Per frame if MB |
| 7 | Tile max velocity | RG16F | Tile res | Per frame if MB |
| 8 | LUT 3D | RGB16F | N³ (3D) | On LUT change |

---

### Other Textures

| Texture | Format | Size | Source | Direction | Frequency |
|---------|--------|------|--------|-----------|-----------|
| Font atlas | R8 | 512×512 | stbtt bake (CPU bitmap) | CPU→GPU | Once |
| LUT 3D | RGB16F | N³ (e.g. 33³) | .cube file parse | CPU→GPU | On change |
| Tracy screenshot | RGBA8 | 320×180 | Blit from backbuffer | GPU→GPU→CPU | Per frame |

---

## Framebuffers

### Main Scene FBO

```mermaid
graph TD
    subgraph FBO ["Scene FBO (PostFX_SceneFBO)"]
        CA0["COLOR_ATTACHMENT0
scene_color_tex RGBA16F"]
        CA1["COLOR_ATTACHMENT1
velocity_tex RG16F"]
        DA["DEPTH_ATTACHMENT
depth_tex D32F"]
    end

    PBR[PBR Billboard Shader] -->|"MRT output"| CA0
    PBR -->|"velocity = curr - prev"| CA1
    Skybox[Skybox Shader] --> CA0
```

| Property | Value |
|----------|-------|
| **MRT** | 2 color attachments + depth |
| **Resize** | Recreated on window resize |
| **Drawn by** | PBR billboard shader, skybox shader |
| **Read by** | All postfx passes |

---

### FXAA Pre-Pass FBO

| Property | Value |
|----------|-------|
| **Attachment** | COLOR0: RGBA16F (same format as scene) |
| **Purpose** | Anti-alias scene BEFORE motion blur samples it |
| **Condition** | Active only when FXAA + MotionBlur both enabled |

---

### Bloom FBO (Shared, Re-attached)

| Property | Value |
|----------|-------|
| **Technique** | Single FBO, texture re-attached per mip level |
| **Mip levels** | 5 (each ½ previous) |
| **Passes** | Prefilter → Downsample ×4 → Upsample ×4 |
| **Format** | RGBA16F per mip |

---

### DoF FBO

| Property | Value |
|----------|-------|
| **Resolution** | ¼ scene (width/4 × height/4) |
| **Textures** | blur_tex + temp_tex (R11G11B10F) |
| **Passes** | Downsample → Upsample (ping-pong) |

---

### Tracy Screenshot FBO

| Property | Value |
|----------|-------|
| **Resolution** | 320×180 fixed |
| **Purpose** | Downscale backbuffer for Tracy frame image |
| **Flow** | Blit backbuffer → FBO → ReadPixels into PBO |

---

## Pixel Buffer Objects

### Tracy Frame Image PBO Ring

```mermaid
graph LR
    subgraph GPU
        FBO["Screenshot FBO
320x180"] -->|"glReadPixels
async, PBO bound"| PBO_Ring["PBO Ring Buffer
4 x 230,400B"]
    end

    subgraph CPU
        PBO_Ring -->|"glMapBuffer READ_ONLY
fence-guarded"| Tracy[tracy_gpu_screenshot]
    end
```

| Property | Value |
|----------|-------|
| **Source** | `src/core/tracy/frame_image.odin` |
| **Count** | 4 PBOs (ring buffer) |
| **Size each** | 320 × 180 × 4 = 230,400 bytes |
| **Direction** | GPU → CPU (async readback) |
| **Sync** | `glFenceSync` + `glClientWaitSync` (non-blocking) |
| **Latency** | ~4 frames (ring depth) |
| **Pattern** | Write PBO[i], read PBO[(i+1)%4] — no stall |

---

### Auto-Exposure PBO Pair

```mermaid
graph LR
    subgraph GPU
        Tex["Exposure 1x1 RGBA32F"] -->|"glGetTexImage
PBO bound"| PBO["PBO Double Buffer
2 x 16B"]
    end

    subgraph CPU
        PBO -->|"glMapBuffer READ_ONLY
fence-guarded"| Values["current_exposure
current_scene_lum
current_target"]
    end
```

| Property | Value |
|----------|-------|
| **Source** | `src/rendering/postfx/auto_exposure.odin` |
| **Count** | 2 PBOs (double buffer) |
| **Size each** | 16 bytes (4 × f32) |
| **Direction** | GPU → CPU (async readback for GUI display) |
| **Sync** | `glFenceSync` + non-blocking `ClientWaitSync` |
| **Latency** | 2 frames |

---

## Compute Shader Resources

### Auto-Exposure (Single-Pass)

```mermaid
graph LR
    Scene["Scene HDR tex
sampler unit 0"] --> Compute["lum_single_pass.comp
256 threads, 1 dispatch"]
    Exposure_RW["Exposure tex 1x1
image unit 1 READ_WRITE"] --> Compute
    Compute --> Exposure_RW
```

| Property | Value |
|----------|-------|
| **Shader** | `shaders/postfx/lum_single_pass.comp` |
| **Dispatch** | `(1, 1, 1)` — 256 threads do sample + reduce + adapt |
| **Input** | Scene HDR texture (sampler 0) |
| **Output** | 1×1 RGBA32F exposure texture (image unit 1, READ_WRITE) |
| **Barrier** | `SHADER_IMAGE_ACCESS_BARRIER_BIT | TEXTURE_FETCH_BARRIER_BIT` |

---

### Motion Blur Tile Passes

```mermaid
graph LR
    Vel["Velocity RG16F\nfull-res, sampler 0"] --> TileMax["tile_max_velocity.comp\n16x16 threads/group"]
    TileMax -->|"image unit 1 WRITE"| TileTex["Tile Max RG16F\nceil W/16 x ceil H/16"]
    TileTex -->|"sampler 0"| NeighborMax["neighbor_max_velocity.comp\n3x3 dilation"]
    NeighborMax -->|"image unit 1 WRITE"| NeighborTex["Neighbor Max RG16F"]
```

| Pass | Shader | Dispatch | Input | Output |
|------|--------|----------|-------|--------|
| Tile-max | `tile_max_velocity.comp` | (tile_w, tile_h, 1) | Velocity tex (sampler 0) | tile_max_tex (image 1) |
| Neighbor-max | `neighbor_max_velocity.comp` | (ceil(tw/16), ceil(th/16), 1) | tile_max_tex (sampler 0) | neighbor_max_tex (image 1) |

---

### IBL Compute Passes

| Pass | Shader | Output | Size | Binding |
|------|--------|--------|------|---------|
| BRDF LUT | `shaders/IBL/spbrdf.glsl` | brdf_lut (RG16F) | 256×256 | image 0, WRITE_ONLY |
| Irradiance | `shaders/IBL/irmap.glsl` | irradiance_map (RGBA16F) | 128×64 | image 1, WRITE_ONLY |
| Prefilter | `shaders/IBL/spmap.glsl` | prefilter_map (RGBA16F) | 512×256, 7 mips | image 1, WRITE_ONLY |

All IBL compute passes read the environment cubemap from sampler unit 0.

---

## Shader Programs

### Runtime Programs

| Program | Vertex | Fragment/Compute | Used For |
|---------|--------|------------------|----------|
| PBR Billboard | `pbr_billboard.vert` | `pbr_billboard.frag` | Main scene rendering |
| Skybox Cubemap | `background.vert` | `background_cubemap.frag` | Background render |
| Skybox Cubemap Diff | `background.vert` | `background_cubemap_diff.frag` | Debug mipmap diff |
| Skybox Blur Diff | `background.vert` | `background_blur_diff.frag` | Debug blur diff |
| Equirect→Cubemap | `equirect_to_cubemap.vert` | `equirect_to_cubemap.frag` | HDR to cubemap conversion |
| Cubemap Downsample | — | `downsample_cubemap.frag` | Mip generation |
| PostFX Composite | `postfx/postfx.vert` | `postfx/postfx.frag` | Final uber-shader |
| FXAA Pre-pass | `postfx/postfx.vert` | `postfx/fxaa_prepass.frag` | Anti-aliasing pass |
| Bloom Prefilter | `postfx/postfx.vert` | `postfx/bloom_prefilter.frag` | Bloom threshold |
| Bloom Downsample | `postfx/postfx.vert` | `postfx/bloom_downsample.frag` | 13-tap downsample |
| Bloom Upsample | `postfx/postfx.vert` | `postfx/bloom_upsample.frag` | Tent filter upsample |
| Text Overlay | (inline GLSL) | (inline GLSL) | HUD text |
| Auto-Exposure | — | `postfx/lum_single_pass.comp` | Luminance adaptation |
| Tile Max | — | `postfx/tile_max_velocity.comp` | Motion blur tiles |
| Neighbor Max | — | `postfx/neighbor_max_velocity.comp` | Motion blur dilation |
| IBL Irradiance | — | `IBL/irmap.glsl` | Irradiance convolution |
| IBL Prefilter | — | `IBL/spmap.glsl` | Specular prefilter |
| IBL BRDF | — | `IBL/spbrdf.glsl` | Split-sum BRDF LUT |

### Variant Cache (PostFX)

The composite shader uses `#define` permutations based on active effects:

```
bit 0: Vignette         bit 5: WhiteBalance
bit 1: Grain            bit 6: ColorGrading
bit 2: Exposure         bit 7: Tonemap
bit 3: ChromAbbr        bit 8: Bloom
bit 4: FXAA             bit 9: DoF
...
```

Variants are compiled on-demand and cached in `shader_cache.odin`.

---

## Binding Point Map

### Buffer Bindings

| Type | Binding | Resource | GLSL Block Name |
|------|---------|----------|-----------------|
| UBO | 0 | Post_FX_UBO (512B) | `PostProcessBlock` |
| SSBO | 2 | Sphere_Instance[] (N×128B) | `BillboardInstanceSSBO` |

### Texture Unit Assignments (PostFX Composite)

| Unit | Sampler Name | Texture | Format |
|------|-------------|---------|--------|
| 0 | `screenTexture` | Scene color | RGBA16F |
| 1 | `bloomTexture` | Bloom result | RGBA16F |
| 2 | `depthTexture` | Scene depth | D32F |
| 3 | `exposureTexture` | Auto-exposure | RGBA32F |
| 4 | `velocityTexture` | Velocity buffer | RG16F |
| 5 | `dofTexture` | DoF blur | R11G11B10F |
| 6 | `neighborMaxTexture` | Neighbor max velocity | RG16F |
| 7 | `tileMaxTexture` | Tile max velocity | RG16F |
| 8 | `lut3dTexture` | Color LUT | RGB16F (3D) |

### Compute Image Bindings

| Unit | Shader | Access | Texture |
|------|--------|--------|---------|
| 0 | spbrdf.glsl | WRITE_ONLY | BRDF LUT |
| 1 | irmap.glsl | WRITE_ONLY | Irradiance map |
| 1 | spmap.glsl | WRITE_ONLY | Prefilter map |
| 1 | lum_single_pass.comp | READ_WRITE | Exposure 1×1 |
| 1 | tile_max_velocity.comp | WRITE_ONLY | Tile max tex |
| 1 | neighbor_max_velocity.comp | WRITE_ONLY | Neighbor max tex |

---

## Data Flow Timing Diagram

```mermaid
sequenceDiagram
    participant CPU
    participant UBO as UBO (binding 0)
    participant SSBO as SSBO (binding 2)
    participant SceneFBO as Scene FBO
    participant PostFX as PostFX Chain
    participant Back as Backbuffer
    participant PBO as PBO Ring
    participant Tracy as Tracy Profiler

    Note over CPU: Frame Start
    CPU->>SSBO: instanced_upload (N×128B)
    CPU->>UBO: upload_ubo (512B)

    Note over SceneFBO: Render Pass
    SceneFBO->>SceneFBO: Skybox render (cubemap)
    SceneFBO->>SceneFBO: PBR billboard instanced draw
    Note over SceneFBO: reads SSBO via gl_InstanceID
    Note over SceneFBO: MRT: color + velocity + depth

    Note over PostFX: Post-Processing
    PostFX->>PostFX: Auto-exposure compute (1×1 tex)
    PostFX->>PostFX: Motion blur compute (tile/neighbor)
    PostFX->>PostFX: FXAA pre-pass (if enabled)
    PostFX->>PostFX: Bloom (prefilter→down→up)
    PostFX->>PostFX: DoF (down→up at ¼ res)
    PostFX->>Back: Composite uber-shader → backbuffer

    Note over CPU: Text overlay
    CPU->>Back: Overlay render (dynamic VBO SubData)

    Note over PBO: Async Readback
    Back->>PBO: Tracy blit + ReadPixels (non-blocking)
    PostFX->>PBO: Exposure GetTexImage (non-blocking)
    PBO-->>CPU: MapBuffer (fence-guarded, next frame)
    CPU-->>Tracy: gpu_screenshot()

    Note over CPU: SwapBuffers
```

---

## Memory Budget Summary

| Category | Count | Total Size | Upload Freq |
|----------|-------|-----------|-------------|
| UBO | 1 | 512 B | Per frame |
| SSBO | 1 | 12,800 B (100 instances) | Per frame |
| Static VBOs | 4 | ~156 B | Once |
| Dynamic VBO (overlay) | 1 | ~64 KB (pre-allocated) | Per frame |
| PBO (Tracy) | 4 | 921,600 B (4 × 230,400) | Per frame |
| PBO (Exposure) | 2 | 32 B | Per frame |
| Scene FBO textures | 3 | W×H×(8+4+4) = 16 bytes/pixel | Per frame |
| PostFX textures | ~12 | Variable (bloom mips, ¼ res DoF...) | Per frame |
| IBL textures | 3 | ~5 MB (prefilter + irradiance + BRDF) | Once |
| Environment tex | 2 | ~32 MB (4K equirect + cubemap) | Once |
| Font atlas | 1 | 262,144 B (512²) | Once |
| LUT 3D | 1 | ~215 KB (33³×6B typical) | On change |

---

## Source File Index

| File | Responsibility |
|------|---------------|
| `src/rendering/instanced.odin` | SSBO lifecycle, SoA→AoS pack, upload |
| `src/rendering/types/types.odin` | Sphere_Instance struct + layout asserts |
| `src/rendering/billboard.odin` | Billboard quad VAO/VBO creation |
| `src/rendering/overlay.odin` | Dynamic text VAO, font atlas texture |
| `src/rendering/skybox.odin` | Skybox VAO, cubemap conversion FBO |
| `src/rendering/texture.odin` | HDR equirect texture loading |
| `src/rendering/ibl.odin` | IBL compute dispatches + textures |
| `src/rendering/shader/shader.odin` | Shader compile/link utilities |
| `src/rendering/postfx/pipeline.odin` | Scene FBO, UBO, composite program |
| `src/rendering/postfx/types.odin` | Post_FX_UBO struct, TEX_UNIT constants |
| `src/rendering/postfx/quad.odin` | Fullscreen triangle VAO |
| `src/rendering/postfx/bloom.odin` | Bloom FBO + mip chain |
| `src/rendering/postfx/dof.odin` | DoF FBO + ¼ res textures |
| `src/rendering/postfx/fxaa_prepass.odin` | FXAA FBO + program |
| `src/rendering/postfx/auto_exposure.odin` | Exposure compute + PBO readback |
| `src/rendering/postfx/motion_blur.odin` | Tile/neighbor compute + textures |
| `src/rendering/postfx/lut3d.odin` | 3D LUT texture upload |
| `src/rendering/postfx/gl_helpers.odin` | Texture creation helpers |
| `src/rendering/postfx/shader_cache.odin` | Uber-shader variant cache |
| `src/core/tracy/frame_image.odin` | Screenshot PBO ring + blit |
