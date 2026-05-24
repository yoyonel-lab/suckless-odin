package perf_mode

import "core:dynlib"
import "core:os"
import "core:sys/linux"

import log "../log"

// Backend used for performance mode — ordered by preference.
Backend :: enum {
	None,
	Game_Mode,  // Feral GameMode (D-Bus → gamemoded)
	Sched_FIFO, // SCHED_FIFO real-time scheduling
	Nice,       // setpriority(-10)
}

// Runtime state for the performance mode subsystem.
Perf_Mode :: struct {
	active:            bool,
	backend:           Backend,
	gamemode_lib:      dynlib.Library,
	gamemode_start:    proc "c" () -> i32,
	gamemode_end:      proc "c" () -> i32,
	gamemode_status:   proc "c" () -> i32,
	original_nice:     i32,
	original_policy:   i32,
	mesa_needs_restart: bool,
	memory_locked:     bool,
}

// Initializes the performance mode subsystem (probes available backends).
// Does NOT activate — call activate() to turn on.
init :: proc(pm: ^Perf_Mode) {
	pm^ = {}
	probe_gamemode(pm)
}

// Activates the best available backend.
// When `quiet` is true, suppresses INFO logs (used for session restore).
// Returns true if successfully activated.
activate :: proc(pm: ^Perf_Mode, quiet := false) -> bool {
	if pm.active { return true }

	// Try backends in order of preference
	if try_gamemode(pm) {
		pm.backend = .Game_Mode
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (GameMode)") }
	} else if try_sched_fifo(pm) {
		pm.backend = .Sched_FIFO
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (SCHED_FIFO)") }
	} else if try_nice(pm) {
		pm.backend = .Nice
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (nice -10)") }
	} else {
		log.log_warning("PERF", "Performance mode: no scheduling backend available")
	}

	// Lock memory (prevents page-fault stutters)
	if !pm.memory_locked {
		// MCL_CURRENT=1, MCL_FUTURE=2 → 3
		errno := linux.mlockall(transmute(linux.MLock_Flags)u32(3))
		if errno == .NONE {
			pm.memory_locked = true
			if !quiet { log.log_info("PERF", "Memory locked (mlockall)") }
		} else if !quiet {
			log.log_debug("PERF", "mlockall failed (errno %v) — needs CAP_IPC_LOCK", errno)
		}
	}

	// Set Mesa env vars (take effect on next GL context creation = restart)
	set_mesa_env(pm, quiet)

	if !pm.active && !pm.memory_locked {
		return false
	}
	pm.active = true
	return true
}

// Deactivates performance mode, restoring previous state.
deactivate :: proc(pm: ^Perf_Mode) {
	if !pm.active { return }

	switch pm.backend {
	case .Game_Mode:
		if pm.gamemode_end != nil {
			pm.gamemode_end()
		}
	case .Sched_FIFO:
		// Restore original scheduling policy (OTHER with priority 0)
		param := linux.Sched_Param{sched_priority = 0}
		linux.sched_setscheduler(linux.Pid(0), pm.original_policy, &param)
	case .Nice:
		linux.setpriority(.PROCESS, 0, pm.original_nice)
	case .None:
		// Nothing to do
	}

	// Unlock memory
	if pm.memory_locked {
		linux.munlockall()
		pm.memory_locked = false
	}

	log.log_info("PERF", "Performance mode OFF")
	pm.active = false
	pm.backend = .None
}

// Toggles performance mode on/off. Returns new active state.
toggle :: proc(pm: ^Perf_Mode) -> bool {
	if pm.active {
		deactivate(pm)
	} else {
		activate(pm)
	}
	return pm.active
}

// Cleans up resources (unloads gamemode library).
cleanup :: proc(pm: ^Perf_Mode) {
	if pm.active {
		deactivate(pm)
	}
	if pm.gamemode_lib != nil {
		dynlib.unload_library(pm.gamemode_lib)
		pm.gamemode_lib = nil
	}
}

