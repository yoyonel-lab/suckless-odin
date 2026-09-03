#version 440 core

// Joint Bilateral Upsampling (JBU) & Edge Debug Volumetric In-Scattering Composite Pass
// Eliminates half-resolution edge bleeding / staircasing on sphere geometric silhouettes
// by using full-resolution depth guidance during upsampling into the HDR scene color buffer.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_volumetric_tex;    // Low-res active volumetric buffer RGBA16F (W/2 x H/2)
layout(binding = 1) uniform sampler2D u_unblurred_tex;     // Low-res raw / pre-blur RGBA16F (W/2 x H/2)
layout(binding = 2) uniform sampler2D u_discontinuity_tex; // Low-res edge discontinuity mask R8 (W/2 x H/2)
layout(binding = 3) uniform sampler2D u_low_depth_tex;     // Low-res linear depth R32F in meters (W/2 x H/2)
layout(binding = 4) uniform sampler2D u_full_depth_tex;    // Full-res non-linear hardware depth (W x H)

uniform int   u_upsample_mode;      // 0: Bilinear Standard, 1: Nearest-Depth Fast JBU, 2: Joint Bilateral Upsampling 2x2
uniform float u_upsample_sharpness; // Sharpness for JBU depth weight (default 200.0)
uniform float u_near_plane;         // Camera near plane
uniform float u_far_plane;          // Camera far plane
uniform vec2  u_low_res_size;       // (width/2, height/2)

uniform int   u_composite_mode;     // 0: Normal Additive, 1: Neon Silhouette Highlight, 2: Isolated Silhouette Edges, 3: Difference Map, 4: Weight Attenuation Map
uniform float u_exposure_boost;     // Default 1.0
uniform float u_sharpness;          // Bilateral blur sharpness (default 500.0)
uniform vec2  u_texel_size;         // (1.0/width, 1.0/height) of low-res buffer

// Converts non-linear hardware depth [0..1] to linear view-space depth in meters [near..far]
float linearize_depth(float depth)
{
    float z_ndc = depth * 2.0 - 1.0;
    return (2.0 * u_near_plane * u_far_plane) / (u_far_plane + u_near_plane - z_ndc * (u_far_plane - u_near_plane));
}

// Samples low-res volumetric buffer with full-res depth-guided upsampling (Phase 6)
vec4 sample_upsampled_volumetric(vec2 uv)
{
    if (u_upsample_mode == 0) {
        // Mode 0: Bilinear Standard (Legacy / Naive baseline)
        return texture(u_volumetric_tex, uv);
    }

    // Full-resolution linear depth at current pixel
    float raw_full_d = texture(u_full_depth_tex, uv).r;
    float full_z = linearize_depth(raw_full_d);

    // Coordinate in low-res texel space
    vec2 low_coord = uv * u_low_res_size - 0.5;
    vec2 low_base  = floor(low_coord);
    vec2 f         = fract(low_coord);

    // 4 Neighbor UVs in low-res texture
    vec2 uv00 = (low_base + vec2(0.5, 0.5)) / u_low_res_size;
    vec2 uv10 = (low_base + vec2(1.5, 0.5)) / u_low_res_size;
    vec2 uv01 = (low_base + vec2(0.5, 1.5)) / u_low_res_size;
    vec2 uv11 = (low_base + vec2(1.5, 1.5)) / u_low_res_size;

    // 4 Low-res depth taps (already stored in linear meters)
    float z00 = textureLod(u_low_depth_tex, uv00, 0.0).r;
    float z10 = textureLod(u_low_depth_tex, uv10, 0.0).r;
    float z01 = textureLod(u_low_depth_tex, uv01, 0.0).r;
    float z11 = textureLod(u_low_depth_tex, uv11, 0.0).r;

    // 4 Low-res volumetric color taps
    vec4 c00 = textureLod(u_volumetric_tex, uv00, 0.0);
    vec4 c10 = textureLod(u_volumetric_tex, uv10, 0.0);
    vec4 c01 = textureLod(u_volumetric_tex, uv01, 0.0);
    vec4 c11 = textureLod(u_volumetric_tex, uv11, 0.0);

    // Mode 1: Nearest-Depth Heuristic (Fast JBU / Vulkan & Unreal style)
    if (u_upsample_mode == 1) {
        float dz00 = abs(full_z - z00);
        float dz10 = abs(full_z - z10);
        float dz01 = abs(full_z - z01);
        float dz11 = abs(full_z - z11);

        float min_dz = dz00;
        vec4 best_c = c00;

        if (dz10 < min_dz) { min_dz = dz10; best_c = c10; }
        if (dz01 < min_dz) { min_dz = dz01; best_c = c01; }
        if (dz11 < min_dz) { min_dz = dz11; best_c = c11; }

        return best_c;
    }

    // Mode 2: Full 2x2 Joint Bilateral Upsampling (JBU)
    float w00_spatial = (1.0 - f.x) * (1.0 - f.y);
    float w10_spatial = f.x * (1.0 - f.y);
    float w01_spatial = (1.0 - f.x) * f.y;
    float w11_spatial = f.x * f.y;

    float norm_z = max(full_z, u_near_plane);
    float w00_depth = 1.0 / (1.0 + u_upsample_sharpness * (abs(full_z - z00) / norm_z));
    float w10_depth = 1.0 / (1.0 + u_upsample_sharpness * (abs(full_z - z10) / norm_z));
    float w01_depth = 1.0 / (1.0 + u_upsample_sharpness * (abs(full_z - z01) / norm_z));
    float w11_depth = 1.0 / (1.0 + u_upsample_sharpness * (abs(full_z - z11) / norm_z));

    float w00 = w00_spatial * w00_depth;
    float w10 = w10_spatial * w10_depth;
    float w01 = w01_spatial * w01_depth;
    float w11 = w11_spatial * w11_depth;

    float total_w = w00 + w10 + w01 + w11;

    if (total_w > 1e-4) {
        return (c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11) / total_w;
    } else {
        // Fallback to nearest depth tap on extreme boundary
        float min_dz = abs(full_z - z00);
        vec4 best_c = c00;
        if (abs(full_z - z10) < min_dz) { min_dz = abs(full_z - z10); best_c = c10; }
        if (abs(full_z - z01) < min_dz) { min_dz = abs(full_z - z01); best_c = c01; }
        if (abs(full_z - z11) < min_dz) { best_c = c11; }
        return best_c;
    }
}

