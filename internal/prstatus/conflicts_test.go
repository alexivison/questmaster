package prstatus

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
)

func TestFetchMergeability(t *testing.T) {
	t.Parallel()
	for _, stateName := range []string{"OPEN", "CLOSED", "MERGED"} {
		for _, mergeable := range []string{"MERGEABLE", "CONFLICTING", "UNKNOWN"} {
			t.Run(stateName+"/"+mergeable, func(t *testing.T) {
				t.Parallel()
				pr := pr(t, "owner/repo#42")
				calls := 0
				result := Fetch(context.Background(), []state.PullRequest{pr}, func(_ context.Context, _, query string) ([]byte, []byte, error) {
					calls++
					if !strings.Contains(query, "isDraft mergeable headRefOid") {
						t.Fatalf("summary query omitted mergeable: %s", query)
					}
					return []byte(fmt.Sprintf(`{"data":{"p0":{"pullRequest":{"state":%q,"mergeable":%q}}}}`, stateName, mergeable)), nil, nil
				}, time.Now())
				if calls != 1 || result.Mergeable[pr.Key] != mergeable || result.Statuses[pr.Key].Conflicts != (stateName == "OPEN" && mergeable == "CONFLICTING") {
					t.Fatalf("calls=%d result=%+v", calls, result)
				}
			})
		}
	}
}

func TestJobConflictsRetainsUnknownAndAlertsOncePerGain(t *testing.T) {
	t.Parallel()
	for _, initial := range []string{"MERGEABLE", "CONFLICTING", "UNKNOWN"} {
		t.Run(initial, func(t *testing.T) {
			t.Parallel()
			j, store, now, live := jobFixture(t)
			(*live)["qm-dead"] = true
			pr := pr(t, "owner/repo#42")
			for _, id := range []string{"qm-live", "qm-dead"} {
				if _, err := state.WatchPullRequest(store.Root(), id, pr, now.Add(-time.Hour)); err != nil {
					t.Fatal(err)
				}
			}
			mergeable, stateName := initial, "OPEN"
			summaryCalls := 0
			j.RunGH = func(_ context.Context, _, query string) ([]byte, []byte, error) {
				// The PR's update time is older than the watch and never changes. Mergeability must not fetch details.
				if !strings.Contains(query, "p0: repository") || !strings.Contains(query, "mergeable") {
					t.Fatalf("unexpected extra request: %s", query)
				}
				summaryCalls++
				return []byte(fmt.Sprintf(`{"data":{"p0":{"pullRequest":{"title":"PR","state":%q,"isDraft":true,"mergeable":%q,"updatedAt":"2026-10-25T00:00:00Z"}}}}`, stateName, mergeable)), nil, nil
			}
			j.RunREST = func(context.Context, string, string) ([]byte, []byte, error) {
				t.Fatal("conflict changes must not fetch REST details")
				return nil, nil, nil
			}
			alerts := map[string]int{}
			held := false
			j.SendAlert = func(_ context.Context, id, text string) (message.Delivery, error) {
				if !strings.Contains(text, "has conflicts") {
					t.Fatalf("conflict alert = %q", text)
				}
				if held {
					return "", nil
				}
				alerts[id]++
				return message.DeliverySubmitted, nil
			}
			expectedEvents := 0
			lastConflicts := false
			lastChangedAt := ""
			poll := func(value string, wantConflicts bool) {
				t.Helper()
				mergeable = value
				*now = now.Add(2 * time.Minute)
				if wantConflicts && !lastConflicts {
					expectedEvents++
				}
				lastConflicts = wantConflicts
				if err := j.step(context.Background()); err != nil {
					t.Fatal(err)
				}
				statuses, err := state.LoadPullRequestStatuses(store.Root())
				if err != nil || statuses[pr.Key].Conflicts != wantConflicts {
					t.Fatalf("statuses=%+v err=%v", statuses, err)
				}
				if value == "UNKNOWN" && lastChangedAt != "" && statuses[pr.Key].ChangedAt != lastChangedAt {
					t.Fatal("UNKNOWN changed the saved status timestamp")
				}
				lastChangedAt = statuses[pr.Key].ChangedAt
				log, err := state.LoadPullRequestEventLog(store.Root(), pr.Key)
				if err != nil || len(log.Events) != expectedEvents {
					t.Fatalf("events=%+v want=%d err=%v", log.Events, expectedEvents, err)
				}
				for _, event := range log.Events {
					if event.Kind != "conflicts" {
						t.Fatalf("unexpected event: %+v", event)
					}
				}
				if !held {
					for _, id := range []string{"qm-live", "qm-dead"} {
						if alerts[id] != expectedEvents {
							t.Fatalf("alerts=%v want=%d per watcher", alerts, expectedEvents)
						}
					}
				}
			}
			poll(initial, initial == "CONFLICTING")
			poll("UNKNOWN", initial == "CONFLICTING")
			poll("CONFLICTING", true)
			restarted := NewJob(j.Root, j.Tmux, j.RunGH, j.TmuxRouter)
			restarted.Now, restarted.RunREST, restarted.SendAlert = j.Now, j.RunREST, j.SendAlert
			j = restarted
			poll("UNKNOWN", true)
			poll("CONFLICTING", true)
			poll("MERGEABLE", false) // resolution is silent
			held = true
			poll("CONFLICTING", true)
			held = false
			poll("UNKNOWN", true) // pending delivery retries through the ordinary watcher cursors
			stateName = "CLOSED"
			// Closing ordinarily fetches details; seed the closed state so this poll exercises conflict clearing alone.
			if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {Title: "PR", State: "closed", Draft: true, Conflicts: true, UpdatedAt: "2026-10-25T00:00:00Z", Review: "none", CI: "none"}}, nil); err != nil {
				t.Fatal(err)
			}
			poll("CONFLICTING", false)
			if summaryCalls != 9 {
				t.Fatalf("summary calls = %d, want one per poll", summaryCalls)
			}
		})
	}
}
