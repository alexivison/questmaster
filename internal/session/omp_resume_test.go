//go:build linux || darwin

package session

import "testing"

func TestOmpResumeIDFromSessionFile(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "standard omp session file",
			in:   "/home/u/.omp/agent/sessions/--repo--/2026-05-30T12-00-00-000Z_1f9d2a6b9c0d1234.jsonl",
			want: "1f9d2a6b9c0d1234",
		},
		{
			name: "bare filename",
			in:   "2026-05-30T12-00-00-000Z_abcd1234ef567890.jsonl",
			want: "abcd1234ef567890",
		},
		{
			name: "not a jsonl file",
			in:   "/tmp/notes.txt",
			want: "",
		},
		{
			name: "id too short after underscore",
			in:   "ts_abc.jsonl",
			want: "",
		},
		{
			name: "empty",
			in:   "",
			want: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ompResumeIDFromSessionFile(tc.in); got != tc.want {
				t.Fatalf("ompResumeIDFromSessionFile(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestCleanOmpResumeIDRejectsUnsafe(t *testing.T) {
	if got := cleanOmpResumeID("has/slash/and.dots"); got != "" {
		t.Fatalf("expected unsafe id rejected, got %q", got)
	}
	if got := cleanOmpResumeID("1f9d2a6b9c0d1234"); got != "1f9d2a6b9c0d1234" {
		t.Fatalf("expected clean hex id preserved, got %q", got)
	}
}
