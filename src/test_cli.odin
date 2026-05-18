// +build test
package main

import "core:testing"

import postfx "rendering/postfx"

// --- CLI argument parsing ---
// ISO port of test_cli.c from suckless-ogl

@(test)
test_cli_no_args :: proc(t: ^testing.T) {
	args := []string{"app"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Continue)
}

@(test)
test_cli_help_short :: proc(t: ^testing.T) {
	args := []string{"app", "-h"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Success)
}

@(test)
test_cli_help_long :: proc(t: ^testing.T) {
	args := []string{"app", "--help"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Success)
}

@(test)
test_cli_version_short :: proc(t: ^testing.T) {
	args := []string{"app", "-v"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Success)
}

@(test)
test_cli_version_long :: proc(t: ^testing.T) {
	args := []string{"app", "--version"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Success)
}

@(test)
test_cli_unknown_arg :: proc(t: ^testing.T) {
	args := []string{"app", "--unknown"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Failure)
}

@(test)
test_cli_partial_match :: proc(t: ^testing.T) {
	args := []string{"app", "--h"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Failure)
}

@(test)
test_cli_no_postfx :: proc(t: ^testing.T) {
	args := []string{"app", "--no-postfx"}
	opts, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Continue)
	testing.expect_value(t, opts.postfx_enabled, false)
}

@(test)
test_cli_postfx_preset :: proc(t: ^testing.T) {
	args := []string{"app", "--postfx-preset=cinematic"}
	opts, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Continue)
	testing.expect_value(t, opts.postfx_preset, Maybe(postfx.Preset_Id)(postfx.Preset_Id.Cinematic))
}

@(test)
test_cli_postfx_preset_invalid :: proc(t: ^testing.T) {
	args := []string{"app", "--postfx-preset=nonexist"}
	_, action := cli_handle_args(args)
	testing.expect_value(t, action, Cli_Action.Exit_Failure)
}
