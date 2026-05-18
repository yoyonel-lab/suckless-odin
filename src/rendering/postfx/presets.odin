package postfx

// Post-processing presets — named configurations as compile-time constants.
// Apply with pipeline_apply_preset().

Preset :: struct {
	name:          string,
	effects:       Effect_Flags,
	vignette:      Vignette_Params,
	grain:         Grain_Params,
	exposure:      Exposure_Params,
	chrom_abbr:    Chrom_Aberration_Params,
	white_balance: White_Balance_Params,
	color_grading: Color_Grading_Params,
	tonemapper:    Tonemap_Params,
	bloom:         Bloom_Params,
	fxaa:          FXAA_Params,
}

// All available presets (indexed by Preset_Id).
Preset_Id :: enum {
	Default,
	Subtle,
	Cinematic,
	Vibrant,
	Clean,
}

PRESET_NAMES :: [Preset_Id]string{
	.Default   = "Default",
	.Subtle    = "Subtle",
	.Cinematic = "Cinematic",
	.Vibrant   = "Vibrant",
	.Clean     = "Clean",
}

PRESETS :: [Preset_Id]Preset{
	.Default = {
		name    = "Default",
		effects = {.Exposure},
		vignette = {
			intensity  = DEFAULT_VIGNETTE_INTENSITY,
			smoothness = DEFAULT_VIGNETTE_SMOOTHNESS,
			roundness  = DEFAULT_VIGNETTE_ROUNDNESS,
		},
		grain = {
			intensity            = DEFAULT_GRAIN_INTENSITY,
			intensity_shadows    = 1.0,
			intensity_midtones   = 1.0,
			intensity_highlights = 1.0,
			shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
			highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
			texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
		},
		exposure      = {exposure = DEFAULT_EXPOSURE},
		chrom_abbr    = {strength = DEFAULT_CHROM_ABBR_STRENGTH},
		white_balance = {temperature = DEFAULT_WB_TEMP, tint = DEFAULT_WB_TINT},
		color_grading = {saturation = 1.0, contrast = 1.0, gamma = 1.0, gain = 1.0, offset = 0.0, lift = 0.0},
		tonemapper    = {slope = DEFAULT_TONEMAP_SLOPE, toe = DEFAULT_TONEMAP_TOE, shoulder = DEFAULT_TONEMAP_SHOULDER, black_clip = DEFAULT_TONEMAP_BLACK_CLIP, white_clip = DEFAULT_TONEMAP_WHITE_CLIP},
		bloom         = {intensity = DEFAULT_BLOOM_INTENSITY, threshold = DEFAULT_BLOOM_THRESHOLD, soft_threshold = DEFAULT_BLOOM_SOFT_THRESHOLD, radius = DEFAULT_BLOOM_RADIUS},
		fxaa          = {subpix = DEFAULT_FXAA_SUBPIX, edge_threshold = DEFAULT_FXAA_EDGE_THRESHOLD, edge_threshold_min = DEFAULT_FXAA_EDGE_THRESHOLD_MIN},
	},
	.Subtle = {
		name    = "Subtle",
		effects = {.Exposure, .Tonemap, .Vignette},
		vignette = {intensity = 0.4, smoothness = 0.6, roundness = 1.0},
		grain = {
			intensity            = 0.0,
			intensity_shadows    = 1.0,
			intensity_midtones   = 1.0,
			intensity_highlights = 1.0,
			shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
			highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
			texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
		},
		exposure      = {exposure = 1.0},
		chrom_abbr    = {strength = 0.0},
		white_balance = {temperature = 6500.0, tint = 0.0},
		color_grading = {saturation = 1.0, contrast = 1.0, gamma = 1.0, gain = 1.0, offset = 0.0, lift = 0.0},
		tonemapper    = {slope = 1.0, toe = 0.1, shoulder = 0.3, black_clip = 0.0, white_clip = 0.0},
		bloom         = {intensity = 0.0, threshold = 1.0, soft_threshold = 0.5, radius = 1.0},
		fxaa          = {subpix = DEFAULT_FXAA_SUBPIX, edge_threshold = DEFAULT_FXAA_EDGE_THRESHOLD, edge_threshold_min = DEFAULT_FXAA_EDGE_THRESHOLD_MIN},
	},
	.Cinematic = {
		name    = "Cinematic",
		effects = {.Exposure, .Tonemap, .Vignette, .Grain, .Bloom, .Color_Grading, .Chrom_Abbr},
		vignette = {intensity = 1.2, smoothness = 0.4, roundness = 0.8},
		grain = {
			intensity            = 0.04,
			intensity_shadows    = 1.2,
			intensity_midtones   = 0.8,
			intensity_highlights = 0.3,
			shadows_max          = 0.12,
			highlights_min       = 0.6,
			texel_size           = 1.5,
		},
		exposure      = {exposure = 1.2},
		chrom_abbr    = {strength = 0.003},
		white_balance = {temperature = 5800.0, tint = 0.0},
		color_grading = {saturation = 0.9, contrast = 1.15, gamma = 0.95, gain = 1.0, offset = -0.01, lift = 0.0},
		tonemapper    = {slope = 1.2, toe = 0.2, shoulder = 0.5, black_clip = 0.01, white_clip = 0.02},
		bloom         = {intensity = 0.3, threshold = 0.8, soft_threshold = 0.6, radius = 1.2},
		fxaa          = {subpix = DEFAULT_FXAA_SUBPIX, edge_threshold = DEFAULT_FXAA_EDGE_THRESHOLD, edge_threshold_min = DEFAULT_FXAA_EDGE_THRESHOLD_MIN},
	},
	.Vibrant = {
		name    = "Vibrant",
		effects = {.Exposure, .Tonemap, .Bloom, .Color_Grading, .FXAA},
		vignette = {intensity = 0.3, smoothness = 0.8, roundness = 1.0},
		grain = {
			intensity            = 0.0,
			intensity_shadows    = 1.0,
			intensity_midtones   = 1.0,
			intensity_highlights = 1.0,
			shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
			highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
			texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
		},
		exposure      = {exposure = 1.3},
		chrom_abbr    = {strength = 0.0},
		white_balance = {temperature = 6500.0, tint = 0.0},
		color_grading = {saturation = 1.4, contrast = 1.1, gamma = 1.0, gain = 1.05, offset = 0.0, lift = 0.0},
		tonemapper    = {slope = 1.0, toe = 0.1, shoulder = 0.4, black_clip = 0.0, white_clip = 0.0},
		bloom         = {intensity = 0.5, threshold = 0.6, soft_threshold = 0.7, radius = 1.5},
		fxaa          = {subpix = 0.75, edge_threshold = 0.125, edge_threshold_min = 0.063},
	},
	.Clean = {
		name    = "Clean",
		effects = {.Exposure, .Tonemap, .FXAA},
		vignette = {intensity = 0.0, smoothness = 0.5, roundness = 1.0},
		grain = {
			intensity            = 0.0,
			intensity_shadows    = 1.0,
			intensity_midtones   = 1.0,
			intensity_highlights = 1.0,
			shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
			highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
			texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
		},
		exposure      = {exposure = 1.0},
		chrom_abbr    = {strength = 0.0},
		white_balance = {temperature = 6500.0, tint = 0.0},
		color_grading = {saturation = 1.0, contrast = 1.0, gamma = 1.0, gain = 1.0, offset = 0.0, lift = 0.0},
		tonemapper    = {slope = 1.0, toe = 0.0, shoulder = 0.0, black_clip = 0.0, white_clip = 0.0},
		bloom         = {intensity = 0.0, threshold = 1.0, soft_threshold = 0.5, radius = 1.0},
		fxaa          = {subpix = 0.75, edge_threshold = 0.125, edge_threshold_min = 0.063},
	},
}

// Apply a preset to the pipeline (overwrites all params and active effects).
pipeline_apply_preset :: proc(p: ^Pipeline, id: Preset_Id) {
	presets := PRESETS
	preset := presets[id]
	p.active_effects = preset.effects
	p.vignette       = preset.vignette
	p.grain          = preset.grain
	p.exposure       = preset.exposure
	p.chrom_abbr     = preset.chrom_abbr
	p.white_balance  = preset.white_balance
	p.color_grading  = preset.color_grading
	p.tonemapper     = preset.tonemapper
	p.bloom          = preset.bloom
	p.fxaa           = preset.fxaa
	p.ubo_dirty      = true
}
