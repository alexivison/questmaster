package modelsuggest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

const piModelTable = `provider       model                    context max-out thinking images
anthropic      claude-example           1M      128K    yes      yes
openai-codex   example-code             400K    128K    yes      no
custom-host    vendor/model:v1          64K     8K      no       no
anthropic      claude-example           1M      128K    yes      yes
`

func TestParsePiModels(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, output string
		want         []string
	}{
		{"provider columns and duplicates", piModelTable, []string{"anthropic/claude-example", "openai-codex/example-code", "custom-host/vendor/model:v1"}},
		{"signed out", "No models available. Sign in first.\n", nil},
		{"diagnostics before table", "[Extensions]\nexample/extension loaded\n" + piModelTable, []string{"anthropic/claude-example", "openai-codex/example-code", "custom-host/vendor/model:v1"}},
		{"trailing guidance", "provider model context max-out thinking images\nUse /login to sign in\n", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := parsePiModels([]byte(tc.output))
			if err != nil || !slices.Equal(got, tc.want) {
				t.Fatalf("models = %v, %v; want %v", got, err, tc.want)
			}
		})
	}
}

func TestPiHarnessProberUsesConfiguredBinaryAndProviderExtensions(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "pi cli")
	script := "#!/bin/sh\n" +
		"[ \"$#\" = 2 ] && [ \"$1\" = --list-models ] && [ \"$2\" = --offline ] || exit 19\n" +
		"cat <<'MODELS'\n" + piModelTable + "MODELS\n"
	if err := os.WriteFile(binary, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PI_BIN", binary)
	probe := HarnessProber(" Pi ")
	if probe == nil {
		t.Fatal("Pi has no native model prober")
	}
	got, err := probe(context.Background())
	if err != nil || !slices.Equal(got, []string{"anthropic/claude-example", "openai-codex/example-code", "custom-host/vendor/model:v1"}) {
		t.Fatalf("native Pi models = %v, %v", got, err)
	}
}

func TestModelProbeBoundsOutputAndCancellation(t *testing.T) {
	t.Parallel()
	if _, err := modelProbeOutput(context.Background(), "sh", "-c", "head -c 1048577 /dev/zero"); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("oversized output error = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := modelProbeOutput(ctx, "sh", "-c", "exit 0"); err == nil {
		t.Fatal("canceled probe succeeded")
	}
	if _, err := modelProbeOutput(context.Background(), "sh", "-c", "exit 23"); err == nil {
		t.Fatal("failed listing succeeded")
	}
	var output strings.Builder
	output.WriteString("provider model context max-out thinking images\n")
	for i := 0; i <= maxProbedModels; i++ {
		fmt.Fprintf(&output, "example model-%d 1M 8K no no\n", i)
	}
	if _, err := parsePiModels([]byte(output.String())); err == nil {
		t.Fatal("unbounded model inventory accepted")
	}
}

func TestResolvePiNeverFetchesCatalog(t *testing.T) {
	t.Parallel()
	for _, available := range [][]string{{"example/model"}, nil} {
		got := Resolve(context.Background(), ResolveOptions{
			Agent: "pi", Root: t.TempDir(), Refresh: true,
			Prober: func(context.Context) ([]string, error) { return available, nil },
			Fetch: func(context.Context, string) ([]byte, error) {
				t.Error("Pi consulted an external model catalog")
				return nil, nil
			},
		})
		if !slices.Equal(ids(got.Models), available) || got.Source != SourceHarness {
			t.Fatalf("Pi resolve = %+v, want %v", got, available)
		}
	}
}
