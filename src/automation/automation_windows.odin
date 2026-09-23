#+build windows
package automation

Command_Type :: enum {
	Unknown,
	Await_Init,
	Load_Env,
	Quit,
}

Automation_Command :: struct {
	type: Command_Type,
	arg:  string,
}

init :: proc(socket_path: string) -> bool {
	_ = socket_path
	return true
}

shutdown :: proc() {}

poll_command :: proc() -> (Automation_Command, bool) {
	return {}, false
}

send_ack :: proc(msg: string) {
	_ = msg
}
