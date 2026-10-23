//go:build darwin

package daemon

import "golang.org/x/sys/unix"

func dupLogFD(old, target int) error { return unix.Dup2(old, target) }
