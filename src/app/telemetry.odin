package app

import "core:fmt"
import "core:os"
import tracy "../core/tracy"
import log "../core/log"

@(private)
tracy_log_callback :: proc(level: log.Log_Level, tag: string, message: string) {
	color: u32 = 0xFFFFFF
	switch level {
	case .Critical:
		color = 0xFF0000
	case .Error:
		color = 0xFF5555
	case .Warning:
		color = 0xFFFF55
	case .Debug:
		color = 0xAAAAAA
	case .Info, .Not_Set:
		color = 0xFFFFFF
	}
	formatted := fmt.tprintf("[%s] %s", tag, message)
	tracy.message_c(formatted, color)
}

@(private)
write_startup_telemetry :: proc(app: ^App) {
	data := fmt.tprintf(
		"metric,value\n" +
		"init_time_ms,%.3f\n" +
		"frame_1_total_ms,%.3f\n" +
		"frame_1_poll_ms,%.3f\n" +
		"frame_1_update_ms,%.3f\n" +
		"frame_1_render_ms,%.3f\n" +
		"frame_1_swap_ms,%.3f\n" +
		"frame_2_total_ms,%.3f\n" +
		"frame_2_poll_ms,%.3f\n" +
		"frame_2_update_ms,%.3f\n" +
		"frame_2_render_ms,%.3f\n" +
		"frame_2_swap_ms,%.3f\n" +
		"frame_3_total_ms,%.3f\n" +
		"frame_3_poll_ms,%.3f\n" +
		"frame_3_update_ms,%.3f\n" +
		"frame_3_render_ms,%.3f\n" +
		"frame_3_swap_ms,%.3f\n" +
		"frame_4_total_ms,%.3f\n" +
		"frame_4_poll_ms,%.3f\n" +
		"frame_4_update_ms,%.3f\n" +
		"frame_4_render_ms,%.3f\n" +
		"frame_4_swap_ms,%.3f\n" +
		"frame_5_total_ms,%.3f\n" +
		"frame_5_poll_ms,%.3f\n" +
		"frame_5_update_ms,%.3f\n" +
		"frame_5_render_ms,%.3f\n" +
		"frame_5_swap_ms,%.3f\n",
		app.init_time_ms,
		app.frame_durations[0], app.frame_poll[0], app.frame_update[0], app.frame_render[0], app.frame_swap[0],
		app.frame_durations[1], app.frame_poll[1], app.frame_update[1], app.frame_render[1], app.frame_swap[1],
		app.frame_durations[2], app.frame_poll[2], app.frame_update[2], app.frame_render[2], app.frame_swap[2],
		app.frame_durations[3], app.frame_poll[3], app.frame_update[3], app.frame_render[3], app.frame_swap[3],
		app.frame_durations[4], app.frame_poll[4], app.frame_update[4], app.frame_render[4], app.frame_swap[4],
	)
	write_err := os.write_entire_file("/tmp/startup_telemetry.csv", transmute([]u8)data)
	if write_err != nil {
		log.log_error("suckless-odin.app", "Failed to save startup telemetry: %v", write_err)
	} else {
		log.log_info("suckless-odin.app", "Saved startup telemetry to /tmp/startup_telemetry.csv")
	}
}
