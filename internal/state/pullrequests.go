package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var shortPullRequestRef = regexp.MustCompile(`^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$`)
var pullRequestName = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

type PullRequestWatcher struct {
	SessionID string `json:"session_id"`
	AddedAt   string `json:"added_at"`
}

type PullRequest struct {
	Key      string               `json:"key"`
	Host     string               `json:"host"`
	Owner    string               `json:"owner"`
	Repo     string               `json:"repo"`
	Number   int                  `json:"number"`
	Watchers []PullRequestWatcher `json:"watchers"`
}

// ParsePullRequestRef accepts a GitHub-style URL on any host or owner/repo#number.
func ParsePullRequestRef(raw string) (PullRequest, error) {
	var host, owner, repo, number string
	if match := shortPullRequestRef.FindStringSubmatch(raw); match != nil {
		host, owner, repo, number = "github.com", match[1], match[2], match[3]
	} else {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawPath != "" {
			return PullRequest{}, fmt.Errorf("invalid PR ref %q: expected https://host/owner/repo/pull/n or owner/repo#n", raw)
		}
		parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
		if len(parts) < 4 || parts[2] != "pull" {
			return PullRequest{}, fmt.Errorf("invalid PR ref %q: expected https://host/owner/repo/pull/n or owner/repo#n", raw)
		}
		host, owner, repo, number = u.Host, parts[0], parts[1], parts[3]
	}
	n, err := strconv.Atoi(number)
	if err != nil || n < 1 || !pullRequestName.MatchString(owner) || !pullRequestName.MatchString(repo) || strings.ContainsAny(host, " \t\n\r") {
		return PullRequest{}, fmt.Errorf("invalid PR ref %q: expected a positive PR number and owner/repo", raw)
	}
	host = strings.ToLower(host)
	return PullRequest{Key: fmt.Sprintf("%s/%s/%s#%d", host, strings.ToLower(owner), strings.ToLower(repo), n), Host: host, Owner: owner, Repo: repo, Number: n}, nil
}

func PullRequestsRegistryPath(root string) string { return filepath.Join(root, "pull_requests.json") }

func LoadPullRequests(root string) ([]PullRequest, error) {
	data, err := os.ReadFile(PullRequestsRegistryPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return []PullRequest{}, nil
	}
	if err != nil {
		return nil, err
	}
	var registry struct {
		PullRequests []PullRequest `json:"pull_requests"`
	}
	if err := json.Unmarshal(data, &registry); err != nil {
		return nil, fmt.Errorf("decode pull_requests registry: %w", err)
	}
	return registry.PullRequests, nil
}

func mutatePullRequests(root string, fn func(*[]PullRequest) (int, error)) (int, error) {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return 0, err
	}
	var changed int
	err := withFileLock(PullRequestsRegistryPath(root)+".lock", func() error {
		prs, err := LoadPullRequests(root)
		if err != nil {
			return err
		}
		changed, err = fn(&prs)
		if err != nil || changed == 0 {
			return err
		}
		sort.Slice(prs, func(i, j int) bool { return prs[i].Key < prs[j].Key })
		data, err := json.Marshal(struct {
			PullRequests []PullRequest `json:"pull_requests"`
		}{prs})
		if err != nil {
			return err
		}
		path := PullRequestsRegistryPath(root)
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
			return err
		}
		if err := os.Rename(tmp, path); err != nil {
			_ = os.Remove(tmp)
			return err
		}
		return nil
	})
	return changed, err
}

func WatchPullRequest(root, sessionID string, ref PullRequest, now time.Time) (bool, error) {
	if !IsValidSessionID(sessionID) {
		return false, fmt.Errorf("invalid session id %q", sessionID)
	}
	n, err := mutatePullRequests(root, func(prs *[]PullRequest) (int, error) {
		if _, err := OpenStore(root).Read(sessionID); err != nil {
			return 0, fmt.Errorf("session %s has no live manifest: %w", sessionID, err)
		}
		for i := range *prs {
			if (*prs)[i].Key != ref.Key {
				continue
			}
			for _, watcher := range (*prs)[i].Watchers {
				if watcher.SessionID == sessionID {
					return 0, nil
				}
			}
			(*prs)[i].Watchers = append((*prs)[i].Watchers, PullRequestWatcher{sessionID, now.UTC().Format(time.RFC3339Nano)})
			return 1, nil
		}
		ref.Watchers = []PullRequestWatcher{{sessionID, now.UTC().Format(time.RFC3339Nano)}}
		*prs = append(*prs, ref)
		return 1, nil
	})
	return n != 0, err
}

func UnwatchPullRequest(root, sessionID, key string) (bool, error) {
	n, err := mutatePullRequests(root, func(prs *[]PullRequest) (int, error) {
		for i := range *prs {
			if (*prs)[i].Key != key {
				continue
			}
			for j, watcher := range (*prs)[i].Watchers {
				if watcher.SessionID != sessionID {
					continue
				}
				(*prs)[i].Watchers = append((*prs)[i].Watchers[:j], (*prs)[i].Watchers[j+1:]...)
				if len((*prs)[i].Watchers) == 0 {
					*prs = append((*prs)[:i], (*prs)[i+1:]...)
				}
				return 1, nil
			}
		}
		return 0, nil
	})
	return n != 0, err
}

// DropPullRequestWatches removes watches matching a session predicate. Dry runs count only.
func DropPullRequestWatches(root string, drop func(string) bool, dryRun bool) (int, error) {
	if dryRun {
		prs, err := LoadPullRequests(root)
		if err != nil {
			return 0, err
		}
		count := 0
		for _, pr := range prs {
			for _, watcher := range pr.Watchers {
				if drop(watcher.SessionID) {
					count++
				}
			}
		}
		return count, nil
	}
	return mutatePullRequests(root, func(prs *[]PullRequest) (int, error) {
		count := 0
		next := (*prs)[:0]
		for _, pr := range *prs {
			watchers := pr.Watchers[:0]
			for _, watcher := range pr.Watchers {
				if drop(watcher.SessionID) {
					count++
				} else {
					watchers = append(watchers, watcher)
				}
			}
			if len(watchers) > 0 {
				pr.Watchers = watchers
				next = append(next, pr)
			}
		}
		*prs = next
		return count, nil
	})
}

// LivePullRequests filters dead watchers and, when scope is non-nil, unrelated sessions.
func LivePullRequests(store *Store, scope map[string]bool) ([]PullRequest, error) {
	prs, err := LoadPullRequests(store.Root())
	if err != nil {
		return nil, err
	}
	result := make([]PullRequest, 0, len(prs))
	live := map[string]bool{}
	checked := map[string]bool{}
	for _, pr := range prs {
		watchers := make([]PullRequestWatcher, 0, len(pr.Watchers))
		for _, watcher := range pr.Watchers {
			id := watcher.SessionID
			if scope != nil && !scope[id] {
				continue
			}
			if !checked[id] {
				_, err := store.Read(id)
				live[id] = err == nil
				checked[id] = true
			}
			if live[id] {
				watchers = append(watchers, watcher)
			}
		}
		if len(watchers) > 0 {
			pr.Watchers = watchers
			result = append(result, pr)
		}
	}
	return result, nil
}
