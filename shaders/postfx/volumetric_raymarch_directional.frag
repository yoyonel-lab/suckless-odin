#version 450 core

// Volumetric Sun Directional Raymarching Pass (Phase 2)
// Evaluates directional god rays & in-scattering from sun ortho shadow map
// using low-res linear depth, 4-tap PCF, and Henyey-Greenstein phase function.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor; // RGB: In-Scattering Radiance, A: Transmittance

layout(binding = 0) uniform sampler2D u_low_res_depth;   // Linear camera depth in meters (W/2 x H/2)
layout(binding = 1) uniform sampler2D u_sun_shadow_map;  // Orthographic hardware depth map (D32F)

// Camera & Frame Uniforms
uniform mat4  u_inv_view_proj;
uniform vec3  u_cam_pos;
uniform float u_near_plane;
uniform float u_far_plane;
uniform int   u_frame_idx;

// Sun Directional Light Uniforms
uniform mat4  u_sun_view_proj;
uniform vec3  u_sun_dir;        // Direction pointing towards the sun
uniform vec3  u_sun_color;
uniform float u_sun_intensity;
uniform float u_shadow_bias;
uniform bool  u_shadows_enabled;
uniform float u_shadow_resolution;
uniform float u_max_ray_distance;

// Volumetric Medium Parameters
uniform int   u_step_count;       // 4 to 64 steps (default 20)
uniform float u_scattering_coeff; // Scattering coefficient sigma_s [0.01..2.0]
uniform float u_extinction_coeff; // Extinction coefficient sigma_t [0.0..1.0]
uniform float u_anisotropy_g;     // Henyey-Greenstein eccentricity g [-0.9..+0.9]
uniform float u_intensity_mult;   // Master volumetric intensity [0.0..10.0]
uniform bool  u_jitter_enabled;   // Interleaved gradient noise spatial jittering

// Interleaved Gradient Noise (spatial/temporal ray jittering)
float interleaved_gradient_noise(vec2 screen_pos, int frame)
{
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(screen_pos + float(frame % 16) * 5.588238, magic.xy)));
}

void main()
{
    float linear_depth = texture(u_low_res_depth, TexCoords).r;

    // Reconstruct World-Space ray direction
    vec4 clip_pos = vec4(TexCoords * 2.0 - 1.0, 1.0, 1.0);
    vec4 world_h  = u_inv_view_proj * clip_pos;
    vec3 world_pos = world_h.xyz / world_h.w;
    vec3 ray_dir   = normalize(world_pos - u_cam_pos);

    float max_dist = (u_max_ray_distance > 0.0) ? u_max_ray_distance : 64.0;
    float t_start = u_near_plane;
    float t_end = (linear_depth > 0.0) ? min(linear_depth, max_dist) : max_dist;

    if (t_start >= t_end) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    int steps = clamp(u_step_count, 4, 64);
    float step_size = (t_end - t_start) / float(steps);
    vec3 step_dir = ray_dir * step_size;

    float jitter = (u_jitter_enabled) ? interleaved_gradient_noise(gl_FragCoord.xy, u_frame_idx) : 0.5;
    vec3 sample_pos = u_cam_pos + ray_dir * (t_start + jitter * step_size);

    float base_step_energy = step_size * u_scattering_coeff;

    // Henyey-Greenstein precomputations
    float g = u_anisotropy_g;
    float g2 = g * g;
    float one_minus_g2 = 1.0 - g2;
    float two_g = 2.0 * g;
    bool has_anisotropy = abs(g) >= 0.001;

    // Directional Phase Function:
    // When ray_dir aligns with u_sun_dir (camera looking towards sun), cos_theta ~ 1
    float cos_theta = dot(normalize(u_sun_dir), ray_dir);
    float phase = 1.0;
    if (has_anisotropy) {
        float denom = max(1.0 + g2 - two_g * cos_theta, 0.0001);
        float inv_denom = inversesqrt(denom);
        phase = one_minus_g2 * (inv_denom * inv_denom * inv_denom);
    }

    float transmittance = 1.0;
    float step_extinction = exp(-u_extinction_coeff * step_size);
    float scattered_amount = 0.0;
    vec3 light_color_intensity = u_sun_color * (u_sun_intensity * u_intensity_mult);

    float shadow_res = max(u_shadow_resolution, 512.0);
    vec2 texel_size = vec2(1.0 / shadow_res);
    const vec2 pcf_offsets[4] = vec2[](
        vec2(-0.5, -0.5),
        vec2( 0.5, -0.5),
        vec2(-0.5,  0.5),
        vec2( 0.5,  0.5)
    );

    for (int i = 0; i < steps; ++i) {
        float shadow_factor = 1.0;
        if (u_shadows_enabled) {
            vec4 light_clip = u_sun_view_proj * vec4(sample_pos, 1.0);
            vec3 light_ndc = light_clip.xyz / light_clip.w;
            vec3 shadow_coords = light_ndc * 0.5 + 0.5;

            if (shadow_coords.x >= 0.0 && shadow_coords.x <= 1.0 &&
                shadow_coords.y >= 0.0 && shadow_coords.y <= 1.0 &&
                shadow_coords.z >= 0.0 && shadow_coords.z <= 1.0) {

                float current_depth = shadow_coords.z - u_shadow_bias;
                float shadow_sum = 0.0;
                for (int k = 0; k < 4; ++k) {
                    float d = texture(u_sun_shadow_map, shadow_coords.xy + pcf_offsets[k] * texel_size).r;
                    shadow_sum += (current_depth <= d) ? 1.0 : 0.0;
                }
                shadow_factor = shadow_sum * 0.25;
            }
        }

        scattered_amount += base_step_energy * (shadow_factor * phase) * transmittance;
        transmittance *= step_extinction;
        sample_pos += step_dir;
    }

    FragColor = vec4(scattered_amount * light_color_intensity, transmittance);
}
