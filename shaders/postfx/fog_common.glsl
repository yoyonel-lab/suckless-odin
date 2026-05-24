// fog_common.glsl — shared fog declarations for passes that run before the
// composite (e.g. bloom prefilter). Include with:  @header fog_common.glsl
//
// DO NOT include in postfx.frag — it declares PostProcessBlock and
// depthTexture inline already (full 432-byte std140 block).
//
// Uses explicit layout(offset=N) to declare only the fog-relevant fields of
// the full PostProcessBlock at their correct std140 positions, skipping
// unrelated fields. Requires GLSL 4.4+ (ARB_enhanced_layouts, core in 4.4).

layout(binding = 2) uniform sampler2D depthTexture;

// Partial PostProcessBlock — only the fog fields, at their std140 offsets.
// The UBO is shared with the composite shader (same binding point 0).
layout(binding = 0, std140) uniform PostProcessBlock {
	uint  activeEffects;                           // offset   0
	layout(offset = 288) float fog_density;        // offset 288
	float fog_start;                               // offset 292
	float fog_heightFalloff;                       // offset 296
	float fog_maxOpacity;                          // offset 300
	vec3  fog_color;                               // offset 304 (12 bytes)
	layout(offset = 320) vec4  fog_camPos;         // offset 320 (explicit: skip vec3 pad)
	mat4  fog_invViewProj;                         // offset 336
};

#define enableFog ((activeEffects & (1u << 15u)) != 0u)

// Returns fog opacity in [0, fog_maxOpacity] for the fragment at uv.
// Uses IQ analytical height-fog integration (same formula as postfx.frag).
float getFogAmount(vec2 uv)
{
	float depth = texture(depthTexture, uv).r;
	if (depth >= 0.9999) return 0.0;

	vec4 clipPos  = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 worldPos = fog_invViewProj * clipPos;
	worldPos.xyz /= worldPos.w;

	vec3  camPos    = fog_camPos.xyz;
	vec3  rayVec    = worldPos.xyz - camPos;
	float rayLength = length(rayVec);

	float effectiveDist = max(0.0, rayLength - fog_start);
	if (effectiveDist <= 0.0) return 0.0;

	vec3  rayDir = rayVec / rayLength;
	float fogRaw;
	float b = fog_heightFalloff;

	if (b > 0.001) {
		float rdY = rayDir.y;
		if (abs(rdY) < 0.0001) {
			fogRaw = fog_density * exp(-camPos.y * b) * effectiveDist;
		} else {
			fogRaw = (fog_density / b) * exp(-camPos.y * b) *
			         (1.0 - exp(-effectiveDist * rdY * b)) / rdY;
		}
	} else {
		fogRaw = fog_density * effectiveDist;
	}

	return clamp(1.0 - exp(-max(fogRaw, 0.0)), 0.0, fog_maxOpacity);
}
