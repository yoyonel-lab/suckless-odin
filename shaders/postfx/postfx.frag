#version 450 core

// Post-processing composite uber-shader.
// Applies enabled effects based on activeEffects bitfield in UBO.

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

// Scene color texture (HDR input)
layout(binding = 0) uniform sampler2D screenTexture;
// Bloom texture (from multi-pass bloom)
layout(binding = 1) uniform sampler2D bloomTexture;
// Depth buffer (for DoF CoC)
layout(binding = 2) uniform sampler2D depthTexture;
// Auto-exposure texture (1x1, R=exposure value)
layout(binding = 3) uniform sampler2D autoExposureTexture;
// DoF blur texture (1/4 res pre-blurred scene)
layout(binding = 5) uniform sampler2D dofBlurTexture;

// --- UBO: Post-Processing Parameters (std140, binding 0) ---
layout(std140, binding = 0) uniform PostProcessBlock
{
	uint activeEffects;
	float time;
	vec2 screenTexelSize;

	// Vignette (16 bytes)
	float v_intensity;
	float v_smoothness;
	float v_roundness;
	float _pad1;

	// Grain (32 bytes)
	float g_intensity;
	float g_intensityShadows;
	float g_intensityMidtones;
	float g_intensityHighlights;
	float g_shadowsMax;
	float g_highlightsMin;
	float g_texelSize;
	float _pad2;

	// Exposure (16 bytes)
	float e_exposure;
	float _pad3_0;
	float _pad3_1;
	float _pad3_2;

	// ChromAbbr (16 bytes)
	float ca_strength;
	float _pad4_0;
	float _pad4_1;
	float _pad4_2;

	// WhiteBalance (16 bytes)
	float wb_temperature;
	float wb_tint;
	float _pad5_0;
	float _pad5_1;

	// ColorGrading (32 bytes)
	float cg_saturation;
	float cg_contrast;
	float cg_gamma;
	float cg_gain;
	float cg_offset;
	float cg_lift;
	float _pad6_0;
	float _pad6_1;

	// Tonemap (32 bytes)
	float tm_slope;
	float tm_toe;
	float tm_shoulder;
	float tm_blackClip;
	float tm_whiteClip;
	float _pad7_0;
	float _pad7_1;
	float _pad7_2;

	// Bloom (16 bytes)
	float b_intensity;
	float b_threshold;
	float b_softThreshold;
	float b_radius;

	// FXAA (16 bytes)
	float fxaaQualitySubpix;
	float fxaaQualityEdgeThreshold;
	float fxaaQualityEdgeThresholdMin;
	float _pad10;

	// DoF (16 bytes)
	float d_focalDistance;
	float d_focalRange;
	float d_bokehScale;
	float d_anamorphicRatio;

	// Camera planes (16 bytes)
	float zNear;
	float zFar;
	float _pad11_0;
	float _pad11_1;

	// Motion Blur (16 bytes)
	float mb_intensity;
	float mb_maxVelocity;
	int mb_samples;
	float _pad12;

	// Banding (32 bytes)
	int bandingMode;
	float bandingLevels;
	float bandingDitherStrength;
	float bandingPerceptualGamma;
	vec3 bandingChannelLevels;
	float _pad13;

	// Fog (112 bytes)
	float fog_density;
	float fog_start;
	float fog_heightFalloff;
	float fog_maxOpacity;
	vec3 fog_color;
	float _pad14;
	vec4 fog_camPos;
	mat4 fog_invViewProj;

	// LUT3D (16 bytes)
	float lut3d_intensity;
	float _pad15_a;
	float _pad15_b;
	float _pad15_c;

	// Debug split-screen mask (16 bytes)
	uint debugSplitMask;
	float _pad16_a;
	float _pad16_b;
	float _pad16_c;
};

// --- Effect flag helpers ---
// When STATIC_* defines are present (optimized variant), use compile-time constants.
// Otherwise, fall back to runtime bitfield checks.
#ifdef STATIC_VIGNETTE
	#define enableVignette true
