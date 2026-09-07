package rendering

import log "../core/log"

Optimization_Profile :: enum i32 {
	Quality           = 0,
	Balanced          = 1,
	Ultra_Performance = 2,
	Custom            = 3,
}

optimization_profile_name :: proc(profile: Optimization_Profile) -> string {
	switch profile {
	case .Quality:           return "Quality (Reference / Cinematic)"
	case .Balanced:          return "Balanced (Optimized iGPU - Recommended)"
	case .Ultra_Performance: return "Ultra-Performance (Maximum FPS)"
	case .Custom:            return "Custom (User-Defined)"
	}
	return "Unknown"
}

optimization_profile_apply :: proc(profile: Optimization_Profile, vr: ^Volumetric_Renderer, light: ^Point_Light, sc: ^Shadow_Cubemap) {
	if profile == .Custom do return

	switch profile {
	case .Quality:
		if vr != nil {
			vr.params.step_count = 32
			vr.params.resolution_divider = 2
			vr.params.upsample_mode = 2
			vr.params.upsample_sharpness = 300.0
			vr.params.blur_mode = 2
			vr.params.blur_sharpness = 600.0
			vr.params.jitter_enabled = true
			vr.params.taa_mode = 2
			vr.params.taa_alpha = 0.25
		}
		if light != nil {
			light.shadow_pcf_samples = 16
			light.shadow_filter_radius = 0.020
			light.shadow_pcf_jitter = true
			light.shadow_temporal_jitter = true
			light.shadow_taa_enabled = true
			light.shadow_taa_mode = 2
		}
		if sc != nil {
			sc.time_slice_mode = 0
			sc.res_index = 2
		}

	case .Balanced:
		if vr != nil {
			vr.params.step_count = 16
			vr.params.resolution_divider = 2
			vr.params.upsample_mode = 2
			vr.params.upsample_sharpness = 250.0
			vr.params.blur_mode = 2
			vr.params.blur_sharpness = 400.0
			vr.params.jitter_enabled = true
			vr.params.taa_mode = 2
			vr.params.taa_alpha = 0.20
		}
		if light != nil {
			light.shadow_pcf_samples = 8
			light.shadow_filter_radius = 0.015
			light.shadow_pcf_jitter = true
			light.shadow_temporal_jitter = true
			light.shadow_taa_enabled = true
			light.shadow_taa_mode = 2
		}
		if sc != nil {
			sc.time_slice_mode = 1
			sc.res_index = 2
		}

	case .Ultra_Performance:
		if vr != nil {
			vr.params.step_count = 8
			vr.params.resolution_divider = 4
			vr.params.upsample_mode = 1
			vr.params.upsample_sharpness = 100.0
			vr.params.blur_mode = 0
			vr.params.jitter_enabled = true
			vr.params.taa_mode = 1
			vr.params.taa_alpha = 0.15
		}
		if light != nil {
			light.shadow_pcf_samples = 4
			light.shadow_filter_radius = 0.010
			light.shadow_pcf_jitter = false
			light.shadow_temporal_jitter = false
			light.shadow_taa_enabled = false
			light.shadow_taa_mode = 0
		}
		if sc != nil {
			sc.time_slice_mode = 2
			sc.res_index = 1
		}

	case .Custom:
		// User custom configuration
	}
}

// Logs the active optimization profile and its technical subsystem parameters
optimization_profile_log :: proc(profile: Optimization_Profile, vr: ^Volumetric_Renderer, light: ^Point_Light, sc: ^Shadow_Cubemap) {
	prof_name := optimization_profile_name(profile)
	log.log_info("suckless-odin.opt", "Active Optimization Profile: %s", prof_name)

	if vr != nil {
		blur_str := "Off"
		switch vr.params.blur_mode {
		case 1: blur_str = "Gaussian 3x3"
		case 2: blur_str = "Bilateral 5x5"
		}
		upsample_str := "Bilinear"
		switch vr.params.upsample_mode {
		case 1: upsample_str = "Nearest-Depth"
		case 2: upsample_str = "Joint Bilateral (JBU 2x2)"
		}
		log.log_info("suckless-odin.opt", "  * [Volumetric] Steps: %d, Downscale: 1/%d, Upsample: %s, Blur: %s, TAA Mode: %d (alpha=%.2f)",
			vr.params.step_count, vr.params.resolution_divider, upsample_str, blur_str, vr.params.taa_mode, vr.params.taa_alpha)
	}

	if light != nil {
		log.log_info("suckless-odin.opt", "  * [Shadows] PCF Samples: %d, Filter Radius: %.3f, Shadow TAA: %v (mode=%d, alpha=%.2f)",
			light.shadow_pcf_samples, light.shadow_filter_radius, light.shadow_taa_enabled, light.shadow_taa_mode, light.shadow_taa_alpha)
	}

	if sc != nil {
		slice_str := "Full (6 faces/frame)"
		switch sc.time_slice_mode {
		case 1: slice_str = "Time-Slicing (2 faces/frame)"
		case 2: slice_str = "Time-Slicing (1 face/frame)"
		}
		log.log_info("suckless-odin.opt", "  * [Shadow Cubemap] Resolution: %dx%d, Update: %s",
			sc.resolution, sc.resolution, slice_str)
	}
}