// Returns a human-readable label for the current backend.
backend_label :: proc(pm: ^Perf_Mode) -> string {
	if !pm.active { return "OFF" }
	switch pm.backend {
	case .Game_Mode:  return "GameMode"
	case .Sched_FIFO: return "SCHED_FIFO"
	case .Nice:       return "Nice (-10)"
	case .None:       return "OFF"
	}
	return "OFF"
}

// --- Private helpers ---

@(private)
probe_gamemode :: proc(pm: ^Perf_Mode) {
	lib, ok := dynlib.load_library("libgamemode.so.0")
	if !ok {
		log.log_debug("PERF", "GameMode not available: %s", dynlib.last_error())
		return
	}
	pm.gamemode_lib = lib

	start_ptr, s_ok := dynlib.symbol_address(lib, "real_gamemode_request_start")
	end_ptr, e_ok   := dynlib.symbol_address(lib, "real_gamemode_request_end")
	status_ptr, q_ok := dynlib.symbol_address(lib, "real_gamemode_query_status")

	if !s_ok || !e_ok || !q_ok {
		log.log_debug("PERF", "GameMode: missing symbols")
		dynlib.unload_library(lib)
		pm.gamemode_lib = nil
		return
	}

	pm.gamemode_start  = cast(proc "c" () -> i32)start_ptr
	pm.gamemode_end    = cast(proc "c" () -> i32)end_ptr
	pm.gamemode_status = cast(proc "c" () -> i32)status_ptr
	log.log_debug("PERF", "GameMode probed successfully")
}

@(private)
try_gamemode :: proc(pm: ^Perf_Mode) -> bool {
	if pm.gamemode_start == nil { return false }
	ret := pm.gamemode_start()
	return ret == 0
}

@(private)
try_sched_fifo :: proc(pm: ^Perf_Mode) -> bool {
	// Save current policy
	pm.original_policy = 0  // SCHED_OTHER

	param := linux.Sched_Param{sched_priority = 50}
	errno := linux.sched_setscheduler(linux.Pid(0), 1, &param)  // 1 = SCHED_FIFO
	if errno != .NONE {
		log.log_debug("PERF", "SCHED_FIFO failed (errno %v) — need CAP_SYS_NICE or root", errno)
		return false
	}
	return true
}

@(private)
try_nice :: proc(pm: ^Perf_Mode) -> bool {
	// Save current nice value
	current, get_err := linux.getpriority(.PROCESS, 0)
	if get_err != .NONE {
		pm.original_nice = 0
	} else {
		pm.original_nice = current
	}

	set_err := linux.setpriority(.PROCESS, 0, -10)
	if set_err != .NONE {
		log.log_debug("PERF", "nice(-10) failed (errno %v)", set_err)
		return false
	}
	return true
}

@(private)
mesa_env_already_set :: proc() -> bool {
	buf1: [8]u8
	buf2: [8]u8
	v1 := os.get_env_buf(buf1[:], "MESA_NO_ERROR")
	v2 := os.get_env_buf(buf2[:], "mesa_glthread")
	return v1 == "1" && v2 == "true"
}

@(private)
set_mesa_env :: proc(pm: ^Perf_Mode, quiet: bool) {
	// These env vars are read by Mesa at context creation time.
	// Setting them mid-session only takes effect on restart.
	// Skip if already set (e.g. setup_mesa_early called before context creation).
	if mesa_env_already_set() {
		return
	}
	err1 := os.set_env("MESA_NO_ERROR", "1")
	err2 := os.set_env("mesa_glthread", "true")
	if err1 == nil && err2 == nil {
		pm.mesa_needs_restart = true
		if !quiet {
			log.log_info("PERF", "Mesa env vars set (MESA_NO_ERROR=1, mesa_glthread=true) — restart needed")
		}
	}
}

// Call BEFORE GL context creation to apply Mesa optimizations immediately.
// Should be called from app init if session persists perf_mode as active.
setup_mesa_early :: proc() {
	os.set_env("MESA_NO_ERROR", "1")
	os.set_env("mesa_glthread", "true")
	log.log_info("PERF", "Mesa optimizations active (pre-context)")
}
