#version 450 core

layout(location = 0) in vec3 WorldPos;
flat layout(location = 1) in vec3 SphereCenter;
flat layout(location = 2) in float SphereRadius;

layout(location = 0) out float LinearDepth;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_light_pos;
uniform float u_light_radius;

// Ray-Sphere intersection
bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius,
                     out float t, out vec3 normal)
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
    } else if (t1 > 0.0) {
        t = t1;
    } else {
        return false;
    }

    vec3 hitPos = ro + t * rd;
    normal = (hitPos - center) / radius;
    return true;
}

void main()
{
    vec3 rayDir = normalize(WorldPos - u_light_pos);

    float t;
    vec3 N;
    bool hit = intersectSphere(u_light_pos, rayDir, SphereCenter, SphereRadius, t, N);

    if (!hit) {
        discard;
    }

    vec3 hitPos = u_light_pos + t * rayDir;

    // Hardware depth buffer
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    gl_FragDepth = clipPos.z / clipPos.w * 0.5 + 0.5;

    // Linear normalized radial distance [0.0..1.0] for volumetric raymarching
    float dist = length(hitPos - u_light_pos);
    LinearDepth = clamp(dist / max(0.001, u_light_radius), 0.0, 1.0);
}
