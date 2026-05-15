#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D environmentMap;
layout(location = 4) uniform float blur_lod;

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 SampleEquirectangular(vec3 v)
{
	float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
	vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
	uv *= invAtan;
	uv += 0.5;  // HDR flipped on load: uv.y=0=ground, uv.y=1=sky
	return uv;
}

void main()
{
	vec2 uv = SampleEquirectangular(normalize(RayDir));
	vec3 envColor = textureLod(environmentMap, uv, blur_lod).rgb;

	/* Sanitize NaN/Inf (Branchless-ish) */
	/* isnan is the only one needing replacement. isinf is handled by min */
	if (any(isnan(envColor)))
		envColor = vec3(0.0);

	/* Clamp max brightness */
	/* 200.0 is safe for bloom accumulation */
	envColor = min(envColor, vec3(200.0));
	envColor = max(envColor, vec3(0.0));

	// Store Luma in Alpha for FXAA (using sqrt approx for Gamma)
	float luma = dot(sqrt(envColor), vec3(0.299, 0.587, 0.114));
	FragColor = vec4(envColor, luma);
}
