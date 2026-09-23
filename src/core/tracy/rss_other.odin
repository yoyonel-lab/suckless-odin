#+build !linux
#+build !windows
package tracy

os_get_process_rss :: proc() -> u64 {
	return 0
}
