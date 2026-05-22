package main

import (
	"fmt"
	"os"

	"github.com/alexivison/questmaster/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		if cmd.IsSilentError(err) {
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
