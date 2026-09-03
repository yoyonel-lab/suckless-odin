package rendering

Volumetric_Preset :: enum {
	Default,
	Isotropic,
	Morning_Fog,
	God_Rays,
	Alan_Wake_Torch,
	Car_Headlights,
	Dense_Dust,
}

volumetric_preset_name :: proc(preset: Volumetric_Preset) -> string {
	switch preset {
	case .Default:         return "Default (Balanced Standard)"
	case .Isotropic:       return "Isotropic Gas (g=0.0)"
	case .Morning_Fog:     return "Morning Fog (Soft Ambient)"
	case .God_Rays:        return "God Rays (Dramatic Sunbeams)"
	case .Alan_Wake_Torch: return "Torch / Searchlight (g=0.80)"
	case .Car_Headlights:  return "Car Headlights (g=0.88)"
	case .Dense_Dust:      return "Dense Dust / Sand (g=0.35)"
	}
	return "Unknown"
}

// Applies a physically-inspired atmosphere preset to volumetric and light parameters
volumetric_preset_apply :: proc(vr: ^Volumetric_Renderer, light: ^Point_Light, preset: Volumetric_Preset) {
	if vr == nil do return

	switch preset {
	case .Default:
		vr.params.enabled = true
		vr.params.step_count = 16
		vr.params.scattering_coeff = 0.025
		vr.params.extinction_coeff = 0.050
		vr.params.intensity_mult = 1.0
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.20
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 500.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 200.0
		volumetric_set_anisotropy(vr, light, 0.55)
		if light != nil {
			light.intensity = 1.0
		}

	case .Isotropic:
		vr.params.enabled = true
		vr.params.step_count = 16
		vr.params.scattering_coeff = 0.040
		vr.params.extinction_coeff = 0.040
		vr.params.intensity_mult = 1.2
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.20
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 300.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 150.0
		volumetric_set_anisotropy(vr, light, 0.00)

	case .Morning_Fog:
		vr.params.enabled = true
		vr.params.step_count = 20
		vr.params.scattering_coeff = 0.060
		vr.params.extinction_coeff = 0.080
		vr.params.intensity_mult = 1.5
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.15
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 200.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 200.0
		volumetric_set_anisotropy(vr, light, 0.55)

	case .God_Rays:
		vr.params.enabled = true
		vr.params.step_count = 32
		vr.params.scattering_coeff = 0.035
		vr.params.extinction_coeff = 0.050
		vr.params.intensity_mult = 2.0
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.25
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 600.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 300.0
		volumetric_set_anisotropy(vr, light, 0.75)
		if light != nil {
			light.intensity = 2.0
		}

	case .Alan_Wake_Torch:
		vr.params.enabled = true
		vr.params.step_count = 24
		vr.params.scattering_coeff = 0.050
		vr.params.extinction_coeff = 0.070
		vr.params.intensity_mult = 2.5
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.20
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 500.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 250.0
		volumetric_set_anisotropy(vr, light, 0.80)
		if light != nil {
			light.intensity = 2.5
		}

	case .Car_Headlights:
		vr.params.enabled = true
		vr.params.step_count = 32
		vr.params.scattering_coeff = 0.060
		vr.params.extinction_coeff = 0.090
		vr.params.intensity_mult = 3.0
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.20
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 500.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 300.0
		volumetric_set_anisotropy(vr, light, 0.88)
		if light != nil {
			light.intensity = 3.0
		}

	case .Dense_Dust:
		vr.params.enabled = true
		vr.params.step_count = 20
		vr.params.scattering_coeff = 0.080
		vr.params.extinction_coeff = 0.120
		vr.params.intensity_mult = 1.8
		vr.params.shadows_enabled = true
		vr.params.jitter_enabled = true
		vr.params.taa_mode = 2
		vr.params.taa_alpha = 0.20
		vr.params.blur_mode = 2
		vr.params.blur_sharpness = 400.0
		vr.params.upsample_mode = 2
		vr.params.upsample_sharpness = 200.0
		volumetric_set_anisotropy(vr, light, 0.35)
	}

	vr.history_valid = false // Force clean reset for new atmosphere
}
