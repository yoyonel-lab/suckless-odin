package tracy

import "core:sync"

// Virtual Fiber Tracks for Tracy Profiler: "Async Status" and "Hybrid Perf"
// (ISO parity with suckless-vulkan & suckless-ogl)

@(private="file")
g_async_status_mutex: sync.Mutex
@(private="file")
g_active_async_ctx: Zone_Context

@(private="file")
SRCLOC_ASYNC_IDLE    := Source_Location_Data{name = "Async IDLE", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_IDLE}
@(private="file")
SRCLOC_ASYNC_PENDING := Source_Location_Data{name = "Async PENDING", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_PENDING}
@(private="file")
SRCLOC_ASYNC_LOADING := Source_Location_Data{name = "Async LOADING", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_DECODE}
@(private="file")
SRCLOC_ASYNC_CONVERT := Source_Location_Data{name = "Async CONVERT", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_CONVERT}
@(private="file")
SRCLOC_ASYNC_READY   := Source_Location_Data{name = "Async READY", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_READY}
@(private="file")
SRCLOC_ASYNC_FAILED  := Source_Location_Data{name = "Async FAILED", function = "async_status_transition", file = #file, line = #line, color = COLOR_IO_FAILED}

// Pre-defined Hybrid Perf source locations
SRCLOC_HYBRID_LUMINANCE  := Source_Location_Data{name = "Host (CPU): Luminance", function = "hybrid_perf", file = #file, line = #line, color = COLOR_IBL_LUMINANCE}
SRCLOC_HYBRID_BRDF       := Source_Location_Data{name = "Host (CPU): BRDF LUT", function = "hybrid_perf", file = #file, line = #line, color = COLOR_IBL_BRDF}
SRCLOC_HYBRID_SPECULAR   := Source_Location_Data{name = "Host (CPU): Specular", function = "hybrid_perf", file = #file, line = #line, color = COLOR_IBL_SPECULAR}
SRCLOC_HYBRID_IRRADIANCE := Source_Location_Data{name = "Host (CPU): Irradiance", function = "hybrid_perf", file = #file, line = #line, color = COLOR_IBL_IRRADIANCE}
SRCLOC_HYBRID_SYNC       := Source_Location_Data{name = "Sync (GPU Wait)", function = "hybrid_perf", file = #file, line = #line, color = COLOR_SYNC_WAIT}

Async_Status_State :: enum {
	Idle,
	Pending,
	Loading,
	Convert,
	Ready,
	Failed,
}

async_status_init :: proc() {
	when TRACY_ENABLE {
		async_status_transition(.Idle)
	}
}

async_status_transition :: proc(state: Async_Status_State) {
	when TRACY_ENABLE {
		sync.mutex_lock(&g_async_status_mutex)
		defer sync.mutex_unlock(&g_async_status_mutex)

		fiber_enter("Async Status")

		if g_active_async_ctx.id != 0 {
			___tracy_emit_zone_end(g_active_async_ctx)
			g_active_async_ctx.id = 0
		}

		srcloc: ^Source_Location_Data
		switch state {
		case .Idle:    srcloc = &SRCLOC_ASYNC_IDLE
		case .Pending: srcloc = &SRCLOC_ASYNC_PENDING
		case .Loading: srcloc = &SRCLOC_ASYNC_LOADING
		case .Convert: srcloc = &SRCLOC_ASYNC_CONVERT
		case .Ready:   srcloc = &SRCLOC_ASYNC_READY
		case .Failed:  srcloc = &SRCLOC_ASYNC_FAILED
		}

		if srcloc != nil {
			g_active_async_ctx = ___tracy_emit_zone_begin(srcloc, 1)
		}

		fiber_leave()
	}
}

async_status_shutdown :: proc() {
	when TRACY_ENABLE {
		sync.mutex_lock(&g_async_status_mutex)
		defer sync.mutex_unlock(&g_async_status_mutex)

		if g_active_async_ctx.id != 0 {
			fiber_enter("Async Status")
			___tracy_emit_zone_end(g_active_async_ctx)
			g_active_async_ctx.id = 0
			fiber_leave()
		}
	}
}

// "Hybrid Perf" virtual fiber track scopes for Host preparation vs GPU Sync Wait
hybrid_perf_zone_begin :: #force_inline proc(loc: ^Source_Location_Data) -> Zone {
	when TRACY_ENABLE {
		fiber_enter("Hybrid Perf")
		return Zone{___tracy_emit_zone_begin(loc, 1)}
	} else {
		return {}
	}
}

hybrid_perf_zone_end :: #force_inline proc(zone: Zone) {
	when TRACY_ENABLE {
		___tracy_emit_zone_end(zone.ctx)
		fiber_leave()
	}
}
