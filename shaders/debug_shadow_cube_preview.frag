#version 450 core

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform samplerCube u_shadow_cubemap;

// Visualizes a 3x2 unfolded cubemap grid:
// Top row:    +X (Face 0), +Y (Face 2), +Z (Face 4)
// Bottom row: -X (Face 1), -Y (Face 3), -Z (Face 5)
void main()
{
    vec2 gridUV = TexCoords;
    
    // Determine grid cell (3 cols, 2 rows)
    int col = int(clamp(gridUV.x * 3.0, 0.0, 2.0));
    int row = int(clamp(gridUV.y * 2.0, 0.0, 1.0));
    
    vec2 localUV = fract(gridUV * vec2(3.0, 2.0));
    
    // Draw 1-pixel border lines between faces for clear visual separation
    vec2 border = step(vec2(0.015), localUV) * step(localUV, vec2(0.985));
    float isContent = border.x * border.y;
    
    // Map local UV [0..1] to cubemap face coordinates [-1..1]
    float s = localUV.x * 2.0 - 1.0;
    float t = localUV.y * 2.0 - 1.0;
    
    vec3 dir = vec3(0.0);
    
    if (row == 1) {
        // Top row
        if (col == 0) {
            // +X (Face 0)
            dir = normalize(vec3(1.0, -t, -s));
        } else if (col == 1) {
            // +Y (Face 2)
            dir = normalize(vec3(s, 1.0, t));
        } else {
            // +Z (Face 4)
            dir = normalize(vec3(s, -t, 1.0));
        }
    } else {
        // Bottom row
        if (col == 0) {
            // -X (Face 1)
            dir = normalize(vec3(-1.0, -t, s));
        } else if (col == 1) {
            // -Y (Face 3)
            dir = normalize(vec3(s, -1.0, -t));
        } else {
            // -Z (Face 5)
            dir = normalize(vec3(-s, -t, -1.0));
        }
    }
    
    float depthVal = texture(u_shadow_cubemap, dir).r;
    
    if (isContent < 0.5) {
        FragColor = vec4(0.2, 0.2, 0.25, 1.0); // Border color
    } else {
        // Depth visualization: normalized distance (with false color tint)
        vec3 color;
        if (depthVal >= 0.999) {
            // Background / Skybox (clear depth)
            color = vec3(0.04, 0.04, 0.07);
        } else {
            // Perceptual Viridis-like smooth colormap for depth inspection:
            // Near = Indigo/Blue, Mid = Emerald Green, Far = Warm Amber
            float d = clamp(depthVal * 2.5, 0.0, 1.0); // Normalize depth across scene radius
            vec3 c0 = vec3(0.15, 0.10, 0.45); // Deep Indigo (Near)
            vec3 c1 = vec3(0.10, 0.60, 0.50); // Teal / Emerald (Mid)
            vec3 c2 = vec3(0.95, 0.75, 0.20); // Warm Amber (Far)
            color = (d < 0.5) ? mix(c0, c1, d * 2.0) : mix(c1, c2, (d - 0.5) * 2.0);
        }
        FragColor = vec4(color, 1.0);
    }
}
