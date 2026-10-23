//go:build linux

package daemon

import "golang.org/x/sys/unix"

func dupLogFD(old, target int) error { return unix.Dup3(old, target, 0) }
