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

import "base:runtime"
import "core:strings"
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
	{"Scene_Render", tracy.COLOR_GPU_PASS},
	{"Instanced_PBR_Spheres", tracy.COLOR_GPU_GEOMETRY},
	{"Swap_Buffers", tracy.COLOR_CPU_PRESENT},
	{"Skybox_Pass", tracy.COLOR_GPU_SKYBOX},
	{"PostProcess_Uber", tracy.COLOR_GPU_POSTFX},
	{"PostFX_Bloom", tracy.COLOR_GPU_POSTFX},
	{"PostFX_DepthOfField", tracy.COLOR_GPU_POSTFX},
	{"PostFX_AutoExposure", tracy.COLOR_GPU_POSTFX},
	{"PostFX_FXAA_Prepass", tracy.COLOR_GPU_POSTFX},
	{"PostFX_MotionBlur_Compute", tracy.COLOR_GPU_POSTFX},
	{"Text_Overlay", tracy.COLOR_GPU_OVERLAY},
	{"GUI_ImGui", tracy.COLOR_CPU_GUI},
	{"IBL: BRDF_LUT_Slice", tracy.COLOR_IBL_BRDF},
	{"IBL: Luminance_Reduction", tracy.COLOR_IBL_LUMINANCE},
	{"IBL: Specular_Init", tracy.COLOR_IBL_SPECULAR},
	{"IBL: Specular_Mip_Slice", tracy.COLOR_IBL_SPECULAR},
	{"IBL: Irradiance_Slice", tracy.COLOR_IBL_IRRADIANCE},
	{"IBL: Finalize", tracy.COLOR_SYNC_WAIT},
	{"Env_Manager: Render_Overlay", tracy.COLOR_GPU_OVERLAY},
	{"Env_Manager: Capture_Snapshot", tracy.COLOR_GPU_SKYBOX},
}

DEFAULT_ZONE_COLOR :: u32(tracy.COLOR_CPU_UPDATE)

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
	loc:    tracy.Source_Location_Data,
}

@(private)
g_cache: [256]Source_Loc_Cache_Entry
@(private)
g_cache_count: int = 0

// Returns a pointer to a stable Source_Location_Data in the cache.
// Static source locations enable Tracy zone aggregation in statistics.
@(private)
get_or_create_srcloc :: proc(name: cstring, loc: runtime.Source_Code_Location) -> ^tracy.Source_Location_Data {
	name_str := string(name)
	for i in 0 ..< g_cache_count {
		if g_cache[i].name == name_str {
			return &g_cache[i].loc
		}
	}

	if g_cache_count < len(g_cache) {
		color := zone_color_for_name(name_str)
		allocator := runtime.default_allocator()
		file_cstr := strings.clone_to_cstring(loc.file_path, allocator)
		proc_cstr := strings.clone_to_cstring(loc.procedure, allocator)

		g_cache[g_cache_count] = Source_Loc_Cache_Entry{
			name = name_str,
			loc  = tracy.Source_Location_Data{
				name     = name,
				function = proc_cstr,
				file     = file_cstr,
				line     = u32(loc.line),
				color    = color,
			},
		}
		entry := &g_cache[g_cache_count]
		g_cache_count += 1
		return &entry.loc
	}
	return nil
}

// Push a named debug group (visible in RenderDoc and Tracy).
push_group :: proc(name: cstring, loc := #caller_location) {
	gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, name)

	when tracy.TRACY_ENABLE {
		loc_data := get_or_create_srcloc(name, loc)
		cpu_zone := tracy.zone_begin(loc_data)
		color := zone_color_for_name(string(name))
		gpu_ctx := tracy.gpu_zone_begin(name, loc_data.function, loc_data.file, loc_data.line, color)

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
push_gpu_zone_only :: proc(name: cstring, loc := #caller_location) {
	when tracy.TRACY_ENABLE {
		loc_data := get_or_create_srcloc(name, loc)
		cpu_zone := tracy.zone_begin(loc_data)
		color := zone_color_for_name(string(name))
		gpu_ctx := tracy.gpu_zone_begin(name, loc_data.function, loc_data.file, loc_data.line, color)

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
	when ODIN_DEBUG {
		gl.ObjectLabel(identifier, handle, -1, label)
	}
}
