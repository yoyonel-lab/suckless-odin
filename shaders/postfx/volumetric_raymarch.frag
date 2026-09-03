#version 440 core

// Volumetric Point Light Raymarching Pass (Phase 3)
// Evaluates in-scattering and transmittance within the light bounding sphere
// using low-res linear depth, omnidirectional shadow cubemap, and Henyey-Greenstein scattering.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor; // RGB: In-Scattering Radiance, A: Transmittance

layout(binding = 0) uniform sampler2D   u_low_res_depth;  // Linear camera depth in meters (W/2 x H/2)
layout(binding = 1) uniform samplerCube u_shadow_cubemap; // Omnidirectional linear depth cubemap

// Camera & Frame Uniforms
uniform mat4  u_inv_view_proj;
uniform vec3  u_cam_pos;
uniform float u_near_plane;
uniform float u_far_plane;
uniform int   u_frame_idx;

// Point Light Uniforms
uniform vec3  u_light_pos;
uniform float u_light_radius;
uniform vec3  u_light_color;
uniform float u_light_intensity;
uniform float u_shadow_bias;
uniform bool  u_shadows_enabled;

// Volumetric Medium Parameters
uniform int   u_step_count;       // 4 to 64 steps (default 16)
uniform float u_scattering_coeff; // Scattering coefficient sigma_s [0.01..2.0]
uniform float u_extinction_coeff; // Extinction coefficient sigma_t [0.0..1.0]
uniform float u_anisotropy_g;     // Henyey-Greenstein eccentricity g [-0.9..+0.9]
uniform float u_intensity_mult;   // Master volumetric intensity [0.0..10.0]
uniform bool  u_jitter_enabled;   // Interleaved gradient noise spatial jittering

const float PI = 3.14159265358979323846;

// Interleaved Gradient Noise (spatial/temporal ray jittering)
float interleaved_gradient_noise(vec2 screen_pos, int frame)
{
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(screen_pos + float(frame % 16) * 5.588238, magic.xy)));
}

// Henyey-Greenstein Normalized Phase Function (phase == 1.0 when g == 0.0, ISO legacy)
// P(theta, g) = (1 - g^2) / (1 + g^2 - 2*g*cos(theta))^(3/2)
float henyey_greenstein(float cos_theta, float g)
{
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cos_theta;
    denom = max(denom, 0.0001);
    return (1.0 - g2) / (denom * sqrt(denom));
}

// Analytic Ray-Sphere Intersection
// Returns true if ray intersects sphere, with enter distance t0 and exit distance t1
bool intersect_ray_sphere(vec3 ray_orig, vec3 ray_dir, vec3 sphere_center, float radius, out float t0, out float t1)
{
    vec3 oc = ray_orig - sphere_center;
    float b = dot(ray_dir, oc);
    float c = dot(oc, oc) - radius * radius;
    float discr = b * b - c;

    if (discr < 0.0) {
        t0 = 0.0;
        t1 = 0.0;
        return false;
    }

    float sqrt_discr = sqrt(discr);
    t0 = -b - sqrt_discr;
    t1 = -b + sqrt_discr;
    return true;
}

void main()
{
    float linear_depth = texture(u_low_res_depth, TexCoords).r;

    // Reconstruct World-Space ray direction
    vec4 clip_pos = vec4(TexCoords * 2.0 - 1.0, 1.0, 1.0);
    vec4 world_h  = u_inv_view_proj * clip_pos;
    vec3 world_pos = world_h.xyz / world_h.w;
    vec3 ray_dir   = normalize(world_pos - u_cam_pos);

    // Max raymarching depth is capped by opaque geometry depth (or far plane)
    float max_ray_len = (linear_depth > 0.0) ? linear_depth : u_far_plane;

    // 1. Intersect Ray with Light Bounding Sphere
    float t_enter, t_exit;
    if (!intersect_ray_sphere(u_cam_pos, ray_dir, u_light_pos, u_light_radius, t_enter, t_exit)) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0); // Completely outside light volume
        return;
    }

    // Clamp marching interval to valid medium region
    float t_start = max(t_enter, u_near_plane);
    float t_end   = min(t_exit, max_ray_len);

    if (t_start >= t_end) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // 2. Raymarching Setup with Precalculated Invariants
    int steps = clamp(u_step_count, 4, 64);
    float step_size = (t_end - t_start) / float(steps);
    vec3 step_dir = ray_dir * step_size;

    // Spatial/temporal ray jittering
    float jitter = (u_jitter_enabled) ? interleaved_gradient_noise(gl_FragCoord.xy, u_frame_idx) : 0.5;
    vec3 sample_pos = u_cam_pos + ray_dir * (t_start + jitter * step_size);

    float base_step_energy = step_size * u_scattering_coeff;
    float inv_light_radius = 1.0 / max(u_light_radius, 0.0001);
    float light_radius_sq = u_light_radius * u_light_radius;

    // Henyey-Greenstein precomputations
    float g = u_anisotropy_g;
    float g2 = g * g;
    float one_minus_g2 = 1.0 - g2;
    float two_g = 2.0 * g;
    bool has_anisotropy = abs(g) >= 0.001;

    float step_transmittance = exp(-max(u_extinction_coeff, 0.0) * step_size);
    float accum_transmittance = 1.0;
    float scattered_amount = 0.0;
    vec3 light_color_intensity = u_light_color * (u_light_intensity * u_intensity_mult);

    // 3. Fast Vectorized Raymarching Loop (zero division, zero sqrt in inner loop)
    for (int i = 0; i < steps; ++i) {
        vec3 light_dir = u_light_pos - sample_pos;
        float dist_sq  = dot(light_dir, light_dir);

        if (dist_sq < light_radius_sq && dist_sq > 0.0001) {
            float inv_dist   = inversesqrt(dist_sq);
            float dist_light = dist_sq * inv_dist;
            float linear_attenuation = clamp(1.0 - dist_light * inv_light_radius, 0.0, 1.0);

            // Phase function evaluated with fast hardware inversesqrt
            float cos_theta = dot(light_dir * inv_dist, ray_dir);
            float phase = 1.0;
            if (has_anisotropy) {
                float denom = max(1.0 + g2 - two_g * cos_theta, 0.0001);
                float inv_denom = inversesqrt(denom);
                phase = one_minus_g2 * (inv_denom * inv_denom * inv_denom);
            }

            // Shadow test from light to sample point
            float shadow_factor = 1.0;
            if (u_shadows_enabled) {
                vec3 light_to_sample = -light_dir;
                float shadow_depth_norm = texture(u_shadow_cubemap, light_to_sample).r;
                if (dist_light - u_shadow_bias > shadow_depth_norm * u_light_radius) {
                    shadow_factor = 0.0;
                }
            }

            scattered_amount += linear_attenuation * base_step_energy * (shadow_factor * phase) * accum_transmittance;
        }

        accum_transmittance *= step_transmittance;
        sample_pos += step_dir;
    }

    FragColor = vec4(scattered_amount * light_color_intensity, accum_transmittance);
}
