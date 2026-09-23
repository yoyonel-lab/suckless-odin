#+build windows
package tracy

foreign import psapi "system:psapi.lib"

PROCESS_MEMORY_COUNTERS :: struct {
	cb:                         u32,
	PageFaultCount:             u32,
	PeakWorkingSetSize:         uint,
	WorkingSetSize:             uint,
	QuotaPeakPagedPoolUsage:    uint,
	QuotaPagedPoolUsage:        uint,
	QuotaPeakNonPagedPoolUsage: uint,
	QuotaNonPagedPoolUsage:     uint,
	PagefileUsage:              uint,
	PeakPagefileUsage:          uint,
}

@(default_calling_convention = "stdcall")
foreign psapi {
	GetProcessMemoryInfo :: proc(hProcess: rawptr, ppsmemCounters: ^PROCESS_MEMORY_COUNTERS, cb: u32) -> i32 ---
}

os_get_process_rss :: proc() -> u64 {
	counters: PROCESS_MEMORY_COUNTERS
	counters.cb = size_of(counters)
	h_process := rawptr(~uintptr(0)) // GetCurrentProcess() pseudo-handle
	if GetProcessMemoryInfo(h_process, &counters, size_of(counters)) != 0 {
		return u64(counters.WorkingSetSize)
	}
	return 0
}
