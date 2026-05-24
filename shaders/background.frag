#version 450 core

layout(location = 0) in vec3 RayDir;
layout(location = 0) out vec4 FragColor;
layout(location = 1) out vec2 VelocityOut;

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

// Bicubic Catmull-Rom filtering via 4 bilinear taps (Sigg & Hadwiger 2005).
// Produces C1-continuous interpolation — much smoother than bilinear at high LODs.
vec3 textureBicubicLod(sampler2D tex, vec2 uv, float lod)
{
	vec2 texSize = vec2(textureSize(tex, int(lod)));
	vec2 invTexSize = 1.0 / texSize;

	// Convert UV to texel-space, center on pixel
	vec2 tc = uv * texSize - 0.5;
	vec2 f = fract(tc);
	tc -= f; // integer part (pixel origin)

	// Catmull-Rom weights: w0..w3 for fractional position f
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);

	// Combine pairs: tap at optimized offset using bilinear HW
	vec2 s0 = w0 + w1;
	vec2 s1 = w2 + w3;
	vec2 f0 = w1 / s0;
	vec2 f1 = w3 / s1;

	// Compute 4 sample positions (2×2 grid with optimized offsets)
	vec2 t0 = (tc - 1.0 + f0) * invTexSize + 0.5 * invTexSize;
	vec2 t1 = (tc + 1.0 + f1) * invTexSize + 0.5 * invTexSize;

	// 4 bilinear taps — each tap does a hardware 2×2, giving effective 4×4 kernel
	vec3 r  = textureLod(tex, vec2(t0.x, t0.y), lod).rgb * s0.x;
	r      += textureLod(tex, vec2(t1.x, t0.y), lod).rgb * s1.x;
	vec3 rb = r * s0.y;

	r       = textureLod(tex, vec2(t0.x, t1.y), lod).rgb * s0.x;
	r      += textureLod(tex, vec2(t1.x, t1.y), lod).rgb * s1.x;
	rb     += r * s1.y;

	return rb;
}

void main()
{
	vec2 uv = SampleEquirectangular(normalize(RayDir));

	// Use bicubic only when blur_lod > 0 (high LODs benefit most; LOD 0 is sharp enough)
	vec3 envColor = (blur_lod > 0.0)
		? textureBicubicLod(environmentMap, uv, blur_lod)
		: textureLod(environmentMap, uv, 0.0).rgb;

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
	VelocityOut = vec2(0.0); // Skybox has no velocity
}
