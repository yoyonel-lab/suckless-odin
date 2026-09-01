#version 450 core

layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 VelocityOut;

layout(location = 0) in vec3 WorldPos;
layout(location = 1) in vec3 Normal;
flat layout(location = 2) in vec3 SphereCenter;
flat layout(location = 3) in float SphereRadius;
flat layout(location = 4) in vec3 Albedo;
flat layout(location = 5) in float Metallic;
flat layout(location = 6) in float Roughness;
flat layout(location = 7) in float AO;
flat layout(location = 8) in vec3 PrevSphereCenter;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform mat4 u_prev_view_proj;
uniform vec3 u_cam_pos;
uniform vec2 u_screen_size;
uniform int u_edge_aa_mode; // 0=off, 1=on, 2=debug
uniform bool u_specular_aa_enabled;
uniform int u_specular_aa_mode; // 0=screen-space, 1=curvature
uniform int u_specular_aa_debug_mode; // 0=off, 1=grayscale-variance, 2=color-difference
uniform bool u_specular_aa_split_enabled;
uniform float u_specular_aa_split_position;

// Point Light & Omnidirectional Shadow Mapping
uniform vec3  u_point_light_pos;
uniform float u_point_light_radius;
uniform vec3  u_point_light_color;
uniform float u_point_light_intensity;
uniform bool  u_point_shadows_enabled;
uniform float u_point_shadow_bias;
uniform float u_point_shadow_normal_bias;
uniform float u_point_shadow_slope_bias;
uniform float u_point_shadow_darkening;
uniform bool  u_point_shadow_debug_mask;

// IBL textures (equirectangular 2D, same binding as suckless-ogl)
layout(binding = 15) uniform sampler2D irradianceMap;
layout(binding = 16) uniform sampler2D prefilterMap;
layout(binding = 17) uniform sampler2D brdfLUT;
layout(binding = 18) uniform samplerCube u_point_shadow_cubemap;

// -------------------------------------------------------------------
// Split-Screen Line Helper
// -------------------------------------------------------------------
vec4 apply_split_line(vec4 color, float edgeFactor)
{
    if (u_specular_aa_split_enabled) {
        float dist = abs(gl_FragCoord.x - u_specular_aa_split_position * u_screen_size.x);
        if (dist < 1.5) {
            return vec4(vec3(0.9, 0.4, 0.0), edgeFactor);
        }
    }
    return color;
}

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
    vec2 brdf = textureLod(brdfLUT, brdfUV, 0.0).rg;

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
// Specular Anti-Aliasing (Varef / Variance-based roughness clamping)
// -------------------------------------------------------------------
float compute_specular_aa_roughness(vec3 N, float roughness, float projectedCurvature, out float out_variance)
{
    float variance = 0.0;
    if (u_specular_aa_mode == 1) {
        // Curvature-based variance (Analytic)
        variance = 50.00 * (projectedCurvature * projectedCurvature);
    } else {
        // Derivative-based variance (Screen-space)
        vec3 dNdx = dFdx(N);
        vec3 dNdy = dFdy(N);
        variance = 50.00 * max(dot(dNdx, dNdx), dot(dNdy, dNdy));
    }

    // Sanitize variance and cap it to prevent "exploding" roughness at geometric silhouettes
    if (variance >= 0.0 && variance <= 0.1) {
        // Keep valid variance
    } else {
        variance = 0.0;
    }
    out_variance = variance;

    // Varef: Add variance to the microfacet distribution variance (roughness^2)
    return sqrt(clamp(roughness * roughness + variance, 0.0, 1.0));
}

