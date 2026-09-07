#version 450 core

// -------------------------------------------------------------------
// Ground Truth Ambient Occlusion Offline Compute Shader
// Computes high-precision cosine-weighted raytraced AO maps
// for a single target sphere on GPU.
// -------------------------------------------------------------------

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output: Single 2D Texture (GL_R8, width x height)
layout(r8, binding = 0) uniform writeonly image2D u_ao_out;

// Input: Per-instance data from SSBO (128-byte stride)
struct SphereInstance {
    mat4 model;
    vec3 albedo;
    float metallic;
    float roughness;
    float ao;
    float padding;
    float prev_center_x;
    float prev_center_y;
    float prev_center_z;
    float prev_radius;
    float flags;
    float pad1;
    float pad2;
};

layout(std430, binding = 2) readonly buffer SphereInstances {
    SphereInstance instances[];
};

uniform int u_target_sphere_idx;
uniform int u_total_spheres;
uniform int u_num_samples;
uniform int u_width;
uniform int u_height;

// Radical inverse for 2D Hammersley sequence
float radical_inverse_vdc(uint bits)
{
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

// Fast Analytical Shadow Ray-Sphere Intersection (zero sqrt)
bool ray_sphere_intersect_fast(vec3 ro, vec3 rd, vec3 center)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    if (b >= 0.0) return false;
    float c = dot(oc, oc) - 1.0; // radius = 1.0
    return (b * b >= c);
}

shared vec3 s_centers[100];

void main()
{
    // Cooperative load of sphere centers into ultra-fast LDS shared memory
    uint local_idx = gl_LocalInvocationIndex;
    if (local_idx < uint(u_total_spheres)) {
        s_centers[local_idx] = instances[local_idx].model[3].xyz;
    }
    barrier();

    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    if (pixel.x >= u_width || pixel.y >= u_height) {
        return;
    }

    int target_sphere = u_target_sphere_idx;
    if (target_sphere >= u_total_spheres) {
        return;
    }

    vec3 target_pos = s_centers[target_sphere];

    // Equirectangular mapping
    float v = (float(pixel.y) + 0.5) / float(u_height);
    float theta = (1.0 - v) * 3.141592653589793; // 0 = +Y (Zenith), PI = -Y (Nadir)
    float u = (float(pixel.x) + 0.5) / float(u_width);
    float phi = u * 6.283185307179586 - 3.141592653589793;

    float sin_t = sin(theta);
    float cos_t = cos(theta);
    vec3 N = vec3(sin_t * cos(phi), cos_t, sin_t * sin(phi));
    vec3 P = target_pos + N;
    vec3 ro = P + N * 0.002;

    // Basis vectors
    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 T = normalize(cross(up, N));
    vec3 B = cross(N, T);

    float visible_count = 0.0;
    int samples = max(u_num_samples, 16);

    for (int k = 0; k < samples; ++k) {
        float u1 = (float(k) + 0.5) / float(samples);
        float u2 = radical_inverse_vdc(uint(k));
        float phi_s = 6.283185307179586 * u1;
        float sin_ts = sqrt(u2);
        float cos_ts = sqrt(1.0 - u2);

        float lx = cos(phi_s) * sin_ts;
        float ly = sin(phi_s) * sin_ts;
        float lz = cos_ts;

        vec3 rd = normalize(T * lx + B * ly + N * lz);

        bool hit = false;
        for (int j = 0; j < u_total_spheres; ++j) {
            if (j == target_sphere) continue;
            vec3 oc_center = s_centers[j];
            // Tangent-plane culling
            if (dot(N, oc_center - P) <= -0.99) continue;

            if (ray_sphere_intersect_fast(ro, rd, oc_center)) {
                hit = true;
                break;
            }
        }

        if (!hit) {
            visible_count += 1.0;
        }
    }

    float ao = clamp(visible_count / float(samples), 0.0, 1.0);
    imageStore(u_ao_out, pixel, vec4(ao, 0.0, 0.0, 0.0));
}
