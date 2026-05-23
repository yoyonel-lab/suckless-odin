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
// Velocity buffer (RG16F, per-pixel motion vectors)
layout(binding = 4) uniform sampler2D velocityTexture;
// DoF blur texture (1/4 res pre-blurred scene)
layout(binding = 5) uniform sampler2D dofBlurTexture;
// Neighbor-max velocity (RG16F, dilated tile max)
layout(binding = 6) uniform sampler2D neighborMaxTexture;
// Tile-max velocity (RG16F, per-tile 16x16 reduction)
layout(binding = 7) uniform sampler2D tileMaxTexture;
// 3D LUT texture (unit 8, RGB16F cube)
layout(binding = 8) uniform sampler3D lut3dTexture;

// Glasbey palette for debug split-line colors (set once at init from CPU).
uniform vec3 splitColors[24];

// --- UBO: Post-Processing Parameters (std140, binding 0) ---
layout(std140, binding = 0) uniform PostProcessBlock
{
	uint activeEffects;
	float time;
	vec2 screenTexelSize;

	// Vignette (16 bytes)
	float v_intensity;	float v_smoothness;
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
	int mb_debugMode; // 0=velocity, 1=tile-max, 2=neighbor-max, 3=speed

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

	// Per-effect split positions (80 bytes = 5 × vec4)
	vec4 splitPositions[5];
};

// --- Effect flag helpers ---
// When STATIC_* defines are present (optimized variant), use compile-time constants.
// Otherwise, fall back to runtime bitfield checks.
#ifdef STATIC_VIGNETTE
	const bool enableVignette = bool(STATIC_VIGNETTE);
#else
	#define enableVignette      ((activeEffects & (1u << 0u)) != 0u)
#endif

#ifdef STATIC_GRAIN
	const bool enableGrain = bool(STATIC_GRAIN);
#else
	#define enableGrain         ((activeEffects & (1u << 1u)) != 0u)
#endif

#ifdef STATIC_EXPOSURE
	const bool enableExposure = bool(STATIC_EXPOSURE);
#else
	#define enableExposure      ((activeEffects & (1u << 2u)) != 0u)
#endif

#ifdef STATIC_CHROM_ABBR
	const bool enableChromAbbr = bool(STATIC_CHROM_ABBR);
#else
	#define enableChromAbbr     ((activeEffects & (1u << 3u)) != 0u)
#endif

#ifdef STATIC_BLOOM
	const bool enableBloom = bool(STATIC_BLOOM);
#else
	#define enableBloom         ((activeEffects & (1u << 4u)) != 0u)
#endif

#ifdef STATIC_COLOR_GRADING
	const bool enableColorGrading = bool(STATIC_COLOR_GRADING);
#else
	#define enableColorGrading  ((activeEffects & (1u << 5u)) != 0u)
#endif

#ifdef STATIC_DOF
	const bool enableDoF = bool(STATIC_DOF);
#else
	#define enableDoF           ((activeEffects & (1u << 6u)) != 0u)
#endif

#ifdef STATIC_AUTO_EXPOSURE
	const bool enableAutoExposure = bool(STATIC_AUTO_EXPOSURE);
#else
	#define enableAutoExposure  ((activeEffects & (1u << 8u)) != 0u)
#endif

#ifdef STATIC_MOTION_BLUR
	const bool enableMotionBlur = bool(STATIC_MOTION_BLUR);
#else
	#define enableMotionBlur    ((activeEffects & (1u << 10u)) != 0u)
#endif

#ifdef STATIC_FXAA
	const bool enableFXAA = bool(STATIC_FXAA);
#else
	#define enableFXAA          ((activeEffects & (1u << 12u)) != 0u)
#endif

#ifdef STATIC_TONEMAP
	const bool enableTonemap = bool(STATIC_TONEMAP);
#else
	#define enableTonemap       ((activeEffects & (1u << 13u)) != 0u)
#endif

#ifdef STATIC_BANDING
	const bool enableBanding = bool(STATIC_BANDING);
