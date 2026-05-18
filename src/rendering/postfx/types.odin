package postfx

// Post-processing effect types, parameters, and UBO layout.
// ISO port of pp_params.h + pp_ubo.h from suckless-ogl.

// Individual post-processing effects (bit positions match GLSL activeEffects).
Post_Effect :: enum u32 {
	Vignette       = 0,
	Grain          = 1,
	Exposure       = 2,
	Chrom_Abbr     = 3,
	Bloom          = 4,
	Color_Grading  = 5,
	Dof            = 6,
	Dof_Debug      = 7,
	Auto_Exposure  = 8,
	Exposure_Debug = 9,
	Motion_Blur    = 10,
	Motion_Blur_Debug = 11,
	FXAA           = 12,
	Tonemap        = 13,
	Banding        = 14,
	Fog            = 15,
	LUT3D          = 16,
}

// Type-safe set of enabled effects — maps directly to GLSL uint bitfield.
Effect_Flags :: bit_set[Post_Effect; u32]

// --- Parameter Structs ---

Vignette_Params :: struct {
	intensity:  f32,
	smoothness: f32,
	roundness:  f32,
}

Grain_Params :: struct {
	intensity:            f32,
	intensity_shadows:    f32,
	intensity_midtones:   f32,
	intensity_highlights: f32,
	shadows_max:          f32,
	highlights_min:       f32,
	texel_size:           f32,
}

Exposure_Params :: struct {
	exposure: f32,
}

Chrom_Aberration_Params :: struct {
	strength: f32,
}

White_Balance_Params :: struct {
	temperature: f32,
	tint:        f32,
}

Color_Grading_Params :: struct {
	saturation: f32,
	contrast:   f32,
	gamma:      f32,
	gain:       f32,
	offset:     f32,
	lift:       f32,
}

Tonemap_Params :: struct {
	slope:      f32,
	toe:        f32,
	shoulder:   f32,
	black_clip: f32,
	white_clip: f32,
}

Bloom_Params :: struct {
	intensity:      f32,
	threshold:      f32,
	soft_threshold: f32,
	radius:         f32,
}

FXAA_Params :: struct {
	subpix:             f32,
	edge_threshold:     f32,
	edge_threshold_min: f32,
}

Auto_Exposure_Params :: struct {
	min_luminance: f32,
	max_luminance: f32,
	speed_up:      f32,
	speed_down:    f32,
	key_value:     f32,
}

Dof_Params :: struct {
	focal_distance:   f32,
	focal_range:      f32,
	bokeh_scale:      f32,
	anamorphic_ratio: f32,
}

// --- Default Values ---

DEFAULT_VIGNETTE_INTENSITY  :: 0.8
DEFAULT_VIGNETTE_SMOOTHNESS :: 0.5
DEFAULT_VIGNETTE_ROUNDNESS  :: 1.0

DEFAULT_GRAIN_INTENSITY     :: 0.02
DEFAULT_GRAIN_SHADOWS_MAX   :: 0.09
DEFAULT_GRAIN_HIGHLIGHTS_MIN :: 0.5
DEFAULT_GRAIN_TEXEL_SIZE    :: 1.0

DEFAULT_EXPOSURE            :: 1.0

DEFAULT_CHROM_ABBR_STRENGTH :: 0.005

DEFAULT_WB_TEMP             :: 6500.0
DEFAULT_WB_TINT             :: 0.0

DEFAULT_TONEMAP_SLOPE       :: 1.0
DEFAULT_TONEMAP_TOE         :: 0.0
DEFAULT_TONEMAP_SHOULDER    :: 0.0
DEFAULT_TONEMAP_BLACK_CLIP  :: 0.0
DEFAULT_TONEMAP_WHITE_CLIP  :: 0.0

DEFAULT_BLOOM_INTENSITY     :: 0.0
DEFAULT_BLOOM_THRESHOLD     :: 1.0
DEFAULT_BLOOM_SOFT_THRESHOLD :: 0.5
DEFAULT_BLOOM_RADIUS        :: 1.0

DEFAULT_FXAA_SUBPIX             :: 0.75
DEFAULT_FXAA_EDGE_THRESHOLD     :: 0.125
DEFAULT_FXAA_EDGE_THRESHOLD_MIN :: 0.063

// Auto-exposure defaults (matches legacy suckless-ogl)
DEFAULT_AUTO_MIN_LUMINANCE    :: 0.05
DEFAULT_AUTO_MAX_LUMINANCE    :: 5000.0
DEFAULT_AUTO_SPEED_UP         :: 2.0
DEFAULT_AUTO_SPEED_DOWN       :: 1.0
DEFAULT_AUTO_KEY_VALUE        :: 0.20
DEFAULT_AUTO_EXPOSURE_INITIAL :: 1.2

// DoF defaults (matches legacy suckless-ogl)
DEFAULT_DOF_FOCAL_DISTANCE   :: 20.0
DEFAULT_DOF_FOCAL_RANGE      :: 5.0
DEFAULT_DOF_BOKEH_SCALE      :: 10.0
DEFAULT_DOF_ANAMORPHIC_RATIO :: 1.0

// --- UBO Layout (std140, binding 0) ---
// Must match the GLSL PostProcessBlock layout exactly.

Post_FX_UBO :: struct #packed {
	// Header (16 bytes)
	active_effects:     u32,
	time:               f32,
	screen_texel_size:  [2]f32,

	// Vignette (16 bytes)
	vignette_intensity:  f32,
	vignette_smoothness: f32,
	vignette_roundness:  f32,
	_pad1:               f32,

	// Grain (32 bytes)
	grain_intensity:            f32,
	grain_intensity_shadows:    f32,
	grain_intensity_midtones:   f32,
	grain_intensity_highlights: f32,
	grain_shadows_max:          f32,
	grain_highlights_min:       f32,
	grain_texel_size:           f32,
	_pad2:                      f32,

	// Exposure (16 bytes)
	exposure_manual: f32,
	_pad3:           [3]f32,

	// Chromatic Aberration (16 bytes)
	chrom_abbr_strength: f32,
	_pad4:               [3]f32,

	// White Balance (16 bytes)
	wb_temperature: f32,
	wb_tint:        f32,
	_pad5:          [2]f32,

	// Color Grading (32 bytes)
	grading_saturation: f32,
	grading_contrast:   f32,
	grading_gamma:      f32,
	grading_gain:       f32,
	grading_offset:     f32,
	grading_lift:       f32,
	_pad6:              [2]f32,

	// Tonemap (32 bytes)
	tonemap_slope:      f32,
	tonemap_toe:        f32,
	tonemap_shoulder:   f32,
	tonemap_black_clip: f32,
	tonemap_white_clip: f32,
	_pad7:              [3]f32,

	// Bloom (16 bytes)
	bloom_intensity:      f32,
	bloom_threshold:      f32,
	bloom_soft_threshold: f32,
	bloom_radius:         f32,

	// FXAA (16 bytes)
	fxaa_subpix:             f32,
	fxaa_edge_threshold:     f32,
	fxaa_edge_threshold_min: f32,
	_pad10:                  f32,

	// DoF (16 bytes)
	dof_focal_distance:   f32,
	dof_focal_range:      f32,
	dof_bokeh_scale:      f32,
	dof_anamorphic_ratio: f32,
}

// Texture unit assignments for post-processing samplers.
TEX_UNIT_SCENE    :: 0
TEX_UNIT_BLOOM    :: 1
TEX_UNIT_DEPTH    :: 2
TEX_UNIT_EXPOSURE :: 3
TEX_UNIT_VELOCITY :: 4
TEX_UNIT_DOF      :: 5
