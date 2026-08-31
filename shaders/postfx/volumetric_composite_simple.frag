#version 440 core

// Simple Volumetric In-Scattering Composite Pass
// Additively blends the half-resolution in-scattering buffer into the HDR scene color buffer.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_volumetric_tex; // Linear filtered RGBA16F

void main()
{
    vec4 vol = texture(u_volumetric_tex, TexCoords);
    // Additive in-scattered radiance into scene HDR
    FragColor = vec4(vol.rgb, 1.0);
}
