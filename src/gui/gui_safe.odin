package gui

import imgui "../../deps/odin-imgui"
import "core:fmt"

// ─── Safe Odin Wrappers for Dear ImGui Text & Tooltip Operations ──────────────
// Prevents C-variadic vsnprintf format string vulnerabilities by enforcing
// explicit "%s" formatting and cstring conversion via context.temp_allocator.

// Display unformatted text safely (avoids printf parsing of '%' characters)
gui_text :: proc(text: string) {
	imgui.TextUnformatted(fmt.ctprintf("%s", text))
}

// Display tooltip on currently hovered item safely
gui_tooltip :: proc(text: string) {
	if imgui.IsItemHovered() {
		imgui.SetTooltip("%s", fmt.ctprintf("%s", text))
	}
}

// Display colored text safely
gui_text_colored :: proc(col: imgui.Vec4, text: string) {
	imgui.TextColored(col, "%s", fmt.ctprintf("%s", text))
}

// Display disabled / muted text safely
gui_text_disabled :: proc(text: string) {
	imgui.TextDisabled("%s", fmt.ctprintf("%s", text))
}

// Display wrapped text safely
gui_text_wrapped :: proc(text: string) {
	imgui.TextWrapped("%s", fmt.ctprintf("%s", text))
}

// Standardized "(?)" help marker with safe tooltip
gui_help_marker :: proc(desc: string) {
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("%s", fmt.ctprintf("%s", desc))
	}
}
