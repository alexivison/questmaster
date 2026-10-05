package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func readFileOrStdin(cmd *cobra.Command, path, label string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("%s file path is required", label)
	}
	if path == "-" {
		raw, err := io.ReadAll(cmd.InOrStdin())
		if err != nil {
			return "", fmt.Errorf("read %s from stdin: %w", label, err)
		}
		return string(raw), nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s file: %w", label, err)
	}
	return string(raw), nil
}

func promptFromFlags(cmd *cobra.Command, prompt, promptFile string) (string, error) {
	promptSet := cmd.Flags().Changed("prompt")
	fileSet := cmd.Flags().Changed("prompt-file")
	switch {
	case promptSet && fileSet:
		return "", fmt.Errorf("prompt accepts only one of --prompt or --prompt-file")
	case fileSet:
		return readFileOrStdin(cmd, promptFile, "prompt")
	default:
		return prompt, nil
	}
}

func messageFromArgsAndFile(cmd *cobra.Command, args []string, messageFile string) (string, error) {
	fileSet := cmd.Flags().Changed("message-file")
	switch {
	case fileSet && len(args) > 0:
		return "", fmt.Errorf("message accepts only one of message or --message-file")
	case fileSet:
		return readFileOrStdin(cmd, messageFile, "message")
	case len(args) != 1:
		return "", fmt.Errorf("message is required (pass it as an argument or with --message-file)")
	default:
		return args[0], nil
	}
}
