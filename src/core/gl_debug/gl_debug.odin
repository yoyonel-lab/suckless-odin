package gl_debug

// GL Debug Groups & Object Labels for RenderDoc / GPU profiler integration.
// ISO port of suckless-ogl/src/gl_debug.c — push/pop debug groups appear as
// hierarchical markers in RenderDoc's event browser.
//
// Calls are always emitted (no compile-time guard). Cost is negligible:
// - Without a debug context, the GL driver short-circuits these calls.
// - With RenderDoc attached, they produce the hierarchical event browser.
//
// Extended with native CPU/GPU Tracy integration:
// - Pushing a group automatically allocates a matching CPU Tracy zone and starts a GPU timer context.
// - Popping a group automatically ends both CPU and GPU stages.

import gl "vendor:OpenGL"
import tracy "../../core/tracy"

MAX_STACK_DEPTH :: 32

Active_Zone :: struct {
	cpu: tracy.Zone,
	gpu: rawptr,
}

@(private)
g_zone_stack: [MAX_STACK_DEPTH]Active_Zone
@(private)
g_stack_depth: int = 0

// Nord Theme color mappings for Tracy zone visualization.
Zone_Color :: struct {
	prefix: string,
	color:  u32,
}

ZONE_COLORS :: [?]Zone_Color{
	{"Scene_Render", 0xD08770},
	{"Instanced_PBR_Spheres", 0xD08770},
	{"Swap_Buffers", 0xD08770},
	{"Skybox_Pass", 0x88C0D0},
	{"PostFX_Bloom", 0x5E81AC},
	{"PostFX_DepthOfField", 0xA3BE8C},
	{"PostFX_AutoExposure", 0xEBCB8B},
	{"PostFX_FXAA_Prepass", 0xBF616A},
	{"PostFX_MotionBlur_Compute", 0xBF616A},
	{"Text_Overlay", 0x4C566A},
	{"GUI_ImGui", 0x4C566A},
}

DEFAULT_ZONE_COLOR :: u32(0x81A1C1) // Composite blue

@(private)
zone_color_for_name :: proc(name_str: string) -> u32 {
	for entry in ZONE_COLORS {
		if entry.prefix == name_str {
			return entry.color
		}
	}
	return DEFAULT_ZONE_COLOR
}

Source_Loc_Cache_Entry :: struct {
	name:   string,
	srcloc: u64,
}

@(private)
g_cache: [256]Source_Loc_Cache_Entry
@(private)
g_cache_count: int = 0

@(private)
get_or_create_srcloc :: proc(name: cstring) -> u64 {
	name_str := string(name)
	for i in 0 ..< g_cache_count {
		if g_cache[i].name == name_str {
			return g_cache[i].srcloc
		}
	}

	if g_cache_count < len(g_cache) {
		color := zone_color_for_name(name_str)
		srcloc := tracy.alloc_srcloc(0, "gl_debug.odin", name, color)

		g_cache[g_cache_count] = Source_Loc_Cache_Entry{
			name   = name_str,
			srcloc = srcloc,
		}
		g_cache_count += 1
		return srcloc
	}
	return 0
}

// Push a named debug group (visible in RenderDoc and Tracy).
push_group :: proc(name: cstring) {
	gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, name)

	when tracy.TRACY_ENABLE {
		srcloc := get_or_create_srcloc(name)
		cpu_zone := tracy.zone_begin_alloc(srcloc)
		color := zone_color_for_name(string(name))
		gpu_ctx := tracy.gpu_zone_begin(name, name, "gl_debug.odin", 0, color)

		if g_stack_depth < MAX_STACK_DEPTH {
			g_zone_stack[g_stack_depth] = Active_Zone{
				cpu = cpu_zone,
				gpu = gpu_ctx,
			}
			g_stack_depth += 1
		}
	}
}

// Pop the current debug group.
pop_group :: proc() {
	gl.PopDebugGroup()

	when tracy.TRACY_ENABLE {
		if g_stack_depth > 0 {
			g_stack_depth -= 1
			zone := g_zone_stack[g_stack_depth]
			tracy.zone_end(zone.cpu)
			tracy.gpu_zone_end(zone.gpu)
		}
	}
}

// Push a Tracy-only marker (CPU and GPU timestamps, no OpenGL Debug Group).
// Bypasses driver/MangoHud debug stack boundaries for cross-frame sync.
push_gpu_zone_only :: proc(name: cstring) {
	when tracy.TRACY_ENABLE {
		srcloc := get_or_create_srcloc(name)
		cpu_zone := tracy.zone_begin_alloc(srcloc)
		color := zone_color_for_name(string(name))
		gpu_ctx := tracy.gpu_zone_begin(name, name, "gl_debug.odin", 0, color)

		if g_stack_depth < MAX_STACK_DEPTH {
			g_zone_stack[g_stack_depth] = Active_Zone{
				cpu = cpu_zone,
				gpu = gpu_ctx,
			}
			g_stack_depth += 1
		}
	}
}

// Pop the current Tracy-only marker.
pop_gpu_zone_only :: proc() {
	when tracy.TRACY_ENABLE {
		if g_stack_depth > 0 {
			g_stack_depth -= 1
			zone := g_zone_stack[g_stack_depth]
			tracy.zone_end(zone.cpu)
			tracy.gpu_zone_end(zone.gpu)
		}
	}
}

// Label a GL object (texture, buffer, program, VAO, etc.) for RenderDoc.
object_label :: proc(identifier: u32, handle: u32, label: cstring) {
	gl.ObjectLabel(identifier, handle, -1, label)
}
