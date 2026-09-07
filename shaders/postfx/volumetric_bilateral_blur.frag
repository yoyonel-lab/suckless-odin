#version 440 core

// Phase 5: Separable Depth-Aware Joint Bilateral Blur (5-tap & 9-tap)
// Smooths volumetric in-scattering noise while strictly preserving geometric silhouettes.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_source_tex; // In-Scattering color (RGBA16F)
layout(binding = 1) uniform sampler2D u_depth_tex;  // Half-res linear depth in meters (R32F)

uniform vec2  u_blur_dir_step;  // (1/W, 0) for Horizontal pass, (0, 1/H) for Vertical pass
uniform int   u_blur_mode;      // 0: Passthrough (Off), 1: 5-tap Bilateral, 2: 9-tap Bilateral
uniform float u_sharpness;      // Depth falloff sharpness (default 500.0)

// 9-tap 1D Gaussian weights (sigma ≈ 2.0)
const float k_weights_9[5] = float[5](0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622);

// 5-tap 1D Gaussian weights (sigma ≈ 1.2)
const float k_weights_5[3] = float[3](0.4026, 0.2442, 0.0545);

float bilateral_depth_weight(float center_depth, float sample_depth)
{
    float depth_diff = abs(center_depth - sample_depth);
    return 1.0 / (u_sharpness * depth_diff + 1.0);
}

void main()
{
    vec4 center_color = texture(u_source_tex, TexCoords);

    // Mode 0: Passthrough (No blur)
    if (u_blur_mode <= 0) {
        FragColor = center_color;
        return;
    }

    float center_depth = texture(u_depth_tex, TexCoords).r;

    vec4  accum_color  = center_color;
    float accum_weight = 1.0;

    if (u_blur_mode == 1) {
        // =====================================================================
        // 5-Tap Bilateral Filter (Radius 2)
        // =====================================================================
        accum_color  = center_color * k_weights_5[0];
        accum_weight = k_weights_5[0];

        for (int i = 1; i <= 2; ++i) {
            float spatial_w = k_weights_5[i];
            vec2 offset = u_blur_dir_step * float(i);

            // Positive offset tap
            vec2 uv_pos = TexCoords + offset;
            vec4 col_pos = texture(u_source_tex, uv_pos);
            float d_pos = texture(u_depth_tex, uv_pos).r;
            float w_pos = spatial_w * bilateral_depth_weight(center_depth, d_pos);
            accum_color  += col_pos * w_pos;
            accum_weight += w_pos;

            // Negative offset tap
            vec2 uv_neg = TexCoords - offset;
            vec4 col_neg = texture(u_source_tex, uv_neg);
            float d_neg = texture(u_depth_tex, uv_neg).r;
            float w_neg = spatial_w * bilateral_depth_weight(center_depth, d_neg);
            accum_color  += col_neg * w_neg;
            accum_weight += w_neg;
        }
    } else {
        // =====================================================================
        // 9-Tap Bilateral Filter (Radius 4 - Smooth ISO Legacy)
        // =====================================================================
        accum_color  = center_color * k_weights_9[0];
        accum_weight = k_weights_9[0];

        for (int i = 1; i <= 4; ++i) {
            float spatial_w = k_weights_9[i];
            vec2 offset = u_blur_dir_step * float(i);

            // Positive offset tap
            vec2 uv_pos = TexCoords + offset;
            vec4 col_pos = texture(u_source_tex, uv_pos);
            float d_pos = texture(u_depth_tex, uv_pos).r;
            float w_pos = spatial_w * bilateral_depth_weight(center_depth, d_pos);
            accum_color  += col_pos * w_pos;
            accum_weight += w_pos;

            // Negative offset tap
            vec2 uv_neg = TexCoords - offset;
            vec4 col_neg = texture(u_source_tex, uv_neg);
            float d_neg = texture(u_depth_tex, uv_neg).r;
            float w_neg = spatial_w * bilateral_depth_weight(center_depth, d_neg);
            accum_color  += col_neg * w_neg;
            accum_weight += w_neg;
        }
    }

    FragColor = accum_color / max(accum_weight, 0.0001);
}
