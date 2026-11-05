package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// The input ceiling covers large tool responses without allowing an unbounded
// pipe to keep a hook busy. The much smaller retained limits keep memory flat
// as a response grows; handlers only need short activity and identity fields.
const (
	maxHookInputBytes  = 64 << 20
	maxHookOutputBytes = 4 << 20
	maxHookStringBytes = 64 << 10
	// A JSON escape can use six source bytes for one decoded byte.
	maxHookEncodedStringBytes = maxHookStringBytes*6 + 2
	maxHookDepth              = 64
)

type hookStdinScanner struct {
	input      *bufio.Reader
	limit      *io.LimitedReader
	output     bytes.Buffer
	discard    bool
	lastString []byte
}

// readStdinNonBlocking skips a real TTY and strips oversized JSON strings
// while streaming the complete input. A large tool response is discarded in
// fixed space before the existing harness decoders see the compact payload.
func readStdinNonBlocking(r io.Reader) ([]byte, error) {
	if r == nil || stdinLooksInteractive(r) {
		return nil, nil
	}
	// Most hooks are tiny. Return them unchanged so the existing tolerant
	// decoders keep their behavior on malformed or partial input.
	head, err := io.ReadAll(io.LimitReader(r, maxHookStringBytes+1))
	if err != nil {
		return nil, err
	}
	if len(head) <= maxHookStringBytes {
		return head, nil
	}
	r = io.MultiReader(bytes.NewReader(head), r)
	limited := &io.LimitedReader{R: r, N: maxHookInputBytes + 1}
	s := hookStdinScanner{input: bufio.NewReaderSize(limited, 32<<10), limit: limited}
	if err := s.space(); err != nil {
		return nil, err
	}
	first, err := s.input.Peek(1)
	if err == io.EOF {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if first[0] != '{' && first[0] != '[' {
		// Preserve the historical small, non-JSON input behavior used by
		// interactive callers. A large non-JSON stream has no useful fields.
		truncated := false
		for {
			b, err := s.readByte()
			if err == io.EOF {
				if truncated {
					return nil, fmt.Errorf("non-JSON stdin exceeds %d-byte retained limit", maxHookOutputBytes)
				}
				return s.output.Bytes(), nil
			}
			if err != nil {
				return nil, err
			}
			if s.output.Len() < maxHookOutputBytes {
				s.output.WriteByte(b)
			} else {
				truncated = true
			}
		}
	}
	if err := s.value(0); err != nil {
		return nil, err
	}
	if err := s.space(); err != nil {
		return nil, err
	}
	if _, err := s.readByte(); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("trailing data after JSON payload")
		}
		return nil, err
	}
	data := s.output.Bytes()
	if !json.Valid(data) {
		return nil, fmt.Errorf("invalid JSON payload")
	}
	return data, nil
}

func (s *hookStdinScanner) readByte() (byte, error) {
	b, err := s.input.ReadByte()
	if err == io.EOF && s.limit.N == 0 {
		return 0, fmt.Errorf("stdin exceeds %d-byte limit (read at least %d bytes)", maxHookInputBytes, maxHookInputBytes+1)
	}
	return b, err
}

func (s *hookStdinScanner) space() error {
	for {
		b, err := s.input.Peek(1)
		if err == io.EOF {
			if s.limit.N == 0 {
				return fmt.Errorf("stdin exceeds %d-byte limit (read at least %d bytes)", maxHookInputBytes, maxHookInputBytes+1)
			}
			return nil
		}
		if err != nil {
			return err
		}
		if b[0] != ' ' && b[0] != '\n' && b[0] != '\r' && b[0] != '\t' {
			return nil
		}
		_, _ = s.input.ReadByte()
	}
}

func (s *hookStdinScanner) write(p []byte) error {
	if s.discard {
		return nil
	}
	if s.output.Len()+len(p) > maxHookOutputBytes {
		return fmt.Errorf("retained JSON exceeds %d-byte limit", maxHookOutputBytes)
	}
	_, _ = s.output.Write(p)
	return nil
}

