package app

import "vendor:glfw"
import session "../core/session"
import postfx "../rendering/postfx"
import rendering "../rendering"
import cam "../camera"
import types "../rendering/types"

// Extract current app state into a Session_State struct
extract_session_state :: proc(application: ^App) -> session.Session_State {
	s := &application.scene
	p := &s.postfx_pipeline
	
	pfx_settings := postfx.Settings_File{
		name          = "session_autosave",
		effects       = transmute(u32)p.active_effects,
		vignette      = p.vignette,
		grain         = p.grain,
		exposure      = p.exposure,
		chrom_abbr    = p.chrom_abbr,
		white_balance = p.white_balance,
		color_grading = p.color_grading,
		tonemapper    = p.tonemapper,
		bloom         = p.bloom,
		fxaa          = p.fxaa,
		dof           = p.dof,
		banding       = p.banding,
		fog           = p.fog,
		motion_blur   = p.motion_blur,
		lut3d         = p.lut3d,
		debug_split     = transmute(u32)p.debug_split,
		split_positions = postfx.split_positions_to_array(p),
	}

	// Update window saved position if not fullscreen
	if !application.is_fullscreen {
		application.saved_x, application.saved_y = glfw.GetWindowPos(application.window)
		application.saved_width, application.saved_height = glfw.GetWindowSize(application.window)
	}

	return session.Session_State{
		window_pos        = {application.saved_x, application.saved_y},
		window_size       = {application.saved_width, application.saved_height},
		camera_pos        = s.camera.position,
		camera_yaw        = s.camera.yaw,
		camera_pitch      = s.camera.pitch,
		camera_zoom       = s.camera.zoom,
		exposure          = s.exposure,
		wireframe_enabled = s.wireframe_enabled,
		skybox_visible    = s.skybox_visible,
		skybox_blur_lod   = s.skybox.blur_lod,
		skybox_mode       = i32(s.skybox.mode),
		mipmap_mode       = i32(s.skybox.mipmap_mode),
		blur_source       = i32(s.skybox.blur_source),
		show_blur_diff    = s.skybox.show_diff,
		diff_gain         = s.skybox.diff_gain,
		sort_mode         = i32(s.sort_mode),
		edge_aa_enabled   = s.edge_aa_enabled,
		edge_aa_debug     = s.edge_aa_debug,
		postfx_active     = p.enabled,
		postfx_settings   = pfx_settings,
		gui_visible       = application.imgui.visible,
		gui_active_tab    = application.imgui.active_tab,
		ibl_debug_open    = application.imgui.ibl_debug_open,
		ibl_debug_exposure = application.imgui.ibl_debug_exposure,
		is_fullscreen     = application.is_fullscreen,
		overlay_mode      = i32(s.overlay.mode),
		camera_enabled    = application.camera_enabled,
		perf_mode_active  = application.perf.active,
		specular_aa       = session.Specular_AA_Settings{
			enabled        = s.specular_aa_enabled,
			mode           = i32(s.specular_aa_mode),
			debug_mode     = i32(s.specular_aa_debug_mode),
			split_enabled  = s.specular_aa_split_enabled,
			split_position = s.specular_aa_split_position,
		},
		volumetric        = session.Volumetric_Session_Settings{
			enabled                = s.volumetric.params.enabled,
			composite_in_scene     = s.volumetric.params.composite_in_scene,
			isolate_in_scene       = s.volumetric.params.isolate_in_scene,
			shadows_enabled        = s.volumetric.params.shadows_enabled,
			step_count             = s.volumetric.params.step_count,
			scattering_coeff       = s.volumetric.params.scattering_coeff,
			extinction_coeff       = s.volumetric.params.extinction_coeff,
			anisotropy_g           = s.volumetric.params.anisotropy_g,
			intensity_mult         = s.volumetric.params.intensity_mult,
			jitter_enabled         = s.volumetric.params.jitter_enabled,
			taa_mode               = s.volumetric.params.taa_mode,
			taa_alpha              = s.volumetric.params.taa_alpha,
			taa_depth_threshold    = s.volumetric.params.taa_depth_threshold,
			taa_clamping_enabled   = s.volumetric.params.taa_clamping_enabled,
			blur_mode              = s.volumetric.params.blur_mode,
			blur_sharpness         = s.volumetric.params.blur_sharpness,
			viewport_debug_mode    = s.volumetric.params.viewport_debug_mode,
			upsample_mode          = s.volumetric.params.upsample_mode,
			upsample_sharpness     = s.volumetric.params.upsample_sharpness,
			resolution_divider     = s.volumetric.params.resolution_divider,
			shadow_cache           = s.shadow_cubemap.shadow_cache,
			time_slice_mode        = s.shadow_cubemap.time_slice_mode,
			shadow_res_index       = s.shadow_cubemap.res_index,
			preview_mode           = s.volumetric.params.preview_mode,
			preview_exposure_boost = s.volumetric.params.preview_exposure_boost,
		},
		point_light       = session.Point_Light_Session_Settings{
			position               = s.point_light.position,
			radius                 = s.point_light.radius,
			color                  = s.point_light.color,
			intensity              = s.point_light.intensity,
			enabled                = s.point_light.enabled,
			direct_shadows_enabled = s.point_light.direct_shadows_enabled,
			shadow_bias            = s.point_light.shadow_bias,
			shadow_normal_bias     = s.point_light.shadow_normal_bias,
			shadow_slope_bias      = s.point_light.shadow_slope_bias,
			shadow_darkening       = s.point_light.shadow_darkening,
			shadow_debug_mask      = s.point_light.shadow_debug_mask,
			shadow_debug_mode      = s.point_light.shadow_debug_mode,
			shadow_split_position  = s.point_light.shadow_split_position,
			shadow_pcf_samples     = s.point_light.shadow_pcf_samples,
			shadow_filter_radius   = s.point_light.shadow_filter_radius,
			shadow_pcf_jitter      = s.point_light.shadow_pcf_jitter,
			phase_g                = s.point_light.phase_g,
			is_animated            = s.point_light.is_animated,
			orbit_speed            = s.point_light.orbit_speed,
			orbit_radius           = s.point_light.orbit_radius,
			orbit_center           = s.point_light.orbit_center,
			show_bulb              = s.point_light.show_bulb,
			bulb_radius            = s.point_light.bulb_radius,
		},
	}
}

