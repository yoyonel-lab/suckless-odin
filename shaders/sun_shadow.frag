#version 450 core

layout(depth_greater) out float gl_FragDepth;

layout(location = 0) in vec3 WorldPos;
flat layout(location = 1) in vec3 SphereCenter;
flat layout(location = 2) in float SphereRadius;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_sun_dir; // Vector pointing towards the sun

bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius, out float t)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float discriminant = b * b - c;

    if (discriminant < 0.0)
        return false;

    float sqrtD = sqrt(discriminant);
    float t0 = -b - sqrtD;
    float t1 = -b + sqrtD;

    if (t0 > 0.0) {
        t = t0;
        return true;
    } else if (t1 > 0.0) {
        t = t1;
        return true;
    } else {
        return false;
    }
}

void main()
{
    // Sun rays travel in direction: -u_sun_dir
    vec3 rayDir = -normalize(u_sun_dir);

    // Offset ray origin backwards along ray to ensure it starts outside the sphere
    vec3 ro = WorldPos - rayDir * (SphereRadius * 2.0);

    float t;
    if (!intersectSphere(ro, rayDir, SphereCenter, SphereRadius, t)) {
        discard;
    }

    vec3 hitPos = ro + t * rayDir;

    // Hardware depth buffer (OpenGL NDC [-1, 1] mapped to [0, 1])
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    gl_FragDepth = (clipPos.z / clipPos.w) * 0.5 + 0.5;
}
