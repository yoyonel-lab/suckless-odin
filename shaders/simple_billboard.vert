#version 440 core

layout(location = 0) in vec3 in_position;  // Quad vertex (+-0.5)

layout(location = 0) out vec3 WorldPos;
flat layout(location = 1) out vec3 SphereCenter;
flat layout(location = 2) out float SphereRadius;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_sphere_center;
uniform float u_sphere_radius;

void main()
{
    SphereCenter = u_sphere_center;
    SphereRadius = u_sphere_radius;

    // Billboard: extract camera right & up from view matrix
    vec3 camRight = vec3(u_view[0][0], u_view[1][0], u_view[2][0]);
    vec3 camUp    = vec3(u_view[0][1], u_view[1][1], u_view[2][1]);

    // Expand quad around sphere center.
    // Factor > 2.0 needed: perspective causes the sphere silhouette
    // to extend beyond the geometric radius on screen.
    // sqrt(3) ≈ 1.732 covers the worst-case diagonal; we use 3.0 for safety
    // (same conservative margin as suckless-ogl's computeBillboardSphere).
    float size = u_sphere_radius * 3.0;
    vec3 worldPos = u_sphere_center
                  + camRight * in_position.x * size
                  + camUp    * in_position.y * size;

    WorldPos = worldPos;
    gl_Position = u_projection * u_view * vec4(worldPos, 1.0);
}
