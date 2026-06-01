package main

import "testing"

func TestAgentsCommandInvokesTracker(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	launched := false
	e.launchAgentsTUI = func() error { launched = true; return nil }
	if _, err := runQuest(t, e, "agents"); err != nil {
		t.Fatalf("agents: %v", err)
	}
	if !launched {
		t.Error("agents command should launch the agents tracker")
	}
}
