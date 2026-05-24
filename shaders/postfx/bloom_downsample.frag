#version 450 core

// 13-tap downsample (Jorge Jimenez, Call of Duty: Advanced Warfare).
// Energy-preserving, reduces flickering vs naive bilinear.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec3 FragColor;

layout(binding = 0) uniform sampler2D srcTexture;
layout(location = 0) uniform vec2 srcResolution;

void main()
{
	vec2 srcTexelSize = 1.0 / srcResolution;
	float x = srcTexelSize.x;
	float y = srcTexelSize.y;

	// 13 taps around center
	vec3 a = texture(srcTexture, vec2(TexCoords.x - 2.0 * x, TexCoords.y + 2.0 * y)).rgb;
	vec3 b = texture(srcTexture, vec2(TexCoords.x,            TexCoords.y + 2.0 * y)).rgb;
	vec3 c = texture(srcTexture, vec2(TexCoords.x + 2.0 * x, TexCoords.y + 2.0 * y)).rgb;

	vec3 d = texture(srcTexture, vec2(TexCoords.x - 2.0 * x, TexCoords.y)).rgb;
	vec3 e = texture(srcTexture, vec2(TexCoords.x,            TexCoords.y)).rgb;
	vec3 f = texture(srcTexture, vec2(TexCoords.x + 2.0 * x, TexCoords.y)).rgb;

	vec3 g = texture(srcTexture, vec2(TexCoords.x - 2.0 * x, TexCoords.y - 2.0 * y)).rgb;
	vec3 h = texture(srcTexture, vec2(TexCoords.x,            TexCoords.y - 2.0 * y)).rgb;
	vec3 i = texture(srcTexture, vec2(TexCoords.x + 2.0 * x, TexCoords.y - 2.0 * y)).rgb;

	vec3 j = texture(srcTexture, vec2(TexCoords.x - x, TexCoords.y + y)).rgb;
	vec3 k = texture(srcTexture, vec2(TexCoords.x + x, TexCoords.y + y)).rgb;
	vec3 l = texture(srcTexture, vec2(TexCoords.x - x, TexCoords.y - y)).rgb;
	vec3 m = texture(srcTexture, vec2(TexCoords.x + x, TexCoords.y - y)).rgb;

	// Energy-preserving weights (distributed to avoid FP16 overflow)
	FragColor  = e * 0.125;
	FragColor += a * 0.03125;
	FragColor += c * 0.03125;
	FragColor += g * 0.03125;
	FragColor += i * 0.03125;
	FragColor += b * 0.0625;
	FragColor += d * 0.0625;
	FragColor += f * 0.0625;
	FragColor += h * 0.0625;
	FragColor += j * 0.125;
	FragColor += k * 0.125;
	FragColor += l * 0.125;
	FragColor += m * 0.125;
}
