#version 440 core

layout(location = 0) in vec2 TexCoords;

layout(location = 0) out float out_linear_depth;
layout(location = 1) out float out_discontinuity;

layout(binding = 0) uniform sampler2D u_full_depth_tex;

uniform vec2  u_texel_size;      // (1.0 / full_width, 1.0 / full_height)
uniform float u_near_plane;      // camera near plane
uniform float u_far_plane;       // camera far plane
uniform float u_edge_threshold;  // discontinuity threshold in world units (meters)

// Converts non-linear hardware depth [0..1] to linear view-space depth in meters [near..far]
float linearize_depth(float depth)
{
    float z_ndc = depth * 2.0 - 1.0;
    return (2.0 * u_near_plane * u_far_plane) / (u_far_plane + u_near_plane - z_ndc * (u_far_plane - u_near_plane));
}

void main()
{
    // Gather 4 depth taps in full-resolution grid
    vec2 uv00 = TexCoords - u_texel_size * 0.5;
    vec2 uv10 = uv00 + vec2(u_texel_size.x, 0.0);
    vec2 uv01 = uv00 + vec2(0.0, u_texel_size.y);
    vec2 uv11 = uv00 + u_texel_size;

    float raw_d00 = texture(u_full_depth_tex, uv00).r;
    float raw_d10 = texture(u_full_depth_tex, uv10).r;
    float raw_d01 = texture(u_full_depth_tex, uv01).r;
    float raw_d11 = texture(u_full_depth_tex, uv11).r;

    float d0 = linearize_depth(raw_d00);
    float d1 = linearize_depth(raw_d10);
    float d2 = linearize_depth(raw_d01);
    float d3 = linearize_depth(raw_d11);

    // Compute min and max across the 4 taps
    float min_d = min(min(d0, d1), min(d2, d3));
    float max_d = max(max(d0, d1), max(d2, d3));

    // 4-tap median: average of the two middle ranked values
    float median_d = (d0 + d1 + d2 + d3 - min_d - max_d) * 0.5;

    // Output 0: Conservative / median linear depth
    out_linear_depth = median_d;

    // Output 1: Geometric depth discontinuity mask
    float depth_delta = max_d - min_d;
    // Relative depth step threshold to handle perspective foreshortening at distance
    float rel_threshold = max(u_edge_threshold, min_d * 0.02);
    float is_edge = (depth_delta > rel_threshold && min_d < (u_far_plane * 0.99)) ? 1.0 : 0.0;

    out_discontinuity = is_edge;
}