#else
	#define enableVignette      ((activeEffects & (1u << 0u)) != 0u)
#endif
#ifdef STATIC_GRAIN
	#define enableGrain true
#else
	#define enableGrain         ((activeEffects & (1u << 1u)) != 0u)
#endif
#ifdef STATIC_EXPOSURE
	#define enableExposure true
#else
	#define enableExposure      ((activeEffects & (1u << 2u)) != 0u)
#endif
#ifdef STATIC_CHROM_ABBR
	#define enableChromAbbr true
#else
	#define enableChromAbbr     ((activeEffects & (1u << 3u)) != 0u)
#endif
#ifdef STATIC_BLOOM
	#define enableBloom true
#else
	#define enableBloom         ((activeEffects & (1u << 4u)) != 0u)
#endif
#ifdef STATIC_COLOR_GRADING
	#define enableColorGrading true
#else
	#define enableColorGrading  ((activeEffects & (1u << 5u)) != 0u)
#endif
#ifdef STATIC_FXAA
	#define enableFXAA true
#else
	#define enableFXAA          ((activeEffects & (1u << 12u)) != 0u)
#endif
#ifdef STATIC_TONEMAP
	#define enableTonemap true
#else
	#define enableTonemap       ((activeEffects & (1u << 13u)) != 0u)
#endif

#define enableAutoExposure  ((activeEffects & (1u << 8u)) != 0u)
#define enableBanding       ((activeEffects & (1u << 14u)) != 0u)
#define enableDoF           ((activeEffects & (1u << 6u)) != 0u)
#define enableDoFDebug      ((activeEffects & (1u << 7u)) != 0u)
#define enableFXAADebug     ((activeEffects & (1u << 17u)) != 0u)
#define enableStencilDebug  ((activeEffects & (1u << 18u)) != 0u)
#define enableBloomDebug    ((activeEffects & (1u << 19u)) != 0u)

// Split-screen A/B debug: returns true when the pixel is in the right half
// AND the given effect bit is set in debugSplitMask → the effect should be bypassed.
bool splitBypassed(uint effectBit)
{
	return (debugSplitMask & (1u << effectBit)) != 0u && TexCoords.x > 0.5;
}

// ============================================================================
// EFFECT: CHROMATIC ABERRATION
// ============================================================================
vec3 applyChromAbbr(vec2 uv)
{
	vec2 direction = uv - vec2(0.5);

	// Sample R and B channels with offset, keep G from center
	float r = texture(screenTexture, uv + direction * ca_strength).r;
	float g = texture(screenTexture, uv).g;
	float b = texture(screenTexture, uv - direction * ca_strength).b;

	return vec3(r, g, b);
}

// ============================================================================
// EFFECT: FXAA (3.11 Quality Preset)
// ============================================================================
#define FXAA_QUALITY_PS 5
#define FXAA_QUALITY_P0 1.0
#define FXAA_QUALITY_P1 1.5
#define FXAA_QUALITY_P2 2.0
#define FXAA_QUALITY_P3 4.0
#define FXAA_QUALITY_P4 8.0

float FxaaLuma(vec3 rgb)
{
	return dot(rgb, vec3(0.299, 0.587, 0.114));
}

