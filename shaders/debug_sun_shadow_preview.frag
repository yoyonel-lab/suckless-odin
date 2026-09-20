#version 450 core

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D u_sun_depth_map;

void main()
{
    vec2 uv = TexCoords;

    // 1-pixel border lines for visual framing
    vec2 border = step(vec2(0.01), uv) * step(uv, vec2(0.99));
    float isContent = border.x * border.y;

    if (isContent < 0.5) {
        FragColor = vec4(0.2, 0.2, 0.25, 1.0);
        return;
    }

    float depthVal = texture(u_sun_depth_map, uv).r;

    if (depthVal >= 0.9999) {
        // Clear background
        FragColor = vec4(0.04, 0.04, 0.07, 1.0);
    } else {
        // Perceptual Viridis-like smooth colormap for depth inspection:
        // Near = Indigo/Blue, Mid = Emerald Green, Far = Warm Amber
        float d = clamp(depthVal, 0.0, 1.0);
        vec3 c0 = vec3(0.15, 0.10, 0.45); // Deep Indigo (Near)
        vec3 c1 = vec3(0.10, 0.60, 0.50); // Teal / Emerald (Mid)
        vec3 c2 = vec3(0.95, 0.75, 0.20); // Warm Amber (Far)
        vec3 color = (d < 0.5) ? mix(c0, c1, d * 2.0) : mix(c1, c2, (d - 0.5) * 2.0);
        FragColor = vec4(color, 1.0);
    }
}
