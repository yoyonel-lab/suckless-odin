#version 450 core

// Volumetric Sun Directional Raymarching Pass (Phase 2)
// Evaluates directional god rays & in-scattering from sun ortho shadow map
// using low-res linear depth, 4-tap PCF, and Henyey-Greenstein phase function.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor; // RGB: In-Scattering Radiance, A: Transmittance

layout(binding = 0) uniform sampler2D u_low_res_depth;   // Linear camera depth in meters (W/2 x H/2)
layout(binding = 1) uniform sampler2D u_sun_shadow_map;  // Orthographic hardware depth map (D32F)
layout(binding = 2) uniform sampler2D u_blue_noise_tex;  // 64x64 periodic blue noise (R8)
layout(binding = 3) uniform sampler3D u_dust_noise_tex3d;// 64x64x64 periodic FBM noise (R8)

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

// Phase 1 Cinematic & Optical Enhancements
uniform bool  u_dual_lobe_enabled;
uniform float u_anisotropy_g_backward; // [-0.99..0.0], default -0.30
uniform float u_dual_lobe_blend;       // [0.0..1.0], default 0.70 (forward weight)
uniform bool  u_crepuscular_boost_enabled;
uniform float u_crepuscular_boost_strength;  // [0.0..5.0], default 2.0
uniform float u_crepuscular_boost_threshold; // [0.0..1.0], default 0.70
uniform bool  u_spectral_scattering_enabled;
uniform vec3  u_spectral_coefficients;       // default vec3(1.20, 1.00, 0.85)

// Phase 2 Corpuscularity & Volumetric Noise
uniform bool  u_blue_noise_jitter_enabled;
uniform bool  u_dust_enabled;
uniform float u_dust_intensity;
uniform float u_dust_scale;
uniform float u_dust_speed;
uniform float u_time;
uniform bool  u_height_fog_enabled;
uniform float u_height_fog_ground_y;
uniform float u_height_fog_falloff;

// Phase 3 Worley Cellular Dust, Depth Window Mask & Multi-Scattering
uniform bool  u_dust_worley_enabled;
uniform float u_dust_worley_blend;      // [0.0..1.0] blend Perlin (0.0) -> Worley (1.0)
uniform bool  u_dust_depth_mask_enabled;
uniform float u_dust_depth_near;        // [0.1..10.0] meters (near focus boundary)
uniform float u_dust_depth_far;         // [5.0..100.0] meters (far focus boundary)
uniform bool  u_multi_scatter_enabled;
uniform float u_multi_scatter_amount;   // [0.0..1.0] isotropic compensation blend weight (default 0.25)

// Mathematical & Quasirandom Constants (Zero Magic Constants)
const float BLUE_NOISE_GOLDEN_X = 0.754877666; // 1 / phi_2
const float BLUE_NOISE_GOLDEN_Y = 0.569840291; // 1 / (phi_2^2)
const vec3  DUST_DRIFT_DIR      = vec3(0.08, 0.04, 0.06); // Normalized convection drift vector

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

    float jitter = 0.5;
    if (u_jitter_enabled) {
        if (u_blue_noise_jitter_enabled) {
            vec2 blue_offset = vec2(float(u_frame_idx % 64) * BLUE_NOISE_GOLDEN_X, float((u_frame_idx / 64) % 64) * BLUE_NOISE_GOLDEN_Y);
            vec2 blue_uv = (gl_FragCoord.xy + blue_offset) / 64.0;
            jitter = texture(u_blue_noise_tex, blue_uv).r;
        } else {
            jitter = interleaved_gradient_noise(gl_FragCoord.xy, u_frame_idx);
        }
    }
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
    if (u_dual_lobe_enabled) {
        float g1 = g;
        float g1_2 = g1 * g1;
        float denom1 = max(1.0 + g1_2 - 2.0 * g1 * cos_theta, 0.0001);
        float inv1 = inversesqrt(denom1);
        float phase1 = (1.0 - g1_2) * (inv1 * inv1 * inv1);

        float g2 = clamp(u_anisotropy_g_backward, -0.99, 0.0);
        float g2_2 = g2 * g2;
        float denom2 = max(1.0 + g2_2 - 2.0 * g2 * cos_theta, 0.0001);
        float inv2 = inversesqrt(denom2);
        float phase2 = (1.0 - g2_2) * (inv2 * inv2 * inv2);

        phase = mix(phase2, phase1, clamp(u_dual_lobe_blend, 0.0, 1.0));
    } else if (has_anisotropy) {
        float denom = max(1.0 + g2 - two_g * cos_theta, 0.0001);
        float inv_denom = inversesqrt(denom);
        phase = one_minus_g2 * (inv_denom * inv_denom * inv_denom);
    }

    // Multi-scattering isotropic background compensation (Phase 3.5)
    if (u_multi_scatter_enabled) {
        phase = mix(phase, 1.0, clamp(u_multi_scatter_amount, 0.0, 1.0));
    }

    // Crepuscular counter-jour boost
    float crepuscular_mult = 1.0;
    if (u_crepuscular_boost_enabled) {
        float boost_factor = smoothstep(u_crepuscular_boost_threshold, 1.0, cos_theta);
        crepuscular_mult += boost_factor * u_crepuscular_boost_strength;
    }

    // Spectral scattering (wavelength-dependent Rayleigh/Mie chromatic shift)
    vec3 spectral_factor = (u_spectral_scattering_enabled) ? u_spectral_coefficients : vec3(1.0);

    float transmittance = 1.0;
    float step_extinction = exp(-u_extinction_coeff * step_size);
    float scattered_amount = 0.0;
    vec3 light_color_intensity = u_sun_color * (u_sun_intensity * u_intensity_mult * crepuscular_mult) * spectral_factor;

    float shadow_res = max(u_shadow_resolution, 512.0);

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
                vec4 depths = textureGather(u_sun_shadow_map, shadow_coords.xy, 0);
                vec4 cmp = step(vec4(current_depth), depths);
                shadow_factor = dot(cmp, vec4(0.25));
            }
        }

        // Density modulation (Phase 2 & 3)
        float density_mod = 1.0;
        if (u_dust_enabled) {
            vec3 dust_coord = sample_pos * u_dust_scale + DUST_DRIFT_DIR * (u_time * u_dust_speed);
            vec2 dust_samples = texture(u_dust_noise_tex3d, dust_coord).rg;
            float dust_sample = dust_samples.r;
            if (u_dust_worley_enabled) {
                dust_sample = mix(dust_samples.r, dust_samples.g, u_dust_worley_blend);
            }

            float depth_mask = 1.0;
            if (u_dust_depth_mask_enabled) {
                float sample_dist = length(sample_pos - u_cam_pos);
                float span = max(0.01, u_dust_depth_far - u_dust_depth_near);
                float d_rel = clamp((sample_dist - u_dust_depth_near) / span, 0.0, 1.0);
                depth_mask = d_rel * (1.0 - d_rel) * 4.0; // Quadratic bell curve [0 -> 1 -> 0]
            }

            density_mod *= mix(1.0, 0.25 + dust_sample * 1.75 * depth_mask, u_dust_intensity);
        }

        if (u_height_fog_enabled) {
            float h_diff = max(0.0, sample_pos.y - u_height_fog_ground_y);
            density_mod *= exp(-h_diff * u_height_fog_falloff);
        }

        scattered_amount += base_step_energy * (shadow_factor * phase * density_mod) * transmittance;
        transmittance *= exp(-u_extinction_coeff * step_size * density_mod);
        sample_pos += step_dir;
    }

    FragColor = vec4(scattered_amount * light_color_intensity, transmittance);
}
