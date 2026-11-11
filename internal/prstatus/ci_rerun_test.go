package prstatus

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
)

const (
	ciHead      = "0123abc"
	ciOtherHead = "4567def"
	ciFirstRun  = "2026-10-25T23:10:00Z"
	ciSecondRun = "2026-10-25T23:20:00Z"
	ciThirdRun  = "2026-10-25T23:30:00Z"
	ciPRUpdated = "2026-10-25T23:00:00Z"
)

func finishedCheck(completedAt string) string {
	return fmt.Sprintf(`{"__typename":"CheckRun","completedAt":%q}`, completedAt)
}

const runningCheck = `{"__typename":"CheckRun","completedAt":null}`

// ciPoller drives a Job against one watched PR whose head commit's CI the test controls.
// The PR's own updatedAt never moves, so only the CI facts can wake the detail fetch.
type ciPoller struct {
	t      *testing.T
	job    *Job
	now    *time.Time
	pr     state.PullRequest
	alerts []string
	head   string
	rollup string
	checks []string
}

func newCIPoller(t *testing.T) *ciPoller {
	t.Helper()
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#42")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	p := &ciPoller{t: t, job: j, now: now, pr: pr}
	empty := `{"nodes":[],"pageInfo":{"hasPreviousPage":false}}`
	j.RunGH = func(_ context.Context, _, query string) ([]byte, []byte, error) {
		const rate = `"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-27T00:00:00Z"}`
		contexts := fmt.Sprintf(`"contexts":{"nodes":[%s]}`, strings.Join(p.checks, ","))
		switch {
		case strings.Contains(query, "p0: repository") && !strings.Contains(query, "contexts(last:100)"):
			return []byte(fmt.Sprintf(`{"data":{%s,"p0":{"pullRequest":{"headRefOid":%q}}}}`, rate, p.head)), nil, nil
		case strings.Contains(query, "p0: repository"):
			rollup := fmt.Sprintf(`{"state":%q,%s}`, p.rollup, contexts)
			return []byte(fmt.Sprintf(`{"data":{"viewer":{"login":"viewer"},%s,"p0":{"pullRequest":{"title":"PR","state":"OPEN","headRefOid":%q,"updatedAt":%q,"commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}}}}`, rate, p.head, ciPRUpdated, rollup)), nil, nil
		case strings.Contains(query, "contexts(last:100)"):
			return []byte(fmt.Sprintf(`{"data":{%s,"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{%s}}}]}}}}}`, rate, contexts)), nil, nil
		case strings.Contains(query, "comments(last:"):
			return []byte(fmt.Sprintf(`{"data":{%s,"repository":{"pullRequest":{"comments":%s}}}}`, rate, empty)), nil, nil
		default:
			return []byte(fmt.Sprintf(`{"data":{%s,"repository":{"pullRequest":{"reviews":%s}}}}`, rate, empty)), nil, nil
		}
	}
	j.RunREST = func(context.Context, string, string) ([]byte, []byte, error) { return []byte(`[]`), nil, nil }
	j.SendAlert = func(_ context.Context, _, text string) (message.Delivery, error) {
		p.alerts = append(p.alerts, text)
		return message.DeliverySubmitted, nil
	}
	return p
}

// poll sets the head's CI as GitHub reports it, then runs one daemon tick two minutes after the last.
func (p *ciPoller) poll(head, rollup string, checks ...string) {
	p.t.Helper()
	p.head, p.rollup, p.checks = head, rollup, checks
	*p.now = p.now.Add(2 * time.Minute)
	if err := p.job.step(context.Background()); err != nil {
		p.t.Fatal(err)
	}
}

func (p *ciPoller) ciEvents() []state.PullRequestEvent {
	p.t.Helper()
	log, err := state.LoadPullRequestEventLog(p.job.Root, p.pr.Key)
	if err != nil {
		p.t.Fatal(err)
	}
	events := []state.PullRequestEvent{}
	for _, event := range log.Events {
		if event.Kind == "ci" {
			events = append(events, event)
		}
	}
	return events
}

// wantCI fails unless the PR has exactly these CI results, one per distinct event ID, each alerted once.
func (p *ciPoller) wantCI(results ...string) {
	p.t.Helper()
	events := p.ciEvents()
	ids := map[string]bool{}
	got := []string{}
	for _, event := range events {
		ids[event.ID] = true
		got = append(got, event.Result)
	}
	if strings.Join(got, ",") != strings.Join(results, ",") || len(ids) != len(events) {
		p.t.Fatalf("ci events = %+v, want results %v with distinct IDs", events, results)
	}
	if len(p.alerts) != len(results) {
		p.t.Fatalf("alerts = %q, want %d", p.alerts, len(results))
	}
	for i, alert := range p.alerts {
		if !strings.Contains(alert, "CI: "+results[i]) {
			p.t.Fatalf("alert %d = %q, want CI: %s", i, alert, results[i])
		}
	}
}

func TestCIRerunOnSameHeadEndingInSameFailureAlertsAgain(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun))
	p.wantCI("failure")
	p.poll(ciHead, "PENDING", runningCheck) // the rerun starts
	p.poll(ciHead, "FAILURE", finishedCheck(ciSecondRun))
	p.wantCI("failure", "failure")
}

