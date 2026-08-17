#version 450 core
layout(location = 0) out vec4 FragColor;
layout(location = 0) in vec2 TexCoords;

layout(binding = 0) uniform sampler2D u_tex;
layout(location = 0) uniform float lod;
layout(location = 1) uniform float u_alpha;
layout(location = 2) uniform bool u_bypass_processing;
layout(location = 3) uniform bool u_black_screen;

void main()
{
	if (u_black_screen) {
		FragColor = vec4(0.0, 0.0, 0.0, u_alpha);
		return;
	}

	vec4 texColor = textureLod(u_tex, TexCoords, lod);
	FragColor = vec4(texColor.rgb, u_alpha);

	if (!u_bypass_processing) {
		// Reinhard tonemapping simple for debug
		FragColor.rgb = FragColor.rgb / (FragColor.rgb + vec3(1.0));
		// Gamma correction
		FragColor.rgb = pow(FragColor.rgb, vec3(1.0 / 2.2));
	}
}
