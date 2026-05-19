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

// ─── Tight Billboard Projection (ISO port of projection_utils.glsl) ───────────

// Compute 1D projected bounds (NDC) using tangent-line geometry.
void getProjectedBounds(vec2 axis, float radius, float projScale,
                        out float outMin, out float outMax)
{
    float d2 = dot(axis, axis);
    float r2 = radius * radius;

    if (d2 <= r2) {
        outMin = -1.0;
        outMax = 1.0;
        return;
    }

    float L = sqrt(max(0.0, d2 - r2));

    float nx1 = (axis.x * L - axis.y * radius) / d2;
    float nz1 = (axis.y * L + axis.x * radius) / d2;

    float nx2 = (axis.x * L + axis.y * radius) / d2;
    float nz2 = (axis.y * L - axis.x * radius) / d2;

    float p1, p2;

    if (nz1 > -0.001)
        p1 = (nx1 >= 0.0 ? 1.0 : -1.0) * 10000.0;
    else
        p1 = projScale * (nx1 / -nz1);

    if (nz2 > -0.001)
        p2 = (nx2 >= 0.0 ? 1.0 : -1.0) * 10000.0;
    else
        p2 = projScale * (nx2 / -nz2);

    outMin = min(p1, p2);
    outMax = max(p1, p2);
}

// Full billboard sphere projection (handles inside/behind/normal cases).
void computeBillboardSphere(vec3 quadVertexPos, vec3 sphereCenterWorld,
                            float sphereRadius, mat4 view, mat4 projection,
                            out vec4 outClipPos, out vec3 outWorldPos)
{
    vec3 viewPos = (view * vec4(sphereCenterWorld, 1.0)).xyz;
    float distSq = dot(viewPos, viewPos);
    float r2 = sphereRadius * sphereRadius;

    float sx = projection[0][0];
    float sy = projection[1][1];

    if (distSq <= r2 + max(r2 * 0.005, 1e-4)) {
        // Inside sphere: fullscreen quad for ray-casting
        outClipPos = vec4(quadVertexPos.xy * 2.0, 0.0, 1.0);

        vec3 camRight   = vec3(view[0][0], view[1][0], view[2][0]);
        vec3 camUp      = vec3(view[0][1], view[1][1], view[2][1]);
        vec3 camForward = -vec3(view[0][2], view[1][2], view[2][2]);
        vec3 camPos     = -(transpose(mat3(view)) * view[3].xyz);

        outWorldPos = camPos + camForward
                    + camRight * (quadVertexPos.x * 2.0 / sx)
                    + camUp * (quadVertexPos.y * 2.0 / sy);
    } else if (viewPos.z > sphereRadius) {
        // Sphere entirely behind camera: cull
        outClipPos = vec4(-2.0, -2.0, 0.0, 1.0);
        outWorldPos = sphereCenterWorld;
    } else {
        // Normal case: tight projected bounds
        float minX, maxX, minY, maxY;
        getProjectedBounds(vec2(viewPos.x, viewPos.z), sphereRadius, sx, minX, maxX);
        getProjectedBounds(vec2(viewPos.y, viewPos.z), sphereRadius, sy, minY, maxY);

        float ndc_x = (quadVertexPos.x < 0.0) ? minX : maxX;
        float ndc_y = (quadVertexPos.y < 0.0) ? minY : maxY;

        float zNear = projection[3][2] / (projection[2][2] - 1.0);
        float nearestZ = viewPos.z + sphereRadius;
        nearestZ = min(nearestZ, -(zNear + 0.01));

        float clipW = -nearestZ;
        float clipZ = projection[2][2] * nearestZ + projection[3][2];

        outClipPos = vec4(ndc_x * clipW, ndc_y * clipW, clipZ, clipW);

        vec3 vertexViewPos;
        vertexViewPos.z = nearestZ;
        vertexViewPos.x = ndc_x * (-nearestZ) / sx;
        vertexViewPos.y = ndc_y * (-nearestZ) / sy;

        vec3 worldOffset = transpose(mat3(view)) * (vertexViewPos - viewPos);
        outWorldPos = sphereCenterWorld + worldOffset;
    }
}

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

    // Forward material data
    Albedo    = inst.albedo;
    Metallic  = inst.metallic;
    Roughness = inst.roughness;
    AO        = inst.ao;

    // Camera-facing normal for the quad (real normal from raycasting in frag)
    Normal = -vec3(u_view[0][2], u_view[1][2], u_view[2][2]);
}