#else
	#define enableBanding       ((activeEffects & (1u << 14u)) != 0u)
#endif

#ifdef STATIC_FOG
	const bool enableFog = bool(STATIC_FOG);
#else
	#define enableFog           ((activeEffects & (1u << 15u)) != 0u)
#endif

#ifdef STATIC_LUT3D
	const bool enableLUT3D = bool(STATIC_LUT3D);
#else
	#define enableLUT3D         ((activeEffects & (1u << 16u)) != 0u)
#endif

#define enableMotionBlurDebug ((activeEffects & (1u << 11u)) != 0u)
#define enableFogDebug      ((activeEffects & (1u << 20u)) != 0u)
#define enableLUT3DDebug    ((activeEffects & (1u << 21u)) != 0u)
#define enableVectorFieldDebug ((activeEffects & (1u << 22u)) != 0u)
#define enableDoFDebug      ((activeEffects & (1u << 7u)) != 0u)
#define enableFXAADebug     ((activeEffects & (1u << 17u)) != 0u)
#define enableStencilDebug  ((activeEffects & (1u << 18u)) != 0u)
#define enableBloomDebug    ((activeEffects & (1u << 19u)) != 0u)
#define enableLuminanceDebug ((activeEffects & (1u << 23u)) != 0u)

// Split-screen A/B debug: returns true when the pixel is past the per-effect split position
// AND the given effect bit is set in debugSplitMask → the effect should be bypassed.
bool splitBypassed(uint effectBit)
{
	if ((debugSplitMask & (1u << effectBit)) == 0u) return false;
	float pos = splitPositions[effectBit / 4u][effectBit % 4u];
	return TexCoords.x > pos;
}

// ============================================================================
// EFFECT: MOTION BLUR (per-pixel, velocity-buffer based)
// ============================================================================

// Interleaved gradient noise for jittered sampling (Jorge Jimenez, 2014)
float InterleavedGradientNoise(vec2 screenPos)
{
	vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
	return fract(magic.z * fract(dot(screenPos.xy, magic.xy)));
}

// Spatial hash without structured diagonal pattern (Dave Hoskins).
// Used for MB jitter where IGN's diagonal structure creates visible banding.
float spatialHash(vec2 p)
{
	p = fract(p * vec2(443.8975, 397.2973));
	p += dot(p, p.yx + 19.19);
	return fract(p.x * p.y);
}

// Linearize depth from [0,1] depth buffer to view-space distance
float linearizeDepth(float depth)
{
	float z_ndc = 2.0 * depth - 1.0;
	return (2.0 * zNear * zFar) / (zFar + zNear - z_ndc * (zFar - zNear));
}

