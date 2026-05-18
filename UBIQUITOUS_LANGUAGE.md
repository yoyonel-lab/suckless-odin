# Ubiquitous Language

## Application Lifecycle

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **App** | Top-level runtime aggregate owning the window, scene, and GUI | Application, engine, renderer |
| **Scene** | Flat aggregate of rendering resources and runtime state that orchestrates update and render passes | World, scene graph, level |
| **Frame Loop** | The per-frame cycle: poll input → update → clear → render → swap | Game loop, render loop, tick |
| **Delta Time** | Elapsed seconds since the previous frame, used for frame-rate-independent motion | dt, timestep |
| **Fixed Timestep** | Constant time quantum (1/120s) for physics-like camera smoothing, accumulated from delta time | Physics step, fixed update |

## Camera & Locomotion

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Camera** | First-person observer defined by position, orientation (yaw/pitch), and projection parameters | View, eye, player |
| **Yaw** | Horizontal rotation angle of the camera around the world up axis | Heading, azimuth |
| **Pitch** | Vertical rotation angle of the camera, clamped to avoid gimbal lock | Elevation, tilt |
| **Front Vector** | Unit direction the camera is looking at, derived from yaw and pitch | Forward, look direction |
| **Head Bobbing** | Sinusoidal vertical camera offset simulating walking motion | Camera bob, walk cycle |
| **Scroll Impulse** | Instantaneous velocity applied to camera position along front vector from mouse scroll | Zoom, dolly |

## Geometry & Rendering

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Billboard** | Camera-facing quad used as a rasterization proxy for ray-sphere intersection in the fragment shader | Sprite, impostor, card |
| **Ray-Sphere Intersection** | Fragment shader technique reconstructing sphere geometry from a billboard by solving the quadratic ray equation | Sphere tracing, raymarching |
| **Fullscreen Triangle** | Single oversized triangle covering the viewport, used for skybox and post-processing passes | Fullscreen quad, screen quad |
| **Instanced Draw** | Single draw call rendering all sphere billboards via hardware instancing and SSBO data | Batch draw, multi-draw |

## Materials & PBR

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **PBR Material** | A physically-based material defined by albedo, metallic, roughness, and ambient occlusion | Material, shader params |
| **Material Library** | Collection of named PBR material presets loaded from JSON at initialization | Material database, palette |
| **Albedo** | Base color of a surface before lighting | Diffuse color, base color |
| **Metallic** | Binary-ish parameter (0–1) indicating whether a surface is dielectric or metallic | Metallness |
| **Roughness** | Surface microfacet irregularity (0 = mirror, 1 = fully diffuse) | Smoothness (inverse) |
| **F0** | Fresnel reflectance at normal incidence, derived from albedo and metallic | Base reflectivity |
| **Fresnel-Schlick** | Approximation of the Fresnel equation using F0 and view angle | Fresnel term |

## IBL Pipeline

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **IBL** | Image-Based Lighting — ambient lighting derived from an environment map via precomputed integrals | Environment lighting, ambient |
| **IBL Resources** | The trio of precomputed textures (irradiance map, prefilter map, BRDF LUT) plus their compute programs | IBL textures, IBL data |
| **Environment Map** | Equirectangular HDR image representing the scene's surrounding light environment | HDR map, skybox texture, envMap |
| **Irradiance Map** | Precomputed diffuse convolution of the environment map for Lambertian shading | Diffuse IBL, irradiance cubemap |
| **Prefilter Map** | Mip-chain of progressively blurred environment map samples for specular IBL at varying roughness | Specular map, radiance map |
| **BRDF LUT** | 2D lookup texture encoding the split-sum approximation of the Cook-Torrance specular integral | Split-sum LUT, specular BRDF |
| **Compute Shader** | GPU program dispatched on a compute grid to generate IBL textures | Compute kernel |

## Sky & Environment

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Skybox** | Fullscreen pass sampling the environment map as a background using inverse view-projection | Background, skydome, env background |
| **Texture HDR** | GPU texture handle wrapping a loaded equirectangular HDR image (RGBA16F + mipmaps) | HDR texture, float texture |
| **Blur LOD** | Mip level used when sampling the environment map for the skybox background | Background blur, env blur |

## Instancing & Data Layout

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Sphere Instance** | Per-instance payload (center, radius, material, previous center) uploaded to the GPU for PBR shading | Instance data, sphere data |
| **Instanced Spheres** | Manager owning the CPU-side SoA arrays and the GPU-side SSBO of packed sphere instances | Sphere renderer, instance buffer |
| **SSBO** | Shader Storage Buffer Object holding the AoS-packed instance array, bound at index 2 | Instance VBO, instance buffer |
| **SoA** | Structure-of-Arrays layout used on the CPU for cache-friendly per-field iteration | Columnar layout |
| **AoS** | Array-of-Structures layout used for GPU upload (one contiguous struct per instance) | Interleaved layout |

## Shader Subsystem

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Shader** | Compiled and linked GPU program with a cached uniform location map | Program, shader program |
| **Uniform Entry** | Cached location of a named uniform variable, avoiding repeated GL queries | Uniform location |
| **@header Include** | Custom preprocessor directive enabling recursive file inclusion in GLSL sources | #include, shader include |

