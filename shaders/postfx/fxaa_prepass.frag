#version 450 core

// FXAA pre-pass shader.
//
// Motivation: When both FXAA and Motion Blur are active, FXAA must run BEFORE
// motion blur. FXAA's edge detection interprets MB's smooth color transitions
// as geometric edges, causing stair-step artifacts and ghosting. By running
// FXAA first on the sharp scene, then letting MB blur the anti-aliased result,
// both effects cooperate without interference.
//
// This shader is only dispatched when both FXAA and Motion Blur are enabled.
// Otherwise, FXAA runs inline in the composite uber-shader (zero overhead).

layout(location = 0) in vec2 TexCoords;
layout(location = 0) out vec4 FragColor;

// Scene color (HDR, pre-blur)
layout(binding = 0) uniform sampler2D screenTexture;

// Only the fields needed by FXAA from the shared PostProcessBlock.
layout(std140, binding = 0) uniform PostProcessBlock
{
	uint activeEffects;
	float time;
	vec2 screenTexelSize;

	// Padding to reach FXAA params at offset 192.
	// Vignette (16 bytes, offset 16)
	float _skip0[4];
	// Grain (32 bytes, offset 32)
	float _skip1[8];
	// Exposure (16 bytes, offset 64)
	float _skip2[4];
	// ChromAbbr (16 bytes, offset 80)
	float _skip3[4];
	// WhiteBalance (16 bytes, offset 96)
	float _skip4[4];
	// ColorGrading (32 bytes, offset 112)
	float _skip5[8];
	// Tonemap (32 bytes, offset 144)
	float _skip6[8];
	// Bloom (16 bytes, offset 176)
	float _skip7[4];

	// FXAA (16 bytes, offset 192)
	float fxaaQualitySubpix;
	float fxaaQualityEdgeThreshold;
	float fxaaQualityEdgeThresholdMin;
	float _pad10;
};

// --- FXAA 3.11 Quality Preset ---
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

void main()
{
	vec2 inverseScreenSize = screenTexelSize;

	// 1. Luma analysis (center + 4 neighbors)
	vec3 rgbM = textureLod(screenTexture, TexCoords, 0.0).rgb;
	float lumaM = FxaaLuma(rgbM);

	float lumaN = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(0, -1)).rgb);
	float lumaW = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(-1, 0)).rgb);
	float lumaE = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(1, 0)).rgb);
	float lumaS = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(0, 1)).rgb);

	float rangeMin = min(lumaM, min(min(lumaN, lumaW), min(lumaS, lumaE)));
	float rangeMax = max(lumaM, max(max(lumaN, lumaW), max(lumaS, lumaE)));
	float range = rangeMax - rangeMin;

	// Early exit: contrast too low — pass through unchanged
	if (range < max(fxaaQualityEdgeThresholdMin, rangeMax * fxaaQualityEdgeThreshold)) {
		FragColor = vec4(rgbM, 1.0);
		return;
	}

	// 2. Corner sampling (diagonal neighbors)
	float lumaNW = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(-1, -1)).rgb);
	float lumaNE = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(1, -1)).rgb);
	float lumaSW = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(-1, 1)).rgb);
	float lumaSE = FxaaLuma(textureLodOffset(screenTexture, TexCoords, 0.0, ivec2(1, 1)).rgb);

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

	vec2 currentUv = TexCoords;
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
			lumaEnd1 = FxaaLuma(textureLod(screenTexture, uv1, 0.0).rgb);
			lumaEnd1 -= lumaLocalAverage;
		}
		if (!reached2) {
			lumaEnd2 = FxaaLuma(textureLod(screenTexture, uv2, 0.0).rgb);
			lumaEnd2 -= lumaLocalAverage;
		}

		reached1 = abs(lumaEnd1) >= gradientScaled;
		reached2 = abs(lumaEnd2) >= gradientScaled;

		if (reached1 && reached2) break;

		if (!reached1) uv1 -= offset * quality[i];
		if (!reached2) uv2 += offset * quality[i];
	}

	// 5. Distance ratios & final offset
	float distance1 = isHorz ? (TexCoords.x - uv1.x) : (TexCoords.y - uv1.y);
	float distance2 = isHorz ? (uv2.x - TexCoords.x) : (uv2.y - TexCoords.y);

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

	// Final read at offset
	vec2 finalUv = TexCoords;
	if (isHorz) {
		finalUv.y += finalOffset * stepLength;
	} else {
		finalUv.x += finalOffset * stepLength;
	}

	FragColor = vec4(textureLod(screenTexture, finalUv, 0.0).rgb, 1.0);
}
