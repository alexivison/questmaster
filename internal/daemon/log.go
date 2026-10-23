//go:build linux || darwin

package daemon

import (
	"os"
)

func rotateLog(path string) error {
	if info, err := os.Stat(path); err == nil && info.Size() >= 5*1024*1024 {
		_ = os.Remove(path + ".2")
		if err := os.Rename(path+".1", path+".2"); err != nil && !os.IsNotExist(err) {
			return err
		}
		if err := os.Rename(path, path+".1"); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := dupLogFD(int(f.Fd()), 1); err != nil {
		return err
	}
	return dupLogFD(int(f.Fd()), 2)
}
