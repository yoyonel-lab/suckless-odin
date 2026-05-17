package main

import "core:fmt"

// CLI action results
Cli_Action :: enum {
	Continue,
	Exit_Success,
	Exit_Failure,
}

cli_handle_args :: proc(args: []string) -> Cli_Action {
	if len(args) <= 1 {
		return .Continue
	}

	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			print_usage(args[0])
			return .Exit_Success
		case "-v", "--version":
			fmt.println("suckless-odin v0.1.0")
			return .Exit_Success
		case:
			fmt.eprintfln("Unknown argument: %s", arg)
			print_usage(args[0])
			return .Exit_Failure
		}
	}

	return .Continue
}

print_usage :: proc(program_name: string) {
	fmt.printfln("Usage: %s [options]", program_name)
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -h, --help       Show this help message")
	fmt.println("  -v, --version    Show version information")
}
