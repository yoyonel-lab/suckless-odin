#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;

layout(binding = 1) uniform samplerCube sourceCubemap;
layout(location = 4) uniform float source_lod;

void main()
{
	vec3 dir = normalize(RayDir);
	vec3 color = textureLod(sourceCubemap, dir, source_lod).rgb;
	FragColor = vec4(color, 1.0);
}