vec3 applyVectorFieldDebug(vec2 uv)
{
	vec2 screenSize = vec2(textureSize(velocityTexture, 0));
	vec2 pixelPos = uv * screenSize;

	/* Grid cell size (one arrow every N pixels) */
	float gridSize = 48.0;
	vec2 cellCenter = (floor(pixelPos / gridSize) * gridSize) + (gridSize * 0.5);
	vec2 uvCenter = cellCenter / screenSize;

	/* Sample velocity at the CENTER of the cell */
	vec2 velCenter = texture(velocityTexture, uvCenter).xy;

	/* Draw arrow if velocity is significant */
	if (length(velCenter) > 1e-4) {
		/* Direction and visual length */
		vec2 dir = normalize(velCenter);
		float len = length(velCenter) * 800.0;
		len = min(len, gridSize * 0.45);

		/* Local position relative to cell center */
		vec2 localPos = pixelPos - cellCenter;

		/* SDF Point-to-Segment distance for symmetric line */
		float h = clamp(dot(localPos, dir) / len, -1.0, 1.0);
		float d = length(localPos - dir * len * h);

		/* Line thickness (2.0 pixels) */
		if (d < 2.0) {
			/* Color based on direction angle (HSV -> RGB) */
			float angle = atan(dir.y, dir.x);
			float hue = (angle + 3.14159) / 6.28318;

			vec3 rgb = clamp(
				abs(mod(hue * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
				0.0, 1.0);
			return rgb;
		}
	}

	/* Darken the base scene to make arrows visible */
	vec3 baseColor = textureLod(screenTexture, uv, 0.0).rgb;
	return baseColor * 0.3;
}

// Velocity heatmap: cold (blue) → warm (red) color ramp for speed visualization.
// Input: normalized speed (0 = no motion, 1 = full intensity).
vec3 velocityHeatmap(float speed)
{
	speed = clamp(speed, 0.0, 1.0);
	// 5-stop gradient: black → blue → cyan → yellow → red
	vec3 c;
	if (speed < 0.25) {
		c = mix(vec3(0.0, 0.0, 0.1), vec3(0.0, 0.2, 1.0), speed * 4.0);
	} else if (speed < 0.5) {
		c = mix(vec3(0.0, 0.2, 1.0), vec3(0.0, 1.0, 1.0), (speed - 0.25) * 4.0);
	} else if (speed < 0.75) {
		c = mix(vec3(0.0, 1.0, 1.0), vec3(1.0, 1.0, 0.0), (speed - 0.5) * 4.0);
	} else {
		c = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (speed - 0.75) * 4.0);
	}
	return c;
}

vec3 applyMotionBlur(vec2 uv)
{
	/* 1. Get Velocity at center pixel */
	vec2 velocity = texture(velocityTexture, uv).rg;

	/* Debug Visualization (Early Exit) — mb_debugMode selects view */
	if (enableMotionBlurDebug) {
		if (mb_debugMode == 0) {
			/* Mode 0: Raw Velocity RG */
			return vec3(abs(velocity.x) * 20.0, abs(velocity.y) * 20.0, 0.0);
		} else if (mb_debugMode == 1) {
			/* Mode 1: Tile-Max velocity (per-tile 16x16 reduction) */
			vec2 tileVel = texture(tileMaxTexture, uv).rg;
			float tileSpeed = length(tileVel) * 20.0;
			return velocityHeatmap(tileSpeed);
		} else if (mb_debugMode == 2) {
			/* Mode 2: Neighbor-Max velocity (3x3 dilated tiles) */
			vec2 neighborVel = texture(neighborMaxTexture, uv).rg;
			float neighborSpeed = length(neighborVel) * 20.0;
			return velocityHeatmap(neighborSpeed);
		} else {
			/* Mode 3: Speed heatmap (per-pixel velocity magnitude) */
			float speed = length(velocity) * 20.0;
			return velocityHeatmap(speed);
		}
	}

	/* Vector Field Overlay */
	if (enableVectorFieldDebug) {
		return applyVectorFieldDebug(uv);
	}

	velocity *= mb_intensity;

	/* Clamp main velocity */
	float speed = length(velocity);
	if (speed > mb_maxVelocity) {
		velocity = normalize(velocity) * mb_maxVelocity;
		speed = mb_maxVelocity;
	}

	/* 2. Get Neighbor Max Velocity */
	vec2 maxNeighborVelocity = texture(neighborMaxTexture, uv).rg * mb_intensity;
	float maxNeighborSpeed = length(maxNeighborVelocity);

	/* Fetch Center Color (Raw) — LOD 0 to avoid mipmap bleed into FXAA */
	vec3 centerColor = textureLod(screenTexture, uv, 0.0).rgb;

	/* Early exit if negligible motion */
	if (speed < 0.0001 && maxNeighborSpeed < 0.0001) {
		return centerColor;
	}

	/* Center Depth */
	float centerDepth = linearizeDepth(texture(depthTexture, uv).r);

	/* Adaptive Sample Count — based on blur span in pixels.
	 * Ensures at least 1 sample per pixel of blur (step ≤ 1px).
	 * At max velocity this naturally limits to mb_samples. */
	float pixel_span = speed / min(screenTexelSize.x, screenTexelSize.y);
	int actual_samples = clamp(int(pixel_span), 2, mb_samples);

	/* Mipmap LOD: pre-filter source proportionally to step size (UE4-style).
	 * Prevents thin features (< step_pixels) from being missed entirely.
	 * Only apply when step > 1px (undersampling); at sub-pixel steps we
	 * are already oversampling so LOD 0 is correct. */
	float step_uv = speed / float(actual_samples);
	float step_pixels = step_uv / min(screenTexelSize.x, screenTexelSize.y);
	float mb_lod = (step_pixels > 1.0) ? (log2(step_pixels) + 1.0) : 0.0;

	vec3 acc = centerColor;
	float totalWeight = 1.0;

	/* Per-pixel base noise (screen-space hash, no diagonal structure) */
	float baseNoise = spatialHash(gl_FragCoord.xy);

	for (int i = 0; i < actual_samples; ++i) {
		if (i == actual_samples / 2)
			continue; /* Skip center */

		/* Golden ratio (R1) per-sample jitter: maximally spreads samples in [0,1].
		 * Each sample gets unique noise = fract(baseHash + i * phi_inv). */
		float noise = fract(baseNoise + float(i) * 0.6180339887498949);
		float t = mix(-0.5, 0.5, (float(i) + noise) / float(actual_samples));
		vec2 sampleUV = uv + velocity * t;

		vec3 sampleColor = textureLod(screenTexture, sampleUV, mb_lod).rgb;

		/* Soft Depth-Testing */
		float sampleDepth = linearizeDepth(texture(depthTexture, sampleUV).r);
		float depthDiff = sampleDepth - centerDepth;
		float weight = mix(1.0, 0.1, smoothstep(0.5, 2.0, depthDiff));

		acc += sampleColor * weight;
		totalWeight += weight;
	}

	return acc / totalWeight;
}

/* Wrapper to get "Scene Color" (Blurred or Raw) for CA to sample */
vec3 getSceneSource(vec2 uv)
{
	if (enableMotionBlur) {
		return applyMotionBlur(uv);
	}
	return textureLod(screenTexture, uv, 0.0).rgb;
}

// ============================================================================
// EFFECT: CHROMATIC ABERRATION
// ============================================================================
vec3 applyChromAbbr(vec2 uv)
{
	vec2 direction = uv - vec2(0.5);

	/* Get center pixel with motion blur (if enabled) */
	vec3 centerBlurred = getSceneSource(uv);

	/* Direct texture samples for R/B channels (skip motion blur for performance) */
	float r = textureLod(screenTexture, uv + direction * ca_strength, 0.0).r;
	float b = textureLod(screenTexture, uv - direction * ca_strength, 0.0).b;

	return vec3(r, centerBlurred.g, b);
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
	vec3 rgbM = textureLod(screenTexture, texCoords, 0.0).rgb;
	float lumaM = FxaaLuma(rgbM);

	float lumaN = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(0, -1)).rgb);
	float lumaW = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(-1, 0)).rgb);
	float lumaE = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(1, 0)).rgb);
	float lumaS = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(0, 1)).rgb);

	float rangeMin = min(lumaM, min(min(lumaN, lumaW), min(lumaS, lumaE)));
	float rangeMax = max(lumaM, max(max(lumaN, lumaW), max(lumaS, lumaE)));
	float range = rangeMax - rangeMin;

	// Early exit: contrast too low
	if (range < max(fxaaQualityEdgeThresholdMin, rangeMax * fxaaQualityEdgeThreshold)) {
		if (enableFXAADebug) return vec3(lumaM * 0.5); // Untouched (grayscale)
		return colorInput;
	}

	// 2. Corner sampling (diagonal neighbors)
	float lumaNW = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(-1, -1)).rgb);
	float lumaNE = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(1, -1)).rgb);
	float lumaSW = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(-1, 1)).rgb);
	float lumaSE = FxaaLuma(textureLodOffset(screenTexture, texCoords, 0.0, ivec2(1, 1)).rgb);

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

	return textureLod(screenTexture, finalUv, 0.0).rgb;
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
// EFFECT: 3D LUT (Gamut mapping / Film emulation)
// ============================================================================
vec3 applyLUT3D(vec3 color)
{
	// Clamp to valid LUT domain
	color = clamp(color, 0.0, 1.0);

	// Texel-center correction: avoids boundary clamping artifacts
	float lutSize = float(textureSize(lut3dTexture, 0).x);
	vec3 scale  = vec3((lutSize - 1.0) / lutSize);
	vec3 offset = vec3(0.5 / lutSize);
	vec3 uvw = color * scale + offset;

	return texture(lut3dTexture, uvw).rgb;
}