vec3 applyFXAA(vec3 colorInput, vec2 texCoords)
{
	vec2 inverseScreenSize = screenTexelSize;

	// 1. Luma analysis (center + 4 neighbors)
	vec3 rgbM = texture(screenTexture, texCoords).rgb;
	float lumaM = FxaaLuma(rgbM);

	float lumaN = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(0, -1)).rgb);
	float lumaW = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(-1, 0)).rgb);
	float lumaE = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(1, 0)).rgb);
	float lumaS = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(0, 1)).rgb);

	float rangeMin = min(lumaM, min(min(lumaN, lumaW), min(lumaS, lumaE)));
	float rangeMax = max(lumaM, max(max(lumaN, lumaW), max(lumaS, lumaE)));
	float range = rangeMax - rangeMin;

	// Early exit: contrast too low
	if (range < max(fxaaQualityEdgeThresholdMin, rangeMax * fxaaQualityEdgeThreshold)) {
		if (enableFXAADebug) return vec3(lumaM * 0.5); // Untouched (grayscale)
		return colorInput;
	}

	// 2. Corner sampling (diagonal neighbors)
	float lumaNW = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(-1, -1)).rgb);
	float lumaNE = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(1, -1)).rgb);
	float lumaSW = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(-1, 1)).rgb);
	float lumaSE = FxaaLuma(textureOffset(screenTexture, texCoords, ivec2(1, 1)).rgb);

	// Filter direction
	float lumaL = (lumaN + lumaS + lumaE + lumaW) * 0.25;

	float edgeVert = abs((0.25 * lumaNW) + (-0.5 * lumaN) + (0.25 * lumaNE)) +
	                 abs((0.50 * lumaW) + (-1.0 * lumaM) + (0.50 * lumaE)) +
	                 abs((0.25 * lumaSW) + (-0.5 * lumaS) + (0.25 * lumaSE));

	float edgeHorz = abs((0.25 * lumaNW) + (-0.5 * lumaW) + (0.25 * lumaSW)) +
	                 abs((0.50 * lumaN) + (-1.0 * lumaM) + (0.50 * lumaS)) +
	                 abs((0.25 * lumaNE) + (-0.5 * lumaE) + (0.25 * lumaSE));

	bool isHorz = edgeHorz >= edgeVert;

	// 3. Sub-pixel AA
	float subPixelOffset1 = clamp(abs(lumaL - lumaM) / range, 0.0, 1.0);
	float subPixelOffset2 = (-2.0 * subPixelOffset1) + 3.0;
	float subPixelOffsetFinal = subPixelOffset1 * subPixelOffset1 * subPixelOffset2;
	subPixelOffsetFinal = subPixelOffsetFinal * subPixelOffsetFinal * fxaaQualitySubpix;

	// 4. Edge search
	float luma1 = isHorz ? lumaN : lumaW;
	float luma2 = isHorz ? lumaS : lumaE;
	float gradient1 = luma1 - lumaM;
	float gradient2 = luma2 - lumaM;

	bool is1Steepest = abs(gradient1) >= abs(gradient2);
	float gradientScaled = 0.25 * max(abs(gradient1), abs(gradient2));

	float stepLength = isHorz ? inverseScreenSize.y : inverseScreenSize.x;

	if (is1Steepest) {
		stepLength = -stepLength;
	}
	float lumaLocalAverage = 0.5 * ((is1Steepest ? luma1 : luma2) + lumaM);

	vec2 currentUv = texCoords;
	if (isHorz) {
		currentUv.y += stepLength * 0.5;
	} else {
		currentUv.x += stepLength * 0.5;
	}

	// Iterative edge search with variable step sizes
	vec2 offset = isHorz ? vec2(inverseScreenSize.x, 0.0)
	                     : vec2(0.0, inverseScreenSize.y);
	vec2 uv1 = currentUv - offset * FXAA_QUALITY_P0;
	vec2 uv2 = currentUv + offset * FXAA_QUALITY_P0;

	float lumaEnd1, lumaEnd2;
	bool reached1 = false;
	bool reached2 = false;

	const float quality[FXAA_QUALITY_PS] = float[FXAA_QUALITY_PS](
	    FXAA_QUALITY_P0, FXAA_QUALITY_P1, FXAA_QUALITY_P2,
	    FXAA_QUALITY_P3, FXAA_QUALITY_P4);

	for (int i = 1; i < FXAA_QUALITY_PS; i++) {
		if (!reached1) {
			lumaEnd1 = FxaaLuma(texture(screenTexture, uv1).rgb);
			lumaEnd1 -= lumaLocalAverage;
		}
		if (!reached2) {
			lumaEnd2 = FxaaLuma(texture(screenTexture, uv2).rgb);
			lumaEnd2 -= lumaLocalAverage;
		}

		reached1 = abs(lumaEnd1) >= gradientScaled;
		reached2 = abs(lumaEnd2) >= gradientScaled;

		if (reached1 && reached2) break;

		if (!reached1) uv1 -= offset * quality[i];
		if (!reached2) uv2 += offset * quality[i];
	}

	// 5. Distance ratios & final offset
	float distance1 = isHorz ? (texCoords.x - uv1.x) : (texCoords.y - uv1.y);
	float distance2 = isHorz ? (uv2.x - texCoords.x) : (uv2.y - texCoords.y);

	bool isDirection1 = distance1 < distance2;
	float distanceFinal = min(distance1, distance2);
	float edgeThickness = (distance1 + distance2);
	float pixelOffset = -distanceFinal / edgeThickness + 0.5;

	// Overshoot check
	bool isLumaCenterSmaller = lumaM < lumaLocalAverage;
	bool correctVariation = ((isDirection1 ? lumaEnd1 : lumaEnd2) < 0.0) != isLumaCenterSmaller;
	float finalOffset = correctVariation ? pixelOffset : 0.0;

	// Blend with subpixel
	finalOffset = max(finalOffset, subPixelOffsetFinal);

	if (enableFXAADebug) {
		if (finalOffset > 0.001) {
			if (subPixelOffsetFinal > finalOffset * 0.9)
				return vec3(0.1, 0.4, 1.0); // Subpixel (blue)
			return vec3(1.0, 0.2, 0.2);     // Edge (red)
		}
		return vec3(lumaM * 0.5);           // Untouched (grayscale)
	}

	// Final read
	vec2 finalUv = texCoords;
	if (isHorz) {
		finalUv.y += finalOffset * stepLength;
	} else {
		finalUv.x += finalOffset * stepLength;
	}

	return texture(screenTexture, finalUv).rgb;
}

