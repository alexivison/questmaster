package dirsuggest

import (
	"os/exec"
	"strings"
)

// NewZoxideDirQuerier returns the production zoxide-backed directory querier,
// or nil when zoxide is unavailable.
func NewZoxideDirQuerier() DirQuerier {
	path, err := exec.LookPath("zoxide")
	if err != nil {
		return nil
	}
	return func(fragment string) ([]string, error) {
		out, err := exec.Command(path, zoxideQueryArgs(fragment)...).Output()
		if err != nil {
			return nil, err
		}
		return splitZoxideDirs(string(out)), nil
	}
}

func zoxideQueryArgs(fragment string) []string {
	args := []string{"query", "-l", "--"}
	return append(args, strings.Fields(fragment)...)
}

func splitZoxideDirs(out string) []string {
	lines := strings.Split(out, "\n")
	dirs := make([]string, 0, len(lines))
	for _, line := range lines {
		dir := strings.TrimSpace(line)
		if dir == "" {
			continue
		}
		dirs = append(dirs, dir)
	}
	return dirs
}
