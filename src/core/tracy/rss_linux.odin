#+build linux
package tracy

import "core:os"

os_get_process_rss :: proc() -> u64 {
	fd, err := os.open("/proc/self/statm", os.O_RDONLY)
	if err != nil {
		return 0
	}
	defer os.close(fd)

	buf: [64]byte
	n, read_err := os.read(fd, buf[:])
	if read_err != nil || n <= 0 {
		return 0
	}

	// Format: "<size> <resident> <shared> ..."
	i := 0
	// Skip first token (virtual size)
	for i < n && buf[i] != ' ' {
		i += 1
	}
	// Skip whitespace
	for i < n && buf[i] == ' ' {
		i += 1
	}
	// Parse resident pages
	pages: u64 = 0
	for i < n && buf[i] >= '0' && buf[i] <= '9' {
		pages = pages * 10 + u64(buf[i] - '0')
		i += 1
	}
	return pages * 4096
}
