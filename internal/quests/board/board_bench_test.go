package board

import (
	"fmt"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// benchBoard builds a board over n active quests across a few projects, sized
// to a typical terminal, with the detail pane focused on the first quest.
func benchBoard(b *testing.B, n int) Model {
	b.Helper()
	lipgloss.SetColorProfile(termenv.TrueColor)
	b.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := quest.NewStore(b.TempDir())
	for i := 0; i < n; i++ {
		q := &quest.Quest{
			ID:      fmt.Sprintf("Q-%03d", i),
			Title:   fmt.Sprintf("Quest number %d with a reasonably long title", i),
			Summary: "Deliver the thing, verify it, and turn it in once the gates pass.",
			Status:  quest.StatusActive,
			Project: fmt.Sprintf("proj-%d", i%4),
			Gates: []quest.Gate{
				{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"},
				{Name: "reviewed", Type: quest.GateToggle},
			},
			Body: []quest.Block{
				{Type: quest.BlockHeading, Level: 2, Text: "Approach"},
				{Type: quest.BlockText, Text: "Some paragraph describing the approach in enough words to wrap across the detail pane a few times."},
			},
		}
		if err := s.Save(q); err != nil {
			b.Fatalf("save %s: %v", q.ID, err)
		}
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m.reload()
	return m
}

// BenchmarkBoardViewFrameCached measures the steady-state frame: repeated View
// on unchanged state must hit the frame cache and allocate nothing, the same
// property the tracker's BenchmarkTrackerNormalViewFrame guards.
func BenchmarkBoardViewFrameCached(b *testing.B) {
	m := benchBoard(b, 60)
	_ = m.View() // prime the cache

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = m.View()
	}
}

// BenchmarkBoardViewFrameRender measures the cache-miss cost: a full two-pane
// render. This is what the cache saves on every no-op message and idle tick.
func BenchmarkBoardViewFrameRender(b *testing.B) {
	m := benchBoard(b, 60)

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = m.renderFrame()
	}
}

// BenchmarkBoardIdleTickFrame measures a full poll cycle on an idle board:
// reload (fingerprint-gated, so no re-parse) plus the cached View. With nothing
// changed on disk and no live runtime, the version stays put and View hits.
func BenchmarkBoardIdleTickFrame(b *testing.B) {
	m := benchBoard(b, 60)
	_ = m.View()

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		updated, _ := m.Update(tickMsg{})
		m = updated.(Model)
		_ = m.View()
	}
}
