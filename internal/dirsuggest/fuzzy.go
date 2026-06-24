package dirsuggest

import (
	"sort"
	"strings"
	"unicode"
)

// fuzzyRank filters candidates to those whose characters appear in order as a
// case-insensitive subsequence of the query, ranked best-first. An empty query
// returns the candidates unchanged, preserving incoming recency order.
func fuzzyRank(query string, candidates []string) []string {
	q := strings.TrimSpace(strings.ToLower(query))
	if q == "" {
		return candidates
	}

	type scored struct {
		value string
		score int
		index int
	}

	matches := make([]scored, 0, len(candidates))
	for i, cand := range candidates {
		if score, ok := fuzzyScore(q, cand); ok {
			matches = append(matches, scored{value: cand, score: score, index: i})
		}
	}

	sort.SliceStable(matches, func(a, b int) bool {
		if matches[a].score != matches[b].score {
			return matches[a].score > matches[b].score
		}
		return matches[a].index < matches[b].index
	})

	out := make([]string, len(matches))
	for i, match := range matches {
		out[i] = match.value
	}
	return out
}

func fuzzyScore(query, candidate string) (int, bool) {
	cand := []rune(candidate)
	lower := []rune(strings.ToLower(candidate))
	q := []rune(query)

	score := 0
	qi := 0
	prevMatch := -2
	for ci := 0; ci < len(lower) && qi < len(q); ci++ {
		if lower[ci] != q[qi] {
			continue
		}
		if ci == prevMatch+1 {
			score += 5
		}
		if ci == 0 || isBoundary(cand, ci) {
			score += 20
		}
		if ci < 16 {
			score += 16 - ci
		}
		prevMatch = ci
		qi++
	}
	if qi != len(q) {
		return 0, false
	}
	return score, true
}

func isBoundary(runes []rune, i int) bool {
	if i <= 0 || i >= len(runes) {
		return false
	}
	prev := runes[i-1]
	if prev == '/' || prev == '_' || prev == '-' || prev == '.' || prev == ' ' {
		return true
	}
	return unicode.IsLower(prev) && unicode.IsUpper(runes[i])
}