// -------------------------------------------------------------------
// Ray-Sphere Intersection
// -------------------------------------------------------------------
bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius,
                     out float t, out vec3 normal,
                     out float discriminant, out bool isInside)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;

    discriminant = h;
    isInside = (c < 0.0);

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
    float discriminant;
    bool isInside;
    bool hit = intersectSphere(u_cam_pos, rayDir, SphereCenter, SphereRadius,
                               t, N, discriminant, isInside);

    if (!hit)
        discard;

    // Correct depth
    vec3 hitPos = u_cam_pos + t * rayDir;
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    gl_FragDepth = clipPos.z / clipPos.w * 0.5 + 0.5;

    // Compute world-space pixel size at hit depth
    float pixelSizeWorld = (2.0 * clipPos.w) / (u_projection[1][1] * u_screen_size.y);

    // Analytic edge smoothing (anti-aliasing)
    float edgeFactor = 1.0;
    if (u_edge_aa_mode > 0) {
        float analyticFwidthH = 2.0 * SphereRadius * pixelSizeWorld;
        edgeFactor = clamp(discriminant / max(analyticFwidthH, 1e-4), 0.0, 1.0);
        edgeFactor = smoothstep(0.0, 1.0, edgeFactor);
    }

    // PBR shading
    vec3 V = normalize(u_cam_pos - hitPos);
    vec3 R = reflect(-V, N);
    float NdotV = max(dot(N, V), 0.0);
    vec3 F0 = mix(vec3(0.04), Albedo, Metallic);

    float uvX = gl_FragCoord.x / u_screen_size.x;
    bool bypass_specular_aa = false;
    if (u_specular_aa_split_enabled && uvX > u_specular_aa_split_position) {
        bypass_specular_aa = true;
    }

    // Specular Anti-Aliasing
    float roughness = max(Roughness, 0.04);
    float spec_aa_variance = 0.0;
    if (u_specular_aa_enabled && !bypass_specular_aa) {
        float projectedCurvature = pixelSizeWorld / max(1e-4, SphereRadius);
        roughness = compute_specular_aa_roughness(N, roughness, projectedCurvature, spec_aa_variance);
    }
    roughness = max(roughness, 0.04);

    vec3 color = compute_IBL_PBR(N, V, R, F0, NdotV,
                                  Albedo, Metallic, roughness, AO);

    if (u_specular_aa_debug_mode == 1 && !bypass_specular_aa) {
        FragColor = apply_split_line(vec4(vec3(spec_aa_variance * 10.0), edgeFactor), edgeFactor);
        return;
    } else if (u_specular_aa_debug_mode == 2 && !bypass_specular_aa) {
        float roughness_no_aa = max(Roughness, 0.04);
        vec3 color_no_aa = compute_IBL_PBR(N, V, R, F0, NdotV,
                                             Albedo, Metallic, roughness_no_aa, AO);
        FragColor = apply_split_line(vec4(abs(color - color_no_aa) * 10.0, edgeFactor), edgeFactor);
        return;
    }

    // Shadow Mapping visibility attenuation with Slope-Scaled & Normal-Offset Auto-Bias
    if (u_point_shadows_enabled) {
        vec3 lightToPos = hitPos - u_point_light_pos;
        float distToLight = length(lightToPos);

        if (distToLight < u_point_light_radius && distToLight > 0.001) {
            vec3 L = -lightToPos / distToLight;
            float NdotL = max(dot(N, L), 0.0);

            // 1. Receiver Normal Offset Bias: shifts sample point outwards along N
            // Scales with (1.0 - NdotL) to expand offset on grazing angles where acne occurs
            float normalOffset = u_point_shadow_normal_bias * (1.0 - NdotL);
            vec3 biasedHitPos = hitPos + N * normalOffset;
            vec3 lightToBiasedPos = biasedHitPos - u_point_light_pos;

            // 2. Slope-Scaled Depth Bias: increases tolerance on steep surface slopes
            float slopeFactor = sqrt(clamp(1.0 - NdotL * NdotL, 0.0, 1.0)) / max(NdotL, 0.05);
            float dynamicBias = u_point_shadow_bias + u_point_shadow_slope_bias * slopeFactor;

            // Sample cubemap along the normal-biased ray direction
            float sampledDepth = texture(u_point_shadow_cubemap, lightToBiasedPos).r;
            float normalizedDist = distToLight / max(0.001, u_point_light_radius);

            float shadow = (normalizedDist - dynamicBias <= sampledDepth) ? 1.0 : 0.0;

            if (u_point_shadow_debug_mask) {
                // Debug mode: highlight shadow mask (Green = Lit, Red = Occluded)
                color = mix(vec3(0.8, 0.1, 0.1), vec3(0.1, 0.9, 0.1), shadow);
            } else {
                // Subtly darken base IBL in shadowed zones (no extra lighting added)
                float lightInfluence = clamp(1.0 - (distToLight / u_point_light_radius), 0.0, 1.0);
                float occlusion = (1.0 - shadow) * lightInfluence * u_point_shadow_darkening;
                color *= (1.0 - occlusion);
            }
        }
    }

    // Debug mode: highlight the AA transition zone
    if (u_edge_aa_mode == 2) {
        // Interior (edgeFactor ~1.0): dim the scene to make edges pop
        // Transition zone (edgeFactor < 0.99): red→yellow→green heatmap
        if (edgeFactor >= 0.99) {
            FragColor = apply_split_line(vec4(color * 0.25, 1.0), edgeFactor);
        } else {
            // Heatmap: 0.0 = red, 0.5 = yellow, 1.0 = green
            vec3 heatmap;
            if (edgeFactor < 0.5) {
                heatmap = mix(vec3(1.0, 0.0, 0.0), vec3(1.0, 1.0, 0.0), edgeFactor * 2.0);
            } else {
                heatmap = mix(vec3(1.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), (edgeFactor - 0.5) * 2.0);
            }
            FragColor = apply_split_line(vec4(heatmap, 1.0), edgeFactor);
        }
    } else {
        // Alpha carries edge factor for blending (GL_BLEND on attachment 0).
        // RGB stays full intensity — the blend equation handles compositing.
        FragColor = apply_split_line(vec4(color, edgeFactor), edgeFactor);
    }

    // Motion blur: per-pixel velocity from raytraced hit position
    // A. Current NDC from actual raytraced hit (not billboard quad vertex)
    vec4 clipPosActual = u_projection * u_view * vec4(hitPos, 1.0);
    vec2 currentPosNDC = clipPosActual.xy / clipPosActual.w;

    // B. Previous NDC: reconstruct previous hit using offset from sphere center
    vec3 prevHitPos = PrevSphereCenter + (hitPos - SphereCenter);
    vec4 previousClip = u_prev_view_proj * vec4(prevHitPos, 1.0);
    vec2 previousPosNDC = previousClip.xy / previousClip.w;

    // C. Delta (0.5 converts NDC [-1,1] to UV [0,1] space)
    VelocityOut = (currentPosNDC - previousPosNDC) * 0.5;
}
