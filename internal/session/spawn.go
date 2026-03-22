package session

import (
	"context"
	"fmt"
)

// SpawnOpts configures a worker session spawned from a master.
type SpawnOpts struct {
	Title          string
	Cwd            string
	Layout         LayoutMode
	ClaudeResumeID string
	CodexResumeID  string
	Prompt         string
	Detached       bool
}

// Spawn creates a new worker session owned by the given master.
func (s *Service) Spawn(ctx context.Context, masterID string, opts SpawnOpts) (StartResult, error) {
	if !validPartyID.MatchString(masterID) {
		return StartResult{}, fmt.Errorf("invalid master session name %q", masterID)
	}

	m, err := s.Store.Read(masterID)
	if err != nil {
		return StartResult{}, fmt.Errorf("read master manifest: %w", err)
	}
	if m.SessionType != "master" {
		return StartResult{}, fmt.Errorf("session %q is not a master", masterID)
	}

	cwd := opts.Cwd
	if cwd == "" {
		cwd = m.Cwd
	}

	return s.Start(ctx, StartOpts{
		Title:          opts.Title,
		Cwd:            cwd,
		Layout:         opts.Layout,
		MasterID:       masterID,
		ClaudeResumeID: opts.ClaudeResumeID,
		CodexResumeID:  opts.CodexResumeID,
		Prompt:         opts.Prompt,
		Detached:       opts.Detached,
	})
}
