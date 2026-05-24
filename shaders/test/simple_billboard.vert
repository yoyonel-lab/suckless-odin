#version 440 core

layout(location = 0) in vec3 in_position;  // Quad vertex (+-0.5)

layout(location = 0) out vec3 WorldPos;
flat layout(location = 1) out vec3 SphereCenter;
flat layout(location = 2) out float SphereRadius;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_sphere_center;
uniform float u_sphere_radius;

// ─── Tight Billboard Projection (ISO port of projection_utils.glsl) ───────────

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
        outClipPos = vec4(quadVertexPos.xy * 2.0, 0.0, 1.0);

        vec3 camRight   = vec3(view[0][0], view[1][0], view[2][0]);
        vec3 camUp      = vec3(view[0][1], view[1][1], view[2][1]);
        vec3 camForward = -vec3(view[0][2], view[1][2], view[2][2]);
        vec3 camPos     = -(transpose(mat3(view)) * view[3].xyz);

        outWorldPos = camPos + camForward
                    + camRight * (quadVertexPos.x * 2.0 / sx)
                    + camUp * (quadVertexPos.y * 2.0 / sy);
    } else if (viewPos.z > sphereRadius) {
        outClipPos = vec4(-2.0, -2.0, 0.0, 1.0);
        outWorldPos = sphereCenterWorld;
    } else {
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
    SphereCenter = u_sphere_center;
    SphereRadius = u_sphere_radius;

    vec4 clipPos;
    vec3 worldPos;
    computeBillboardSphere(in_position, u_sphere_center, u_sphere_radius,
                           u_view, u_projection, clipPos, worldPos);

    WorldPos = worldPos;
    gl_Position = clipPos;
}
