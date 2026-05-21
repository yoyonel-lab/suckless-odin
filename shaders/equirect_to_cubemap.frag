#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;

layout(binding = 0) uniform sampler2D environmentMap;

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 SampleEquirectangular(vec3 v)
{
	float phi = atan(v.z, v.x);
	vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
	uv *= invAtan;
	uv += 0.5;
	return uv;
}

void main()
{
	vec3 dir = normalize(RayDir);
	vec2 uv = SampleEquirectangular(dir);
	vec3 color = texture(environmentMap, uv).rgb;
	FragColor = vec4(color, 1.0);
}
