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
uniform int   u_point_shadow_debug_mode; // 0=Off, 1=Mask, 2=Penumbra, 3=Delta vs Hard, 4=Split-Screen
uniform float u_point_shadow_split_pos;  // 0.0 .. 1.0
uniform int   u_point_shadow_pcf_samples;
uniform float u_point_shadow_filter_radius;
uniform bool  u_point_shadow_pcf_jitter;
uniform bool  u_point_shadow_temporal_jitter;
uniform int   u_frame_count;

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
    if (u_point_shadows_enabled && u_point_shadow_debug_mode == 4) {
        float dist = abs(gl_FragCoord.x - u_point_shadow_split_pos * u_screen_size.x);
        if (dist < 1.5) {
            return vec4(vec3(0.1, 0.75, 1.0), edgeFactor); // Cyan separator line
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
// Interleaved Gradient Noise (Jorge Jimenez, Call of Duty: AW)
// -------------------------------------------------------------------
float ign_noise(vec2 screen_pos)
{
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(screen_pos, magic.xy)));
}

// -------------------------------------------------------------------
// Point Shadow PCF Filtering (Vogel-Disk Distribution + Stochastic Rotation)
// -------------------------------------------------------------------
float compute_point_shadow_pcf(vec3 lightToBiasedPos, float normalizedDist, float dynamicBias)
{
    if (u_point_shadow_pcf_samples <= 1) {
        float sampledDepth = texture(u_point_shadow_cubemap, lightToBiasedPos).r;
        return (normalizedDist - dynamicBias <= sampledDepth) ? 1.0 : 0.0;
    }

    vec3 dir = normalize(lightToBiasedPos);
    vec3 up = abs(dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    float rotation = 0.0;
    if (u_point_shadow_pcf_jitter) {
        float base_ign = ign_noise(gl_FragCoord.xy);
        if (u_point_shadow_temporal_jitter) {
            float temporal_offset = fract(float(u_frame_count) * 0.61803398875);
            rotation = fract(base_ign + temporal_offset) * 6.28318530718;
        } else {
            rotation = base_ign * 6.28318530718;
        }
    }

    float cosRot = cos(rotation);
    float sinRot = sin(rotation);

    int numSamples = (u_point_shadow_pcf_samples >= 16) ? 16 : 8;
    float shadowSum = 0.0;
    const float GOLDEN_ANGLE = 2.39996323;

    for (int i = 0; i < numSamples; ++i) {
        float r = sqrt((float(i) + 0.5) / float(numSamples)) * u_point_shadow_filter_radius;
        float theta = float(i) * GOLDEN_ANGLE;

        // Apply stochastic IGN rotation
        float x = r * (cos(theta) * cosRot - sin(theta) * sinRot);
        float y = r * (sin(theta) * cosRot + cos(theta) * sinRot);

        vec3 sampleDir = lightToBiasedPos + tangent * x + bitangent * y;
        float sampledDepth = texture(u_point_shadow_cubemap, sampleDir).r;
        shadowSum += (normalizedDist - dynamicBias <= sampledDepth) ? 1.0 : 0.0;
    }

    return shadowSum / float(numSamples);
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

            if (NdotL <= 0.0001) {
                // Surface facing away from light is 100% occluded (zero direct visibility)
                float shadow = 0.0;
                if (u_point_shadow_debug_mode == 1 || u_point_shadow_debug_mask) {
                    color = vec3(0.85, 0.1, 0.1);
                } else if (u_point_shadow_debug_mode == 6) {
                    color = vec3(0.0);
                } else {
                    float lightInfluence = clamp(1.0 - (distToLight / u_point_light_radius), 0.0, 1.0);
                    float occlusion = lightInfluence * u_point_shadow_darkening;
                    color *= (1.0 - occlusion);
                }
            } else {
                // Smooth geometric terminator falloff (eliminates silhouette acne and grazing light leaks)
                float terminator = smoothstep(0.0, 0.06, NdotL);

                // 1. Receiver Normal Offset Bias: scaled by (1.0 - NdotL) to expand bias at grazing angles
                float normalOffset = u_point_shadow_normal_bias * clamp(1.0 - NdotL, 0.0, 1.0);
                vec3 biasedHitPos = hitPos + N * normalOffset;
                vec3 lightToBiasedPos = biasedHitPos - u_point_light_pos;

                // 2. Slope-Scaled Depth Bias: increases tolerance on steep surface slopes
                float slopeFactor = sqrt(clamp(1.0 - NdotL * NdotL, 0.0, 1.0)) / max(NdotL, 0.05);
                float dynamicBias = u_point_shadow_bias + u_point_shadow_slope_bias * slopeFactor;

                // 3. Compute baseline 1-tap Hard shadow (unfiltered)
                float sampledDepthHard = texture(u_point_shadow_cubemap, lightToBiasedPos).r;
                float normalizedDist = distToLight / max(0.001, u_point_light_radius);
                float shadowHard = (normalizedDist - dynamicBias <= sampledDepthHard) ? 1.0 : 0.0;
                shadowHard *= terminator;

                // 4. Compute active PCF shadow (1-tap, Vogel 8-tap, or Vogel 16-tap)
                float shadowPCF = compute_point_shadow_pcf(lightToBiasedPos, normalizedDist, dynamicBias);
                shadowPCF *= terminator;

                // 5. Select effective shadow factor (Left=Hard 1-tap, Right=Active PCF in Split-Screen)
                float shadow = shadowPCF;
                if (u_point_shadow_debug_mode == 4) {
                    shadow = (uvX < u_point_shadow_split_pos) ? shadowHard : shadowPCF;
                }

                // 6. Handle Debug Visualization Modes
                if (u_point_shadow_debug_mode == 1 || u_point_shadow_debug_mask) {
                    // Mode 1: Shadow Mask (Green = Lit, Red = Occluded)
                    color = mix(vec3(0.85, 0.1, 0.1), vec3(0.1, 0.9, 0.1), shadow);
                } else if (u_point_shadow_debug_mode == 2) {
                    // Mode 2: Penumbra / Softness Heatmap
                    float penumbra = 1.0 - abs(shadow * 2.0 - 1.0);
                    vec3 penumbraColor = vec3(penumbra * 1.6, penumbra * 0.8 + pow(penumbra, 3.0) * 0.2, pow(penumbra, 6.0));
                    color = mix(color * 0.15, penumbraColor, clamp(penumbra * 2.5, 0.0, 1.0));
                } else if (u_point_shadow_debug_mode == 3) {
                    // Mode 3: Delta vs Hard 1-tap Heatmap (|PCF - Hard|)
                    float delta = shadowPCF - shadowHard;
                    vec3 diffColor = vec3(0.0);
                    if (delta > 0.001) {
                        diffColor = mix(vec3(0.0, 0.1, 0.3), vec3(0.1, 0.7, 1.0), delta * 1.5);
                    } else if (delta < -0.001) {
                        diffColor = mix(vec3(0.3, 0.05, 0.0), vec3(1.0, 0.2, 0.1), -delta * 1.5);
                    }
                    color = mix(color * 0.2, diffColor, clamp(abs(delta) * 3.0, 0.0, 1.0));
                } else if (u_point_shadow_debug_mode == 5) {
                    // Mode 5: Temporal Jitter Phase Distribution Heatmap
                    float base_ign = ign_noise(gl_FragCoord.xy);
                    float temporal_offset = fract(float(u_frame_count) * 0.61803398875);
                    float phase = fract(base_ign + temporal_offset);
                    vec3 phaseColor = vec3(sin(phase * 6.283) * 0.5 + 0.5, cos(phase * 6.283) * 0.5 + 0.5, phase);
                    color = mix(color * 0.1, phaseColor, 0.85);
                } else if (u_point_shadow_debug_mode == 6) {
                    // Mode 6: Only Shadow Factor (Pure Grayscale: 1.0=White/Lit, 0.0=Black/Occluded)
                    color = vec3(shadow);
                } else {
                    // Mode 0 & 4: Normal Shading / Split-Screen comparison
                    float lightInfluence = clamp(1.0 - (distToLight / u_point_light_radius), 0.0, 1.0);
                    float occlusion = (1.0 - shadow) * lightInfluence * u_point_shadow_darkening;
                    color *= (1.0 - occlusion);
                }
            }
        } else if (u_point_shadow_debug_mode == 6) {
            color = vec3(0.0);
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
        // In shadow diagnostic views (Mode 1 & Mode 6), force alpha=1.0 to prevent skybox background contamination
        float outAlpha = (u_point_shadow_debug_mode == 6 || u_point_shadow_debug_mode == 1 || u_point_shadow_debug_mask) ? 1.0 : edgeFactor;
        FragColor = apply_split_line(vec4(color, outAlpha), outAlpha);
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
