#version 440 core

in vec2 v_uv;
in vec3 v_center_vs;
in vec3 v_pos_vs;

uniform mat4 u_projection;
uniform vec3 u_light_color;
uniform float u_light_intensity;
uniform float u_bulb_radius;

layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 FragVelocity;

void main()
{
    float distSq = dot(v_uv, v_uv);
    if (distSq > 1.0) {
        discard;
    }

    // Analytical sphere raytrace depth in view space
    float z_offset = sqrt(max(0.0, 1.0 - distSq)) * u_bulb_radius;
    vec3 hit_vs = v_pos_vs;
    hit_vs.z += z_offset; // Toward camera (OpenGL view space camera looks along -Z)

    vec4 clip_pos = u_projection * vec4(hit_vs, 1.0);
    float ndc_depth = clip_pos.z / clip_pos.w;
    gl_FragDepth = (ndc_depth * 0.5) + 0.5;

    // Glowing sphere lighting
    float NdotV = sqrt(max(0.0, 1.0 - distSq));
    vec3 base_color = u_light_color * max(1.0, u_light_intensity * 0.5);
    vec3 emissive = base_color * (0.6 + 0.6 * NdotV);

    // Glowing hot white center
    emissive = mix(emissive, vec3(1.2, 1.2, 1.2), pow(NdotV, 3.0) * 0.8);

    FragColor = vec4(emissive, 1.0);
    FragVelocity = vec2(0.0);
}
