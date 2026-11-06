package prstatus

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
)

func TestPendingAlertUsesCurrentHeadForCI(t *testing.T) {
	const oldHead = "a0dcbf07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const newHead = "6e3b9977bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	ci := func(id, head, result string) state.PullRequestEvent {
		return state.PullRequestEvent{ID: id, Kind: "ci", HeadSHA: head, Result: result}
	}
	settled := func(id, head, result string) state.PullRequestEvent {
		event := ci(id, head, result)
		event.Finished = true
		return event
	}
	comment := state.PullRequestEvent{ID: "comment-1", Kind: "comment"}
	for _, tc := range []struct {
		name, registryHead, checkedHead string
		checkErr                        error
		events                          []state.PullRequestEvent
		want, absent                    string
		wantCalls, wantSends            int
	}{
		{"stale CI alone", newHead, newHead, nil, []state.PullRequestEvent{ci("old", oldHead, "success")}, "", "CI:", 1, 0},
		{"stale settled CI", newHead, newHead, nil, []state.PullRequestEvent{settled("old-settled", oldHead, "failure")}, "", "CI:", 1, 0},
		{"stale CI and comment", newHead, newHead, nil, []state.PullRequestEvent{ci("old", oldHead, "success"), comment}, "1 comment", "CI:", 1, 1},
		{"current head", newHead, newHead, nil, []state.PullRequestEvent{ci("new", newHead, "success")}, "CI: success (6e3b997)", "", 1, 1},
		{"current settled CI", newHead, newHead, nil, []state.PullRequestEvent{settled("new-settled", newHead, "failure")}, "CI: failure, finished (6e3b997)", "", 1, 1},
		{"registry lags push", oldHead, newHead, nil, []state.PullRequestEvent{ci("old", oldHead, "success")}, "", "CI:", 1, 0},
		{"checked head overrides registry", oldHead, newHead, nil, []state.PullRequestEvent{ci("new", newHead, "success")}, "CI: success (6e3b997)", "", 1, 1},
		{"check error falls back", oldHead, "", errors.New("unavailable"), []state.PullRequestEvent{ci("old", oldHead, "success")}, "CI: success (a0dcbf0)", "", 1, 1},
		{"unknown event head", newHead, newHead, nil, []state.PullRequestEvent{ci("legacy", "", "success")}, "CI: success", "", 1, 1},
		{"several heads", newHead, newHead, nil, []state.PullRequestEvent{ci("new-first", newHead, "failure"), ci("old", oldHead, "failure"), ci("new-rerun", newHead, "success")}, "CI: success (6e3b997)", "failure", 1, 1},
		{"comment only", newHead, "", nil, []state.PullRequestEvent{comment}, "1 comment", "CI:", 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			j, store, now, _ := jobFixture(t)
			pr, _ := state.ParsePullRequestRef("owner/repo#12")
			if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
				t.Fatal(err)
			}
			if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {HeadSHA: tc.registryHead}}, nil); err != nil {
				t.Fatal(err)
			}
			for i := range tc.events {
				tc.events[i].OccurredAt = now.Format(time.RFC3339Nano)
			}
			if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, tc.events, nil); err != nil {
				t.Fatal(err)
			}
			calls := 0
			j.RunGH = func(_ context.Context, host, query string) ([]byte, []byte, error) {
				calls++
				if host != "github.com" || !strings.Contains(query, "headRefOid") || strings.Contains(query, "contexts(") || strings.Contains(query, "reviews(") {
					t.Fatalf("unexpected head request host=%q query=%q", host, query)
				}
				if tc.checkErr != nil {
					return nil, nil, tc.checkErr
				}
				return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100},"p0":{"pullRequest":{"headRefOid":%q}}}}`, tc.checkedHead)), nil, nil
			}
			var sent []string
			j.SendAlert = func(_ context.Context, _ string, text string) (message.Delivery, error) {
				sent = append(sent, text)
				return message.DeliverySubmitted, nil
			}
			if err := j.deliverPending(context.Background()); err != nil {
				t.Fatal(err)
			}
			if calls != tc.wantCalls || len(sent) != tc.wantSends {
				t.Fatalf("head checks=%d, alerts=%q; want %d checks and %d alerts", calls, sent, tc.wantCalls, tc.wantSends)
			}
			if len(sent) > 0 && (len(sent[0]) > alertMaxBytes || !strings.Contains(sent[0], tc.want) || (tc.absent != "" && strings.Contains(sent[0], tc.absent))) {
				t.Fatalf("alert=%q, want %q, exclude %q", sent[0], tc.want, tc.absent)
			}
			log, err := state.LoadPullRequestEventLog(store.Root(), pr.Key)
			if err != nil || log.Cursors["qm-live"] != (state.PullRequestEventCursor{AlertedSeq: int64(len(tc.events))}) || len(log.Events) != len(tc.events) {
				t.Fatalf("event log=%+v err=%v", log, err)
			}
		})
	}
}

func TestPendingCIHeadCheckRespectsRateLimitBackoff(t *testing.T) {
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	const head = "a0dcbf07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {HeadSHA: head}}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "ci-1", Kind: "ci", HeadSHA: head, Result: "success", OccurredAt: now.Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	calls := 0
	reset := now.Add(time.Minute).Format(time.RFC3339)
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		calls++
		return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":0,"resetAt":%q}},"errors":[{"message":"API rate limit exceeded"}]}`, reset)), nil, nil
	}
	j.SendAlert = func(context.Context, string, string) (message.Delivery, error) { return "", nil }
	for range 2 {
		if err := j.deliverPending(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 1 || !j.blocked[pr.Host].Equal(now.Add(time.Minute)) {
		t.Fatalf("head checks=%d, blocked until=%v", calls, j.blocked[pr.Host])
	}
}
