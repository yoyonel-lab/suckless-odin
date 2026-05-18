package search

import "core:strings"

// Fuzzy multi-term search with Levenshtein distance tolerance.
//
// Returns true if ALL space-separated terms in `filter` match the haystack
// (concatenation of `label` + `keywords`).
//
// A term matches if (checked in priority order):
//   1. Exact substring of haystack (e.g. "memory" in "gpu memory estimation")
//   2. Prefix of any word in haystack (e.g. "estim" → "estimation")
//   3. Levenshtein distance to any word ≤ threshold (e.g. "estimate" ~ "estimation")
//
// Threshold is adaptive: max_distance = max(1, len(term) / 4)
//   - 1-4 chars  → distance ≤ 1
//   - 5-8 chars  → distance ≤ 1-2
//   - 9+ chars   → distance ≤ 2+
fuzzy_match :: proc(filter: string, label: string, keywords: string) -> bool {
	if len(filter) == 0 { return true }

	// Build haystack: "label keywords" lowercased into stack buffer.
	// Operates on raw bytes — all GUI labels are ASCII.
	haystack_buf: [512]u8
	haystack_len := 0

	for b in transmute([]u8)label {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = to_lower_byte(b)
		haystack_len += 1
	}
	if haystack_len < len(haystack_buf) - 1 {
		haystack_buf[haystack_len] = ' '
		haystack_len += 1
	}
	for b in transmute([]u8)keywords {
		if haystack_len >= len(haystack_buf) - 1 { break }
		haystack_buf[haystack_len] = to_lower_byte(b)
		haystack_len += 1
	}
	haystack := string(haystack_buf[:haystack_len])

	// Split filter by spaces — every term must match (AND logic).
	filter_it := filter
	for term in strings.split_iterator(&filter_it, " ") {
		if len(term) == 0 { continue }

		term_buf: [128]u8
		term_len := 0
		for b in transmute([]u8)term {
			if term_len >= len(term_buf) { break }
			term_buf[term_len] = to_lower_byte(b)
			term_len += 1
		}
		if !term_matches(haystack, string(term_buf[:term_len])) {
			return false
		}
	}
	return true
}

// Check if ANY term in filter matches the section keywords (used for section visibility).
section_has_matches :: proc(filter: string, section_keywords: string) -> bool {
	return fuzzy_match(filter, "", section_keywords)
}

// A term matches via: substring → prefix → Levenshtein distance.
@(private)
term_matches :: proc(haystack: string, term: string) -> bool {
	if len(term) == 0 { return true }

	// 1. Substring match (fast path).
	if strings.contains(haystack, term) {
		return true
	}

	// 2. Prefix-of-word match + 3. Levenshtein with adaptive threshold.
	max_dist := max(1, len(term) / 4)

	hay_it := haystack
	for word in strings.split_iterator(&hay_it, " ") {
		if len(word) == 0 { continue }

		// Prefix match.
		if strings.has_prefix(word, term) {
			return true
		}

		// Levenshtein: compare term against the word.
		if levenshtein(term, word) <= max_dist {
			return true
		}

		// Also check term as prefix with Levenshtein tolerance:
		// compare term against the first len(term) chars of word.
		if len(word) > len(term) {
			if levenshtein(term, word[:len(term)]) <= max_dist {
				return true
			}
		}
	}
	return false
}

// Levenshtein distance — two-row DP on stack, O(n) space, zero allocations.
levenshtein :: proc(a: string, b: string) -> int {
	m := len(a)
	n := len(b)
	if m == 0 { return n }
	if n == 0 { return m }

	// Clamp to avoid stack overflow for very long strings.
	if m > 64 { return m }
	if n > 64 { return n }

	// Two-row DP with O(1) swap via slices.
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
to_lower_byte :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}