func (s *hookStdinScanner) value(depth int) error {
	if depth > maxHookDepth {
		return fmt.Errorf("JSON nesting exceeds %d levels", maxHookDepth)
	}
	if err := s.space(); err != nil {
		return err
	}
	b, err := s.readByte()
	if err != nil {
		return err
	}
	switch b {
	case '"':
		return s.string()
	case '{', '[':
		close := byte('}')
		if b == '[' {
			close = ']'
		}
		if err := s.write([]byte{b}); err != nil {
			return err
		}
		for {
			if err := s.space(); err != nil {
				return err
			}
			next, err := s.input.Peek(1)
			if err != nil {
				return s.readError(err)
			}
			if next[0] == close {
				_, _ = s.input.ReadByte()
				return s.write([]byte{close})
			}
			if b == '{' {
				key, err := s.readByte()
				if err != nil || key != '"' {
					return fmt.Errorf("invalid JSON object key: %v", err)
				}
				if err := s.string(); err != nil {
					return err
				}
				discardValue := bytes.Equal(s.lastString, []byte(`"tool_response"`))
				if err := s.space(); err != nil {
					return err
				}
				colon, err := s.readByte()
				if err != nil || colon != ':' {
					return fmt.Errorf("invalid JSON object separator: %v", err)
				}
				if err := s.write([]byte{':'}); err != nil {
					return err
				}
				if discardValue {
					if err := s.write([]byte("null")); err != nil {
						return err
					}
					previous := s.discard
					s.discard = true
					err := s.value(depth + 1)
					s.discard = previous
					if err != nil {
						return err
					}
				} else if err := s.value(depth + 1); err != nil {
					return err
				}
			} else if err := s.value(depth + 1); err != nil {
				return err
			}
			if err := s.space(); err != nil {
				return err
			}
			sep, err := s.readByte()
			if err != nil {
				return err
			}
			if sep == close {
				return s.write([]byte{close})
			}
			if sep != ',' {
				return fmt.Errorf("invalid JSON separator %q", sep)
			}
			if err := s.write([]byte{','}); err != nil {
				return err
			}
		}
	default:
		var token []byte
		token = append(token, b)
		for {
			next, err := s.input.Peek(1)
			if err == io.EOF {
				if s.limit.N == 0 {
					return s.readError(err)
				}
				break
			}
			if err != nil {
				return err
			}
			if next[0] == ',' || next[0] == '}' || next[0] == ']' || next[0] == ' ' || next[0] == '\n' || next[0] == '\r' || next[0] == '\t' {
				break
			}
			c, err := s.readByte()
			if err != nil {
				return err
			}
			if len(token) >= maxHookStringBytes {
				return fmt.Errorf("JSON scalar exceeds %d-byte limit", maxHookStringBytes)
			}
			token = append(token, c)
		}
		return s.write(token)
	}
}

func (s *hookStdinScanner) string() error {
	token := []byte{'"'}
	escaped := false
	truncated := false
	for {
		b, err := s.readByte()
		if err != nil {
			return err
		}
		if !truncated {
			if len(token) < maxHookEncodedStringBytes {
				token = append(token, b)
			} else {
				truncated = true
				token = nil
			}
		}
		if escaped {
			escaped = false
			continue
		}
		if b == '\\' {
			escaped = true
			continue
		}
		if b == '"' {
			if !truncated && len(token) > maxHookStringBytes+2 {
				var decoded string
				if err := json.Unmarshal(token, &decoded); err != nil {
					return fmt.Errorf("invalid JSON string: %w", err)
				}
				truncated = len(decoded) > maxHookStringBytes
			}
			if truncated {
				s.lastString = nil
				return s.write([]byte(`""`))
			}
			s.lastString = token
			return s.write(token)
		}
	}
}

func (s *hookStdinScanner) readError(err error) error {
	if err == io.EOF && s.limit.N == 0 {
		return fmt.Errorf("stdin exceeds %d-byte limit (read at least %d bytes)", maxHookInputBytes, maxHookInputBytes+1)
	}
	return err
}
