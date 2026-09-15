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
flat layout(location = 8) out vec3 PrevSphereCenter;
flat layout(location = 9) out int InstanceID;

// Per-instance data from SSBO (128-byte stride, matches C SphereInstance)
struct SphereInstance {
    mat4 model;
    vec3 albedo;
    float metallic;
    float roughness;
    float ao;
    int id;
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

@header common/sphere_projection.glsl

// ─── Main ─────────────────────────────────────────────────────────────────────

void main()
{
    SphereInstance inst = billboard_instances[gl_InstanceID];

    // Extract radius from model matrix scale
    float scaleX = length(vec3(inst.model[0]));
    float scaleY = length(vec3(inst.model[1]));
    float scaleZ = length(vec3(inst.model[2]));
    SphereRadius = max(scaleX, max(scaleY, scaleZ));
    SphereCenter = vec3(inst.model[3]);

    // Compute tight billboard projection
    vec4 clipPos;
    vec3 worldPos;
    computeBillboardSphere(in_position, SphereCenter, SphereRadius,
                           u_view, u_projection, clipPos, worldPos);

    WorldPos = worldPos;
    gl_Position = clipPos;

    // Previous frame center for per-object motion blur velocity
    PrevSphereCenter = vec3(inst.prev_center_x, inst.prev_center_y, inst.prev_center_z);

    // Forward material data
    Albedo    = inst.albedo;
    Metallic  = inst.metallic;
    Roughness = inst.roughness;
    AO        = inst.ao;
    InstanceID = inst.id;

    // Camera-facing normal for the quad (real normal from raycasting in frag)
    Normal = -vec3(u_view[0][2], u_view[1][2], u_view[2][2]);
}
