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
	FXAA_Debug     = 17,
	Stencil_Debug  = 18,
	Bloom_Debug    = 19,
	Fog_Debug      = 20,
	LUT3D_Debug    = 21,
	Vector_Field_Debug = 22,
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

// Banding algorithm modes (matches GLSL bandingMode).
Banding_Mode :: enum i32 {
	Linear     = 0, // Standard uniform posterization
	Dithered   = 1, // Ordered dithering (Bayer 4x4)
	Perceptual = 2, // Gamma-weighted quantization
	Channel    = 3, // Independent RGB levels
	Luminance  = 4, // Grayscale quantization + tint
}

Banding_Params :: struct {
	mode:             Banding_Mode,
	levels:           f32,
	dither_strength:  f32,
	perceptual_gamma: f32,
	channel_levels:   [3]f32,
}

Fog_Params :: struct {
	density:        f32,
	start:          f32,
	height_falloff: f32,
	max_opacity:    f32,
	color:          [3]f32,
}

Motion_Blur_Params :: struct {
	intensity:        f32,
	max_velocity:     f32,
	samples:          i32,
	debug_mode:       i32, // 0=velocity, 1=tile-max, 2=neighbor-max, 3=speed
	// Synthetic velocity injection (debug tool — persisted in session)
	inject_enabled:   bool,
	inject_direction: f32, // Angle in degrees (0=right, 90=up, 180=left, 270=down)
	inject_magnitude: f32, // Velocity magnitude in UV space (same units as max_velocity)
}

LUT3D_Params :: struct {
	intensity: f32,
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

DEFAULT_DOF_PARAMS :: Dof_Params{
	focal_distance   = DEFAULT_DOF_FOCAL_DISTANCE,
	focal_range      = DEFAULT_DOF_FOCAL_RANGE,
	bokeh_scale      = DEFAULT_DOF_BOKEH_SCALE,
	anamorphic_ratio = DEFAULT_DOF_ANAMORPHIC_RATIO,
}

// Banding defaults
DEFAULT_BANDING_LEVELS :: 256.0 // 8-bit simulation (no visible banding)

DEFAULT_BANDING_PARAMS :: Banding_Params{
	mode             = .Linear,
	levels           = DEFAULT_BANDING_LEVELS,
	dither_strength  = 0.0,
	perceptual_gamma = 1.0,
	channel_levels   = {DEFAULT_BANDING_LEVELS, DEFAULT_BANDING_LEVELS, DEFAULT_BANDING_LEVELS},
}

// Fog defaults (matches legacy suckless-ogl)
DEFAULT_FOG_DENSITY        :: 0.08
DEFAULT_FOG_START          :: 18.0
DEFAULT_FOG_HEIGHT_FALLOFF :: 0.02
DEFAULT_FOG_MAX_OPACITY    :: 0.75
DEFAULT_FOG_COLOR          :: [3]f32{0.20, 0.25, 0.30}

DEFAULT_FOG_PARAMS :: Fog_Params{
	density        = DEFAULT_FOG_DENSITY,
	start          = DEFAULT_FOG_START,
	height_falloff = DEFAULT_FOG_HEIGHT_FALLOFF,
	max_opacity    = DEFAULT_FOG_MAX_OPACITY,
	color          = DEFAULT_FOG_COLOR,
}

// Motion blur defaults
DEFAULT_MOTION_BLUR_PARAMS :: Motion_Blur_Params{
	intensity    = 1.0,
	max_velocity = 0.05,
	samples      = 8,
	debug_mode   = 0,
}

// LUT3D defaults
DEFAULT_LUT3D_PARAMS :: LUT3D_Params{
	intensity = 1.0,
}

// --- UBO Layout (std140, binding 0) ---
// Must match the GLSL PostProcessBlock layout exactly.
// See docs/std140-padding-strategy-2026-05-19.md for rationale.

Post_FX_UBO :: struct #packed {
	// Header (16 bytes)
	active_effects:     u32,
	time:               f32,
	screen_texel_size:  [2]f32,

	// Vignette (16 bytes)
	vignette_intensity:  f32,
	vignette_smoothness: f32,
	vignette_roundness:  f32,
	_:                   f32,

	// Grain (32 bytes)
	grain_intensity:            f32,
	grain_intensity_shadows:    f32,
	grain_intensity_midtones:   f32,
	grain_intensity_highlights: f32,
	grain_shadows_max:          f32,
	grain_highlights_min:       f32,
	grain_texel_size:           f32,
	_:                          f32,

	// Exposure (16 bytes)
	exposure_manual: f32,
	_:               [3]f32,

	// Chromatic Aberration (16 bytes)
	chrom_abbr_strength: f32,
	_:                   [3]f32,

	// White Balance (16 bytes)
	wb_temperature: f32,
	wb_tint:        f32,
	_:              [2]f32,

	// Color Grading (32 bytes)
	grading_saturation: f32,
	grading_contrast:   f32,
	grading_gamma:      f32,
	grading_gain:       f32,
	grading_offset:     f32,
	grading_lift:       f32,
	_:                  [2]f32,

	// Tonemap (32 bytes)
	tonemap_slope:      f32,
	tonemap_toe:        f32,
	tonemap_shoulder:   f32,
	tonemap_black_clip: f32,
	tonemap_white_clip: f32,
	_:                  [3]f32,

	// Bloom (16 bytes)
	bloom_intensity:      f32,
	bloom_threshold:      f32,
	bloom_soft_threshold: f32,
	bloom_radius:         f32,

	// FXAA (16 bytes)
	fxaa_subpix:             f32,
	fxaa_edge_threshold:     f32,
	fxaa_edge_threshold_min: f32,
	_:                       f32,

	// DoF (16 bytes)
	dof_focal_distance:   f32,
	dof_focal_range:      f32,
	dof_bokeh_scale:      f32,
	dof_anamorphic_ratio: f32,

	// Camera planes (16 bytes)
	z_near: f32,
	z_far:  f32,
	_:      [2]f32,

	// Motion Blur (16 bytes)
	mb_intensity:    f32,
	mb_max_velocity: f32,
	mb_samples:      i32,
	mb_debug_mode:   i32,

	// Banding (32 bytes)
	banding_mode:             i32,
	banding_levels:           f32,
	banding_dither_strength:  f32,
	banding_perceptual_gamma: f32,
	banding_channel_levels:   [3]f32,
	_:                        f32,

	// Fog (112 bytes: 16 + 16 + 16 + 64)
	fog_density:        f32,
	fog_start:          f32,
	fog_height_falloff: f32,
	fog_max_opacity:    f32,
	fog_color:          [3]f32,
	_:                  f32,
	fog_cam_pos:        [4]f32,
	fog_inv_view_proj:  [16]f32, // mat4 as flat array (std140)

	// LUT3D (16 bytes)
	lut3d_intensity: f32,
	_:               [3]f32,

	// Debug split-screen mask (16 bytes) — per-effect A/B comparison view.
	debug_split_mask: u32,
	_pad_split:       [3]f32,

	// Per-effect split positions (80 bytes = 5 × vec4).
	// Indexed as splitPositions[bit/4][bit%4] in GLSL.
	split_positions: [20]f32,
}

