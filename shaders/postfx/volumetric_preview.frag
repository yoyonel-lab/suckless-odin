#version 440 core

// Volumetric Buffer Preview Shader for Dear ImGui Inspector & Silhouette Debugging
// Displays In-Scattering HDR with exposure boost, bilateral difference, edge contours, and depth weight maps.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_volumetric_tex;    // Filtered in-scattering (RGBA16F)
layout(binding = 1) uniform sampler2D u_unblurred_tex;     // Raw / Pre-blur in-scattering (RGBA16F)
layout(binding = 2) uniform sampler2D u_depth_tex;         // Half-res linear depth in meters (R32F)
layout(binding = 3) uniform sampler2D u_discontinuity_tex; // Geometric edge mask (R8)

uniform float u_exposure_boost; // 1.0 to 10.0
uniform int   u_preview_mode;   
// 0: Final In-Scattering (ACES LDR)
// 1: Raw Pre-TAA / Pre-Blur Grain
// 2: False Color Heatmap (Turbo)
// 3: TAA Acceptance Map
// 4: Bilateral Filtered (Pre-Composite)
// 5: Bilateral Difference Map (|Blurred - Unblurred| * Boost * 10)
// 6: Silhouette Edge Highlight (Volumetric + Neon Red/Magenta Contours)
// 7: Silhouette Edges Only (Isolate Edge Pixels)
// 8: Bilateral Depth-Weight Attenuation Map (1.0 = Full blur / green, <0.2 = Edge stopped / red)
// 9: Transmittance (Grayscale)

uniform float u_sharpness;      // Bilateral sharpness parameter (default 500.0)
uniform vec2  u_texel_size;      // (1.0/width, 1.0/height)
uniform float u_zoom_scale;     // 1.0 (Normal) to 16.0 (Loupe)
uniform vec2  u_zoom_center;    // UV center for magnifier loupe (default 0.5, 0.5)

// ACES Film Tone-mapping curve
vec3 aces_film(vec3 x)
{
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
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
    // Apply optional magnifier / loupe transform
    float zoom = max(u_zoom_scale, 1.0);
    vec2 uv = (TexCoords - u_zoom_center) / zoom + u_zoom_center;

    // Out of bounds check for loupe
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        FragColor = vec4(0.04, 0.04, 0.06, 1.0);
        return;
    }

    vec4 vol = texture(u_volumetric_tex, uv);

    // Mode 9: Transmittance (Grayscale)
    if (u_preview_mode == 9) {
        FragColor = vec4(vec3(vol.a), 1.0);
        return;
    }

    // Mode 2: False Color Heatmap of in-scattering intensity
    if (u_preview_mode == 2) {
        float intensity = length(vol.rgb) * u_exposure_boost;
        FragColor = vec4(turbo_colormap(intensity), 1.0);
        return;
    }

    // Mode 3: TAA Acceptance Map
    if (u_preview_mode == 3) {
        // Sampled directly from u_volumetric_tex if acceptance bound, or pass through
        FragColor = vec4(vol.rgb, 1.0);
        return;
    }

    // Mode 5: Bilateral Difference Map (|Blurred - Unblurred| * Boost * 10)
    if (u_preview_mode == 5) {
        vec4 vol_unblur = texture(u_unblurred_tex, uv);
        float delta = length(vol.rgb - vol_unblur.rgb) * u_exposure_boost * 10.0;
        FragColor = vec4(turbo_colormap(delta), 1.0);
        return;
    }

    // Mode 6: Silhouette Edge Highlight (Volumetric In-Scattering + Neon Red/Magenta Contours)
    if (u_preview_mode == 6) {
        float is_edge = texture(u_discontinuity_tex, uv).r;
        vec3 boosted_hdr = vol.rgb * u_exposure_boost;
        vec3 ldr = aces_film(boosted_hdr);
        vec3 edge_color = vec3(1.0, 0.15, 0.45); // Neon Magenta / Crimson Edge Highlight
        vec3 composite = mix(ldr, edge_color, is_edge * 0.85);
        FragColor = vec4(composite, 1.0);
        return;
    }

    // Mode 7: Silhouette Edges Only (Isolate Edge Pixels, Black Background)
    if (u_preview_mode == 7) {
        float is_edge = texture(u_discontinuity_tex, uv).r;
        vec3 boosted_hdr = vol.rgb * u_exposure_boost;
        vec3 ldr = aces_film(boosted_hdr);
        FragColor = vec4(ldr * is_edge, 1.0);
        return;
    }

    // Mode 8: Bilateral Depth-Weight Attenuation Map
    // Computes average bilateral weight around current pixel to verify edge stopping
    if (u_preview_mode == 8) {
        float center_d = texture(u_depth_tex, uv).r;
        float total_w = 0.0;
        float max_w   = 0.0;

        const float k_weights_9[5] = float[5](0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622);
        total_w += k_weights_9[0] * 2.0;
        max_w   += k_weights_9[0] * 2.0;

        for (int i = 1; i <= 4; ++i) {
            float sw = k_weights_9[i];
            vec2 off_x = vec2(u_texel_size.x * float(i), 0.0);
            vec2 off_y = vec2(0.0, u_texel_size.y * float(i));

            float d_px = texture(u_depth_tex, uv + off_x).r;
            float d_nx = texture(u_depth_tex, uv - off_x).r;
            float d_py = texture(u_depth_tex, uv + off_y).r;
            float d_ny = texture(u_depth_tex, uv - off_y).r;

            float w_px = sw / (u_sharpness * abs(center_d - d_px) + 1.0);
            float w_nx = sw / (u_sharpness * abs(center_d - d_nx) + 1.0);
            float w_py = sw / (u_sharpness * abs(center_d - d_py) + 1.0);
            float w_ny = sw / (u_sharpness * abs(center_d - d_ny) + 1.0);

            total_w += (w_px + w_nx + w_py + w_ny);
            max_w   += sw * 4.0;
        }

        float weight_ratio = clamp(total_w / max(max_w, 0.0001), 0.0, 1.0);
        // Turbo Colormap: 1.0 (Green/Yellow) = Full Blur, <0.2 (Blue/Red/Dark) = Edge Stop
        FragColor = vec4(turbo_colormap(weight_ratio), 1.0);
        return;
    }

    // Modes 0, 1, 4: In-Scattering with Exposure Boost + Tonemapping
    vec3 boosted_hdr = vol.rgb * u_exposure_boost;
    vec3 ldr = aces_film(boosted_hdr);
    FragColor = vec4(ldr, 1.0);
}
