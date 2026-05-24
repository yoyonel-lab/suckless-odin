#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 VelocityOut;

layout(binding = 1) uniform samplerCube cubemapA;  // glGenerateMipmap
layout(binding = 2) uniform samplerCube cubemapB;  // Seamless

layout(location = 4) uniform float blur_lod;
layout(location = 5) uniform float diff_gain;      // amplification factor

void main()
{
	vec3 dir = normalize(RayDir);
	vec3 colorA = textureLod(cubemapA, dir, blur_lod).rgb;
	vec3 colorB = textureLod(cubemapB, dir, blur_lod).rgb;

	// Amplified absolute difference
	vec3 diff = abs(colorA - colorB) * diff_gain;

	// Clamp and output
	diff = min(diff, vec3(1.0));

	float luma = dot(diff, vec3(0.299, 0.587, 0.114));
	FragColor = vec4(diff, luma);
	VelocityOut = vec2(0.0);
}
