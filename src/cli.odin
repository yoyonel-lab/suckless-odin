package main

import "core:fmt"
import "core:strings"

import postfx "rendering/postfx"

// CLI action results
Cli_Action :: enum {
	Continue,
	Exit_Success,
	Exit_Failure,
}

// CLI options passed to the application.
Cli_Options :: struct {
	postfx_preset:  Maybe(postfx.Preset_Id),
	postfx_enabled: bool,
}

DEFAULT_CLI_OPTIONS :: Cli_Options{
	postfx_preset  = nil,
	postfx_enabled = true,
}

cli_handle_args :: proc(args: []string) -> (Cli_Options, Cli_Action) {
	opts := DEFAULT_CLI_OPTIONS

	if len(args) <= 1 {
		return opts, .Continue
	}

	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case arg == "-h" || arg == "--help":
			print_usage(args[0])
			return opts, .Exit_Success
		case arg == "-v" || arg == "--version":
			fmt.println("suckless-odin v0.1.0")
			return opts, .Exit_Success
		case arg == "--no-postfx":
			opts.postfx_enabled = false
		case strings.has_prefix(arg, "--postfx-preset="):
			value := arg[len("--postfx-preset="):]
			preset_id, ok := parse_preset_name(value)
			if !ok {
				fmt.eprintfln("Unknown preset: '%s'", value)
				fmt.eprintln("Available presets: default, subtle, cinematic, vibrant, clean")
				return opts, .Exit_Failure
			}
			opts.postfx_preset = preset_id
		case:
			fmt.eprintfln("Unknown argument: %s", arg)
			print_usage(args[0])
			return opts, .Exit_Failure
		}
	}

	return opts, .Continue
}

@(private)
parse_preset_name :: proc(name: string) -> (postfx.Preset_Id, bool) {
	switch name {
	case "default":   return .Default, true
	case "subtle":    return .Subtle, true
	case "cinematic": return .Cinematic, true
	case "vibrant":   return .Vibrant, true
	case "clean":     return .Clean, true
	}
	return .Default, false
}

print_usage :: proc(program_name: string) {
	fmt.printfln("Usage: %s [options]", program_name)
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -h, --help                  Show this help message")
	fmt.println("  -v, --version               Show version information")
	fmt.println("  --no-postfx                 Disable post-processing")
	fmt.println("  --postfx-preset=<name>      Apply a preset (default, subtle, cinematic, vibrant, clean)")
}