// ============================================================================
// EFFECT: EXPOSURE
// ============================================================================
vec3 applyExposure(vec3 color)
{
	float exposure;
	if (enableAutoExposure) {
		// Read computed exposure from 1x1 texture (replaces manual)
		exposure = texture(autoExposureTexture, vec2(0.5)).r;
	} else {
		exposure = e_exposure;
	}
	return color * exposure;
}

// ============================================================================
// EFFECT: TONEMAPPING (ACES-like filmic)
// ============================================================================
vec3 unrealTonemap(vec3 x)
{
	float a = 2.51 * tm_slope;
	const float b = 0.03;
	const float c = 2.43;
	float d = 0.59 * tm_shoulder;
	float e = 0.14 * (1.1 - tm_toe);

	vec3 res = (x * (a * x + b)) / (x * (c * x + d) + e);

	if (tm_blackClip > 0.001) {
		res = max(vec3(0.0), res - tm_blackClip) / (1.0 - tm_blackClip);
	}
	if (tm_whiteClip > 0.001) {
		float maxVal = 1.0 - tm_whiteClip;
		res = min(vec3(maxVal), res) / maxVal;
	}

	return clamp(res, 0.0, 1.0);
}

// ============================================================================
// EFFECT: BLOOM (additive mix from bloom texture)
// ============================================================================
vec3 applyBloom(vec3 color)
{
	vec3 bloomColor = texture(bloomTexture, TexCoords).rgb;
	return color + bloomColor * b_intensity;
}

