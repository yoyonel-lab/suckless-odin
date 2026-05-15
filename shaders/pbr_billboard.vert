#version 450 core

layout(location = 0) in vec3 in_position;  // Quad vertex (+-0.5)

layout(location = 0) out vec3 WorldPos;
layout(location = 1) out vec3 Normal;
flat layout(location = 2) out vec3 SphereCenter;
flat layout(location = 3) out float SphereRadius;
flat layout(location = 4) out vec3 Albedo;
flat layout(location = 5) out float Metallic;
flat layout(location = 6) out float Roughness;
flat layout(location = 7) out float AO;

// Per-instance data from SSBO (128-byte stride, matches C SphereInstance)
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
    float _pad[6];
};

layout(std430, binding = 2) readonly buffer BillboardInstanceSSBO {
    SphereInstance billboard_instances[];
};

uniform mat4 u_view;
uniform mat4 u_projection;

void main()
{
    SphereInstance inst = billboard_instances[gl_InstanceID];

    // Extract radius from model matrix scale
    float scaleX = length(vec3(inst.model[0]));
    float scaleY = length(vec3(inst.model[1]));
    float scaleZ = length(vec3(inst.model[2]));
    SphereRadius = max(scaleX, max(scaleY, scaleZ));
    SphereCenter = vec3(inst.model[3]);

    // Billboard: extract camera axes from view matrix
    vec3 camRight = vec3(u_view[0][0], u_view[1][0], u_view[2][0]);
    vec3 camUp    = vec3(u_view[0][1], u_view[1][1], u_view[2][1]);

    // Expand quad (conservative coverage)
    float size = SphereRadius * 3.0;
    vec3 worldPos = SphereCenter
                  + camRight * in_position.x * size
                  + camUp    * in_position.y * size;

    WorldPos = worldPos;

    // Forward material data
    Albedo    = inst.albedo;
    Metallic  = inst.metallic;
    Roughness = inst.roughness;
    AO        = inst.ao;

    // Camera-facing normal for the quad (real normal from raycasting in frag)
    Normal = -vec3(u_view[0][2], u_view[1][2], u_view[2][2]);

    gl_Position = u_projection * u_view * vec4(worldPos, 1.0);
}
