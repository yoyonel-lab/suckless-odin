#version 450 core

layout(location = 0) in vec3 in_position; // Quad vertex (+-0.5)

layout(location = 0) out vec3 WorldPos;
flat layout(location = 1) out vec3 SphereCenter;
flat layout(location = 2) out float SphereRadius;

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

void main()
{
    SphereInstance inst = billboard_instances[gl_InstanceID];

    float scaleX = length(vec3(inst.model[0]));
    float scaleY = length(vec3(inst.model[1]));
    float scaleZ = length(vec3(inst.model[2]));
    SphereRadius = max(scaleX, max(scaleY, scaleZ));
    SphereCenter = vec3(inst.model[3]);

    vec4 clipPos;
    vec3 worldPos;
    computeBillboardSphere(in_position, SphereCenter, SphereRadius,
                           u_view, u_projection, clipPos, worldPos);

    WorldPos = worldPos;
    gl_Position = clipPos;
}
