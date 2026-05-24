#version 450 core

// 9-tap tent filter upsample for bloom.
// Weights: [1 2 1] / [2 4 2] / [1 2 1] = /16

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec3 FragColor;

layout(binding = 0) uniform sampler2D srcTexture;
layout(location = 0) uniform float filterRadius;

void main()
{
	ivec2 sz = textureSize(srcTexture, 0);
	float x = filterRadius / float(sz.x);
	float y = filterRadius / float(sz.y);

	// 9-tap tent filter
	vec3 a = texture(srcTexture, vec2(TexCoords.x - x, TexCoords.y + y)).rgb;
	vec3 b = texture(srcTexture, vec2(TexCoords.x,     TexCoords.y + y)).rgb;
	vec3 c = texture(srcTexture, vec2(TexCoords.x + x, TexCoords.y + y)).rgb;

	vec3 d = texture(srcTexture, vec2(TexCoords.x - x, TexCoords.y)).rgb;
	vec3 e = texture(srcTexture, vec2(TexCoords.x,     TexCoords.y)).rgb;
	vec3 f = texture(srcTexture, vec2(TexCoords.x + x, TexCoords.y)).rgb;

	vec3 g = texture(srcTexture, vec2(TexCoords.x - x, TexCoords.y - y)).rgb;
	vec3 h = texture(srcTexture, vec2(TexCoords.x,     TexCoords.y - y)).rgb;
	vec3 i = texture(srcTexture, vec2(TexCoords.x + x, TexCoords.y - y)).rgb;

	FragColor = (e * 4.0 + (b + d + f + h) * 2.0 + (a + c + g + i)) / 16.0;
}
