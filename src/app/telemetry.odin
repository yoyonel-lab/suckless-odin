package app

import "core:fmt"
import "core:os"
import log "../core/log"

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
		log.log_error("app", "Failed to save startup telemetry: %v", write_err)
	} else {
		log.log_info("app", "Saved startup telemetry to /tmp/startup_telemetry.csv")
	}
}
