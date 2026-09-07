#version 440 core

layout(location = 0) in vec3 a_position;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_light_pos;
uniform float u_bulb_radius;

out vec2 v_uv;
out vec3 v_center_vs;
out vec3 v_pos_vs;

void main()
{
    // a_position.xy is in [-0.5, 0.5], map to [-1.0, 1.0]
    v_uv = a_position.xy * 2.0;

    // View-space light center
    vec4 center_vs4 = u_view * vec4(u_light_pos, 1.0);
    vec3 center_vs = center_vs4.xyz;
    v_center_vs = center_vs;

    // View-space billboard expansion (tight bounding quad)
    float half_size = u_bulb_radius * 1.25;
    vec3 pos_vs = center_vs + vec3(a_position.xy * (half_size * 2.0), 0.0);
    v_pos_vs = pos_vs;

    gl_Position = u_projection * vec4(pos_vs, 1.0);
}
