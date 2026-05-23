package glasbey

// Glasbey maximin palette generator.
//
// Implements the greedy sequential algorithm from:
//   Glasbey et al. (2007) "Colour Displays for Categorical Images"
//   Color Research & Application, 32(4), 304–309.
//   DOI: 10.1002/col.20327
//
// Given a set of background colors (constraints), iteratively selects
// the RGB color that maximizes the minimum CIELAB ΔE to all previously
// selected colors. This produces a palette where consecutive entries are
// maximally perceptually distinct.

import "core:fmt"
import "core:math"
import "core:strings"

// --- Public types ---

Color_RGB :: struct {
	r, g, b: f32, // [0, 255] range
}

Color_LAB :: struct {
	L, a, b: f32,
}

// Configuration for palette generation.
Config :: struct {
	size:             int, // Number of colors to generate
	step:             int, // Gamut sampling step (1 = full 16M, 16 = ~4K)
	backgrounds:      []Color_RGB, // Constraint colors (not included in output)
	lightness_bounds: [2]f32, // L* range filter, e.g. {20, 90}. {0,0} = disabled
	chroma_bounds:    [2]f32, // C*ab range filter, e.g. {20, 100}. {0,0} = disabled
	adaptive:         bool, // Use coarse+refine strategy (fast, near-optimal)
}

// Result of palette generation.
Result :: struct {
	palette:       []Color_RGB, // Caller owns — must call `destroy_result`
	min_delta_e:   f32, // Minimum pairwise ΔE in the final palette
	closest_pair:  [2]int, // Indices of the closest pair
}

DEFAULT_CONFIG :: Config{
	size             = 16,
	step             = 1,
	backgrounds      = nil,
	lightness_bounds = {0, 0},
	chroma_bounds    = {0, 0},
	adaptive         = false,
}

@(rodata)
DEFAULT_BACKGROUNDS := [?]Color_RGB{{0, 0, 0}, {255, 255, 255}}

// --- Public API ---

// Generate a Glasbey palette with the given configuration.
// Returns a Result whose `palette` field is heap-allocated.
// The caller MUST call `destroy_result` when done.
generate :: proc(cfg: Config) -> Result {
	step := cfg.step if cfg.step > 0 else 1
	size := cfg.size if cfg.size > 0 else 16

	if cfg.adaptive && step > 1 {
		return generate_adaptive(cfg, step, size)
	}

	// Build candidate gamut with optional L*/C* filtering
	candidates := build_gamut(step, cfg.lightness_bounds, cfg.chroma_bounds)
	defer delete(candidates)

	// Apply background constraints
	apply_backgrounds(candidates, cfg.backgrounds)

	// Greedy maximin selection
	palette := make([]Color_RGB, size)
	for pick := 0; pick < size; pick += 1 {
		best_idx := find_maximin(candidates)
		winner := candidates[best_idx]
		palette[pick] = winner.rgb
		update_distances(candidates, winner.lab)
	}

	min_de, pair := compute_min_pairwise_delta_e(palette)
	return Result{palette = palette, min_delta_e = min_de, closest_pair = pair}
}

// Free the palette allocated by `generate`.
destroy_result :: proc(r: ^Result) {
	if r.palette != nil {
		delete(r.palette)
		r.palette = nil
	}
}

// Compute the minimum pairwise ΔE and the indices of the closest pair.
compute_min_pairwise_delta_e :: proc(palette: []Color_RGB) -> (min_de: f32, pair: [2]int) {
	min_de = math.INF_F32
	pair = {0, 0}

	n := len(palette)
	if n < 2 {
		return
	}

	labs := make([]Color_LAB, n)
	defer delete(labs)
	for c, i in palette {
		labs[i] = rgb_to_lab(c)
	}

	for i := 0; i < n; i += 1 {
		for j := i + 1; j < n; j += 1 {
			d := delta_e(labs[i], labs[j])
			if d < min_de {
				min_de = d
				pair = {i, j}
			}
		}
	}
	return
}

// --- Export utilities ---