func TestCIRerunFinishingBetweenPollsAlerts(t *testing.T) {
	t.Parallel()
	for _, result := range []string{"FAILURE", "SUCCESS"} {
		t.Run(result, func(t *testing.T) {
			t.Parallel()
			p := newCIPoller(t)
			p.poll(ciHead, result, finishedCheck(ciFirstRun))
			// No poll saw the rerun pending: the head and the result are unchanged.
			p.poll(ciHead, result, finishedCheck(ciSecondRun))
			want := strings.ToLower(result)
			p.wantCI(want, want)
		})
	}
}

func TestCIFailureThenSuccessOnSameHeadAlertsBoth(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun))
	p.poll(ciHead, "PENDING", runningCheck)
	p.poll(ciHead, "SUCCESS", finishedCheck(ciSecondRun))
	p.wantCI("failure", "success")
}

func TestCISuccessThenSameResultRerunAlerts(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	p.poll(ciHead, "SUCCESS", finishedCheck(ciFirstRun))
	p.poll(ciHead, "PENDING", runningCheck)
	p.poll(ciHead, "SUCCESS", finishedCheck(ciSecondRun))
	p.wantCI("success", "success")
}

func TestCIOneRunPolledRepeatedlyIsOneEvent(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	for range 5 {
		p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun))
	}
	p.wantCI("failure")
	// A new head is a new run even when its checks finish at the same instant.
	for range 3 {
		p.poll(ciOtherHead, "FAILURE", finishedCheck(ciFirstRun))
	}
	p.wantCI("failure", "failure")
}

func TestCIFailureWhileOtherChecksRunAlertsOncePerRun(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	// GitHub can report FAILURE while other checks still run. Only the final finish alerts again.
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun), runningCheck, runningCheck)
	p.wantCI("failure")
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun), finishedCheck(ciSecondRun), runningCheck)
	p.wantCI("failure")
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun), finishedCheck(ciSecondRun), finishedCheck(ciThirdRun))
	for range 5 {
		p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun), finishedCheck(ciSecondRun), finishedCheck(ciThirdRun))
	}
	p.wantCI("failure", "failure")
	events := p.ciEvents()
	if !strings.HasSuffix(events[1].ID, ":settled") || events[1].OccurredAt != ciThirdRun || !events[1].Finished {
		t.Fatalf("settle event = %+v", events[1])
	}
	if !strings.Contains(p.alerts[1], "CI: failure, finished ("+ciHead+")") {
		t.Fatalf("settle alert = %q", p.alerts[1])
	}
}

func TestCIEarlyFailureThenSuccessHasOnlyResultChangeEvent(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun), runningCheck)
	p.poll(ciHead, "SUCCESS", finishedCheck(ciFirstRun), finishedCheck(ciSecondRun))
	for range 5 {
		p.poll(ciHead, "SUCCESS", finishedCheck(ciFirstRun), finishedCheck(ciSecondRun))
	}
	p.wantCI("failure", "success")
	if strings.Contains(p.alerts[1], "finished") {
		t.Fatalf("result-change alert = %q", p.alerts[1])
	}
}

func TestCIStatusStoredBeforeTheCompletionFieldStaysSilentThenTracksReruns(t *testing.T) {
	t.Parallel()
	p := newCIPoller(t)
	root := p.job.Root
	// A pre-upgrade install: the status has no completion time and the first run was already alerted.
	legacy := fmt.Sprintf(`{%q:{"title":"PR","state":"open","head_sha":%q,"updated_at":%q,"review":"none","ci":"failure","changed_at":%q}}`, p.pr.Key, ciHead, ciPRUpdated, p.now.Add(-time.Minute).Format(time.RFC3339))
	if err := os.WriteFile(state.PullRequestStatusPath(root), []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	seed := state.PullRequestEvent{ID: "ci:" + ciHead + ":failure", Kind: "ci", Result: "failure", HeadSHA: ciHead, OccurredAt: ciFirstRun}
	if _, err := state.RecordPullRequestEvents(root, p.pr.Key, []state.PullRequestEvent{seed}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := state.ReadPullRequestEvents(root, p.pr.Key, "qm-live", true); err != nil {
		t.Fatal(err)
	}
	if err := state.AdvancePullRequestAlert(root, p.pr.Key, "qm-live", 1); err != nil {
		t.Fatal(err)
	}

	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun))
	p.poll(ciHead, "FAILURE", finishedCheck(ciFirstRun))
	if events := p.ciEvents(); len(events) != 1 || len(p.alerts) != 0 {
		t.Fatalf("upgrade fired: events=%+v alerts=%q", events, p.alerts)
	}

	p.poll(ciHead, "FAILURE", finishedCheck(ciSecondRun))
	if events := p.ciEvents(); len(events) != 2 || len(p.alerts) != 1 || !strings.Contains(p.alerts[0], "CI: failure") {
		t.Fatalf("rerun after upgrade: events=%+v alerts=%q", events, p.alerts)
	}
}
