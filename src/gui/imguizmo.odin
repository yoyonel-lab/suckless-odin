package gui

import "core:c"

when ODIN_OS == .Windows {
	foreign import libguizmo "../../deps/libimguizmo_windows_x64.lib"
} else when ODIN_OS == .Linux {
	foreign import libguizmo "../../deps/libimguizmo.a"
}

Guizmo_Operation :: enum c.int {
	Translate_X = 1 << 0,
	Translate_Y = 1 << 1,
	Translate_Z = 1 << 2,
	Rotate_X    = 1 << 3,
	Rotate_Y    = 1 << 4,
	Rotate_Z    = 1 << 5,
	Rotate_Screen = 1 << 6,
	Scale_X     = 1 << 7,
	Scale_Y     = 1 << 8,
	Scale_Z     = 1 << 9,
	Bounds      = 1 << 10,
	Scale_XU    = 1 << 11,
	Scale_YU    = 1 << 12,
	Scale_ZU    = 1 << 13,

	Translate   = (1 << 0) | (1 << 1) | (1 << 2),
	Rotate      = (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6),
	Scale       = (1 << 7) | (1 << 8) | (1 << 9),
	ScaleU      = (1 << 11) | (1 << 12) | (1 << 13),
	Universal   = ((1 << 0) | (1 << 1) | (1 << 2)) | ((1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)) | ((1 << 11) | (1 << 12) | (1 << 13)),
}

Guizmo_Mode :: enum c.int {
	Local = 0,
	World = 1,
}

@(default_calling_convention = "c")
foreign libguizmo {
	@(link_name = "ImGuizmo_SetDrawlist")
	guizmo_set_drawlist :: proc(drawlist: rawptr = nil) ---

	@(link_name = "ImGuizmo_BeginFrame")
	guizmo_begin_frame :: proc() ---

	@(link_name = "ImGuizmo_SetImGuiContext")
	guizmo_set_imgui_context :: proc(ctx: rawptr) ---

	@(link_name = "ImGuizmo_IsOver")
	guizmo_is_over :: proc() -> bool ---

	@(link_name = "ImGuizmo_IsUsing")
	guizmo_is_using :: proc() -> bool ---

	@(link_name = "ImGuizmo_IsUsingAny")
	guizmo_is_using_any :: proc() -> bool ---

	@(link_name = "ImGuizmo_Enable")
	guizmo_enable :: proc(enable: bool) ---

	@(link_name = "ImGuizmo_DecomposeMatrixToComponents")
	guizmo_decompose_matrix :: proc(mat: [^]f32, translation: [^]f32, rotation: [^]f32, scale: [^]f32) ---

	@(link_name = "ImGuizmo_RecomposeMatrixFromComponents")
	guizmo_recompose_matrix :: proc(translation: [^]f32, rotation: [^]f32, scale: [^]f32, mat: [^]f32) ---

	@(link_name = "ImGuizmo_SetRect")
	guizmo_set_rect :: proc(x, y, width, height: f32) ---

	@(link_name = "ImGuizmo_SetOrthographic")
	guizmo_set_orthographic :: proc(is_ortho: bool) ---

	@(link_name = "ImGuizmo_DrawGrid")
	guizmo_draw_grid :: proc(view, proj, mat: [^]f32, grid_size: f32) ---

	@(link_name = "ImGuizmo_Manipulate")
	guizmo_manipulate :: proc(view, proj: [^]f32, op: Guizmo_Operation, mode: Guizmo_Mode, mat: [^]f32, delta_matrix: [^]f32 = nil, snap: [^]f32 = nil, local_bounds: [^]f32 = nil, bounds_snap: [^]f32 = nil) -> bool ---

	@(link_name = "ImGuizmo_ViewManipulate")
	guizmo_view_manipulate :: proc(view: [^]f32, length: f32, pos_x, pos_y, size_x, size_y: f32, bg_color: u32) ---

	@(link_name = "ImGuizmo_AllowAxisFlip")
	guizmo_allow_axis_flip :: proc(value: bool) ---

	@(link_name = "ImGuizmo_SetGizmoSizeClipSpace")
	guizmo_set_gizmo_size_clip_space :: proc(value: f32) ---
}