## Text Overlay & Debug

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Text Overlay** | Bitmap-font debug HUD rendered as baked glyph quads in orthographic projection | Debug text, HUD, OSD |
| **Overlay Mode** | Tri-state display level: Off, FPS+Position, FPS+Position+Environment info | Debug level, verbosity |
| **Font Atlas** | Single texture containing all printable ASCII glyphs for text rendering | Glyph texture, bitmap font |

## GUI & Controls

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **GUI** | ImGui-based control panel exposing runtime-tunable scene and camera parameters | UI, interface, panel |
| **Exposure** | Tone-mapping multiplier for HDR→LDR conversion (placeholder, not yet wired to shaders) | Brightness, EV |
| **Wireframe Toggle** | Runtime switch between filled and wireframe polygon modes | Debug draw, outline mode |

## Configuration & CLI

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Settings** | Compile-time constants defining camera defaults, projection planes, grid dimensions, and AA mode | Config, preferences, params |
| **CLI Action** | Discriminated result of command-line parsing: Continue, Exit_Success, or Exit_Failure | Parse result, CLI state |

## Relationships

- An **App** owns exactly one **Scene** and one **GUI**
- A **Scene** owns one **Camera**, one **Material Library**, one **Billboard** (quad geometry), one **Instanced Spheres** manager, one **Texture HDR**, one **IBL Resources** set, one **Skybox**, one **Text Overlay**, and two **Shaders** (PBR billboard + skybox)
- **Instanced Spheres** depends on **Material Library** to assign a **PBR Material** to each **Sphere Instance**
- **IBL Resources** are computed from the **Texture HDR** (environment map)
- The PBR **Shader** consumes the **SSBO** of **Sphere Instances** and the three **IBL Resources** textures
- The **Skybox** shader consumes the **Texture HDR** directly
- The **Camera** provides view matrix, projection matrix, and position to both the PBR and skybox shaders
- The **GUI** mutates **Camera** parameters and **Scene** runtime toggles

## Example dialogue

> **Dev:** "When the **Scene** initializes, does it create the **IBL Resources** before or after the **Instanced Spheres**?"

> **Domain expert:** "After. The **Instanced Spheres** only need **Material Library** data — they don't reference IBL at all. IBL is consumed at render time by the PBR **Shader**, not by the instance buffer."

> **Dev:** "So each **Sphere Instance** in the **SSBO** stores its own **PBR Material** inline?"

> **Domain expert:** "Yes. During init, we iterate the **Material Library**, assign materials round-robin to a grid of instances, pack them into **AoS** layout, and upload once. The fragment shader reads material fields directly from the **SSBO** — no texture lookups for material data."

> **Dev:** "And the **Billboard** geometry is shared across all instances?"

> **Domain expert:** "Exactly. There's one quad VAO. The **Instanced Draw** call renders N copies; the vertex shader expands each quad using the per-instance center and radius from the **SSBO**. The fragment shader then does **Ray-Sphere Intersection** to reconstruct the actual sphere surface and writes corrected depth."

> **Dev:** "What about the **Skybox** — does it also use IBL textures?"

> **Domain expert:** "No. The **Skybox** samples the raw **Texture HDR** with a **Blur LOD** for the background. The **IBL Resources** (irradiance, prefilter, BRDF LUT) are exclusively for PBR shading of the spheres."

## Flagged ambiguities

- **"Environment map" vs "envMap" vs "environmentMap"**: The same HDR texture is called `environmentMap` in the skybox fragment shader, `envMap` in compute IBL shaders, and `Texture_HDR` in Odin code. Canonical term: **Environment Map** (Odin type: `Texture_HDR`). Shader uniforms should be unified to `environment_map`.

- **"SSBO" vs "instance VBO"** *(resolved)*: A stale comment in `types/types.odin` said "instanced VBO" — fixed to say SSBO. The porting doc's "Instanced VBO (icosphere)" refers to a separate, not-yet-ported legacy feature (traditional mesh instancing), not the current billboard SSBO. No remaining drift.

- **"clamp_threshold" vs "clampThreshold"**: The irradiance compute shader uses `clamp_threshold` (snake_case) while the specular prefilter shader uses `clampThreshold` (camelCase) for the identical concept. Should be unified to `clamp_threshold` (matching GLSL convention in this project).

- **"Exposure"**: Exists as a GUI slider and Scene field, but is not wired into the shader pipeline. Currently a dead parameter. If implemented, it should live in a post-processing pass, not in the PBR shader directly.

- **"Billboard"** *(acceptable — no action needed)*: In general graphics, "billboard" means any camera-facing quad. This engine uses the term in that exact sense: a camera-facing quad. The domain-specific aspect is that the fragment shader performs **Ray-Sphere Intersection** on that quad to reconstruct sphere geometry. The term "billboard" itself is used correctly; the specialization lives in the shader, not in the geometry concept. No qualification needed in code; docs may mention "sphere billboard" for newcomer onboarding.
