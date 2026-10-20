//go:build linux || darwin

package state

import (
	"path"
	"strings"
)

// shortcut: parse only 4096 input bytes; raise the cap if harnesses prepend longer wrappers.
const maxToolCommandInputBytes = 4096

// shortcut: ignore command keys over 80 bytes; raise the cap if shell command names exceed it.
const maxToolCommandKeyBytes = 80

var (
	sudoValueOptions    = map[string]bool{"-u": true, "--user": true, "-g": true, "--group": true, "-h": true, "--host": true, "-p": true, "--prompt": true, "-C": true, "--close-from": true, "-T": true, "-R": true, "-D": true, "-r": true, "-t": true}
	timeValueOptions    = map[string]bool{"-f": true, "--format": true, "-o": true, "--output": true}
	envValueOptions     = map[string]bool{"-u": true, "--unset": true, "-S": true, "--split-string": true}
	timeoutValueOptions = map[string]bool{"-k": true, "--kill-after": true, "-s": true, "--signal": true}
)

type shellWord struct {
	value  string
	quoted bool
}

func NormalizeToolCommand(command string) string {
	if len(command) > maxToolCommandInputBytes {
		command = strings.ToValidUTF8(command[:maxToolCommandInputBytes], "")
	}
	segments, separators := splitShellCommand(command)
	segmentIndex := firstNonEmptySegment(segments, 0)
	if segmentIndex < 0 {
		return ""
	}
	for firstCommandWord(segments[segmentIndex]) == "cd" {
		next := -1
		for i := segmentIndex; i < len(separators); i++ {
			if separators[i] == ";" || separators[i] == "&&" {
				next = firstNonEmptySegment(segments, i+1)
				break
			}
		}
		if next < 0 {
			return ""
		}
		segmentIndex = next
	}

	words := stripShellWrappers(segments[segmentIndex])
	if len(words) == 0 {
		return ""
	}
	program := path.Base(words[0].value)
	if program == "." || program == "/" || program == "" {
		return ""
	}
	key := program
	if len(words) > 1 && !words[1].quoted && plainShellWord(words[1].value) {
		key += " " + words[1].value
	}
	if len(key) > maxToolCommandKeyBytes {
		return ""
	}
	return key
}

func splitShellCommand(command string) ([][]shellWord, []string) {
	segments := make([][]shellWord, 1)
	var word strings.Builder
	quoted, inQuote, escaped, started := false, byte(0), false, false
	flushWord := func() {
		if !started {
			return
		}
		segments[len(segments)-1] = append(segments[len(segments)-1], shellWord{value: word.String(), quoted: quoted})
		word.Reset()
		quoted = false
		started = false
	}
	var separators []string
	for i := 0; i < len(command); i++ {
		ch := command[i]
		if escaped {
			word.WriteByte(ch)
			started = true
			escaped = false
			continue
		}
		if inQuote != 0 {
			if ch == inQuote {
				inQuote = 0
				continue
			}
			if ch == '\\' && inQuote == '"' {
				escaped = true
				continue
			}
			word.WriteByte(ch)
			started = true
			continue
		}
		switch ch {
		case '\'', '"':
			inQuote = ch
			quoted = true
			started = true
		case '\\':
			escaped = true
			started = true
		case ' ', '\t', '\n', '\r':
			flushWord()
		case ';', '|', '&':
			flushWord()
			separator := string(ch)
			if i+1 < len(command) && command[i+1] == ch && (ch == '|' || ch == '&') {
				separator += string(ch)
				i++
			}
			separators = append(separators, separator)
			segments = append(segments, nil)
		default:
			word.WriteByte(ch)
			started = true
		}
	}
	if escaped {
		word.WriteByte('\\')
		started = true
	}
	flushWord()
	return segments, separators
}

func firstNonEmptySegment(segments [][]shellWord, start int) int {
	for i := start; i < len(segments); i++ {
		if len(segments[i]) > 0 {
			return i
		}
	}
	return -1
}

func firstCommandWord(words []shellWord) string {
	words = stripShellWrappers(words)
	if len(words) == 0 {
		return ""
	}
	return words[0].value
}

func stripShellWrappers(words []shellWord) []shellWord {
	index := 0
	for index < len(words) {
		for index < len(words) && shellAssignment(words[index].value) {
			index++
		}
		if index >= len(words) {
			return nil
		}
		switch path.Base(words[index].value) {
		case "sudo":
			index++
			index = skipWrapperOptions(words, index, sudoValueOptions)
		case "time":
			index++
			index = skipWrapperOptions(words, index, timeValueOptions)
		case "env":
			index++
			index = skipWrapperOptions(words, index, envValueOptions)
		case "nice":
			index++
			index = skipNiceOptions(words, index)
		case "timeout":
			index++
			index = skipWrapperOptions(words, index, timeoutValueOptions)
			if index < len(words) && words[index].value != "--" {
				index++
			} else if index < len(words) {
				index++
			}
		case "command":
			index++
			for index < len(words) && (words[index].value == "-p" || words[index].value == "-v" || words[index].value == "-V") {
				index++
			}
		case "exec":
			index++
			if index < len(words) && words[index].value == "-a" {
				index += 2
			}
		case "nohup":
			index++
		default:
			return words[index:]
		}
	}
	return nil
}

func skipWrapperOptions(words []shellWord, index int, takesValue map[string]bool) int {
	for index < len(words) {
		value := words[index].value
		if value == "--" {
			return index + 1
		}
		if !strings.HasPrefix(value, "-") || value == "-" {
			return index
		}
		if takesValue[value] {
			index += 2
			continue
		}
		index++
	}
	return index
}

func skipNiceOptions(words []shellWord, index int) int {
	for index < len(words) {
		value := words[index].value
		if value == "--" {
			return index + 1
		}
		if value == "-n" || value == "--adjustment" {
			index += 2
			continue
		}
		if strings.HasPrefix(value, "-n") && len(value) > 2 {
			index++
			continue
		}
		if !strings.HasPrefix(value, "-") || value == "-" {
			return index
		}
		index++
	}
	return index
}

func shellAssignment(word string) bool {
	index := strings.IndexByte(word, '=')
	if index < 1 {
		return false
	}
	for i := 0; i < index; i++ {
		ch := word[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || (i > 0 && ch >= '0' && ch <= '9') {
			continue
		}
		return false
	}
	return true
}

func plainShellWord(word string) bool {
	if len(word) == 0 || word[0] < 'a' || word[0] > 'z' {
		return false
	}
	for i := 1; i < len(word); i++ {
		ch := word[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}
