package prstatus

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"
)

const (
	ghAuthStatusTimeout = 10 * time.Second
	ghAccountAuthorized = "success"
)

// LoggedInHosts lists the hosts that gh has an authenticated account for, sorted.
func LoggedInHosts() ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), ghAuthStatusTimeout)
	defer cancel()
	stdout, err := exec.CommandContext(ctx, "gh", "auth", "status", "--json", "hosts").Output()
	if err != nil {
		return nil, fmt.Errorf("gh auth status: %w", err)
	}
	return parseLoggedInHosts(stdout)
}

// parseLoggedInHosts reads `gh auth status --json hosts`. A host counts when one of its accounts is authorized.
func parseLoggedInHosts(data []byte) ([]string, error) {
	var status struct {
		Hosts map[string][]struct {
			State string `json:"state"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(data, &status); err != nil {
		return nil, fmt.Errorf("decode gh auth status: %w", err)
	}
	hosts := []string{}
	for host, accounts := range status.Hosts {
		for _, account := range accounts {
			if account.State == ghAccountAuthorized {
				hosts = append(hosts, strings.ToLower(host))
				break
			}
		}
	}
	sort.Strings(hosts)
	return hosts, nil
}
