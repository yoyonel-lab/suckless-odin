package main

import "core:fmt"
import "core:os"
import "core:strings"

Parsed_Data :: struct {
	transition_states: [dynamic]string,
	ibl_states:        [dynamic]string,
	transition_pairs:  [dynamic][2]string,
	ibl_pairs:         [dynamic][2]string,
	invariants:        [dynamic]Invariant,
}

Invariant :: struct {
	name:        string,
	description: string,
	lhs:         string,
	rhs:         string,
}

parse_quoted_list :: proc(slice: string) -> [dynamic]string {
	res: [dynamic]string
	cursor := 0
	for {
		start_quote := strings.index(slice[cursor:], "\"")
		if start_quote == -1 do break
		abs_start := cursor + start_quote + 1
		end_quote := strings.index(slice[abs_start:], "\"")
		if end_quote == -1 do break
		word := slice[abs_start : abs_start + end_quote]
		append(&res, strings.clone(word))
		cursor = abs_start + end_quote + 1
	}
	return res
}

parse_pairs :: proc(slice: string) -> [dynamic][2]string {
	res: [dynamic][2]string
	cursor := 0
	for {
		start_pair := strings.index(slice[cursor:], "<<")
		if start_pair == -1 do break
		abs_start := cursor + start_pair + 2
		end_pair := strings.index(slice[abs_start:], ">>")
		if end_pair == -1 do break
		pair_content := slice[abs_start : abs_start + end_pair]

		first_quote_1 := strings.index(pair_content, "\"")
		if first_quote_1 == -1 do continue
		end_quote_1 := strings.index(pair_content[first_quote_1 + 1:], "\"")
		if end_quote_1 == -1 do continue
		word1 := pair_content[first_quote_1 + 1 : first_quote_1 + 1 + end_quote_1]

		rest := pair_content[first_quote_1 + 1 + end_quote_1 + 1:]
		first_quote_2 := strings.index(rest, "\"")
		if first_quote_2 == -1 do continue
		end_quote_2 := strings.index(rest[first_quote_2 + 1:], "\"")
		if end_quote_2 == -1 do continue
		word2 := rest[first_quote_2 + 1 : first_quote_2 + 1 + end_quote_2]

		append(&res, [2]string{strings.clone(word1), strings.clone(word2)})
		cursor = abs_start + end_pair + 2
	}
	return res
}

clean_clause :: proc(clause: string) -> string {
	step1, _ := strings.replace_all(clause, "=", "==")
	step1, _ = strings.replace_all(step1, "====", "==")
	step1, _ = strings.replace_all(step1, "===", "==")

	// Remplacement des "State" en .State
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	cursor := 0
	for {
		idx := strings.index(step1[cursor:], "\"")
		if idx == -1 {
			strings.write_string(&builder, step1[cursor:])
			break
		}

		strings.write_string(&builder, step1[cursor : cursor + idx])
		abs_quote := cursor + idx

		end_quote := strings.index(step1[abs_quote + 1:], "\"")
		if end_quote == -1 {
			strings.write_string(&builder, step1[abs_quote:])
			break
		}

		word := step1[abs_quote + 1 : abs_quote + 1 + end_quote]
		strings.write_string(&builder, ".")
		strings.write_string(&builder, word)

		cursor = abs_quote + 1 + end_quote + 1
	}

	return strings.clone(strings.to_string(builder))
}

