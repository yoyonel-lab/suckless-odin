package search

import "core:strings"

// Fuzzy multi-term AND search.
// Returns true if ALL space-separated terms in `filter` are found as substrings
// in the concatenation of `label` + `keywords` (case-insensitive).
fuzzy_match :: proc(filter: string, label: string, keywords: string) -> bool {
	if len(filter) == 0 { return true }

	// Build haystack: "label keywords" lowercased
	haystack_buf: [512]u8
	haystack_len := 0
	for ch in label {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = u8(to_lower_ascii(ch))
		haystack_len += 1
	}
	haystack_buf[haystack_len] = ' '
	haystack_len += 1
	for ch in keywords {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = u8(to_lower_ascii(ch))
		haystack_len += 1
	}
	haystack := string(haystack_buf[:haystack_len])

	// Split filter by spaces, each term must be found (AND logic)
	term_start := 0
	for i in 0 ..= len(filter) {
		is_end := i == len(filter)
		is_space := !is_end && filter[i] == ' '
		if is_end || is_space {
			if i > term_start {
				term := filter[term_start:i]
				// Lowercase the term for comparison
				term_buf: [128]u8
				term_len := 0
				for ch in term {
					if term_len >= len(term_buf) { break }
					term_buf[term_len] = u8(to_lower_ascii(ch))
					term_len += 1
				}
				term_lower := string(term_buf[:term_len])
				if !strings.contains(haystack, term_lower) {
					return false
				}
			}
			term_start = i + 1
		}
	}
	return true
}

// Check if ANY term in filter matches the section keywords.
section_has_matches :: proc(filter: string, section_keywords: string) -> bool {
	return fuzzy_match(filter, "", section_keywords)
}

// Levenshtein distance -- two-row DP, zero allocations.
levenshtein :: proc(a: string, b: string) -> int {
	m := len(a)
	n := len(b)
	if m == 0 { return n }
	if n == 0 { return m }
	if m > 64 { return m }
	if n > 64 { return n }

	buf_a: [65]int
	buf_b: [65]int
	prev := buf_a[:n + 1]
	curr := buf_b[:n + 1]

	for j in 0 ..= n {
		prev[j] = j
	}

	for i in 1 ..= m {
		curr[0] = i
		for j in 1 ..= n {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, curr = curr, prev
	}

	return prev[n]
}

@(private)
to_lower_ascii :: proc(ch: rune) -> rune {
	if ch >= 'A' && ch <= 'Z' {
		return ch + 32
	}
	return ch
}
