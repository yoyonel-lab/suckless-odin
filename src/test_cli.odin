// +build test
package main

import "core:testing"

// --- CLI argument parsing ---
// ISO port of test_cli.c from suckless-ogl

@(test)
test_cli_no_args :: proc(t: ^testing.T) {
	args := []string{"app"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Continue)
}

@(test)
test_cli_help_short :: proc(t: ^testing.T) {
	args := []string{"app", "-h"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Success)
}

@(test)
test_cli_help_long :: proc(t: ^testing.T) {
	args := []string{"app", "--help"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Success)
}

@(test)
test_cli_version_short :: proc(t: ^testing.T) {
	args := []string{"app", "-v"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Success)
}

@(test)
test_cli_version_long :: proc(t: ^testing.T) {
	args := []string{"app", "--version"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Success)
}

@(test)
test_cli_unknown_arg :: proc(t: ^testing.T) {
	args := []string{"app", "--unknown"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Failure)
}

@(test)
test_cli_partial_match :: proc(t: ^testing.T) {
	args := []string{"app", "--h"}
	testing.expect_value(t, cli_handle_args(args), Cli_Action.Exit_Failure)
}
