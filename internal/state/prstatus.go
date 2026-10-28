package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
)

func PullRequestStatusPath(root string) string { return filepath.Join(root, "pr_status.json") }

func LoadPullRequestStatuses(root string) (map[string]PullRequestStatus, error) {
	data, err := os.ReadFile(PullRequestStatusPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return map[string]PullRequestStatus{}, nil
	}
	if err != nil {
		return nil, err
	}
	var statuses map[string]PullRequestStatus
	if err := json.Unmarshal(data, &statuses); err != nil {
		return nil, err
	}
	if statuses == nil {
		statuses = map[string]PullRequestStatus{}
	}
	return statuses, nil
}

// SavePullRequestStatuses merges a fetch result with the last good values.
// Failed hosts become stale; entries without a watch are removed.
func SavePullRequestStatuses(root string, updates map[string]PullRequestStatus, failedHosts map[string]bool) error {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return err
	}
	return withFileLock(PullRequestStatusPath(root)+".lock", func() error {
		old, err := LoadPullRequestStatuses(root)
		if err != nil {
			return err
		}
		watches, err := LoadPullRequests(root)
		if err != nil {
			return err
		}
		next := make(map[string]PullRequestStatus, len(watches))
		for _, pr := range watches {
			if len(pr.Watchers) == 0 {
				continue
			}
			if status, ok := updates[pr.Key]; ok {
				prior := old[pr.Key]
				changedAt := status.ChangedAt
				status.ChangedAt = ""
				comparable := prior
				comparable.ChangedAt = ""
				// An unknown previous change time is established on this successful poll.
				if prior.ChangedAt == "" || !reflect.DeepEqual(status, comparable) {
					status.ChangedAt = changedAt
				} else {
					status.ChangedAt = prior.ChangedAt
				}
				next[pr.Key] = status
			} else if prior, ok := old[pr.Key]; ok {
				if failedHosts[pr.Host] {
					prior.Stale = true
				}
				next[pr.Key] = prior
			}
		}
		if reflect.DeepEqual(old, next) {
			return nil
		}
		data, err := json.Marshal(next)
		if err != nil {
			return err
		}
		path := PullRequestStatusPath(root)
		f, err := os.CreateTemp(root, ".pr_status-*")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())
		if _, err = f.Write(append(data, '\n')); err == nil {
			err = f.Close()
		} else {
			_ = f.Close()
		}
		if err != nil {
			return err
		}
		return os.Rename(f.Name(), path)
	})
}

func AttachPullRequestStatuses(prs []PullRequest, statuses map[string]PullRequestStatus) {
	for i := range prs {
		if status, ok := statuses[prs[i].Key]; ok {
			prs[i].Status = &status
		}
	}
}
