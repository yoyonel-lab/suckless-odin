package tracy


TRACY_ENABLE :: #config(TRACY_ENABLE, false)

Source_Location_Data :: struct {
	name:     cstring,
	function: cstring,
	file:     cstring,
	line:     u32,
	color:    u32,
}

Zone_Context :: struct {
	id:     u32,
	active: i32,
}

Zone :: struct {
	ctx: Zone_Context,
}

when TRACY_ENABLE {
	foreign import libtracy "../../../deps/libtracy.a"

	@(default_calling_convention="c")
	foreign libtracy {
		___tracy_set_thread_name :: proc(name: cstring) ---
		___tracy_emit_zone_begin :: proc(srcloc: ^Source_Location_Data, active: i32) -> Zone_Context ---
		___tracy_emit_zone_begin_callstack :: proc(srcloc: ^Source_Location_Data, depth: i32, active: i32) -> Zone_Context ---
		___tracy_emit_zone_end :: proc(ctx: Zone_Context) ---
		___tracy_emit_zone_text :: proc(ctx: Zone_Context, txt: cstring, size: uint) ---
		___tracy_emit_zone_name :: proc(ctx: Zone_Context, txt: cstring, size: uint) ---
		___tracy_emit_zone_color :: proc(ctx: Zone_Context, color: u32) ---
		___tracy_emit_zone_value :: proc(ctx: Zone_Context, value: u64) ---
		___tracy_emit_frame_mark :: proc(name: cstring) ---
		___tracy_fiber_enter :: proc(fiber: cstring) ---
		___tracy_fiber_leave :: proc() ---

		___tracy_alloc_srcloc :: proc(line: u32, source: cstring, sourceSz: uint, function: cstring, functionSz: uint, color: u32) -> u64 ---
		___tracy_emit_zone_begin_alloc :: proc(srcloc: u64, active: i32) -> Zone_Context ---
		___tracy_emit_message :: proc(txt: cstring, size: uint, callstack_depth: i32) ---
		___tracy_emit_messageC :: proc(txt: cstring, size: uint, color: u32, callstack_depth: i32) ---

		// GPU Profiling functions from tracy_gpu.cpp
		tracy_gpu_init :: proc() ---
		tracy_gpu_shutdown :: proc() ---
		tracy_gpu_collect :: proc() ---
		tracy_gpu_screenshot :: proc(data: rawptr, w, h: u16) ---
		tracy_gpu_zone_begin :: proc(name, function, file: cstring, line, color: u32) -> rawptr ---
		tracy_gpu_zone_end :: proc(ctx: rawptr) ---
	}
}

set_thread_name :: #force_inline proc(name: cstring) {
	when TRACY_ENABLE {
		___tracy_set_thread_name(name)
	}
}

zone_begin :: #force_inline proc(loc: ^Source_Location_Data) -> Zone {
	when TRACY_ENABLE {
		return Zone{___tracy_emit_zone_begin(loc, 1)}
	} else {
		return {}
	}
}

zone_end :: #force_inline proc(zone: Zone) {
	when TRACY_ENABLE {
		___tracy_emit_zone_end(zone.ctx)
	}
}

frame_mark :: #force_inline proc(name: cstring = nil) {
	when TRACY_ENABLE {
		___tracy_emit_frame_mark(name)
	}
}

fiber_enter :: #force_inline proc(name: cstring) {
	when TRACY_ENABLE {
		___tracy_fiber_enter(name)
	}
}

fiber_leave :: #force_inline proc() {
	when TRACY_ENABLE {
		___tracy_fiber_leave()
	}
}

gpu_init :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_init()
	}
}

gpu_collect :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_collect()
	}
}

gpu_screenshot :: #force_inline proc(data: rawptr, w, h: u16) {
	when TRACY_ENABLE {
		tracy_gpu_screenshot(data, w, h)
	}
}

gpu_zone_begin :: #force_inline proc(name, function, file: cstring, line, color: u32) -> rawptr {
	when TRACY_ENABLE {
		return tracy_gpu_zone_begin(name, function, file, line, color)
	} else {
		return nil
	}
}

gpu_zone_end :: #force_inline proc(ctx: rawptr) {
	when TRACY_ENABLE {
		tracy_gpu_zone_end(ctx)
	}
}

gpu_shutdown :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_shutdown()
	}
}

alloc_srcloc :: #force_inline proc(line: u32, source, function: cstring, color: u32) -> u64 {
	when TRACY_ENABLE {
		return ___tracy_alloc_srcloc(line, source, uint(len(source)), function, uint(len(function)), color)
	} else {
		return 0
	}
}

zone_begin_alloc :: #force_inline proc(srcloc: u64) -> Zone {
	when TRACY_ENABLE {
		return Zone{___tracy_emit_zone_begin_alloc(srcloc, 1)}
	} else {
		return {}
	}
}

message :: #force_inline proc(msg: string) {
	when TRACY_ENABLE {
		___tracy_emit_message(cstring(raw_data(msg)), uint(len(msg)), 0)
	}
}

message_c :: #force_inline proc(msg: string, color: u32) {
	when TRACY_ENABLE {
		___tracy_emit_messageC(cstring(raw_data(msg)), uint(len(msg)), color, 0)
	}
}
