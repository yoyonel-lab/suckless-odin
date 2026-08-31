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

    // 2. Raymarching Setup (ISO legacy: stepLenWorld & dithering)
    int steps = clamp(u_step_count, 4, 64);
    float step_size = (t_end - t_start) / float(steps);

    // Spatial/temporal ray jittering
    float jitter = 0.5;
    if (u_jitter_enabled) {
        jitter = interleaved_gradient_noise(gl_FragCoord.xy, u_frame_idx);
    }
    float t_current = t_start + jitter * step_size;

    float scattered_amount = 0.0;
    vec3 light_color_intensity = u_light_color * (u_light_intensity * u_intensity_mult);

    // 3. Raymarching Loop (ISO legacy formula)
    for (int i = 0; i < steps; ++i) {
        vec3 sample_pos = u_cam_pos + ray_dir * t_current;
        vec3 light_dir  = u_light_pos - sample_pos;
        float dist_light = length(light_dir);

        if (dist_light < u_light_radius && dist_light > 0.001) {
            // ISO legacy linear attenuation: smooth boundary without 1/d^2 blowup
            float linear_attenuation = clamp((u_light_radius - dist_light) / u_light_radius, 0.0, 1.0);
            float step_energy = linear_attenuation * step_size * u_scattering_coeff;

            // Phase function
            float cos_theta = dot(light_dir / dist_light, ray_dir);
            float phase = (abs(u_anisotropy_g) < 0.001) ? 1.0 : henyey_greenstein(cos_theta, u_anisotropy_g);

            // Shadow test from light to sample point
            float shadow_factor = 1.0;
            if (u_shadows_enabled) {
                vec3 light_to_sample = sample_pos - u_light_pos;
                float shadow_depth = texture(u_shadow_cubemap, light_to_sample).r * u_light_radius;
                if (dist_light - u_shadow_bias > shadow_depth) {
                    shadow_factor = 0.0;
                }
            }

            scattered_amount += step_energy * shadow_factor * phase;
        }

        t_current += step_size;
    }

    FragColor = vec4(scattered_amount * light_color_intensity, 1.0);
}