parse_tla :: proc(content: string) -> (data: Parsed_Data, ok: bool) {
	// 1. Parser TransitionStates
	idx_trans := strings.index(content, "TransitionStates == {")
	if idx_trans == -1 do return {}, false
	end_trans := strings.index(content[idx_trans:], "}")
	if end_trans == -1 do return {}, false
	trans_slice := content[idx_trans + len("TransitionStates == {") : idx_trans + end_trans]
	data.transition_states = parse_quoted_list(trans_slice)

	// 2. Parser IBLStates
	idx_ibl := strings.index(content, "IBLStates == {")
	if idx_ibl == -1 do return {}, false
	end_ibl := strings.index(content[idx_ibl:], "}")
	if end_ibl == -1 do return {}, false
	ibl_slice := content[idx_ibl + len("IBLStates == {") : idx_ibl + end_ibl]
	data.ibl_states = parse_quoted_list(ibl_slice)

	// 3. Parser TransitionTransitions
	idx_trans_tx := strings.index(content, "TransitionTransitions == {")
	if idx_trans_tx == -1 do return {}, false
	end_trans_tx := strings.index(content[idx_trans_tx:], "}")
	if end_trans_tx == -1 do return {}, false
	trans_tx_slice := content[idx_trans_tx + len("TransitionTransitions == {") : idx_trans_tx + end_trans_tx]
	data.transition_pairs = parse_pairs(trans_tx_slice)

	// 4. Parser IBLTransitions
	idx_ibl_tx := strings.index(content, "IBLTransitions == {")
	if idx_ibl_tx == -1 do return {}, false
	end_ibl_tx := strings.index(content[idx_ibl_tx:], "}")
	if end_ibl_tx == -1 do return {}, false
	ibl_tx_slice := content[idx_ibl_tx + len("IBLTransitions == {") : idx_ibl_tx + end_ibl_tx]
	data.ibl_pairs = parse_pairs(ibl_tx_slice)

	// 5. Parser les invariants (* Invariant ... *)
	cursor := 0
	for {
		idx_inv := strings.index(content[cursor:], "(* Invariant")
		if idx_inv == -1 do break

		abs_idx := cursor + idx_inv
		end_comment := strings.index(content[abs_idx:], "*)")
		if end_comment == -1 do break

		comment_content := content[abs_idx + len("(* Invariant") : abs_idx + end_comment]
		colon_idx := strings.index(comment_content, ":")
		if colon_idx == -1 do break

		name := strings.trim_space(comment_content[:colon_idx])
		desc := strings.trim_space(comment_content[colon_idx + 1:])

		search_def := fmt.tprintf("%s == ", name)
		def_idx := strings.index(content[abs_idx + end_comment:], search_def)
		if def_idx == -1 {
			// Essai avec "Name ==" (sans espace après)
			search_def = fmt.tprintf("%s ==", name)
			def_idx = strings.index(content[abs_idx + end_comment:], search_def)
		}
		if def_idx == -1 do break

		abs_def_idx := abs_idx + end_comment + def_idx + len(search_def)
		next_double_nl := strings.index(content[abs_def_idx:], "\n\n")
		expr_len := next_double_nl != -1 ? next_double_nl : len(content[abs_def_idx:])
		expr := strings.trim_space(content[abs_def_idx : abs_def_idx + expr_len])

		parts := strings.split(expr, "=>")
		if len(parts) == 2 {
			lhs := strings.trim_space(parts[0])
			rhs := strings.trim_space(parts[1])

			clean_lhs := clean_clause(lhs)
			clean_rhs := clean_clause(rhs)

			append(&data.invariants, Invariant{
				name = name,
				description = desc,
				lhs = clean_lhs,
				rhs = clean_rhs,
			})
		}

		cursor = abs_def_idx + expr_len
	}

	return data, true
}