// Export palette as an Odin compile-time constant.
// Caller owns the returned string (heap-allocated).
export_odin :: proc(palette: []Color_RGB, name: string) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s :: [%d][3]f32{{\n", name, len(palette))
	for c, i in palette {
		hex_r := int(c.r)
		hex_g := int(c.g)
		hex_b := int(c.b)
		fmt.sbprintf(
			&b,
			"\t{{%.4f, %.4f, %.4f}}, // %3d #%02x%02x%02x\n",
			c.r / 255.0, c.g / 255.0, c.b / 255.0,
			i, hex_r, hex_g, hex_b,
		)
	}
	fmt.sbprintf(&b, "}}\n")
	return strings.to_string(b)
}

// Export palette as a GLSL const array declaration.
// Caller owns the returned string (heap-allocated).
export_glsl :: proc(palette: []Color_RGB, name: string) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "const vec3 %s[%d] = vec3[](\n", name, len(palette))
	for c, i in palette {
		hex_r := int(c.r)
		hex_g := int(c.g)
		hex_b := int(c.b)
		comma := "," if i < len(palette) - 1 else ""
		fmt.sbprintf(
			&b,
			"\tvec3(%.4f, %.4f, %.4f)%s  // %2d #%02x%02x%02x\n",
			c.r / 255.0, c.g / 255.0, c.b / 255.0,
			comma, i, hex_r, hex_g, hex_b,
		)
	}
	fmt.sbprintf(&b, ");\n")
	return strings.to_string(b)
}

// --- Colorimetric conversions (public for testing) ---

// Convert sRGB [0,255] to CIELAB.
rgb_to_lab :: proc(color: Color_RGB) -> Color_LAB {
	r := srgb_to_linear(color.r / 255.0)
	g := srgb_to_linear(color.g / 255.0)
	b := srgb_to_linear(color.b / 255.0)

	// Linear RGB → CIEXYZ (sRGB D65 matrix)
	x := r * 0.4124564 + g * 0.3575761 + b * 0.1804375
	y := r * 0.2126729 + g * 0.7151522 + b * 0.0721750
	z := r * 0.0193339 + g * 0.1191920 + b * 0.9503041

	// XYZ → CIELAB (D65 white reference)
	XN :: 0.95047
	YN :: 1.00000
	ZN :: 1.08883

	fx := lab_f(x / XN)
	fy := lab_f(y / YN)
	fz := lab_f(z / ZN)

	L_val := 116.0 * fy - 16.0
	a_val := 500.0 * (fx - fy)
	b_val := 200.0 * (fy - fz)

	return Color_LAB{L_val, a_val, b_val}
}

// CIELAB chroma: C*ab = sqrt(a*² + b*²).
chroma :: proc(lab: Color_LAB) -> f32 {
	return math.sqrt(lab.a * lab.a + lab.b * lab.b)
}

// Euclidean distance in CIELAB (CIE76 ΔE).
delta_e :: proc(c1, c2: Color_LAB) -> f32 {
	dL := c1.L - c2.L
	da := c1.a - c2.a
	db := c1.b - c2.b
	return math.sqrt(dL * dL + da * da + db * db)
}

// --- Private ---

@(private)
Candidate :: struct {
	rgb:      Color_RGB,
	lab:      Color_LAB,
	min_dist: f32,
}

@(private)
srgb_to_linear :: proc(c: f32) -> f32 {
	if c <= 0.04045 {
		return c / 12.92
	}
	return math.pow((c + 0.055) / 1.055, 2.4)
}

@(private)
lab_f :: proc(t: f32) -> f32 {
	if t > 0.008856 {
		return math.pow(t, 1.0 / 3.0)
	}
	return (903.3 * t + 16.0) / 116.0
}

// Build the candidate gamut with optional L*/C* bounds filtering.
@(private)
build_gamut :: proc(step: int, l_bounds, c_bounds: [2]f32) -> []Candidate {
	filter_l := l_bounds[0] != 0 || l_bounds[1] != 0
	filter_c := c_bounds[0] != 0 || c_bounds[1] != 0

	// First pass: count candidates (to avoid over-allocation with dynamic array)
	count := 0
	for r := 0; r <= 255; r += step {
		for g := 0; g <= 255; g += step {
			for b := 0; b <= 255; b += step {
				if filter_l || filter_c {
					lab := rgb_to_lab(Color_RGB{f32(r), f32(g), f32(b)})
					if filter_l && (lab.L < l_bounds[0] || lab.L > l_bounds[1]) {
						continue
					}
					if filter_c {
						c := chroma(lab)
						if c < c_bounds[0] || c > c_bounds[1] {
							continue
						}
					}
				}
				count += 1
			}
		}
	}

	candidates := make([]Candidate, count)
	idx := 0
	for r := 0; r <= 255; r += step {
		for g := 0; g <= 255; g += step {
			for b := 0; b <= 255; b += step {
				rgb := Color_RGB{f32(r), f32(g), f32(b)}
				lab := rgb_to_lab(rgb)
				if filter_l && (lab.L < l_bounds[0] || lab.L > l_bounds[1]) {
					continue
				}
				if filter_c {
					c := chroma(lab)
					if c < c_bounds[0] || c > c_bounds[1] {
						continue
					}
				}
				candidates[idx] = Candidate{
					rgb      = rgb,
					lab      = lab,
					min_dist = math.INF_F32,
				}
				idx += 1
			}
		}
	}
	return candidates
}