// ============================================================================
// EFFECT: FOG (Analytically-integrated exponential height fog)
// Based on Inigo Quilez "Better Fog" (2010) and UE5 Exponential Height Fog.
// Density follows d(y) = density * exp(-heightFalloff * y); the integral
// along the view ray is solved analytically to avoid banding artifacts.
// ============================================================================

// Compute opacity in [0, fog_maxOpacity] for a given UV.
float getFogAmount(vec2 uv)
{
	float depth = texture(depthTexture, uv).r;

	// Skip skybox (no geometry — depth at far plane)
	if (depth >= 0.9999) return 0.0;

	// Reconstruct world-space position from depth + invViewProj
	vec4 clipPos  = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 worldPos = fog_invViewProj * clipPos;
	worldPos.xyz /= worldPos.w;

	vec3 camPos    = fog_camPos.xyz;
	vec3 rayVec    = worldPos.xyz - camPos;
	float rayLength = length(rayVec);

	// Apply start distance — no fog before fog_start
	float effectiveDist = max(0.0, rayLength - fog_start);
	if (effectiveDist <= 0.0) return 0.0;

	vec3  rayDir = rayVec / rayLength;
	float fogRaw;

	if (fog_heightFalloff > 0.001) {
		// IQ analytical integration: density(y) = fog_density * exp(-b * y)
		// Integral from camPos to worldPos along the ray:
		//   fogRaw = (density/b) * exp(-camY * b) * (1 - exp(-dist * rayDir.y * b)) / rayDir.y
		float b   = fog_heightFalloff;
		float rdY = rayDir.y;

		if (abs(rdY) < 0.0001) {
			// Horizontal ray — constant density at camera height
			fogRaw = fog_density * exp(-camPos.y * b) * effectiveDist;
		} else {
			fogRaw = (fog_density / b) * exp(-camPos.y * b) *
			         (1.0 - exp(-effectiveDist * rdY * b)) / rdY;
		}
	} else {
		// No height variation — simple distance exponential
		fogRaw = fog_density * effectiveDist;
	}

	return clamp(1.0 - exp(-max(fogRaw, 0.0)), 0.0, fog_maxOpacity);
}