// ============================================================================
// EFFECT: VIGNETTE
// ============================================================================
float sdRoundedBox(vec2 p, vec2 b, float r)
{
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 applyVignette(vec3 color, vec2 uv)
{
	vec2 centered = uv * 2.0 - 1.0;
	float r = v_roundness;
	float dist = sdRoundedBox(centered, vec2(1.0), r);
	float vignette = smoothstep(0.0, v_smoothness, -dist);
	return color * mix(1.0, vignette, v_intensity);
}

// ============================================================================
// EFFECT: FILM GRAIN
// ============================================================================
vec3 filmHash(vec2 p)
{
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

vec3 applyGrain(vec3 color, vec2 uv)
{
	float luma = dot(color, vec3(0.299, 0.587, 0.114));

	float shadowMask = 1.0 - smoothstep(0.0, g_shadowsMax, luma);
	float highlightMask = smoothstep(g_highlightsMin, 1.0, luma);
	float midtoneMask = max(0.0, 1.0 - shadowMask - highlightMask);

	float lumaMult = shadowMask * g_intensityShadows +
	                 midtoneMask * g_intensityMidtones +
	                 highlightMask * g_intensityHighlights;

	vec2 grainUV = gl_FragCoord.xy / g_texelSize;
	vec2 jitter = filmHash(vec2(time, time * 0.618)).xy;
	vec3 noise3 = filmHash(grainUV + jitter * 10.0);
	noise3 = noise3 * 2.0 - 1.0;

	float lumaGrain = dot(noise3, vec3(0.333));
	vec3 grain = mix(vec3(lumaGrain), noise3, 0.3);

	vec3 overlay = mix(
	    2.0 * color * (0.5 + grain * g_intensity * lumaMult),
	    1.0 - 2.0 * (1.0 - color) * (0.5 - grain * g_intensity * lumaMult),
	    step(0.5, color));

	return mix(color, overlay, 0.7);
}

// ============================================================================
// MAIN
// ============================================================================
// EFFECT: DEPTH OF FIELD
// ============================================================================
vec3 applyDoF(vec3 color, vec2 uv)
{
	float depth = texture(depthTexture, uv).r;

	// Skybox early exit
	if (depth >= 0.99999) return color;

	// Linearize depth (perspective projection)
	float z_ndc = 2.0 * depth - 1.0;
	float dist = (2.0 * zNear * zFar) / (zFar + zNear - z_ndc * (zFar - zNear));

	// Circle of Confusion (simplified thin-lens)
	float coc = abs(dist - d_focalDistance) / (dist + 0.0001);

	// Focal range: sharp zone with smooth transitions
	float blurFactor = 0.0;
	float distDiff = abs(dist - d_focalDistance);
	if (distDiff > d_focalRange) {
		float transition = 5.0;
		blurFactor = clamp((distDiff - d_focalRange) / transition, 0.0, 1.0);
	}

	blurFactor *= clamp(coc * d_bokehScale, 0.0, 1.0);
	blurFactor = clamp(blurFactor, 0.0, 1.0);

	// Mix with pre-blurred texture
	if (blurFactor > 0.01) {
		vec3 blurredColor = texture(dofBlurTexture, uv).rgb;
		color = mix(color, blurredColor, blurFactor);
	}

	// Debug visualization
	if (enableDoFDebug) {
		if (dist < d_focalDistance - d_focalRange) {
			color = mix(color, vec3(0.0, 1.0, 0.0), 0.3);  // near = green
		} else if (dist > d_focalDistance + d_focalRange) {
			color = mix(color, vec3(0.0, 0.0, 1.0), 0.3);  // far = blue
		}
	}

	return color;
}

// ============================================================================
// EFFECT: BANDING (Color Quantization — 5 artistic modes)
// ============================================================================

// Bayer 4x4 ordered dither matrix (normalized to [0,1])
float bayerDither4x4(vec2 pos)
{
	int x = int(mod(pos.x, 4.0));
	int y = int(mod(pos.y, 4.0));
	const int matrix[16] = int[16](
		 0,  8,  2, 10,
		12,  4, 14,  6,
		 3, 11,  1,  9,
		15,  7, 13,  5
	);
	return float(matrix[y * 4 + x]) / 16.0;
}

vec3 applyBanding(vec3 color)
{
	// Mode 0: Linear — uniform posterization
	if (bandingMode == 0) {
		return floor(color * bandingLevels + 0.5) / bandingLevels;
	}

	// Mode 1: Dithered — Bayer 4x4 ordered dithering
	if (bandingMode == 1) {
		vec2 pixelPos = gl_FragCoord.xy;
		float dither = bayerDither4x4(pixelPos) - 0.5;
		vec3 shifted = color + dither * bandingDitherStrength / bandingLevels;
		return floor(shifted * bandingLevels + 0.5) / bandingLevels;
	}

	// Mode 2: Perceptual — gamma-weighted quantization
	if (bandingMode == 2) {
		vec3 linear = pow(max(color, vec3(0.0)), vec3(bandingPerceptualGamma));
		vec3 quantized = floor(linear * bandingLevels + 0.5) / bandingLevels;
		return pow(quantized, vec3(1.0 / bandingPerceptualGamma));
	}

	// Mode 3: Channel — independent RGB levels
	if (bandingMode == 3) {
		return vec3(
			floor(color.r * bandingChannelLevels.r + 0.5) / bandingChannelLevels.r,
			floor(color.g * bandingChannelLevels.g + 0.5) / bandingChannelLevels.g,
			floor(color.b * bandingChannelLevels.b + 0.5) / bandingChannelLevels.b
		);
	}

	// Mode 4: Luminance — grayscale quantization + tint
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float quantLuma = floor(luma * bandingLevels + 0.5) / bandingLevels;
	return quantLuma * bandingChannelLevels;
}

// ============================================================================
void main()
{
	vec3 color;

	// Debug priority: Bloom_Debug shows the bloom contribution (intensity-weighted).
	if (enableBloomDebug) {
		FragColor = vec4(texture(bloomTexture, TexCoords).rgb * b_intensity, 1.0);
		return;
	}

	// 1. Chromatic Aberration (samples screenTexture with R/B offsets)
	if (enableChromAbbr && !splitBypassed(3u)) {
		color = applyChromAbbr(TexCoords);
	} else {
		color = texture(screenTexture, TexCoords).rgb;
	}

	// 2. FXAA (spatial anti-aliasing, operates on screenTexture neighbors)
	if (enableFXAA && !splitBypassed(12u)) {
		color = applyFXAA(color, TexCoords);
	}

	// 3. Depth of Field (mix sharp/blurred based on CoC from depth)
	if (enableDoF && !splitBypassed(6u)) {
		color = applyDoF(color, TexCoords);
	}

	// 4. Bloom mix (additive from separate bloom texture)
	if (enableBloom && !splitBypassed(4u)) {
		color = applyBloom(color);
	}

	// 5. Exposure (HDR brightness) — also runs when only Auto_Exposure is active.
	if ((enableExposure || enableAutoExposure) && !splitBypassed(2u) && !splitBypassed(8u)) {
		color = applyExposure(color);
	}

	// 6. Tonemapping (HDR → LDR)
	if (enableTonemap && !splitBypassed(13u)) {
		color = unrealTonemap(color);
	}

	// 7. Color grading (post-tonemap, LDR space)
	if (enableColorGrading && !splitBypassed(5u)) {
		color = pow(max(color, vec3(0.0)), vec3(1.0 / cg_gamma));
		color = (color - 0.5) * cg_contrast + 0.5;
		float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
		color = mix(vec3(luma), color, cg_saturation);
		color = color * cg_gain + cg_offset;
	}

	// 8. Banding (artistic color quantization)
	if (enableBanding && !splitBypassed(14u)) {
		color = applyBanding(color);
	}

	// 9. Vignette
	if (enableVignette && !splitBypassed(0u)) {
		color = applyVignette(color, TexCoords);
	}

	// 10. Grain (applied last before output)
	if (enableGrain && !splitBypassed(1u)) {
		color = applyGrain(color, TexCoords);
	}

	// Draw split-line separator when any debug split is active.
	if (debugSplitMask != 0u && abs(TexCoords.x - 0.5) < screenTexelSize.x * 1.5) {
		FragColor = vec4(1.0, 1.0, 0.0, 1.0); // Yellow vertical line
		return;
	}

	FragColor = vec4(color, 1.0);
}
