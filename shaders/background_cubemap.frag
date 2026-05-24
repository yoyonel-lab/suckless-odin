#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 VelocityOut;

layout(binding = 1) uniform samplerCube environmentCubemap;
layout(location = 4) uniform float blur_lod;

void main()
{
	vec3 dir = normalize(RayDir);
	vec3 envColor = textureLod(environmentCubemap, dir, blur_lod).rgb;

	/* Sanitize NaN/Inf */
	if (any(isnan(envColor)))
		envColor = vec3(0.0);

	envColor = min(envColor, vec3(200.0));
	envColor = max(envColor, vec3(0.0));

	// Store Luma in Alpha for FXAA
	float luma = dot(sqrt(envColor), vec3(0.299, 0.587, 0.114));
	FragColor = vec4(envColor, luma);
	VelocityOut = vec2(0.0);
}
