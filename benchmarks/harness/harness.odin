// Benchmark harness — shared utilities for all benchmarks.
//
// Provides:
//   - Bench_Case: a named function to benchmark
//   - run_suite: executes all cases with warmup + timed iterations
//   - Report output (human-readable + optional JSON)
//
// Usage in a benchmark package:
//
//   import harness "../../benchmarks/harness"
//
//   main :: proc() {
//       harness.run_suite("My Feature", {
//           {"case_a", 100_000, my_func_a},
//           {"case_b", 500_000, my_func_b},
//       })
//   }
package harness

import "core:fmt"
import "core:os"
import "core:time"

// A single benchmark case: a name, iteration count, and the function to call.
Bench_Case :: struct {
	name:       string,
	iterations: int,
	run:        proc() -> int, // returns a checksum/match count to prevent dead code elimination
}

// Result of running one benchmark case.
Bench_Result :: struct {
	name:        string,
	iterations:  int,
	duration:    time.Duration,
	ns_per_call: i64,
	checksum:    int,
}

// Run a full benchmark suite: warmup → measure → report.
run_suite :: proc(suite_name: string, cases: []Bench_Case) {
	fmt.printf("=== %s ===\n\n", suite_name)

	results: [16]Bench_Result
	result_count := 0

	for c in cases {
		if result_count >= len(results) { break }
		r := run_case(c)
		results[result_count] = r
		result_count += 1
	}

	// Summary table.
	fmt.printf("\n── Summary ──\n")
	for i in 0 ..< result_count {
		r := results[i]
		fmt.printf("  %s: %v ns/call (%v iters, checksum=%v)\n",
			r.name, r.ns_per_call, r.iterations, r.checksum)
	}

	// JSON output if requested via environment variable.
	json_buf: [256]u8
	json_path, json_err := os.lookup_env_buf(json_buf[:], "BENCH_JSON")
	if json_err == nil && len(json_path) > 0 {
		write_json(suite_name, results[:result_count], json_path)
	}
}

// Execute a single case with warmup.
@(private)
run_case :: proc(c: Bench_Case) -> Bench_Result {
	fmt.printf("  %-30s ", c.name)

	// Warmup: 1% of iterations or 1000, whichever is larger.
	warmup_count := max(1000, c.iterations / 100)
	for _ in 0 ..< warmup_count {
		_ = c.run()
	}

	// Timed run.
	sw := time.Stopwatch{}
	time.stopwatch_start(&sw)

	checksum := 0
	for _ in 0 ..< c.iterations {
		checksum += c.run()
	}

	time.stopwatch_stop(&sw)
	elapsed := time.stopwatch_duration(sw)
	ns_total := time.duration_nanoseconds(elapsed)
	ns_per_call := ns_total / i64(c.iterations) if c.iterations > 0 else 0

	fmt.printf("%d calls in %v — %d ns/call\n", c.iterations, elapsed, ns_per_call)

	return Bench_Result{
		name        = c.name,
		iterations  = c.iterations,
		duration    = elapsed,
		ns_per_call = ns_per_call,
		checksum    = checksum,
	}
}

// Write results as JSON lines (append-friendly for historical tracking).
@(private)
write_json :: proc(suite: string, results: []Bench_Result, path: string) {
	fd, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {
		fmt.eprintf("Warning: cannot write JSON to %s: %v\n", path, err)
		return
	}
	defer os.close(fd)

	os.write_string(fd, "[\n")
	for r, i in results {
		comma := "," if i < len(results) - 1 else ""
		line := fmt.tprintf(
			"  {{\"suite\":\"%s\",\"name\":\"%s\",\"iterations\":%d,\"ns_per_call\":%d,\"checksum\":%d}}%s\n",
			suite, r.name, r.iterations, r.ns_per_call, r.checksum, comma,
		)
		os.write_string(fd, line)
	}
	os.write_string(fd, "]\n")
	fmt.printf("\n  JSON results written to: %s\n", path)
}
