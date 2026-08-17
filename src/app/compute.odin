package app

import log "../core/log"
import settings "../core/settings"
import scene "../scene"
import rendering "../rendering"

apply_compute_tuning_callback :: proc(scene_ptr: rawptr, params: settings.Compute_Tuning_Params) -> bool {
	s := (^scene.Scene)(scene_ptr)
	if s == nil { return false }

	// 1. Recompile IBL shaders
	if !rendering.ibl_recompile_shaders(&s.ibl, params) {
		log.log_error("suckless-odin.app", "Failed to recompile IBL compute shaders with new parameters")
		return false
	}

	// 2. Propagate new parameters to all subsystems
	s.env_mgr.compute_tuning = params
	s.skybox.compute_tuning = params

	// 3. Trigger recalculation of the current active environment
	if len(s.hdr_files) > 0 && s.current_hdr_index >= 0 && s.current_hdr_index < i32(len(s.hdr_files)) {
		current_path := s.hdr_files[s.current_hdr_index]
		scene.env_manager_trigger_transition(&s.env_mgr, current_path)
	} else {
		scene.env_manager_trigger_transition(&s.env_mgr, scene.HDR_PATH)
	}

	log.log_info("suckless-odin.app", "Applied new compute tuning parameters and triggered IBL recalculation")
	return true
}