// ============================================================================
// EFFECT: Luminance Stops Debug (Filament-style color-coded exposure zones)
// Cyan = middle gray (18%), each stop up/down shifts color.
// ============================================================================

const vec3 luminanceDebugColors[16] = vec3[](
	vec3(0.0, 0.0, 0.0),         // black
	vec3(0.0, 0.0, 0.1647),      // darkest blue
	vec3(0.0, 0.0, 0.3647),      // darker blue
	vec3(0.0, 0.0, 0.6647),      // dark blue
	vec3(0.0, 0.0, 0.9647),      // blue
	vec3(0.0, 0.9255, 0.9255),   // cyan (middle gray)
	vec3(0.0, 0.5647, 0.0),      // dark green
	vec3(0.0, 0.7843, 0.0),      // green
	vec3(1.0, 1.0, 0.0),         // yellow
	vec3(0.90588, 0.75294, 0.0), // yellow-orange
	vec3(1.0, 0.5647, 0.0),      // orange
	vec3(1.0, 0.0, 0.0),         // bright red
	vec3(0.8392, 0.0, 0.0),      // red
	vec3(1.0, 0.0, 1.0),         // magenta
	vec3(0.6, 0.3333, 0.7882),   // purple
	vec3(1.0, 1.0, 1.0)          // white
);

