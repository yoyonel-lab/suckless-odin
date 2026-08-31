#version 440 core

// Simple & Edge Debug Volumetric In-Scattering Composite Pass
// Additively blends the in-scattering buffer or edge debug overlay into the HDR scene color buffer.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_volumetric_tex;    // Linear filtered RGBA16F (Active volumetric buffer)
layout(binding = 1) uniform sampler2D u_unblurred_tex;     // Raw / Pre-blur RGBA16F
layout(binding = 2) uniform sampler2D u_discontinuity_tex; // Low-res edge discontinuity mask R8
layout(binding = 3) uniform sampler2D u_depth_tex;         // Low-res linear depth R32F

uniform int   u_composite_mode; // 0: Normal Additive, 1: Neon Silhouette Highlight, 2: Isolated Silhouette Edges, 3: Difference Map, 4: Weight Attenuation Map
uniform float u_exposure_boost; // Default 1.0
uniform float u_sharpness;      // Bilateral sharpness (default 500.0)
uniform vec2  u_texel_size;      // (1.0/width, 1.0/height)

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
    vec4 vol = texture(u_volumetric_tex, TexCoords);

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
        float center_d = texture(u_depth_tex, TexCoords).r;
        float total_w = 0.0;
        float max_w   = 0.0;

        const float k_weights_9[5] = float[5](0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622);
        total_w += k_weights_9[0] * 2.0;
        max_w   += k_weights_9[0] * 2.0;

        for (int i = 1; i <= 4; ++i) {
            float sw = k_weights_9[i];
            vec2 off_x = vec2(u_texel_size.x * float(i), 0.0);
            vec2 off_y = vec2(0.0, u_texel_size.y * float(i));

            float d_px = texture(u_depth_tex, TexCoords + off_x).r;
            float d_nx = texture(u_depth_tex, TexCoords - off_x).r;
            float d_py = texture(u_depth_tex, TexCoords + off_y).r;
            float d_ny = texture(u_depth_tex, TexCoords - off_y).r;

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
