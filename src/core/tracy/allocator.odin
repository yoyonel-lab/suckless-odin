package tracy

import "base:runtime"

Tracy_Allocator_Data :: struct {
	backing: runtime.Allocator,
}

@(private="file")
g_tracy_alloc_data: Tracy_Allocator_Data

tracy_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (result: []byte, err: runtime.Allocator_Error) {
	backing: runtime.Allocator
	if allocator_data != nil {
		backing = (cast(^Tracy_Allocator_Data)allocator_data).backing
	} else {
		backing = runtime.default_allocator()
	}

	result, err = backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err != .None {
		return
	}

	when TRACY_ENABLE {
		switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			if size > 0 && raw_data(result) != nil {
				alloc(raw_data(result), uint(size))
			}
		case .Free:
			if old_memory != nil {
				free(old_memory)
			}
		case .Resize, .Resize_Non_Zeroed:
			if old_memory != nil {
				free(old_memory)
			}
			if size > 0 && raw_data(result) != nil {
				alloc(raw_data(result), uint(size))
			}
		case .Free_All, .Query_Features, .Query_Info:
			// no-op for tracy
		}
	}

	return
}

// Wraps an existing allocator with Tracy memory tracking.
// When TRACY_ENABLE is false, returns backing unchanged (zero runtime overhead).
make_tracy_allocator :: proc(backing: runtime.Allocator) -> runtime.Allocator {
	when TRACY_ENABLE {
		g_tracy_alloc_data.backing = backing
		return runtime.Allocator{
			procedure = tracy_allocator_proc,
			data      = &g_tracy_alloc_data,
		}
	} else {
		return backing
	}
}

// Queries the physical Resident Set Size (RSS) of the current process in bytes.
// Zero-allocation implementation (reads /proc/self/statm on Linux, GetProcessMemoryInfo on Windows).
get_process_rss :: proc() -> u64 {
	when TRACY_ENABLE {
		return os_get_process_rss()
	} else {
		return 0
	}
}
