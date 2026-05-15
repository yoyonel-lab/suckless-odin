#version 450 core

layout(location = 0) out vec4 FragColor;

layout(location = 0) in vec3 WorldPos;
layout(location = 1) in vec3 Normal;
flat layout(location = 2) in vec3 SphereCenter;
flat layout(location = 3) in float SphereRadius;
flat layout(location = 4) in vec3 Albedo;
flat layout(location = 5) in float Metallic;
flat layout(location = 6) in float Roughness;
flat layout(location = 7) in float AO;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_cam_pos;

// IBL textures (equirectangular 2D, same binding as suckless-ogl)
layout(binding = 15) uniform sampler2D irradianceMap;
layout(binding = 16) uniform sampler2D prefilterMap;
layout(binding = 17) uniform sampler2D brdfLUT;

// -------------------------------------------------------------------
// Constants
// -------------------------------------------------------------------
const float PI = 3.14159265359;
const float EPSILON = 1e-6;

// -------------------------------------------------------------------
// Equirectangular UV from direction
// -------------------------------------------------------------------
vec2 dirToUV(vec3 v)
{
    float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
    vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
    uv *= vec2(0.1591, 0.3183);  // 1/2PI, 1/PI
    uv += 0.5;
    return uv;
}

// -------------------------------------------------------------------
// Fresnel-Schlick with roughness
// -------------------------------------------------------------------
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
    float f = pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * f;
}

// -------------------------------------------------------------------
// IBL PBR with multiple scattering compensation
// (ISO port of compute_IBL_PBR_Advanced from suckless-ogl)
// -------------------------------------------------------------------
vec3 compute_IBL_PBR(vec3 N, vec3 V, vec3 R, vec3 F0, float NdotV,
                     vec3 albedo, float metallic, float roughness, float ao)
{
    vec3 F = fresnelSchlickRoughness(NdotV, F0, roughness);

    // Diffuse IBL
    vec3 kS = F;
    vec3 kD = (1.0 - kS) * (1.0 - metallic);
    vec3 irradiance = textureLod(irradianceMap, dirToUV(N), 0.0).rgb;
    irradiance = max(irradiance, vec3(0.0));
    vec3 diffuse = irradiance * albedo;

    // Specular IBL (split-sum)
    const float MAX_REFLECTION_LOD = 4.0;
    vec3 prefilteredColor = textureLod(prefilterMap, dirToUV(R),
                                       roughness * MAX_REFLECTION_LOD).rgb;
    prefilteredColor = max(prefilteredColor, vec3(0.0));

    // BRDF LUT lookup (texel-center correction)
    vec2 brdfUV = vec2(NdotV, roughness);
    vec2 texSize = vec2(textureSize(brdfLUT, 0));
    brdfUV = brdfUV * (texSize - 1.0) / texSize + 0.5 / texSize;
    vec2 brdf = texture(brdfLUT, brdfUV).rg;

    // Multiple scattering compensation
    vec3 FssEss = F * brdf.x + brdf.y;
    vec3 Favg = F0 + (1.0 - F0) * (1.0 / 21.0);
    float Ess = brdf.x + brdf.y;
    vec3 Fms = Favg * FssEss / max(1.0 - Favg * (1.0 - Ess), EPSILON);
    vec3 multipleScattering = Fms * (1.0 - Ess);

    vec3 specular = prefilteredColor * (FssEss + multipleScattering);

    // Final energy conservation
    kD = (1.0 - (FssEss + multipleScattering)) * (1.0 - metallic);

    return (kD * diffuse + specular) * ao;
}

// -------------------------------------------------------------------
// Ray-Sphere Intersection
// -------------------------------------------------------------------
bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius,
                     out float t, out vec3 normal)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;

    if (h < 0.0)
        return false;

    h = sqrt(h);
    float t1 = -b - h;
    float t2 = -b + h;

    if (t1 >= 0.0)
        t = t1;
    else if (t2 >= 0.0)
        t = t2;
    else
        return false;

    vec3 hitPos = ro + t * rd;
    normal = normalize(hitPos - center);
    return true;
}

// -------------------------------------------------------------------
// Main
// -------------------------------------------------------------------
void main()
{
    vec3 rayDir = normalize(WorldPos - u_cam_pos);

    float t;
    vec3 N;
    bool hit = intersectSphere(u_cam_pos, rayDir, SphereCenter, SphereRadius, t, N);

    if (!hit)
        discard;

    // Correct depth
    vec3 hitPos = u_cam_pos + t * rayDir;
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    gl_FragDepth = clipPos.z / clipPos.w * 0.5 + 0.5;

    // PBR shading
    vec3 V = normalize(u_cam_pos - hitPos);
    vec3 R = reflect(-V, N);
    float NdotV = max(dot(N, V), 0.0);
    vec3 F0 = mix(vec3(0.04), Albedo, Metallic);

    float roughness = max(Roughness, 0.04);

    vec3 color = compute_IBL_PBR(N, V, R, F0, NdotV,
                                  Albedo, Metallic, roughness, AO);

    FragColor = vec4(color, 1.0);
}
