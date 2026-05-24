#version 450 core

// Bloom prefilter: extract bright pixels above threshold with soft knee.
// Fog-aware: luminance is attenuated by the fog factor before threshold
// extraction — fogged objects do not generate bloom halos.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec3 FragColor;

layout(binding = 0) uniform sampler2D srcTexture;
layout(location = 0) uniform float threshold;
layout(location = 1) uniform float knee;

@header fog_common.glsl

void main()
{
	// Attenuate by fog before brightness extraction: a sphere deep in fog
	// should not emit bloom halos even though its HDR value is high.
	float fogF = enableFog ? getFogAmount(TexCoords) : 0.0;
	vec3 color = texture(srcTexture, TexCoords).rgb * (1.0 - fogF);

	// Perceptual luminance
	float brightness = dot(color, vec3(0.2126, 0.7152, 0.0722));

	// Quadratic threshold curve (UE4-style soft knee)
	float soft = brightness - threshold + knee;
	soft = clamp(soft, 0.0, 2.0 * knee);
	soft = soft * soft / (4.0 * knee + 0.00001);

	float contribution = max(soft, brightness - threshold);
	contribution /= max(brightness, 0.00001);

	FragColor = color * contribution;
}
