#version 440 core

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_tex;

uniform int   u_mode;              // 0: Turbo Heatmap, 1: Linear Grayscale, 2: Discontinuity Mask
uniform float u_min_depth;         // Min depth for heatmap normalization (meters)
uniform float u_max_depth;         // Max depth for heatmap normalization (meters)

// Google Turbo colormap polynomial approximation
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
    float val = texture(u_tex, TexCoords).r;

    if (u_mode == 2) {
        // Discontinuity mask (Edge = white, Flat = dark blue/black)
        vec3 col = (val > 0.5) ? vec3(1.0, 0.2, 0.2) : vec3(0.05, 0.08, 0.12);
        FragColor = vec4(col, 1.0);
        return;
    }

    // Normalize depth range
    float norm = clamp((val - u_min_depth) / max(0.001, u_max_depth - u_min_depth), 0.0, 1.0);

    if (u_mode == 0) {
        // Turbo False-Color Heatmap (Blue=Near -> Cyan -> Green -> Yellow -> Red=Far)
        FragColor = vec4(turbo_colormap(norm), 1.0);
    } else {
        // Linear Grayscale
        FragColor = vec4(vec3(norm), 1.0);
    }
}