#assert(size_of(Post_FX_UBO) == 512)

// Compile-time offset verification — matches GLSL PostProcessBlock (std140).
// If any field shifts, these will catch the mismatch at compile time.
#assert(offset_of(Post_FX_UBO, active_effects)      == 0)    // Header
#assert(offset_of(Post_FX_UBO, vignette_intensity)   == 16)   // Vignette
#assert(offset_of(Post_FX_UBO, grain_intensity)      == 32)   // Grain
#assert(offset_of(Post_FX_UBO, exposure_manual)      == 64)   // Exposure
#assert(offset_of(Post_FX_UBO, chrom_abbr_strength)  == 80)   // ChromAbbr
#assert(offset_of(Post_FX_UBO, wb_temperature)       == 96)   // WhiteBalance
#assert(offset_of(Post_FX_UBO, grading_saturation)   == 112)  // ColorGrading
#assert(offset_of(Post_FX_UBO, tonemap_slope)        == 144)  // Tonemap
#assert(offset_of(Post_FX_UBO, bloom_intensity)      == 176)  // Bloom
#assert(offset_of(Post_FX_UBO, fxaa_subpix)          == 192)  // FXAA
#assert(offset_of(Post_FX_UBO, dof_focal_distance)   == 208)  // DoF
#assert(offset_of(Post_FX_UBO, z_near)               == 224)  // Camera planes
#assert(offset_of(Post_FX_UBO, mb_intensity)         == 240)  // Motion Blur
#assert(offset_of(Post_FX_UBO, banding_mode)         == 256)  // Banding
#assert(offset_of(Post_FX_UBO, fog_density)          == 288)  // Fog
#assert(offset_of(Post_FX_UBO, lut3d_intensity)      == 400)  // LUT3D
#assert(offset_of(Post_FX_UBO, debug_split_mask)     == 416)  // Debug split
#assert(offset_of(Post_FX_UBO, split_positions)      == 432)  // Per-effect split pos

// Texture unit assignments for post-processing samplers.
TEX_UNIT_SCENE        :: 0
TEX_UNIT_BLOOM        :: 1
TEX_UNIT_DEPTH        :: 2
TEX_UNIT_EXPOSURE     :: 3
TEX_UNIT_VELOCITY     :: 4
TEX_UNIT_DOF          :: 5
TEX_UNIT_NEIGHBOR_MAX :: 6
TEX_UNIT_TILE_MAX     :: 7
TEX_UNIT_LUT3D        :: 8
