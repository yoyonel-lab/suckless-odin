#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 VelocityOut;

layout(binding = 0) uniform sampler2D envMap;        // Standard equirect
layout(binding = 1) uniform sampler2D prefilterMap;  // IBL prefiltered equirect

layout(location = 4) uniform float env_lod;          // LOD for standard env
layout(location = 5) uniform float prefilter_lod;    // LOD for IBL prefilter
layout(location = 6) uniform float diff_gain;        // amplification factor

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 SampleEquirectangular(vec3 v)
{
	float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
	vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
	uv *= invAtan;
	uv += 0.5;
	return uv;
}

void main()
{
	vec3 dir = normalize(RayDir);
	vec2 uv = SampleEquirectangular(dir);

	vec3 colorA = textureLod(envMap, uv, env_lod).rgb;
	vec3 colorB = textureLod(prefilterMap, uv, prefilter_lod).rgb;

	// Amplified absolute difference
	vec3 diff = abs(colorA - colorB) * diff_gain;
	diff = min(diff, vec3(1.0));

	float luma = dot(diff, vec3(0.299, 0.587, 0.114));
	FragColor = vec4(diff, luma);
	VelocityOut = vec2(0.0);
}
