#version 440 core

// Volumetric Buffer Preview Shader for Dear ImGui Inspector
// Displays Raw In-Scattering HDR with adjustable exposure boost and tone-mapping.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_volumetric_tex; // RGBA16F (RGB: In-scattering, A: Transmittance)

uniform float u_exposure_boost; // 1.0 to 10.0
uniform int   u_preview_mode;   // 0: RGB In-Scattering, 1: Alpha Transmittance, 2: False Color Heatmap

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
    vec4 vol = texture(u_volumetric_tex, TexCoords);

    if (u_preview_mode == 1) {
        // Transmittance (Grayscale)
        FragColor = vec4(vec3(vol.a), 1.0);
        return;
    }

    if (u_preview_mode == 2) {
        // False Color Heatmap of in-scattering intensity
        float intensity = length(vol.rgb) * u_exposure_boost;
        FragColor = vec4(turbo_colormap(intensity), 1.0);
        return;
    }

    // Default Mode 0: In-Scattering with Exposure Boost + Tonemapping
    vec3 boosted_hdr = vol.rgb * u_exposure_boost;
    vec3 ldr = aces_film(boosted_hdr);
    FragColor = vec4(ldr, 1.0);
}
