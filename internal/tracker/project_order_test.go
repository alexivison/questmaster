package tracker

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func rowIDs(rows []SessionRow) []string {
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.ID)
	}
	return ids
}

func TestGroupRowsByRepoFollowsProjectOrder(t *testing.T) {
	t.Parallel()

	rows := []SessionRow{
		{ID: "qm-alpha", SessionType: "master", RepoIdentity: "/r/alpha/.git", RepoName: "alpha"},
		{ID: "qm-ungrouped", SessionType: "master"},
		{ID: "qm-beta", SessionType: "master", RepoIdentity: "/r/beta/.git", RepoName: "beta"},
	}
	tests := []struct {
		name   string
		stored []string
		want   []string
	}{
		{
			name:   "unstored projects sort alphabetically with ungrouped last",
			stored: nil,
			want:   []string{"qm-alpha", "qm-beta", "qm-ungrouped"},
		},
		{
			name:   "stored order replaces the alphabet",
			stored: []string{"/r/beta/.git", "/r/alpha/.git"},
			want:   []string{"qm-beta", "qm-alpha", "qm-ungrouped"},
		},
		{
			name:   "a stored project ranks ahead of unstored ones",
			stored: []string{"/r/beta/.git"},
			want:   []string{"qm-beta", "qm-alpha", "qm-ungrouped"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := rowIDs(GroupRowsByRepo(rows, state.NewProjectOrder(tt.stored)))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("row order = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGroupRowsByRepoMovesWorkersWithTheirMaster(t *testing.T) {
	t.Parallel()

	rows := []SessionRow{
		{ID: "qm-alpha", SessionType: "master", RepoIdentity: "/r/alpha/.git", RepoName: "alpha"},
		{ID: "qm-beta", SessionType: "master", RepoIdentity: "/r/beta/.git", RepoName: "beta"},
		{ID: "qm-beta-w", SessionType: "worker", ParentID: "qm-beta"},
	}
	got := GroupRowsByRepo(rows, state.NewProjectOrder([]string{"/r/beta/.git"}))

	if want := []string{"qm-beta", "qm-beta-w", "qm-alpha"}; !reflect.DeepEqual(rowIDs(got), want) {
		t.Fatalf("row order = %v, want %v", rowIDs(got), want)
	}
	if worker := got[1]; worker.RepoIdentity != "/r/beta/.git" || worker.RepoName != "beta" {
		t.Fatalf("worker project = %q %q, want its master's project", worker.RepoIdentity, worker.RepoName)
	}
}

func TestProjectLookupResolvesRowProjectNameAndColor(t *testing.T) {
	t.Parallel()

	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temp dir: %v", err)
	}
	repoRoot := filepath.Join(base, "example-app")
	if err := os.MkdirAll(filepath.Join(repoRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create repo: %v", err)
	}
	identity := filepath.Join(repoRoot, ".git")
	lookup := projectLookup{
		resolver: state.NewProjectResolver(),
		registry: state.ProjectRegistry{Projects: map[string]state.ProjectRecord{identity: {Name: "Dots"}}},
		colors:   map[string]state.RepoColor{identity: {Color: "green"}},
	}

	tests := []struct {
		name        string
		sessionType string
		ownColor    string
		wantDisplay string
	}{
		{name: "master takes the project color", sessionType: "master", wantDisplay: "green"},
		{name: "shell ignores the project color", sessionType: "shell", wantDisplay: ""},
		{name: "shell keeps its own color", sessionType: "shell", ownColor: "red", wantDisplay: "red"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			row := SessionRow{SessionType: tt.sessionType, DisplayColor: tt.ownColor}
			lookup.resolveRow(&row, state.Manifest{Cwd: repoRoot})

			if row.RepoIdentity != identity || row.RepoName != "Dots" || row.RepoColor != "green" {
				t.Fatalf("row project = %q %q %q, want %q Dots green", row.RepoIdentity, row.RepoName, row.RepoColor, identity)
			}
			if row.DisplayColor != tt.wantDisplay {
				t.Fatalf("display color = %q, want %q", row.DisplayColor, tt.wantDisplay)
			}
		})
	}
}
