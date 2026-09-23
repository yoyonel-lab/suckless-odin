#+build !windows
package automation

import log "../core/log"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:strings"
import "core:time"
import "core:sys/posix"

// Commands
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

MAX_COMMANDS :: 32

Automation_Context :: struct {
	socket_path:   string,
	is_running:    bool,
	server_thread: ^thread.Thread,
	server_fd:     posix.FD,
	
	// Inbound queue (from client to main thread)
	in_mu:    sync.Mutex,
	in_queue: [MAX_COMMANDS]Automation_Command,
	in_head:  int,
	in_tail:  int,
	in_count: int,
	
	// Outbound signal (from main thread to client)
	out_mu:    sync.Mutex,
	out_ready: bool,
	out_msg:   string,
}

g_ctx: ^Automation_Context

init :: proc(socket_path: string) -> bool {
	if len(socket_path) == 0 do return true // Disabled
	
	g_ctx = new(Automation_Context)
	g_ctx.socket_path = strings.clone(socket_path)
	g_ctx.is_running = true
	g_ctx.server_fd = -1
	
	t := thread.create(automation_worker_proc)
	if t == nil {
		log.log_error("app", "Failed to create automation thread")
		return false
	}
	g_ctx.server_thread = t
	thread.start(t)
	return true
}

shutdown :: proc() {
	if g_ctx == nil do return
	
	g_ctx.is_running = false
	
	// Unblock accept() in server_thread by connecting a dummy client
	dummy_fd := posix.socket(.UNIX, .STREAM, .IP)
	if dummy_fd >= 0 {
		addr: posix.sockaddr_un
		addr.sun_family = .UNIX
		copy(addr.sun_path[:], transmute([]u8)g_ctx.socket_path)
		_ = posix.connect(dummy_fd, (^posix.sockaddr)(&addr), size_of(addr))
		posix.close(dummy_fd)
	}
	
	thread.join(g_ctx.server_thread)
	thread.destroy(g_ctx.server_thread)
	
	if g_ctx.server_fd >= 0 {
		posix.close(g_ctx.server_fd)
		g_ctx.server_fd = -1
	}
	
	c_path := strings.clone_to_cstring(g_ctx.socket_path, context.temp_allocator)
	posix.unlink(c_path)
	
	delete(g_ctx.socket_path)
	free(g_ctx)
	g_ctx = nil
}

// Thread-safe command enqueue
push_command :: proc(cmd: Automation_Command) -> bool {
	sync.lock(&g_ctx.in_mu)
	defer sync.unlock(&g_ctx.in_mu)
	
	if g_ctx.in_count >= MAX_COMMANDS {
		return false
	}
	
	g_ctx.in_queue[g_ctx.in_tail] = cmd
	g_ctx.in_tail = (g_ctx.in_tail + 1) % MAX_COMMANDS
	g_ctx.in_count += 1
	return true
}

// Called by main thread to poll commands
poll_command :: proc() -> (Automation_Command, bool) {
	if g_ctx == nil do return {}, false
	
	sync.lock(&g_ctx.in_mu)
	defer sync.unlock(&g_ctx.in_mu)
	
	if g_ctx.in_count == 0 {
		return {}, false
	}
	
	cmd := g_ctx.in_queue[g_ctx.in_head]
	g_ctx.in_head = (g_ctx.in_head + 1) % MAX_COMMANDS
	g_ctx.in_count -= 1
	return cmd, true
}

// Called by main thread to send ACK
send_ack :: proc(msg: string) {
	if g_ctx == nil do return
	
	sync.lock(&g_ctx.out_mu)
	defer sync.unlock(&g_ctx.out_mu)
	g_ctx.out_msg = msg
	g_ctx.out_ready = true
}

automation_worker_proc :: proc(t: ^thread.Thread) {
	c_path := strings.clone_to_cstring(g_ctx.socket_path, context.temp_allocator)
	posix.unlink(c_path)
	
	fd := posix.socket(.UNIX, .STREAM, .IP)
	if fd < 0 {
		log.log_error("app", "Failed to create UNIX socket")
		return
	}
	g_ctx.server_fd = fd
	
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)g_ctx.socket_path)
	
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		log.log_error("app", "Failed to bind UNIX socket: %s", g_ctx.socket_path)
		return
	}
	
	if posix.listen(fd, 4) != .OK {
		log.log_error("app", "Failed to listen on UNIX socket")
		return
	}
	
	for g_ctx.is_running {
		client_fd := posix.accept(fd, nil, nil)
		if client_fd < 0 {
			break
		}
		if !g_ctx.is_running {
			posix.close(client_fd)
			break
		}
		
		handle_client(client_fd)
		posix.close(client_fd)
	}
}

handle_client :: proc(client_fd: posix.FD) {
	buf: [1024]u8
	
	for g_ctx.is_running {
		n := posix.recv(client_fd, &buf[0], len(buf), {})
		if n <= 0 do break
		
		data := string(buf[:n])
		data = strings.trim_space(data)
		if len(data) == 0 do continue
		
		cmd_type := Command_Type.Unknown
		arg_str := ""
		
		idx := strings.index(data, ":")
		cmd_str := data
		if idx > 0 {
			cmd_str = data[:idx]
			arg_str = data[idx+1:]
		}
		
		if cmd_str == "AWAIT_INIT" do cmd_type = .Await_Init
		else if cmd_str == "LOAD_ENV" do cmd_type = .Load_Env
		else if cmd_str == "QUIT" do cmd_type = .Quit
		
		if cmd_type == .Unknown {
			err_msg := "ERROR\n"
			posix.send(client_fd, raw_data(err_msg), len(err_msg), {})
			continue
		}
		
		cmd := Automation_Command{type = cmd_type, arg = strings.clone(arg_str)}
		if !push_command(cmd) {
			err_msg := "ERROR:Queue full\n"
			posix.send(client_fd, raw_data(err_msg), len(err_msg), {})
			continue
		}
		
		wait_for_ack(client_fd)
	}
}

wait_for_ack :: proc(client_fd: posix.FD) {
	for g_ctx.is_running {
		sync.lock(&g_ctx.out_mu)
		ready := g_ctx.out_ready
		msg := g_ctx.out_msg
		if ready {
			g_ctx.out_ready = false
			g_ctx.out_msg = ""
		}
		sync.unlock(&g_ctx.out_mu)
		
		if ready {
			buf_resp: [512]u8
			response := fmt.bprintf(buf_resp[:], "OK:%s\n", msg)
			posix.send(client_fd, raw_data(response), len(response), {})
			return
		}
		
		time.sleep(10 * time.Millisecond)
	}
}