vec3 applyLuminanceStops(vec3 hdrColor)
{
	float luma = dot(hdrColor, vec3(0.2126, 0.7152, 0.0722));
	// The 5th color (cyan) represents middle gray (18%)
	// Each stop above/below shifts one color index
	float v = log2(max(luma, 1e-7) / 0.18);
	v = clamp(v + 5.0, 0.0, 15.0);
	int index = int(floor(v));
	return mix(luminanceDebugColors[index], luminanceDebugColors[min(15, index + 1)], fract(v));
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

	// Debug priority: Motion blur debug (velocity visualization)
	if (enableMotionBlurDebug) {
		FragColor = vec4(applyMotionBlur(TexCoords), 1.0);
		return;
	}

	// Debug priority: Vector field debug (directional arrows overlay)
	if (enableVectorFieldDebug) {
		FragColor = vec4(applyMotionBlur(TexCoords), 1.0);
		return;
	}

	// Skybox detection: background pixels have depth exactly 1.0 (drawn at far plane)
	float depth = texture(depthTexture, TexCoords).r;
	bool isSkybox = (depth >= 0.9999);

	// Pipeline: Motion Blur -> Chromatic Aberration -> FXAA
	// CA calls getSceneSource() internally (which applies MB if enabled).
	if (enableChromAbbr && !splitBypassed(3u) && !isSkybox) {
		color = applyChromAbbr(TexCoords);
	} else {
		color = getSceneSource(TexCoords);
	}

	// 2. FXAA (spatial anti-aliasing, operates on screenTexture neighbors)
	if (enableFXAA && !splitBypassed(12u) && !isSkybox) {
		color = applyFXAA(color, TexCoords);
	}

	// 3. Depth of Field (mix sharp/blurred based on CoC from depth)
	if (enableDoF && !splitBypassed(6u)) {
		color = applyDoF(color, TexCoords);
	}

	// 4. Fog + Bloom (HDR space, interleaved — fog before bloom mix)
	// Fog is applied first so that the bloom contribution is attenuated by the
	// same fog factor: a sphere deep in fog should not emit bright halos.
	// fogFactor is computed once and reused to avoid a second depth-reconstruct.
	float fogFactor = 0.0;
	if (enableFog && !splitBypassed(15u)) {
		fogFactor = getFogAmount(TexCoords);
		if (enableFogDebug) {
			// Debug takes over the whole output — skip bloom/rest of pipeline.
			FragColor = vec4(vec3(fogFactor / max(fog_maxOpacity, 0.001)), 1.0);
			return;
		}
		color = mix(color, fog_color, fogFactor);
	}

	if (enableBloom && !splitBypassed(4u)) {
		// Bloom contribution scaled by (1 - fogFactor): heavy fog suppresses halos.
		vec3 bloomContrib = texture(bloomTexture, TexCoords).rgb * b_intensity;
		color += bloomContrib * (1.0 - fogFactor);
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

	// 7b. 3D LUT (gamut mapping — blended at lut3d_intensity, applied after grading)
	if (enableLUT3D && !splitBypassed(16u)) {
		vec3 lutColor = applyLUT3D(color);
		if (enableLUT3DDebug) {
			// Amplified delta: reveals even subtle LUT corrections (gray = neutral)
			color = clamp((lutColor - color) * 4.0 + 0.5, 0.0, 1.0);
		} else {
			color = mix(color, lutColor, lut3d_intensity);
		}
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

	// 11. Luminance Stops (Filament-style — final visualization of pipeline output)
	if (enableLuminanceDebug) {
		color = applyLuminanceStops(color);
	}

	// Draw split-line separators for each active effect (unique color per effect).
	// Colors come from the splitColors[] uniform (Glasbey palette, set at init).
	if (debugSplitMask != 0u) {
		for (uint i = 0u; i <= 23u; ++i) {
			if ((debugSplitMask & (1u << i)) != 0u) {
				float pos = splitPositions[i / 4u][i % 4u];
				float dist = abs(TexCoords.x - pos);
				if (dist < screenTexelSize.x * 1.5) {
					FragColor = vec4(splitColors[i], 1.0);
					return;
				}
			}
		}
	}

	FragColor = vec4(color, 1.0);
}
