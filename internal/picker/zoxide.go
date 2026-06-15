package picker

import (
	"os/exec"
	"strings"
)

func newZoxideDirQuerier() DirQuerier {
	path, err := exec.LookPath("zoxide")
	if err != nil {
		return nil
	}
	return zoxideDirQuerier{path: path}
}

type zoxideDirQuerier struct {
	path string
}

func (q zoxideDirQuerier) QueryDirs(fragment string) ([]string, error) {
	args := []string{"query", "-l"}
	args = append(args, strings.Fields(fragment)...)

	out, err := exec.Command(q.path, args...).Output()
	if err != nil {
		return nil, err
	}
	return splitZoxideDirs(string(out)), nil
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