generate_odin :: proc(data: Parsed_Data, output_path: string) -> bool {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprint(&builder, "package scene\n\n")
	fmt.sbprint(&builder, "// --- GENERATED FILE — DO NOT EDIT MANUALLY ---\n")
	fmt.sbprint(&builder, "// Generated by tools/codegen from verification/EnvManagerVerification.tla\n\n")

	fmt.sbprint(&builder, "Transition_State :: enum {\n")
	for s in data.transition_states {
		fmt.sbprintf(&builder, "\t%s,\n", s)
	}
	fmt.sbprint(&builder, "}\n\n")

	fmt.sbprint(&builder, "IBL_State :: enum {\n")
	for s in data.ibl_states {
		fmt.sbprintf(&builder, "\t%s,\n", s)
	}
	fmt.sbprint(&builder, "}\n\n")

	// Transition valid
	fmt.sbprint(&builder, "IS_TRANSITION_VALID : [Transition_State][Transition_State]bool = {\n")
	for src in data.transition_states {
		fmt.sbprintf(&builder, "\t.%s = ", src)
		fmt.sbprint(&builder, "{\n")
		for dest in data.transition_states {
			is_valid := src == dest
			for pair in data.transition_pairs {
				if pair[0] == src && pair[1] == dest {
					is_valid = true
					break
				}
			}
			val_str := is_valid ? "true" : "false"
			fmt.sbprintf(&builder, "\t\t.%s = %s,\n", dest, val_str)
		}
		fmt.sbprint(&builder, "\t},\n")
	}
	fmt.sbprint(&builder, "}\n\n")

	// IBL valid
	fmt.sbprint(&builder, "IS_IBL_VALID : [IBL_State][IBL_State]bool = {\n")
	for src in data.ibl_states {
		fmt.sbprintf(&builder, "\t.%s = ", src)
		fmt.sbprint(&builder, "{\n")
		for dest in data.ibl_states {
			is_valid := src == dest
			for pair in data.ibl_pairs {
				if pair[0] == src && pair[1] == dest {
					is_valid = true
					break
				}
			}
			val_str := is_valid ? "true" : "false"
			fmt.sbprintf(&builder, "\t\t.%s = %s,\n", dest, val_str)
		}
		fmt.sbprint(&builder, "\t},\n")
	}
	fmt.sbprint(&builder, "}\n\n")

	fmt.sbprint(&builder, "env_manager_validate_transition :: proc(from, to: Transition_State) -> bool {\n")
	fmt.sbprint(&builder, "\treturn IS_TRANSITION_VALID[from][to]\n")
	fmt.sbprint(&builder, "}\n\n")

	fmt.sbprint(&builder, "env_manager_validate_ibl :: proc(from, to: IBL_State) -> bool {\n")
	fmt.sbprint(&builder, "\treturn IS_IBL_VALID[from][to]\n")
	fmt.sbprint(&builder, "}\n\n")

	fmt.sbprint(&builder, "env_manager_validate_invariants :: proc(transition_state: Transition_State, ibl_state: IBL_State) {\n")
	for inv in data.invariants {
		fmt.sbprintf(&builder, "\t// Invariant %s: %s\n", inv.name, inv.description)
		fmt.sbprintf(&builder, "\tif %s ", inv.lhs)
		fmt.sbprint(&builder, "{\n")
		fmt.sbprintf(&builder, "\t\tassert(%s, \"Invariant Violation (%s): %s\")\n", inv.rhs, inv.name, inv.description)
		fmt.sbprint(&builder, "\t}\n")
	}
	fmt.sbprint(&builder, "}\n")

	out_str := strings.to_string(builder)
	ok := os.write_entire_file(output_path, transmute([]byte)out_str)
	return ok == nil
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.println("Usage: generate_states <EnvManagerVerification.tla>")
		os.exit(1)
	}

	tla_path := args[1]

	data, read_err := os.read_entire_file_from_path(tla_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error: Could not read TLA+ file: %s (error: %v)\n", tla_path, read_err)
		os.exit(1)
	}
	defer delete(data)

	parsed_data, parse_ok := parse_tla(string(data))
	if !parse_ok {
		fmt.eprintf("Error: Failed to parse TLA+ file structure\n")
		os.exit(1)
	}

	output_path := "src/scene/env_manager_states.gen.odin"

	gen_ok := generate_odin(parsed_data, output_path)
	if !gen_ok {
		fmt.eprintf("Error: Failed to write generated Odin file\n")
		os.exit(1)
	}

	fmt.printf("✓ Generated Odin code: %s\n", output_path)
}
