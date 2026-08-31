#version 440 core

// Phase 4: Volumetric TAA Reprojection & History Blending Pass
// Re-projects previous frame volumetric buffer, detects disocclusions, and applies EMA temporal filtering.

layout(location = 0) in vec2 TexCoords;

layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec4 OutAcceptanceMap; // Debug: Green = Accepted, Red = Disocclusion, Blue = Offscreen

layout(binding = 0) uniform sampler2D u_current_volumetric; // Half-res newly raymarched in-scattering (RGBA16F)
layout(binding = 1) uniform sampler2D u_history_volumetric; // Half-res previous frame accumulated buffer (RGBA16F)
layout(binding = 2) uniform sampler2D u_current_depth;      // Half-res current frame linear depth in meters (R32F)
layout(binding = 3) uniform sampler2D u_history_depth;      // Half-res previous frame linear depth in meters (R32F)

uniform mat4  u_inv_view_proj;
uniform mat4  u_prev_view_proj;
uniform vec3  u_cam_pos;
uniform vec3  u_prev_cam_pos;
uniform float u_near_plane;
uniform float u_far_plane;

uniform int   u_taa_mode;          // 0: Off (Raw Jitter Grain), 1: Simple Blend (EMA), 2: TAA Reprojection
uniform float u_alpha;             // Current frame blend weight (default 0.20)
uniform float u_depth_threshold;   // Disocclusion depth tolerance in meters (default 0.80)
uniform bool  u_clamping_enabled;  // 3x3 color neighborhood bounding box clamping
uniform bool  u_history_valid;     // False on first frame / reset

void main()
{
    vec4 curr_color = texture(u_current_volumetric, TexCoords);

    // Mode 0: Off / Raw Jitter Passthrough
    if (u_taa_mode == 0) {
        FragColor = curr_color;
        OutAcceptanceMap = vec4(0.5, 0.5, 0.5, 1.0); // Neutral gray
        return;
    }

    // Mode 1: Simple Static EMA Blend (no camera reprojection)
    if (u_taa_mode == 1) {
        if (!u_history_valid) {
            FragColor = curr_color;
            OutAcceptanceMap = vec4(0.1, 1.0, 0.2, 1.0);
            return;
        }
        vec4 prev_color = texture(u_history_volumetric, TexCoords);
        if (u_clamping_enabled) {
            vec2 texel = 1.0 / vec2(textureSize(u_current_volumetric, 0));
            vec4 box_min = curr_color;
            vec4 box_max = curr_color;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    vec4 n = texture(u_current_volumetric, TexCoords + vec2(dx, dy) * texel);
                    box_min = min(box_min, n);
                    box_max = max(box_max, n);
                }
            }
            prev_color = clamp(prev_color, box_min, box_max);
        }
        FragColor = mix(prev_color, curr_color, clamp(u_alpha, 0.01, 1.0));
        OutAcceptanceMap = vec4(0.1, 1.0, 0.2, 1.0); // 100% Green
        return;
    }

    // Mode 2: TAA Reprojection with Camera Motion and Disocclusion Awareness
    float depth = texture(u_current_depth, TexCoords).r;
    float linear_dist = (depth > 0.0) ? depth : u_far_plane;

    // 1. Reconstruct Current World-Space Position
    vec4 clip_pos = vec4(TexCoords * 2.0 - 1.0, 1.0, 1.0);
    vec4 world_h  = u_inv_view_proj * clip_pos;
    vec3 world_pos_far = world_h.xyz / world_h.w;
    vec3 ray_dir = normalize(world_pos_far - u_cam_pos);
    vec3 world_pos = u_cam_pos + ray_dir * linear_dist;

    // 2. Project into Previous Frame Screen Space (UV)
    vec4 prev_clip = u_prev_view_proj * vec4(world_pos, 1.0);
    vec3 prev_ndc  = prev_clip.xyz / prev_clip.w;
    vec2 prev_uv   = prev_ndc.xy * 0.5 + 0.5;

    bool offscreen = (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0 || prev_clip.w <= 0.0);

    float acceptance = 1.0;
    vec4 debug_map = vec4(0.1, 1.0, 0.2, 1.0); // Green = Accepted

    if (offscreen) {
        acceptance = 0.0;
        debug_map = vec4(0.1, 0.4, 1.0, 1.0); // Blue = Offscreen
    } else {
        // Sample previous frame depth at reprojected UV
        float prev_depth = texture(u_history_depth, prev_uv).r;
        float prev_linear_dist = (prev_depth > 0.0) ? prev_depth : u_far_plane;

        float depth_diff = abs(prev_linear_dist - linear_dist);
        if (depth_diff > u_depth_threshold) {
            acceptance = 0.0;
            debug_map = vec4(1.0, 0.1, 0.1, 1.0); // Red = Disocclusion
        } else {
            float scale = 2.0 / max(u_depth_threshold, 0.01);
            acceptance = exp(-depth_diff * scale);
            debug_map = vec4(mix(vec3(1.0, 0.4, 0.1), vec3(0.1, 1.0, 0.2), acceptance), 1.0);
        }
    }

    vec4 prev_color = offscreen ? curr_color : texture(u_history_volumetric, prev_uv);

    // 3. 3x3 Neighborhood Clamping to eliminate ghosting on moving light/objects
    if (u_clamping_enabled) {
        vec2 texel = 1.0 / vec2(textureSize(u_current_volumetric, 0));
        vec4 box_min = curr_color;
        vec4 box_max = curr_color;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                vec4 n = texture(u_current_volumetric, TexCoords + vec2(dx, dy) * texel);
                box_min = min(box_min, n);
                box_max = max(box_max, n);
            }
        }
        prev_color = clamp(prev_color, box_min, box_max);
    }

    float blend_weight = u_alpha;
    float effective_alpha = 1.0 - (1.0 - blend_weight) * acceptance;
    if (!u_history_valid) {
        effective_alpha = 1.0;
    }

    FragColor = mix(prev_color, curr_color, clamp(effective_alpha, 0.0, 1.0));
    OutAcceptanceMap = debug_map;
}