// Google Turbo colormap
vec3 turbo_colormap(float x)
{
    x = clamp(x, 0.0, 1.0);
    const vec4 kRedVec4   = vec4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const vec4 kGreenVec4 = vec4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const vec4 kBlueVec4  = vec4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const vec2 kRedVec2   = vec2(-152.94239396, 59.28637943);
    const vec2 kGreenVec2 = vec2(4.27729857, 2.82956604);
    const vec2 kBlueVec2  = vec2(-89.90310912, 27.34824973);

    vec4 v4 = vec4(1.0, x, x * x, x * x * x);
    vec2 v2 = v4.zw * v4.z;

    return clamp(vec3(
        dot(v4, kRedVec4)   + dot(v2, kRedVec2),
        dot(v4, kGreenVec4) + dot(v2, kGreenVec2),
        dot(v4, kBlueVec4)  + dot(v2, kBlueVec2)
    ), 0.0, 1.0);
}

void main()
{
    vec4 vol = sample_upsampled_volumetric(TexCoords);

    // Mode 0: Standard Additive In-Scattering
    if (u_composite_mode <= 0) {
        FragColor = vec4(vol.rgb, 1.0);
        return;
    }

    // Mode 1: Neon Silhouette Highlight
    if (u_composite_mode == 1) {
        float is_edge = texture(u_discontinuity_tex, TexCoords).r;
        vec3 neon_edge = vec3(2.5, 0.2, 0.8); // Glowing neon magenta edge
        FragColor = vec4(vol.rgb + neon_edge * is_edge, 1.0);
        return;
    }

    // Mode 2: Isolated Silhouette Edges
    if (u_composite_mode == 2) {
        float is_edge = texture(u_discontinuity_tex, TexCoords).r;
        FragColor = vec4(vol.rgb * is_edge * 2.0, 1.0);
        return;
    }

    // Mode 3: Difference Map
    if (u_composite_mode == 3) {
        vec4 vol_unblur = texture(u_unblurred_tex, TexCoords);
        float delta = length(vol.rgb - vol_unblur.rgb) * u_exposure_boost * 10.0;
        FragColor = vec4(turbo_colormap(delta), 1.0);
        return;
    }

    // Mode 4: Bilateral Weight Attenuation Map
    if (u_composite_mode == 4) {
        float center_d = texture(u_low_depth_tex, TexCoords).r;
        float total_w = 0.0;
        float max_w   = 0.0;

        const float k_weights_9[5] = float[5](0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622);
        total_w += k_weights_9[0] * 2.0;
        max_w   += k_weights_9[0] * 2.0;

        for (int i = 1; i <= 4; ++i) {
            float sw = k_weights_9[i];
            vec2 off_x = vec2(u_texel_size.x * float(i), 0.0);
            vec2 off_y = vec2(0.0, u_texel_size.y * float(i));

            float d_px = texture(u_low_depth_tex, TexCoords + off_x).r;
            float d_nx = texture(u_low_depth_tex, TexCoords - off_x).r;
            float d_py = texture(u_low_depth_tex, TexCoords + off_y).r;
            float d_ny = texture(u_low_depth_tex, TexCoords - off_y).r;

            float w_px = sw / (u_sharpness * abs(center_d - d_px) + 1.0);
            float w_nx = sw / (u_sharpness * abs(center_d - d_nx) + 1.0);
            float w_py = sw / (u_sharpness * abs(center_d - d_py) + 1.0);
            float w_ny = sw / (u_sharpness * abs(center_d - d_ny) + 1.0);

            total_w += (w_px + w_nx + w_py + w_ny);
            max_w   += sw * 4.0;
        }

        float weight_ratio = clamp(total_w / max(max_w, 0.0001), 0.0, 1.0);
        FragColor = vec4(turbo_colormap(weight_ratio), 1.0);
        return;
    }

    FragColor = vec4(vol.rgb, 1.0);
}