// Restore app state from a Session_State struct
restore_session_state :: proc(application: ^App, state: session.Session_State) {
	s := &application.scene
	
	s.camera.position = state.camera_pos
	s.camera.yaw      = state.camera_yaw
	s.camera.pitch    = state.camera_pitch
	s.camera.yaw_target   = state.camera_yaw
	s.camera.pitch_target = state.camera_pitch
	s.camera.zoom     = state.camera_zoom
	cam.update_vectors(&s.camera)
	
	s.exposure          = state.exposure
	s.wireframe_enabled = state.wireframe_enabled
	s.skybox_visible    = state.skybox_visible
	s.skybox.blur_lod   = state.skybox_blur_lod
	s.skybox.mode       = rendering.Skybox_Mode(state.skybox_mode)
	s.skybox.mipmap_mode = rendering.Mipmap_Mode(state.mipmap_mode)
	s.skybox.blur_source = rendering.Blur_Source(state.blur_source)
	s.skybox.show_diff   = state.show_blur_diff
	if state.diff_gain > 0 {
		s.skybox.diff_gain = state.diff_gain
	}
	s.sort_mode         = rendering.Sort_Mode(state.sort_mode)
	s.edge_aa_enabled   = state.edge_aa_enabled
	s.edge_aa_debug     = state.edge_aa_debug
	s.specular_aa_enabled        = state.specular_aa.enabled
	s.specular_aa_mode           = types.Specular_AA_Mode(state.specular_aa.mode)
	s.specular_aa_debug_mode     = types.Specular_AA_Debug_Mode(state.specular_aa.debug_mode)
	s.specular_aa_split_enabled  = state.specular_aa.split_enabled
	s.specular_aa_split_position = state.specular_aa.split_position if state.specular_aa.split_position > 0.0 else 0.5
	
	p := &s.postfx_pipeline
	p.enabled = state.postfx_active
	
	pfx := state.postfx_settings
	p.active_effects = transmute(postfx.Effect_Flags)pfx.effects
	p.debug_split    = transmute(postfx.Effect_Flags)pfx.debug_split
	postfx.split_positions_from_array(p, pfx.split_positions)
	p.vignette       = pfx.vignette
	p.grain          = pfx.grain
	p.exposure       = pfx.exposure
	p.chrom_abbr     = pfx.chrom_abbr
	p.white_balance  = pfx.white_balance
	p.color_grading  = pfx.color_grading
	p.tonemapper     = pfx.tonemapper
	p.bloom          = pfx.bloom
	p.fxaa           = pfx.fxaa
	p.dof            = pfx.dof
	p.banding        = pfx.banding
	p.fog            = pfx.fog
	p.motion_blur    = pfx.motion_blur
	p.lut3d          = pfx.lut3d
	p.ubo_dirty      = true
	
	application.imgui.visible = state.gui_visible
	application.imgui.active_tab = state.gui_active_tab
	application.imgui.restore_tab = 3
	application.imgui.ibl_debug_open = state.ibl_debug_open
	application.imgui.ibl_debug_exposure = state.ibl_debug_exposure
	
	s.overlay.mode = rendering.Overlay_Mode(state.overlay_mode)
	
	application.camera_enabled = state.camera_enabled
	if state.gui_visible {
		application.camera_enabled = false
	}
	
	if application.camera_enabled {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	} else {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
	
	if state.is_fullscreen {
		monitor := glfw.GetPrimaryMonitor()
		if monitor != nil {
			mode := glfw.GetVideoMode(monitor)
			glfw.SetWindowMonitor(application.window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
			application.is_fullscreen = true
		}
	}

	// Restore volumetric parameters (if valid saved state with step_count > 0)
	if state.volumetric.step_count > 0 {
		s.volumetric.params.enabled                = state.volumetric.enabled
		s.volumetric.params.composite_in_scene     = state.volumetric.composite_in_scene
		s.volumetric.params.isolate_in_scene       = state.volumetric.isolate_in_scene
		s.volumetric.params.shadows_enabled        = state.volumetric.shadows_enabled
		s.volumetric.params.step_count             = state.volumetric.step_count
		s.volumetric.params.scattering_coeff       = state.volumetric.scattering_coeff
		s.volumetric.params.extinction_coeff       = state.volumetric.extinction_coeff
		s.volumetric.params.anisotropy_g           = state.volumetric.anisotropy_g
		s.volumetric.params.intensity_mult         = state.volumetric.intensity_mult
		s.volumetric.params.jitter_enabled         = state.volumetric.jitter_enabled
		s.volumetric.params.taa_mode               = state.volumetric.taa_mode
		s.volumetric.params.taa_alpha              = state.volumetric.taa_alpha
		s.volumetric.params.taa_depth_threshold    = state.volumetric.taa_depth_threshold
		s.volumetric.params.taa_clamping_enabled   = state.volumetric.taa_clamping_enabled
		s.volumetric.params.blur_mode              = state.volumetric.blur_mode
		s.volumetric.params.blur_sharpness         = state.volumetric.blur_sharpness
		s.volumetric.params.viewport_debug_mode    = state.volumetric.viewport_debug_mode
		s.volumetric.params.upsample_mode          = state.volumetric.upsample_mode
		s.volumetric.params.upsample_sharpness     = state.volumetric.upsample_sharpness
		if state.volumetric.resolution_divider > 0 {
			s.volumetric.params.resolution_divider = state.volumetric.resolution_divider
		}
		s.volumetric.params.preview_mode           = state.volumetric.preview_mode
		s.volumetric.params.preview_exposure_boost = state.volumetric.preview_exposure_boost
		s.volumetric.history_valid                 = false

		// Restore shadow cubemap caching and resolution
		s.shadow_cubemap.shadow_cache = state.volumetric.shadow_cache
		s.shadow_cubemap.time_slice_mode = state.volumetric.time_slice_mode
		if state.volumetric.shadow_res_index >= 0 && state.volumetric.shadow_res_index < 4 {
			s.shadow_cubemap.res_index = state.volumetric.shadow_res_index
			res := rendering.shadow_cubemap_res_for_index(s.shadow_cubemap.res_index)
			if res != s.shadow_cubemap.resolution {
				rendering.shadow_cubemap_resize(&s.shadow_cubemap, res)
			}
		}
	}

	// Restore point light parameters (if valid saved radius > 0)
	if state.point_light.radius > 0 {
		s.point_light.position               = state.point_light.position
		s.point_light.radius                 = state.point_light.radius
		s.point_light.color                  = state.point_light.color
		s.point_light.intensity              = state.point_light.intensity
		s.point_light.enabled                = state.point_light.enabled
		s.point_light.direct_shadows_enabled = state.point_light.direct_shadows_enabled
		s.point_light.shadow_bias            = state.point_light.shadow_bias
		s.point_light.shadow_normal_bias     = state.point_light.shadow_normal_bias
		s.point_light.shadow_slope_bias      = state.point_light.shadow_slope_bias
		s.point_light.shadow_darkening       = state.point_light.shadow_darkening
		s.point_light.shadow_debug_mask      = state.point_light.shadow_debug_mask
		s.point_light.shadow_debug_mode      = state.point_light.shadow_debug_mode
		if state.point_light.shadow_split_position > 0.0 {
			s.point_light.shadow_split_position = state.point_light.shadow_split_position
		}
		if state.point_light.shadow_pcf_samples > 0 {
			s.point_light.shadow_pcf_samples = state.point_light.shadow_pcf_samples
		}
		if state.point_light.shadow_filter_radius > 0 {
			s.point_light.shadow_filter_radius = state.point_light.shadow_filter_radius
		}
		s.point_light.shadow_pcf_jitter      = state.point_light.shadow_pcf_jitter
		s.point_light.phase_g                = state.point_light.phase_g
		s.point_light.is_animated            = state.point_light.is_animated
		s.point_light.orbit_speed            = state.point_light.orbit_speed
		s.point_light.orbit_radius           = state.point_light.orbit_radius
		s.point_light.orbit_center           = state.point_light.orbit_center
		s.point_light.show_bulb              = state.point_light.show_bulb
		s.point_light.bulb_radius            = state.point_light.bulb_radius
		s.point_light.is_dirty               = true
	}
}