// Apply background color constraints to candidate distances.
@(private)
apply_backgrounds :: proc(candidates: []Candidate, backgrounds: []Color_RGB) {
	bgs := backgrounds if backgrounds != nil else DEFAULT_BACKGROUNDS[:]
	for bg in bgs {
		bg_lab := rgb_to_lab(bg)
		for &c in candidates {
			dist := delta_e(c.lab, bg_lab)
			if dist < c.min_dist {
				c.min_dist = dist
			}
		}
	}
}

// Find the candidate with the maximum min_dist (maximin selection).
@(private)
find_maximin :: proc(candidates: []Candidate) -> int {
	best_idx := 0
	max_min: f32 = -1.0
	for c, i in candidates {
		if c.min_dist > max_min {
			max_min = c.min_dist
			best_idx = i
		}
	}
	return best_idx
}

// Update all candidate distances after selecting a new palette color.
@(private)
update_distances :: proc(candidates: []Candidate, new_lab: Color_LAB) {
	for &c in candidates {
		dist := delta_e(c.lab, new_lab)
		if dist < c.min_dist {
			c.min_dist = dist
		}
	}
}

// Adaptive strategy: coarse pick + local refinement per step.
// For each pick: find winner at coarse step, then re-search ±step neighborhood
// at step=1 to find the true local optimum.
@(private)
generate_adaptive :: proc(cfg: Config, coarse_step: int, size: int) -> Result {
	// Build coarse gamut
	candidates := build_gamut(coarse_step, cfg.lightness_bounds, cfg.chroma_bounds)
	defer delete(candidates)

	apply_backgrounds(candidates, cfg.backgrounds)

	// Track selected LABs for distance updates on refinement candidates
	selected_labs := make([dynamic]Color_LAB)
	defer delete(selected_labs)

	// Collect background LABs for refinement constraint
	bgs := cfg.backgrounds if cfg.backgrounds != nil else DEFAULT_BACKGROUNDS[:]
	for bg in bgs {
		append(&selected_labs, rgb_to_lab(bg))
	}

	palette := make([]Color_RGB, size)

	for pick := 0; pick < size; pick += 1 {
		// Coarse pick
		coarse_idx := find_maximin(candidates)
		coarse_winner := candidates[coarse_idx]

		// Refine: search ±coarse_step around the coarse winner at step=1
		refined := refine_local(coarse_winner.rgb, coarse_step, selected_labs[:],
			cfg.lightness_bounds, cfg.chroma_bounds)

		palette[pick] = refined.rgb
		append(&selected_labs, refined.lab)

		// Update coarse candidates with the refined winner
		update_distances(candidates, refined.lab)
	}

	min_de, pair := compute_min_pairwise_delta_e(palette)
	return Result{palette = palette, min_delta_e = min_de, closest_pair = pair}
}

// Search the ±radius neighborhood around center at step=1, returning the
// candidate that maximizes min(ΔE) to all already-selected colors.
@(private)
refine_local :: proc(
	center: Color_RGB,
	radius: int,
	selected: []Color_LAB,
	l_bounds, c_bounds: [2]f32,
) -> Candidate {
	filter_l := l_bounds[0] != 0 || l_bounds[1] != 0
	filter_c := c_bounds[0] != 0 || c_bounds[1] != 0

	best := Candidate{rgb = center, lab = rgb_to_lab(center), min_dist = -1.0}

	r_lo := max(0, int(center.r) - radius)
	r_hi := min(255, int(center.r) + radius)
	g_lo := max(0, int(center.g) - radius)
	g_hi := min(255, int(center.g) + radius)
	b_lo := max(0, int(center.b) - radius)
	b_hi := min(255, int(center.b) + radius)

	for r := r_lo; r <= r_hi; r += 1 {
		for g := g_lo; g <= g_hi; g += 1 {
			for b := b_lo; b <= b_hi; b += 1 {
				rgb := Color_RGB{f32(r), f32(g), f32(b)}
				lab := rgb_to_lab(rgb)

				if filter_l && (lab.L < l_bounds[0] || lab.L > l_bounds[1]) {
					continue
				}
				if filter_c {
					ch := chroma(lab)
					if ch < c_bounds[0] || ch > c_bounds[1] {
						continue
					}
				}

				// Compute min distance to all selected colors
				min_d: f32 = math.INF_F32
				for sel in selected {
					d := delta_e(lab, sel)
					if d < min_d {
						min_d = d
					}
				}

				if min_d > best.min_dist {
					best = Candidate{rgb = rgb, lab = lab, min_dist = min_d}
				}
			}
		}
	}

	return best
}
