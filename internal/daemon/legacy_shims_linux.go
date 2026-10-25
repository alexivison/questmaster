//go:build linux

package daemon

func MigrateLegacyShims(_, _ string) error                            { return nil }
func PruneLegacyShims(_ string, _ []string, _ bool) ([]string, error) { return nil, nil }
